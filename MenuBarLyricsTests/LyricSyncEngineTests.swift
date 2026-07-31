import XCTest
@testable import MenuBarLyrics

final class LyricSyncEngineTests: XCTestCase {

    private let engine = LyricSyncEngine()
    private let sessionID = PlaybackSessionID(generation: 1)

    // MARK: - Lyric builders

    private func makeLine(_ start: TimeInterval, _ text: String, end: TimeInterval? = nil) -> LyricLine {
        LyricLine(startTime: start, intervalEndTime: end, text: text)
    }

    private func makeDocument(_ lines: [LyricLine]) -> LyricDocument {
        LyricDocument(
            lookupKey: LyricLookupKey(
                normalizedTitle: "song",
                normalizedArtist: "artist",
                normalizedAlbum: nil,
                roundedDuration: nil
            ),
            lines: lines,
            source: .lrclib,
            sourceRecordIdentifier: nil,
            globalOffset: 0
        )
    }

    /// Lines starting at 10, 20, 30 (end times inferred from next line's start).
    private var threeLines: [LyricLine] {
        [makeLine(10, "first"), makeLine(20, "second"), makeLine(30, "third")]
    }

    // MARK: - Tests

    /// Lyrics at 10/20/30, elapsed=25 -> lineIndex=1, phase=.playing.
    func testFindsCurrentLineByBinarySearch() {
        let doc = makeDocument(threeLines)
        let state = engine.computeState(
            elapsed: 25,
            playing: true,
            lyrics: doc,
            sessionID: sessionID,
            duration: 40
        )
        XCTAssertEqual(state.lineIndex, 1)
        XCTAssertEqual(state.phase, .playing)
        XCTAssertEqual(state.sessionID, sessionID)
        XCTAssertEqual(state.estimatedElapsed, 25)
        XCTAssertEqual(state.duration, 40)
    }

    /// elapsed=15 (midpoint of 10-20) -> lineProgress=0.5.
    func testProgressWithinLine() {
        let doc = makeDocument(threeLines)
        let state = engine.computeState(
            elapsed: 15,
            playing: true,
            lyrics: doc,
            sessionID: sessionID,
            duration: 40
        )
        XCTAssertEqual(state.lineIndex, 0)
        XCTAssertEqual(state.lineProgress, 0.5, accuracy: 0.001)
    }

    /// elapsed=5, before first line at 10 -> phase should NOT be .playing.
    func testBeforeFirstLine() {
        let doc = makeDocument(threeLines)
        let state = engine.computeState(
            elapsed: 5,
            playing: true,
            lyrics: doc,
            sessionID: sessionID,
            duration: 40
        )
        XCTAssertNotEqual(state.phase, .playing)
    }

    /// elapsed=45, past last line at 30 (duration=40) -> lineIndex=2, lineProgress=1.0.
    func testAfterLastLine() {
        let doc = makeDocument(threeLines)
        let state = engine.computeState(
            elapsed: 45,
            playing: true,
            lyrics: doc,
            sessionID: sessionID,
            duration: 40
        )
        XCTAssertEqual(state.lineIndex, 2)
        XCTAssertEqual(state.lineProgress, 1.0, accuracy: 0.001)
    }

    /// elapsed=25, playing=false -> phase=.paused.
    func testPausedPhase() {
        let doc = makeDocument(threeLines)
        let state = engine.computeState(
            elapsed: 25,
            playing: false,
            lyrics: doc,
            sessionID: sessionID,
            duration: 40
        )
        XCTAssertEqual(state.lineIndex, 1)
        XCTAssertEqual(state.phase, .paused)
    }

    /// lyrics=nil -> phase=.noLyrics, lineIndex=nil.
    func testNoLyricsShowsNoLyricsPhase() {
        let state = engine.computeState(
            elapsed: 0,
            playing: true,
            lyrics: nil,
            sessionID: nil,
            duration: nil
        )
        XCTAssertEqual(state.phase, .noLyrics)
        XCTAssertNil(state.lineIndex)
        XCTAssertEqual(state.lineProgress, 0)
    }

    /// A line with empty text -> phase=.explicitInstrumental.
    func testEmptyLineShowsInstrumental() {
        let doc = makeDocument([
            makeLine(10, "first"),
            makeLine(20, ""),  // instrumental gap
            makeLine(30, "third")
        ])
        let state = engine.computeState(
            elapsed: 25,
            playing: true,
            lyrics: doc,
            sessionID: sessionID,
            duration: 40
        )
        XCTAssertEqual(state.lineIndex, 1)
        XCTAssertEqual(state.phase, .explicitInstrumental)
    }

    /// Regression for Bug 2: normal -> instrumental -> normal sequence.
    ///
    /// The sync engine itself correctly returns .explicitInstrumental during
    /// the gap and .playing after it. The bug was that the display link
    /// stopped during .explicitInstrumental, preventing the clock from
    /// advancing past the gap. This test documents the correct engine
    /// behavior that the display link must not interrupt.
    func testNormalToInstrumentalToNormalSequence() {
        let doc = makeDocument([
            makeLine(10, "first line"),
            makeLine(20, ""),      // instrumental gap at 20-30
            makeLine(30, "third line"),
            makeLine(40, "fourth line")
        ])

        // Before first line: loadingLyrics
        let s0 = engine.computeState(elapsed: 5, playing: true, lyrics: doc, sessionID: sessionID, duration: 50)
        XCTAssertEqual(s0.phase, .loadingLyrics)

        // Normal lyric line: playing
        let s1 = engine.computeState(elapsed: 15, playing: true, lyrics: doc, sessionID: sessionID, duration: 50)
        XCTAssertEqual(s1.lineIndex, 0)
        XCTAssertEqual(s1.phase, .playing)

        // Instrumental gap: explicitInstrumental
        let s2 = engine.computeState(elapsed: 25, playing: true, lyrics: doc, sessionID: sessionID, duration: 50)
        XCTAssertEqual(s2.lineIndex, 1)
        XCTAssertEqual(s2.phase, .explicitInstrumental)

        // After gap, back to normal: playing (THIS is the transition that was frozen)
        let s3 = engine.computeState(elapsed: 35, playing: true, lyrics: doc, sessionID: sessionID, duration: 50)
        XCTAssertEqual(s3.lineIndex, 2)
        XCTAssertEqual(s3.phase, .playing)

        // Next normal line
        let s4 = engine.computeState(elapsed: 45, playing: true, lyrics: doc, sessionID: sessionID, duration: 50)
        XCTAssertEqual(s4.lineIndex, 3)
        XCTAssertEqual(s4.phase, .playing)
    }

    /// During instrumental, paused state should still be .explicitInstrumental
    /// (not .paused), and the clock should not advance.
    func testInstrumentalWhenPaused() {
        let doc = makeDocument([
            makeLine(10, "first"),
            makeLine(20, ""),
            makeLine(30, "third")
        ])
        let state = engine.computeState(
            elapsed: 25,
            playing: false,
            lyrics: doc,
            sessionID: sessionID,
            duration: 40
        )
        XCTAssertEqual(state.lineIndex, 1)
        XCTAssertEqual(state.phase, .explicitInstrumental)
    }
}
