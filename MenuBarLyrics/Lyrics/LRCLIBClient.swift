import Foundation

/// Fetches synchronized lyrics from the LRCLIB API.
///
/// The client first attempts an exact `/api/get` lookup using the track's
/// metadata and duration. When that yields no synchronized lyrics it falls back
/// to `/api/search`, scoring each result with `LyricMatcher` and returning the
/// best candidate at or above the acceptance threshold.
///
/// Marked `@unchecked Sendable` so instances can be shared across concurrency
/// domains (e.g. captured by an actor's in-flight task). The class holds only
/// immutable `let` properties and is only subclassed to override `fetchLyrics`
/// for testing, so the unchecked conformance is safe.
open class LRCLIBClient: LyricProvider, @unchecked Sendable {
    let source: LyricSource = .lrclib

    private let session: URLSession
    private let baseURL: URL
    private let maxResponseSize: Int

    /// Creates a client.
    init(
        session: URLSession = LRCLIBClient.makeSession(),
        baseURL: URL = URL(string: "https://lrclib.net/api")!,
        maxResponseSize: Int = 2 * 1024 * 1024
    ) {
        self.session = session
        self.baseURL = baseURL
        self.maxResponseSize = maxResponseSize
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        config.httpAdditionalHeaders = ["User-Agent": "MenuBarLyrics/1.0"]
        return URLSession(configuration: config)
    }

    /// Attempts to fetch a ranked lyric candidate for the given track.
    ///
    /// Tries an exact `/api/get` match first, then falls back to `/api/search`
    /// when no synchronized lyrics are found. Returns `nil` when nothing
    /// matches.
    open func fetchLyrics(
        lookupKey: LyricLookupKey,
        displayTitle: String,
        displayArtist: String?,
        displayAlbum: String?
    ) async throws -> RankedLyricCandidate? {
        if let candidate = try await exactMatch(
            lookupKey: lookupKey,
            displayTitle: displayTitle,
            displayArtist: displayArtist,
            displayAlbum: displayAlbum
        ) {
            return candidate
        }
        return try await search(
            lookupKey: lookupKey,
            displayTitle: displayTitle,
            displayArtist: displayArtist
        )
    }

    // MARK: - Exact match

    private func exactMatch(
        lookupKey: LyricLookupKey,
        displayTitle: String,
        displayArtist: String?,
        displayAlbum: String?
    ) async throws -> RankedLyricCandidate? {
        guard let url = exactMatchURL(
            displayTitle: displayTitle,
            displayArtist: displayArtist,
            displayAlbum: displayAlbum,
            duration: lookupKey.roundedDuration
        ) else { return nil }

        let (data, http) = try await get(url)
        let statusCode = http.statusCode
        // Only a 404 means "no exact match"; fall through to search. Any other
        // non-200 (500, 429, ...) is a genuine error and must propagate rather
        // than be silently masked as a no-match.
        if statusCode == 404 { return nil }
        guard statusCode == 200 else { throw LyricError.http(status: statusCode) }

        let response = try decode(LRCLIBResponse.self, from: data)
        guard let synced = response.syncedLyrics, !synced.isEmpty else { return nil }

        let duration = response.duration ?? lookupKey.roundedDuration.map(Double.init)
        guard let document = LRCParser.parse(
            synced,
            lookupKey: lookupKey,
            source: .lrclib,
            sourceRecordIdentifier: String(response.id),
            duration: duration
        ) else { return nil }

        return RankedLyricCandidate(document: document, matchKind: .exact, score: 100)
    }

    private func exactMatchURL(
        displayTitle: String,
        displayArtist: String?,
        displayAlbum: String?,
        duration: Int?
    ) -> URL? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("get"),
            resolvingAgainstBaseURL: false
        )
        var items: [URLQueryItem] = [URLQueryItem(name: "track_name", value: displayTitle)]
        if let artist = displayArtist {
            items.append(URLQueryItem(name: "artist_name", value: artist))
        }
        if let album = displayAlbum {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if let duration = duration {
            items.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        components?.queryItems = items
        return components?.url
    }

    // MARK: - Search

    private func search(
        lookupKey: LyricLookupKey,
        displayTitle: String,
        displayArtist: String?
    ) async throws -> RankedLyricCandidate? {
        let query = [displayArtist, displayTitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty, let url = searchURL(query: query) else { return nil }

        let (data, http) = try await get(url)
        let statusCode = http.statusCode
        // A non-200 here is a genuine error, not "no match".
        guard statusCode == 200 else { throw LyricError.http(status: statusCode) }

        let responses = try decode([LRCLIBResponse].self, from: data)

        var best: (response: LRCLIBResponse, score: Int)?
        for response in responses {
            guard let synced = response.syncedLyrics, !synced.isEmpty else { continue }
            guard let score = LyricMatcher.scoreCandidate(
                candidateTitle: response.trackName,
                candidateArtist: response.artistName,
                candidateAlbum: response.albumName,
                candidateDuration: response.duration,
                lookupKey: lookupKey
            ) else { continue }
            guard score >= LyricMatcher.acceptThreshold else { continue }
            if best == nil || score > best!.score {
                best = (response, score)
            }
        }
        guard let chosen = best else { return nil }

        let duration = chosen.response.duration ?? lookupKey.roundedDuration.map(Double.init)
        guard let document = LRCParser.parse(
            chosen.response.syncedLyrics!,
            lookupKey: lookupKey,
            source: .lrclib,
            sourceRecordIdentifier: String(chosen.response.id),
            duration: duration
        ) else { return nil }

        return RankedLyricCandidate(document: document, matchKind: .search, score: chosen.score)
    }

    private func searchURL(query: String) -> URL? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
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

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw LyricError.decoding
        }
    }
}

/// LRCLIB API record. Field names are camelCase and decoded from snake_case
/// JSON keys via `JSONDecoder.convertFromSnakeCase`.
private struct LRCLIBResponse: Decodable {
    let id: Int
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let syncedLyrics: String?
    let plainLyrics: String?
}
