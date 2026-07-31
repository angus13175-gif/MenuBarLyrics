import XCTest
@testable import MenuBarLyrics

@MainActor
final class PlaybackClockTests: XCTestCase {

    // MARK: - Snapshot builder helper

    private func makeSnapshot(
        elapsedTime: TimeInterval,
        isPlaying: Bool,
        playbackRate: Double? = 1.0,
        duration: TimeInterval? = 300,
        remoteTimestamp: Date? = nil,
        receivedAt: ContinuousClock.Instant = .now
    ) -> NowPlayingSnapshot {
        return NowPlayingSnapshot(
            sessionID: PlaybackSessionID(generation: 1),
            identity: .stable(bundleIdentifier: "com.test", uniqueIdentifier: "t1"),
            lyricLookupKey: LyricLookupKey(
                normalizedTitle: "song",
                normalizedArtist: "artist",
                normalizedAlbum: nil,
                roundedDuration: 300
            ),
            title: "Song",
            artist: "Artist",
            album: nil,
            duration: duration,
            elapsedTime: elapsedTime,
            remoteTimestamp: remoteTimestamp,
            playbackRate: playbackRate,
            isPlaying: isPlaying,
            receivedAtContinuous: receivedAt
        )
    }

    // MARK: - Tests

    /// Snapshot at elapsed=100, rate=1, playing; 10s later estimated should be ~110.
    func testPlayingAdvancesAt1x() {
        let clock = PlaybackClock()
        let anchor = ContinuousClock.Instant.now
        let snapshot = makeSnapshot(
            elapsedTime: 100,
            isPlaying: true,
            playbackRate: 1.0,
            receivedAt: anchor
        )
        clock.update(snapshot: snapshot)

        let now = anchor.advanced(by: .seconds(10))
        let estimated = clock.estimatedElapsed(now: now)
        XCTAssertEqual(estimated, 110, accuracy: 0.5)
    }

    /// Snapshot at elapsed=50, rate=2; 5s later estimated ~60.
    func testPlayingAdvancesAt2x() {
        let clock = PlaybackClock()
        let anchor = ContinuousClock.Instant.now
        let snapshot = makeSnapshot(
            elapsedTime: 50,
            isPlaying: true,
            playbackRate: 2.0,
            receivedAt: anchor
        )
        clock.update(snapshot: snapshot)

        let now = anchor.advanced(by: .seconds(5))
        let estimated = clock.estimatedElapsed(now: now)
        XCTAssertEqual(estimated, 60, accuracy: 0.5)
    }

    /// Snapshot at elapsed=80, playing=false; 30s later still 80.
    func testPausedDoesNotAdvance() {
        let clock = PlaybackClock()
        let anchor = ContinuousClock.Instant.now
        let snapshot = makeSnapshot(
            elapsedTime: 80,
            isPlaying: false,
            playbackRate: 1.0,
            receivedAt: anchor
        )
        clock.update(snapshot: snapshot)

        let now = anchor.advanced(by: .seconds(30))
        let estimated = clock.estimatedElapsed(now: now)
        XCTAssertEqual(estimated, 80, accuracy: 0.5)
    }

    /// First snapshot elapsed=100, then 1s later snapshot elapsed=200; after another 1s estimated ~201.
    func testSeekDetectedByLargeJump() {
        let clock = PlaybackClock()
        let anchor1 = ContinuousClock.Instant.now
        clock.update(snapshot: makeSnapshot(
            elapsedTime: 100,
            isPlaying: true,
            playbackRate: 1.0,
            receivedAt: anchor1
        ))

        let anchor2 = anchor1.advanced(by: .seconds(1))
        clock.update(snapshot: makeSnapshot(
            elapsedTime: 200,
            isPlaying: true,
            playbackRate: 1.0,
            receivedAt: anchor2
        ))

        let now = anchor2.advanced(by: .seconds(1))
        let estimated = clock.estimatedElapsed(now: now)
        XCTAssertEqual(estimated, 201, accuracy: 0.5)
    }

    /// elapsed=200, duration=210; 20s later clamped to 210.
    func testClampToDuration() {
        let clock = PlaybackClock()
        let anchor = ContinuousClock.Instant.now
        let snapshot = makeSnapshot(
            elapsedTime: 200,
            isPlaying: true,
            playbackRate: 1.0,
            duration: 210,
            receivedAt: anchor
        )
        clock.update(snapshot: snapshot)

        let now = anchor.advanced(by: .seconds(20))
        let estimated = clock.estimatedElapsed(now: now)
        XCTAssertEqual(estimated, 210, accuracy: 0.5)
    }

    /// remote timestamp 2s behind receipt; at receipt estimated ~102.
    func testRemoteTimestampCalibration() {
        let clock = PlaybackClock()
        let receiptInstant = ContinuousClock.Instant.now
        let receiptWall = Date()
        // Remote timestamp is 2s before receipt.
        let remoteTs = receiptWall.addingTimeInterval(-2)
        let snapshot = makeSnapshot(
            elapsedTime: 100,
            isPlaying: true,
            playbackRate: 1.0,
            remoteTimestamp: remoteTs,
            receivedAt: receiptInstant
        )
        clock.update(snapshot: snapshot)

        // Query at the receipt instant itself.
        let estimated = clock.estimatedElapsed(now: receiptInstant)
        // calibratedElapsed = 100 + ~2 * 1.0 = ~102
        XCTAssertEqual(estimated, 102, accuracy: 0.5)
    }

    /// rate=NaN; 10s later estimated ~110 (invalid rate falls back to 1.0).
    func testInvalidRateFallbacksToOne() {
        let clock = PlaybackClock()
        let anchor = ContinuousClock.Instant.now
        let snapshot = makeSnapshot(
            elapsedTime: 100,
            isPlaying: true,
            playbackRate: Double.nan,
            receivedAt: anchor
        )
        clock.update(snapshot: snapshot)

        let now = anchor.advanced(by: .seconds(10))
        let estimated = clock.estimatedElapsed(now: now)
        XCTAssertEqual(estimated, 110, accuracy: 0.5)
    }

    /// Regression for Bug 3: cumulative lag from 80/20 smoothing.
    ///
    /// When the player's true position is consistently ~0.2s ahead of the
    /// clock's prediction (a common scenario with transport latency), the
    /// old 80/20 blend only corrected 20% per snapshot, causing
    /// calibratedElapsed to lag persistently. After 5 consecutive snapshots
    /// each 0.2s ahead, the lag should be negligible (< 0.1s), not
    /// accumulating.
    func testNoCumulativeLagFromSmoothing() {
        let clock = PlaybackClock()
        var anchor = ContinuousClock.Instant.now

        // First snapshot: hard anchor at elapsed=100
        clock.update(snapshot: makeSnapshot(
            elapsedTime: 100, isPlaying: true, playbackRate: 1.0, receivedAt: anchor
        ))

        // 10 consecutive snapshots, each 1s apart, where the player's elapsed
        // is consistently 0.3s ahead of what the clock would predict.
        // With old 80/20 blend: after 10 steps, lag = 0.3 * 0.8^10 = 0.032s
        // But the issue is each NEW snapshot is ALSO 0.3 ahead of the
        // already-lagged prediction, so lag accumulates:
        // After step 1: calibrated = 0.8*101 + 0.2*101.3 = 101.06, true=101.3, lag=0.24
        // After step 2: prediction=102.06, player=102.3, calibrated=0.8*102.06+0.2*102.3=102.108, lag=0.192
        // The lag converges to 0.3*0.8 = 0.24 steady state, not 0.
        // With the fix (50/50 for 0.1-0.35 range), lag converges to 0.3*0.5=0.15
        // which is still > 0.1. So we need the fix to use higher new-value weight.
        for i in 1...10 {
            anchor = anchor.advanced(by: .seconds(1))
            let playerElapsed = 100.0 + Double(i) + 0.3  // always 0.3s ahead
            clock.update(snapshot: makeSnapshot(
                elapsedTime: playerElapsed,
                isPlaying: true,
                playbackRate: 1.0,
                receivedAt: anchor
            ))
        }

        // Query immediately after the last snapshot.
        let estimated = clock.estimatedElapsed(now: anchor)
        // The player reported 110.3 at the last snapshot.
        // With old 80/20: steady-state lag ~0.24, estimated ~110.06
        // With fix: should be much closer to 110.3
        XCTAssertEqual(estimated, 110.3, accuracy: 0.1)
    }

    /// Very small drift (< 0.1s) should hard-anchor, not smooth.
    func testSmallDriftHardAnchors() {
        let clock = PlaybackClock()
        let anchor0 = ContinuousClock.Instant.now
        let anchor1 = anchor0.advanced(by: .seconds(1))

        clock.update(snapshot: makeSnapshot(
            elapsedTime: 100, isPlaying: true, playbackRate: 1.0, receivedAt: anchor0
        ))

        // 1s later, player reports 0.05s ahead (within old smoothing range)
        clock.update(snapshot: makeSnapshot(
            elapsedTime: 101.05, isPlaying: true, playbackRate: 1.0, receivedAt: anchor1
        ))

        let estimated = clock.estimatedElapsed(now: anchor1)
        // Should be exactly 101.05 (hard anchor), not smoothed to 101.01
        XCTAssertEqual(estimated, 101.05, accuracy: 0.01)
    }

    /// Medium drift (0.1s-0.35s) should use higher new-value weight (50/50)
    /// to avoid cumulative lag. Old 80/20 caused persistent offset.
    func testMediumDriftUsesHigherNewWeight() {
        let clock = PlaybackClock()
        let anchor0 = ContinuousClock.Instant.now
        let anchor1 = anchor0.advanced(by: .seconds(1))

        clock.update(snapshot: makeSnapshot(
            elapsedTime: 100, isPlaying: true, playbackRate: 1.0, receivedAt: anchor0
        ))

        // 1s later, player reports 0.2s ahead (within smoothing range)
        clock.update(snapshot: makeSnapshot(
            elapsedTime: 101.2, isPlaying: true, playbackRate: 1.0, receivedAt: anchor1
        ))

        let estimated = clock.estimatedElapsed(now: anchor1)
        // With old 80/20: calibrated = 0.8*101 + 0.2*101.2 = 101.04 (lag=0.16)
        // With fix (50/50): calibrated = 0.5*101 + 0.5*101.2 = 101.1 (lag=0.1)
        // Test requires lag < 0.12, so 50/50 passes, 80/20 fails
        XCTAssertLessThan(abs(estimated - 101.2), 0.12,
                         "Clock should not lag more than 0.12s after one drift snapshot, got \(estimated) vs 101.2")
    }
}
