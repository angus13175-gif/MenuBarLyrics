import XCTest
import os
@testable import MenuBarLyrics

private final class SettlingMetadataProvider: LyricProvider, @unchecked Sendable {
    private struct State {
        var requestedKeys: [LyricLookupKey] = []
    }

    let source: LyricSource = .lrclib
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let expectedDuration: Int?
    private let succeedStartingAtAttempt: Int

    init(expectedDuration: Int? = nil, succeedStartingAtAttempt: Int = 1) {
        self.expectedDuration = expectedDuration
        self.succeedStartingAtAttempt = succeedStartingAtAttempt
    }

    var requestedDurations: [Int?] {
        state.withLock { $0.requestedKeys.map(\.roundedDuration) }
    }

    func fetchLyrics(
        lookupKey: LyricLookupKey,
        displayTitle: String,
        displayArtist: String?,
        displayAlbum: String?
    ) async throws -> RankedLyricCandidate? {
        let attempt = state.withLock { state in
            state.requestedKeys.append(lookupKey)
            return state.requestedKeys.count
        }

        guard attempt >= succeedStartingAtAttempt,
              expectedDuration == nil || lookupKey.roundedDuration == expectedDuration else {
            return nil
        }

        let document = LyricDocument(
            lookupKey: lookupKey,
            lines: [LyricLine(startTime: 0, intervalEndTime: 10, text: "line")],
            source: source,
            sourceRecordIdentifier: "test-\(attempt)",
            globalOffset: 0
        )
        return RankedLyricCandidate(document: document, matchKind: .exact, score: 100)
    }
}

@MainActor
final class AppStateLyricFetchTests: XCTestCase {
    private func makeSnapshot(duration: Int) -> NowPlayingSnapshot {
        let key = LyricLookupKey(
            normalizedTitle: "settling song",
            normalizedArtist: "artist",
            normalizedAlbum: "album",
            roundedDuration: duration
        )
        return NowPlayingSnapshot(
            sessionID: PlaybackSessionID(generation: 9),
            identity: .stable(
                bundleIdentifier: "com.test.player",
                uniqueIdentifier: "same-track"
            ),
            lyricLookupKey: key,
            title: "Settling Song",
            artist: "Artist",
            album: "Album",
            duration: TimeInterval(duration),
            elapsedTime: 1,
            remoteTimestamp: nil,
            playbackRate: 1,
            isPlaying: true,
            receivedAtContinuous: .now
        )
    }

    private func makeRepository(provider: LyricProvider) -> LyricRepository {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateLyricFetchTests-\(UUID().uuidString)", isDirectory: true)
        return LyricRepository(
            providers: [provider],
            negativeCacheTTL: 300,
            diskCache: LyricDiskCache(directoryURL: directory)
        )
    }

    func testDebounceUsesLatestMetadataFromSamePlaybackSession() async throws {
        let provider = SettlingMetadataProvider(expectedDuration: 151)
        let appState = AppState(
            lyricDebounceDuration: .milliseconds(100),
            automaticRetryDelay: .seconds(1)
        )
        appState.configure(lyricRepo: makeRepository(provider: provider))

        appState.updateSnapshot(makeSnapshot(duration: 177))
        try await Task.sleep(for: .milliseconds(25))
        appState.updateSnapshot(makeSnapshot(duration: 151))
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(provider.requestedDurations, [151])
        guard case .loaded(_, let document) = appState.lyricsState else {
            return XCTFail("Expected lyrics to load using the settled metadata")
        }
        XCTAssertEqual(document.lookupKey.roundedDuration, 151)
    }

    func testNoResultAutomaticallyRetriesWithoutManualResearch() async throws {
        let provider = SettlingMetadataProvider(succeedStartingAtAttempt: 2)
        let appState = AppState(
            lyricDebounceDuration: .zero,
            automaticRetryDelay: .milliseconds(30)
        )
        appState.configure(lyricRepo: makeRepository(provider: provider))

        appState.updateSnapshot(makeSnapshot(duration: 151))
        try await Task.sleep(for: .milliseconds(180))

        XCTAssertEqual(provider.requestedDurations, [151, 151])
        guard case .loaded = appState.lyricsState else {
            return XCTFail("Expected the automatic retry to recover from the first no-result")
        }
    }
}
