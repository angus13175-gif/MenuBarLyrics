import XCTest
@testable import MenuBarLyrics

final class LRCParserTests: XCTestCase {

    // MARK: - Lookup key helper

    private func makeLookupKey(duration: Int? = nil) -> LyricLookupKey {
        LyricLookupKey(
            normalizedTitle: "song",
            normalizedArtist: "artist",
            normalizedAlbum: nil,
            roundedDuration: duration
        )
    }

    private func parse(
        _ lrcText: String,
        lookupKey: LyricLookupKey,
        duration: TimeInterval?
    ) -> LyricDocument? {
        LRCParser.parse(
            lrcText,
            lookupKey: lookupKey,
            source: .lrclib,
            sourceRecordIdentifier: "rec-1",
            duration: duration
        )
    }

    /// Asserts an optional TimeInterval equals `value` (uses accuracy for float compare).
    private func assertEqualEnd(
        _ actual: TimeInterval?,
        _ value: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual ?? .nan, value, accuracy: 0.001, file: file, line: line)
    }

    // MARK: - Tests

    /// 3 lines, verify startTime/text/intervalEndTime; last line endTime = duration.
    func testBasicParsing() throws {
        let lrc = """
        [00:10.00]first line
        [00:20.00]second line
        [00:30.00]third line
        """
        let doc = try XCTUnwrap(parse(lrc, lookupKey: makeLookupKey(), duration: 45))

        XCTAssertEqual(doc.lines.count, 3)

        XCTAssertEqual(doc.lines[0].startTime, 10, accuracy: 0.001)
        XCTAssertEqual(doc.lines[0].text, "first line")
        assertEqualEnd(doc.lines[0].intervalEndTime, 20)

        XCTAssertEqual(doc.lines[1].startTime, 20, accuracy: 0.001)
        XCTAssertEqual(doc.lines[1].text, "second line")
        assertEqualEnd(doc.lines[1].intervalEndTime, 30)

        XCTAssertEqual(doc.lines[2].startTime, 30, accuracy: 0.001)
        XCTAssertEqual(doc.lines[2].text, "third line")
        assertEqualEnd(doc.lines[2].intervalEndTime, 45)

        XCTAssertEqual(doc.source, .lrclib)
        XCTAssertEqual(doc.sourceRecordIdentifier, "rec-1")
        XCTAssertEqual(doc.globalOffset, 0, accuracy: 0.001)
    }

    /// [offset:500] shifts all times +0.5s, globalOffset = 0.5.
    func testOffsetApplied() throws {
        let lrc = """
        [offset:500]
        [00:10.00]line one
        [00:20.00]line two
        """
        let doc = try XCTUnwrap(parse(lrc, lookupKey: makeLookupKey(), duration: 30))

        XCTAssertEqual(doc.globalOffset, 0.5, accuracy: 0.001)
        XCTAssertEqual(doc.lines[0].startTime, 10.5, accuracy: 0.001)
        XCTAssertEqual(doc.lines[1].startTime, 20.5, accuracy: 0.001)
        assertEqualEnd(doc.lines[1].intervalEndTime, 30)
    }

    /// Filter 作词/作曲/编曲/制作人/版权 lines, keep real lyrics.
    func testMetaFiltering() throws {
        let lrc = """
        [00:01.00]作词：Someone
        [00:02.00]作曲：Else
        [00:03.00]编曲：Band
        [00:04.00]制作人：P
        [00:05.00]未经著作权人许可不得翻唱
        [00:10.00]real lyric one
        [00:20.00]real lyric two
        """
        let doc = try XCTUnwrap(parse(lrc, lookupKey: makeLookupKey(), duration: 30))

        let texts = doc.lines.map(\.text)
        XCTAssertEqual(texts, ["real lyric one", "real lyric two"])
        XCTAssertEqual(doc.lines.count, 2)
    }

    /// [00:10.00][00:30.00]Repeated -> 3 total entries (with the 00:20 line).
    func testMultiTimestamp() throws {
        let lrc = """
        [00:10.00][00:30.00]Repeated line
        [00:20.00]middle line
        """
        let doc = try XCTUnwrap(parse(lrc, lookupKey: makeLookupKey(), duration: 40))

        XCTAssertEqual(doc.lines.count, 3)
        XCTAssertEqual(doc.lines[0].startTime, 10, accuracy: 0.001)
        XCTAssertEqual(doc.lines[0].text, "Repeated line")
        XCTAssertEqual(doc.lines[1].startTime, 20, accuracy: 0.001)
        XCTAssertEqual(doc.lines[1].text, "middle line")
        XCTAssertEqual(doc.lines[2].startTime, 30, accuracy: 0.001)
        XCTAssertEqual(doc.lines[2].text, "Repeated line")
        // After sorting, the 00:30 Repeated line is last; its end = duration.
        assertEqualEnd(doc.lines[2].intervalEndTime, 40)
    }

    /// [00:10.123] -> 10.123.
    func testMillisecondsPrecision() throws {
        let lrc = """
        [00:10.123]precise line
        """
        let doc = try XCTUnwrap(parse(lrc, lookupKey: makeLookupKey(), duration: 30))

        XCTAssertEqual(doc.lines[0].startTime, 10.123, accuracy: 0.0001)
        XCTAssertEqual(doc.lines[0].text, "precise line")
    }

    /// Empty text line kept as instrumental marker.
    func testEmptyLinesPreserved() throws {
        let lrc = """
        [00:10.00]first
        [00:20.00]
        [00:30.00]third
        """
        let doc = try XCTUnwrap(parse(lrc, lookupKey: makeLookupKey(), duration: 40))

        XCTAssertEqual(doc.lines.count, 3)
        XCTAssertEqual(doc.lines[1].text, "")
        XCTAssertEqual(doc.lines[1].startTime, 20, accuracy: 0.001)
    }

    /// Input reversed, output sorted by startTime.
    func testUnsortedInputSorted() throws {
        let lrc = """
        [00:30.00]third
        [00:10.00]first
        [00:20.00]second
        """
        let doc = try XCTUnwrap(parse(lrc, lookupKey: makeLookupKey(), duration: 40))

        XCTAssertEqual(doc.lines.count, 3)
        XCTAssertEqual(doc.lines[0].startTime, 10, accuracy: 0.001)
        XCTAssertEqual(doc.lines[0].text, "first")
        XCTAssertEqual(doc.lines[1].startTime, 20, accuracy: 0.001)
        XCTAssertEqual(doc.lines[1].text, "second")
        XCTAssertEqual(doc.lines[2].startTime, 30, accuracy: 0.001)
        XCTAssertEqual(doc.lines[2].text, "third")
    }

    /// No duration param -> last line intervalEndTime = nil.
    func testLastLineWithoutDuration() throws {
        let lrc = """
        [00:10.00]first
        [00:20.00]second
        """
        let doc = try XCTUnwrap(parse(lrc, lookupKey: makeLookupKey(), duration: nil))

        XCTAssertEqual(doc.lines.count, 2)
        assertEqualEnd(doc.lines[0].intervalEndTime, 20)
        XCTAssertNil(doc.lines[1].intervalEndTime)
    }

    /// Empty string -> nil.
    func testEmptyInputReturnsNil() {
        let doc = parse("", lookupKey: makeLookupKey(), duration: 30)
        XCTAssertNil(doc)
    }
}
