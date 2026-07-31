import XCTest
import os
@testable import MenuBarLyrics

// MARK: - Mock clients

/// Mock LRCLIB client that records call counts and returns a canned result.
private final class MockLRCLIBClient: LRCLIBClient, @unchecked Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var fetchCount: Int { count.withLock { $0 } }

    var result: RankedLyricCandidate?
    var error: LyricError?

    override init(
        session: URLSession = URLSession(configuration: .ephemeral),
        baseURL: URL = URL(string: "https://example.invalid/api")!,
        maxResponseSize: Int = 2 * 1024 * 1024
    ) {
        super.init(session: session, baseURL: baseURL, maxResponseSize: maxResponseSize)
    }

    override func fetchLyrics(
        lookupKey: LyricLookupKey,
        displayTitle: String,
        displayArtist: String?,
        displayAlbum: String?
    ) async throws -> RankedLyricCandidate? {
        count.withLock { $0 += 1 }
        if let error { throw error }
        return result
    }
}

/// Mock QQ Music client that records call counts and returns a canned result.
private final class MockQQMusicClient: QQMusicClient, @unchecked Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var fetchCount: Int { count.withLock { $0 } }

    var result: RankedLyricCandidate?
    var error: LyricError?

    override init(
        session: URLSession = URLSession(configuration: .ephemeral),
        searchBaseURL: URL = URL(string: "https://example.invalid/search")!,
        lyricBaseURL: URL = URL(string: "https://example.invalid/lyric")!,
        maxResponseSize: Int = 2 * 1024 * 1024,
        maxLyricSize: Int = 1024 * 1024
    ) {
        super.init(
            session: session,
            searchBaseURL: searchBaseURL,
            lyricBaseURL: lyricBaseURL,
            maxResponseSize: maxResponseSize,
            maxLyricSize: maxLyricSize
        )
    }

    override func fetchLyrics(
        lookupKey: LyricLookupKey,
        displayTitle: String,
        displayArtist: String?,
        displayAlbum: String?
    ) async throws -> RankedLyricCandidate? {
        count.withLock { $0 += 1 }
        if let error { throw error }
        return result
    }
}

/// Mock NetEase client that records call counts and returns a canned result.
private final class MockNetEaseClient: NetEaseClient, @unchecked Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var fetchCount: Int { count.withLock { $0 } }

    var result: RankedLyricCandidate?
    var error: LyricError?

    override init(
        session: URLSession = URLSession(configuration: .ephemeral),
        searchBaseURL: URL = URL(string: "https://example.invalid/search")!,
        lyricBaseURL: URL = URL(string: "https://example.invalid/lyric")!,
        maxResponseSize: Int = 2 * 1024 * 1024
    ) {
        super.init(
            session: session,
            searchBaseURL: searchBaseURL,
            lyricBaseURL: lyricBaseURL,
            maxResponseSize: maxResponseSize
        )
    }

    override func fetchLyrics(
        lookupKey: LyricLookupKey,
        displayTitle: String,
        displayArtist: String?,
        displayAlbum: String?
    ) async throws -> RankedLyricCandidate? {
        count.withLock { $0 += 1 }
        if let error { throw error }
        return result
    }
}

// MARK: - Tests

final class LyricRepositoryTests: XCTestCase {

    // MARK: - Helpers

    private func makeLookupKey() -> LyricLookupKey {
        LyricLookupKey(
            normalizedTitle: "song",
            normalizedArtist: "artist",
            normalizedAlbum: nil,
            roundedDuration: 200
        )
    }

    private func makeRequestID(key: LyricLookupKey? = nil) -> LyricRequestID {
        LyricRequestID(
            sessionID: PlaybackSessionID(generation: 1),
            lookupKey: key ?? makeLookupKey(),
            requestGeneration: 1
        )
    }

    private func makeCandidate() -> RankedLyricCandidate {
        let doc = LyricDocument(
            lookupKey: makeLookupKey(),
            lines: [LyricLine(startTime: 10, intervalEndTime: 20, text: "hello")],
            source: .lrclib,
            sourceRecordIdentifier: "rec-1",
            globalOffset: 0
        )
        return RankedLyricCandidate(document: doc, matchKind: .exact, score: 100)
    }

    /// Builds a `LyricRepository` backed by an isolated on-disk cache in a
    /// fresh temporary directory. This keeps tests deterministic (no leakage
    /// between tests or from the user's real cache) while still exercising the
    /// real `LyricDiskCache`.
    private func makeRepo(providers: [LyricProvider]) -> LyricRepository {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuBarLyricsTests-\(UUID().uuidString)", isDirectory: true)
        return LyricRepository(
            providers: providers,
            diskCache: LyricDiskCache(directoryURL: dir)
        )
    }

    // MARK: - Tests

    /// First call fetches from LRCLIB; second call returns the cached result
    /// without invoking the client again (fetch count stays at 1).
    func testCachesPositiveResult() async throws {
        let lrclib = MockLRCLIBClient()
        lrclib.result = makeCandidate()
        let qq = MockQQMusicClient()
        let repo = makeRepo(providers: [lrclib, qq])

        let first = await repo.fetchLyricsAsync(
            requestID: makeRequestID(),
            displayTitle: "Song",
            displayArtist: "Artist",
            displayAlbum: nil,
            playerBundleId: nil
        )
        let second = await repo.fetchLyricsAsync(
            requestID: makeRequestID(),
            displayTitle: "Song",
            displayArtist: "Artist",
            displayAlbum: nil,
            playerBundleId: nil
        )

        // Both calls resolve to the same candidate.
        let firstCandidate = try first.get()
        let secondCandidate = try second.get()
        XCTAssertNotNil(firstCandidate)
        XCTAssertNotNil(secondCandidate)
        XCTAssertEqual(
            firstCandidate?.document.sourceRecordIdentifier,
            secondCandidate?.document.sourceRecordIdentifier
        )

        // The client was hit only once; the second call was served from cache.
        XCTAssertEqual(lrclib.fetchCount, 1, "Second call should hit the positive cache")
        XCTAssertEqual(qq.fetchCount, 0, "QQ should not be consulted when LRCLIB succeeds")
    }

    /// All sources return nil -> success(nil); LRCLIB is tried first, then QQ
    /// as a fallback.
    func testReturnsNilForNoMatch() async throws {
        let lrclib = MockLRCLIBClient()
        lrclib.result = nil
        let qq = MockQQMusicClient()
        qq.result = nil
        let repo = makeRepo(providers: [lrclib, qq])

        let result = await repo.fetchLyricsAsync(
            requestID: makeRequestID(),
            displayTitle: "Song",
            displayArtist: "Artist",
            displayAlbum: nil,
            playerBundleId: nil
        )

        switch result {
        case .success(let candidate):
            XCTAssertNil(candidate, "Expected nil candidate when no source matches")
        case .failure(let error):
            XCTFail("Expected success(nil), got failure: \(error)")
        }
        XCTAssertEqual(lrclib.fetchCount, 1)
        XCTAssertEqual(qq.fetchCount, 1)
    }

    /// Falls back to QQ when LRCLIB returns nil and QQ has a match.
    func testFallsBackToQQ() async throws {
        let lrclib = MockLRCLIBClient()
        lrclib.result = nil
        let qq = MockQQMusicClient()
        qq.result = makeCandidate()
        let repo = makeRepo(providers: [lrclib, qq])

        let result = await repo.fetchLyricsAsync(
            requestID: makeRequestID(),
            displayTitle: "Song",
            displayArtist: "Artist",
            displayAlbum: nil,
            playerBundleId: nil
        )

        let candidate = try result.get()
        XCTAssertNotNil(candidate)
        XCTAssertEqual(lrclib.fetchCount, 1)
        XCTAssertEqual(qq.fetchCount, 1)
    }

    /// A transient LRCLIB error does NOT populate the negative cache, so a
    /// retry can succeed.
    func testErrorDoesNotPopulateNegativeCache() async throws {
        let lrclib = MockLRCLIBClient()
        lrclib.error = .transport(.timedOut)
        let qq = MockQQMusicClient()
        let repo = makeRepo(providers: [lrclib, qq])

        // First call fails with the transport error.
        let first = await repo.fetchLyricsAsync(
            requestID: makeRequestID(),
            displayTitle: "Song",
            displayArtist: "Artist",
            displayAlbum: nil,
            playerBundleId: nil
        )
        switch first {
        case .success: XCTFail("Expected failure")
        case .failure: break
        }

        // Now make LRCLIB succeed; the retry should not be suppressed by a
        // stale negative cache entry.
        lrclib.error = nil
        lrclib.result = makeCandidate()

        let second = await repo.fetchLyricsAsync(
            requestID: makeRequestID(),
            displayTitle: "Song",
            displayArtist: "Artist",
            displayAlbum: nil,
            playerBundleId: nil
        )
        let candidate = try second.get()
        XCTAssertNotNil(candidate, "Retry should succeed after the transient error cleared")
    }

    /// A genuine no-match populates the negative cache, so an immediate second
    /// call is served without hitting the network.
    func testNegativeCacheSuppressesRefetch() async throws {
        let lrclib = MockLRCLIBClient()
        lrclib.result = nil
        let qq = MockQQMusicClient()
        qq.result = nil
        let repo = makeRepo(providers: [lrclib, qq])

        _ = await repo.fetchLyricsAsync(
            requestID: makeRequestID(),
            displayTitle: "Song",
            displayArtist: "Artist",
            displayAlbum: nil,
            playerBundleId: nil
        )
        _ = await repo.fetchLyricsAsync(
            requestID: makeRequestID(),
            displayTitle: "Song",
            displayArtist: "Artist",
            displayAlbum: nil,
            playerBundleId: nil
        )

        // Negative cache serves the second call: each client hit only once.
        XCTAssertEqual(lrclib.fetchCount, 1)
        XCTAssertEqual(qq.fetchCount, 1)
    }

    /// Concurrent calls for the same lookup key share a single in-flight
    /// fetch task (deduplication): the client is hit once, not twice.
    func testInFlightDeduplication() async throws {
        let lrclib = MockLRCLIBClient()
        lrclib.result = makeCandidate()
        let qq = MockQQMusicClient()
        let repo = makeRepo(providers: [lrclib, qq])

        let key = makeLookupKey()
        let requestA = makeRequestID(key: key)
        let requestB = makeRequestID(key: key)
        async let a = repo.fetchLyricsAsync(
            requestID: requestA,
            displayTitle: "Song",
            displayArtist: "Artist",
            displayAlbum: nil,
            playerBundleId: nil
        )
        async let b = repo.fetchLyricsAsync(
            requestID: requestB,
            displayTitle: "Song",
            displayArtist: "Artist",
            displayAlbum: nil,
            playerBundleId: nil
        )
        let results = await [a, b]

        for result in results {
            XCTAssertNotNil(try result.get())
        }
        XCTAssertEqual(lrclib.fetchCount, 1, "Concurrent calls must share one in-flight task")
    }

    // MARK: - Player-corresponding source routing

    /// When the player is QQ Music, QQ is a primary source queried in parallel
    /// with LRCLIB. Even if LRCLIB returns nothing, QQ is still consulted
    /// (as a primary source, not just a fallback).
    func testQQPlayerRoutesQQAsPrimary() async throws {
        let lrclib = MockLRCLIBClient()
        lrclib.result = nil
        let qq = MockQQMusicClient()
        qq.result = makeCandidate()
        let repo = makeRepo(providers: [lrclib, qq])

        let result = await repo.fetchLyricsAsync(
            requestID: makeRequestID(),
            displayTitle: "Song",
            displayArtist: "Artist",
            displayAlbum: nil,
            playerBundleId: "com.tencent.QQMusicMac"
        )

        let candidate = try result.get()
        XCTAssertNotNil(candidate, "QQ as primary source should produce a match")
        XCTAssertEqual(qq.fetchCount, 1, "QQ should be queried as a primary source")
    }

    /// When the player is NetEase Music, NetEase is a primary source queried in
    /// parallel with LRCLIB.
    func testNetEasePlayerRoutesNetEaseAsPrimary() async throws {
        let lrclib = MockLRCLIBClient()
        lrclib.result = nil
        let netease = MockNetEaseClient()
        netease.result = makeCandidate()
        let repo = makeRepo(providers: [lrclib, netease])

        let result = await repo.fetchLyricsAsync(
            requestID: makeRequestID(),
            displayTitle: "Song",
            displayArtist: "Artist",
            displayAlbum: nil,
            playerBundleId: "com.netease.163music"
        )

        let candidate = try result.get()
        XCTAssertNotNil(candidate, "NetEase as primary source should produce a match")
        XCTAssertEqual(netease.fetchCount, 1, "NetEase should be queried as a primary source")
    }

    /// An unknown player bundle id falls back to LRCLIB-only as primary; other
    /// registered providers are consulted sequentially only if LRCLIB fails.
    func testUnknownPlayerFallsBackToRemainingProviders() async throws {
        let lrclib = MockLRCLIBClient()
        lrclib.result = nil
        let netease = MockNetEaseClient()
        netease.result = makeCandidate()
        let repo = makeRepo(providers: [lrclib, netease])

        let result = await repo.fetchLyricsAsync(
            requestID: makeRequestID(),
            displayTitle: "Song",
            displayArtist: "Artist",
            displayAlbum: nil,
            playerBundleId: "com.unknown.player"
        )

        let candidate = try result.get()
        XCTAssertNotNil(candidate, "NetEase should be found via fallback")
        XCTAssertEqual(lrclib.fetchCount, 1, "LRCLIB is always primary")
        XCTAssertEqual(netease.fetchCount, 1, "NetEase should be tried as a fallback")
    }
}
