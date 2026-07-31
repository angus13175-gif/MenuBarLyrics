import XCTest
@testable import MenuBarLyrics

final class AdapterDecoderTests: XCTestCase {

    // MARK: - Stream line decoding

    func testDecodeStreamLineWithFullPayload() throws {
        let json = """
        {"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","playing":true,"title":"Yesterday","artist":"The Beatles","album":"Help!","durationMicros":125000000,"elapsedTimeMicros":30000000,"timestampEpochMicros":1700000000000000,"playbackRate":1.0,"uniqueIdentifier":"abc123"}}
        """
        let data = Data(json.utf8)
        let envelope = try AdapterDecoder.decodeStreamLine(data)

        XCTAssertEqual(envelope.type, "data")
        XCTAssertFalse(envelope.diff)
        let payload = envelope.payload
        XCTAssertEqual(payload.bundleIdentifier, "com.apple.Music")
        XCTAssertTrue(payload.isPlaying)
        XCTAssertEqual(payload.title, "Yesterday")
        XCTAssertEqual(payload.artist, "The Beatles")
        XCTAssertEqual(payload.album, "Help!")
        assertEqual(payload.duration, 125.0)
        assertEqual(payload.elapsedTime, 30.0)
        XCTAssertEqual(payload.timestampEpochMicros, 1_700_000_000_000_000)
        XCTAssertEqual(payload.playbackRate, 1.0)
        XCTAssertEqual(payload.uniqueIdentifier, "abc123")
    }

    func testDecodeStreamLineWithEmptyPayload() throws {
        let json = #"{"type":"data","diff":false}"#
        let data = Data(json.utf8)
        let envelope = try AdapterDecoder.decodeStreamLine(data)

        XCTAssertEqual(envelope.type, "data")
        XCTAssertFalse(envelope.diff)
        let payload = envelope.payload
        XCTAssertNil(payload.bundleIdentifier)
        XCTAssertFalse(payload.isPlaying)
        XCTAssertNil(payload.title)
        XCTAssertNil(payload.artist)
        XCTAssertNil(payload.album)
        XCTAssertNil(payload.duration)
        XCTAssertNil(payload.elapsedTime)
        XCTAssertNil(payload.timestampEpochMicros)
        XCTAssertNil(payload.playbackRate)
        XCTAssertNil(payload.uniqueIdentifier)
    }

    func testDecodeStreamLineRejectsDiffTrue() {
        let json = #"{"type":"data","diff":true,"payload":{}}"#
        let data = Data(json.utf8)
        XCTAssertThrowsError(try AdapterDecoder.decodeStreamLine(data)) { error in
            guard case AdapterDecodeError.diffNotDisabled = error else {
                XCTFail("Expected diffNotDisabled, got \(error)")
                return
            }
        }
    }

    func testDecodeStreamLineRejectsWrongType() {
        let json = #"{"type":"hello","diff":false,"payload":{}}"#
        let data = Data(json.utf8)
        XCTAssertThrowsError(try AdapterDecoder.decodeStreamLine(data)) { error in
            guard case AdapterDecodeError.wrongType = error else {
                XCTFail("Expected wrongType, got \(error)")
                return
            }
        }
    }

    // MARK: - Get response decoding

    func testDecodeGetResponseWithPayload() throws {
        let json = #"{"bundleIdentifier":"com.apple.Music","playing":false,"title":"Song"}"#
        let data = Data(json.utf8)
        let payload = try AdapterDecoder.decodeGetResponse(data)
        let unwrapped = try XCTUnwrap(payload)
        XCTAssertEqual(unwrapped.bundleIdentifier, "com.apple.Music")
        XCTAssertFalse(unwrapped.isPlaying)
        XCTAssertEqual(unwrapped.title, "Song")
    }

    func testDecodeGetResponseWithNull() throws {
        let data = Data("null".utf8)
        let payload = try AdapterDecoder.decodeGetResponse(data)
        XCTAssertNil(payload)
    }

    func testDecodeGetResponseRejectsTrailingJson() {
        // Two top-level JSON objects back-to-back must be rejected.
        let json = #"{"title":"Song"}{"title":"Second"}"#
        let data = Data(json.utf8)
        XCTAssertThrowsError(try AdapterDecoder.decodeGetResponse(data)) { error in
            guard case AdapterDecodeError.invalidStructure = error else {
                XCTFail("Expected invalidStructure for trailing JSON, got \(error)")
                return
            }
        }
    }

    // MARK: - Micros conversion & fallbacks

    func testMicrosConversion() throws {
        // micros fields take precedence and convert by /1_000_000
        let json = #"{"durationMicros":2000000,"elapsedTimeMicros":500000,"timestampEpochMicros":123000000}"#
        let data = Data(json.utf8)
        let payload = try AdapterDecoder.decodeGetResponse(data)
        let unwrapped = try XCTUnwrap(payload)
        assertEqual(unwrapped.duration, 2.0)
        assertEqual(unwrapped.elapsedTime, 0.5)
        XCTAssertEqual(unwrapped.timestampEpochMicros, 123_000_000)
    }

    func testUnknownFieldsIgnored() throws {
        let json = #"{"type":"data","diff":false,"payload":{"playing":true,"someUnknownField":42,"another":"value"}}"#
        let data = Data(json.utf8)
        let envelope = try AdapterDecoder.decodeStreamLine(data)
        XCTAssertTrue(envelope.payload.isPlaying)
        // Known fields remain nil; unknown ones are ignored without error.
        XCTAssertNil(envelope.payload.title)
    }

    // MARK: - Helpers

    private func assertEqual(
        _ actual: Double?,
        _ expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("expected \(expected) but value was nil", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, accuracy: 1e-9, file: file, line: line)
    }
}
