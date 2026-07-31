import XCTest
@testable import MenuBarLyrics

final class JSONLFramerTests: XCTestCase {

    func testSingleCompleteLine() {
        let framer = JSONLFramer()
        let data = Data("hello\n".utf8)
        let lines = framer.feed(data)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0], Data("hello".utf8))
    }

    func testPartialLineBuffered() {
        let framer = JSONLFramer()
        // Feed the first half: nothing should be emitted yet.
        let first = framer.feed(Data("hel".utf8))
        XCTAssertTrue(first.isEmpty)
        // Feed the rest including the newline: now the full line appears.
        let second = framer.feed(Data("lo\n".utf8))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0], Data("hello".utf8))
    }

    func testMultipleLinesInOneChunk() {
        let framer = JSONLFramer()
        let data = Data("one\ntwo\nthree\n".utf8)
        let lines = framer.feed(data)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], Data("one".utf8))
        XCTAssertEqual(lines[1], Data("two".utf8))
        XCTAssertEqual(lines[2], Data("three".utf8))
    }

    func testNoTrailingNewlineBuffered() {
        let framer = JSONLFramer()
        // A complete line plus leftover content with no terminating newline.
        let first = framer.feed(Data("one\nincomplete".utf8))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0], Data("one".utf8))
        // The incomplete remainder is buffered; flush returns it.
        let flushed = framer.flush()
        XCTAssertEqual(flushed, Data("incomplete".utf8))
    }

    func testEmptyLinesSkipped() {
        let framer = JSONLFramer()
        let data = Data("\n\nactual\n\n".utf8)
        let lines = framer.feed(data)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0], Data("actual".utf8))
    }

    func testLineExceedingMaxSizeDropped() {
        let framer = JSONLFramer(maxLineSize: 5)
        // A line of 8 bytes exceeds the 5-byte limit and is dropped.
        let data = Data("toolong\n".utf8)
        let lines = framer.feed(data)
        XCTAssertTrue(lines.isEmpty)
        // A line within the limit is still emitted.
        let next = framer.feed(Data("ok\n".utf8))
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0], Data("ok".utf8))
    }
}
