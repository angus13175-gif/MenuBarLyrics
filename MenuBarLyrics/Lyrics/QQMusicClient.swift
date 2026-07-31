import Foundation

/// Fetches synchronized lyrics from the unofficial QQ Music API.
///
/// The client searches for a track via `client_search_cp`, scores the returned
/// candidates with `LyricMatcher` and, for the best match, retrieves the
/// base64-encoded LRC via `fcg_query_lyric_new.fcg`.
///
/// Marked `@unchecked Sendable` so instances can be shared across concurrency
/// domains (it holds only immutable `let` properties and is only subclassed to
/// override `fetchLyrics` for testing).
open class QQMusicClient: LyricProvider, @unchecked Sendable {
    let source: LyricSource = .qqExperimental

    private let session: URLSession
    private let searchBaseURL: URL
    private let lyricBaseURL: URL
    private let maxResponseSize: Int
    private let maxLyricSize: Int

    init(
        session: URLSession = QQMusicClient.makeSession(),
        searchBaseURL: URL = URL(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")!,
        lyricBaseURL: URL = URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!,
        maxResponseSize: Int = 2 * 1024 * 1024,
        maxLyricSize: Int = 1024 * 1024
    ) {
        self.session = session
        self.searchBaseURL = searchBaseURL
        self.lyricBaseURL = lyricBaseURL
        self.maxResponseSize = maxResponseSize
        self.maxLyricSize = maxLyricSize
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        config.httpAdditionalHeaders = [
            "User-Agent": "MenuBarLyrics/1.0",
            "Referer": "https://y.qq.com",
        ]
        return URLSession(configuration: config)
    }

    /// Attempts to fetch a ranked lyric candidate for the given track.
    ///
    /// Searches QQ Music, scores candidates, and fetches the LRC for the best
    /// match. Returns `nil` when nothing matches.
    ///
    /// `displayAlbum` is accepted to satisfy `LyricProvider` but is not used:
    /// the QQ search endpoint does not filter by album, and album-based scoring
    /// is handled via `LyricMatcher` against the candidate's own album field.
    open func fetchLyrics(
        lookupKey: LyricLookupKey,
        displayTitle: String,
        displayArtist: String?,
        displayAlbum: String?
    ) async throws -> RankedLyricCandidate? {
        guard let songmid = try await bestSongmid(
            lookupKey: lookupKey,
            displayTitle: displayTitle,
            displayArtist: displayArtist
        ) else { return nil }

        return try await fetchLyric(songmid: songmid, lookupKey: lookupKey)
    }

    // MARK: - Search

    private func bestSongmid(
        lookupKey: LyricLookupKey,
        displayTitle: String,
        displayArtist: String?
    ) async throws -> String? {
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
              let dataDict = root["data"] as? [String: Any],
              let song = dataDict["song"] as? [String: Any],
              let list = song["list"] as? [Any] else {
            return nil
        }

        var best: (songmid: String, score: Int)?
        for entry in list {
            guard let dict = entry as? [String: Any] else { continue }
            guard let songmid = dict["songmid"] as? String else { continue }
            let songname = dict["songname"] as? String
            let albumname = dict["albumname"] as? String
            let interval = (dict["interval"] as? Int).map(Double.init)
                ?? (dict["interval"] as? Double)

            // Singer list is an array of {name: String}; join names.
            let artist: String?
            if let singers = dict["singer"] as? [Any] {
                let names = singers.compactMap { ($0 as? [String: Any])?["name"] as? String }
                artist = names.isEmpty ? nil : names.joined(separator: ", ")
            } else {
                artist = nil
            }

            guard let score = LyricMatcher.scoreCandidate(
                candidateTitle: songname,
                candidateArtist: artist,
                candidateAlbum: albumname,
                candidateDuration: interval,
                lookupKey: lookupKey
            ) else { continue }
            guard score >= LyricMatcher.acceptThreshold else { continue }
            if best == nil || score > best!.score {
                best = (songmid, score)
            }
        }
        return best?.songmid
    }

    private func searchURL(query: String) -> URL? {
        var components = URLComponents(
            url: searchBaseURL,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "n", value: "5"),
            URLQueryItem(name: "w", value: query),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    // MARK: - Lyric fetch

    private func fetchLyric(songmid: String, lookupKey: LyricLookupKey) async throws -> RankedLyricCandidate? {
        guard let url = lyricURL(songmid: songmid) else { return nil }
        let (data, http) = try await get(url)
        guard http.statusCode == 200 else { return nil }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw LyricError.decoding
        }

        guard let dict = json as? [String: Any] else { return nil }
        // QQ Music may return a base64 "lyric" field (LRC) and a "trans"
        // translation field. We only consume the base lyric.
        guard let lyricB64 = dict["lyric"] as? String, !lyricB64.isEmpty else { return nil }

        guard let decoded = Data(base64Encoded: lyricB64), !decoded.isEmpty else {
            return nil
        }
        guard decoded.count <= maxLyricSize else { throw LyricError.responseTooLarge }

        guard let lrcText = String(data: decoded, encoding: .utf8), !lrcText.isEmpty else {
            return nil
        }

        let duration = lookupKey.roundedDuration.map(Double.init)
        guard let document = LRCParser.parse(
            lrcText,
            lookupKey: lookupKey,
            source: .qqExperimental,
            sourceRecordIdentifier: songmid,
            duration: duration
        ) else { return nil }

        return RankedLyricCandidate(document: document, matchKind: .search, score: 100)
    }

    private func lyricURL(songmid: String) -> URL? {
        var components = URLComponents(
            url: lyricBaseURL,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "songmid", value: songmid),
            URLQueryItem(name: "pcachetime", value: String(Int(Date().timeIntervalSince1970))),
            URLQueryItem(name: "format", value: "json"),
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
