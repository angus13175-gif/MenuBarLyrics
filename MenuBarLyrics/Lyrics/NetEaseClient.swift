import Foundation

/// Fetches synchronized lyrics from the NetEase Cloud Music (music.163.com)
/// public API.
///
/// The client searches for a track via `/api/search/get`, scores the returned
/// candidates with `LyricMatcher` (NetEase reports duration in milliseconds,
/// converted to seconds before scoring) and, for the best match, retrieves the
/// LRC text via `/api/song/lyric`.
///
/// The NetEase API is anonymous: no login, cookie, or rate-limit token is
/// required. Both endpoints accept a `Referer: https://music.163.com` header.
///
/// Marked `@unchecked Sendable` so instances can be shared across concurrency
/// domains (it holds only immutable `let` properties and is only subclassed to
/// override `fetchLyrics` for testing).
open class NetEaseClient: LyricProvider, @unchecked Sendable {
    let source: LyricSource = .netease

    private let session: URLSession
    private let searchBaseURL: URL
    private let lyricBaseURL: URL
    private let maxResponseSize: Int

    init(
        session: URLSession = NetEaseClient.makeSession(),
        searchBaseURL: URL = URL(string: "https://music.163.com/api/search/get")!,
        lyricBaseURL: URL = URL(string: "https://music.163.com/api/song/lyric")!,
        maxResponseSize: Int = 2 * 1024 * 1024
    ) {
        self.session = session
        self.searchBaseURL = searchBaseURL
        self.lyricBaseURL = lyricBaseURL
        self.maxResponseSize = maxResponseSize
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        config.httpAdditionalHeaders = [
            "User-Agent": "MenuBarLyrics/1.0",
            "Referer": "https://music.163.com",
        ]
        return URLSession(configuration: config)
    }

    /// Attempts to fetch a ranked lyric candidate for the given track.
    ///
    /// Searches NetEase Cloud Music, scores candidates, and fetches the LRC for
    /// the best match. Returns `nil` when nothing matches.
    ///
    /// `displayAlbum` is accepted to satisfy `LyricProvider` but is not used in
    /// the search query; album-based scoring is handled by `LyricMatcher`
    /// against the candidate's own album field.
    open func fetchLyrics(
        lookupKey: LyricLookupKey,
        displayTitle: String,
        displayArtist: String?,
        displayAlbum: String?
    ) async throws -> RankedLyricCandidate? {
        guard let best = try await bestSong(
            lookupKey: lookupKey,
            displayTitle: displayTitle,
            displayArtist: displayArtist
        ) else { return nil }

        return try await fetchLyric(songID: best.id, score: best.score, lookupKey: lookupKey)
    }

    // MARK: - Search

    private func bestSong(
        lookupKey: LyricLookupKey,
        displayTitle: String,
        displayArtist: String?
    ) async throws -> (id: Int, score: Int)? {
        let query = [displayArtist, displayTitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty, let url = searchURL(query: query) else { return nil }

        let (data, http) = try await get(url)
        guard http.statusCode == 200 else { return nil }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw LyricError.decoding
        }

        guard let root = json as? [String: Any],
              let result = root["result"] as? [String: Any],
              let songs = result["songs"] as? [Any] else {
            return nil
        }

        var best: (id: Int, score: Int)?
        for entry in songs {
            guard let dict = entry as? [String: Any] else { continue }
            guard let id = dict["id"] as? Int else { continue }
            let name = dict["name"] as? String

            // Artists list is an array of {name: String}; join names.
            let artist: String?
            if let artists = dict["artists"] as? [Any] {
                let names = artists.compactMap { ($0 as? [String: Any])?["name"] as? String }
                artist = names.isEmpty ? nil : names.joined(separator: ", ")
            } else {
                artist = nil
            }

            // Album is a nested {name: String} dict.
            let album: String?
            if let albumDict = dict["album"] as? [String: Any] {
                album = albumDict["name"] as? String
            } else {
                album = nil
            }

            // NetEase reports duration in milliseconds; convert to seconds.
            let durationSeconds: Double?
            if let durationMs = dict["duration"] as? Int {
                durationSeconds = Double(durationMs) / 1000.0
            } else if let durationMs = dict["duration"] as? Double {
                durationSeconds = durationMs / 1000.0
            } else {
                durationSeconds = nil
            }

            guard let score = LyricMatcher.scoreCandidate(
                candidateTitle: name,
                candidateArtist: artist,
                candidateAlbum: album,
                candidateDuration: durationSeconds,
                lookupKey: lookupKey
            ) else { continue }
            guard score >= LyricMatcher.acceptThreshold else { continue }
            if best == nil || score > best!.score {
                best = (id, score)
            }
        }
        return best
    }

    private func searchURL(query: String) -> URL? {
        var components = URLComponents(
            url: searchBaseURL,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "s", value: query),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        return components?.url
    }

    // MARK: - Lyric fetch

    private func fetchLyric(
        songID: Int,
        score: Int,
        lookupKey: LyricLookupKey
    ) async throws -> RankedLyricCandidate? {
        guard let url = lyricURL(songID: songID) else { return nil }
        let (data, http) = try await get(url)
        guard http.statusCode == 200 else { return nil }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw LyricError.decoding
        }

        guard let dict = json as? [String: Any] else { return nil }
        // NetEase returns the LRC text under `lrc.lyric`. A `tlyric.lyric`
        // translation field may also be present but is not consumed here.
        guard let lrcContainer = dict["lrc"] as? [String: Any],
              let lrcText = lrcContainer["lyric"] as? String,
              !lrcText.isEmpty else {
            return nil
        }

        let duration = lookupKey.roundedDuration.map(Double.init)
        guard let document = LRCParser.parse(
            lrcText,
            lookupKey: lookupKey,
            source: .netease,
            sourceRecordIdentifier: String(songID),
            duration: duration
        ) else { return nil }

        return RankedLyricCandidate(document: document, matchKind: .search, score: score)
    }

    private func lyricURL(songID: Int) -> URL? {
        var components = URLComponents(
            url: lyricBaseURL,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "id", value: String(songID)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "kv", value: "1"),
            URLQueryItem(name: "tv", value: "-1"),
        ]
        return components?.url
    }

    // MARK: - Networking

    private func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw LyricError.transport(urlError.code)
        }
        guard data.count <= maxResponseSize else { throw LyricError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else { throw LyricError.decoding }
        return (data, http)
    }
}
