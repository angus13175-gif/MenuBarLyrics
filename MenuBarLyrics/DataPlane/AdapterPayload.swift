import Foundation

struct AdapterPayload: Sendable {
    let bundleIdentifier: String?
    let isPlaying: Bool
    let title: String?
    let artist: String?
    let album: String?
    let duration: TimeInterval?
    let elapsedTime: TimeInterval?
    let timestampEpochMicros: Int64?
    let playbackRate: Double?
    let uniqueIdentifier: String?
}

struct AdapterStreamEnvelope: Sendable {
    let type: String
    let diff: Bool
    let payload: AdapterPayload
}

enum AdapterDecodeError: Error, Sendable {
    case lineTooLarge
    case invalidStructure
    case wrongType
    case diffNotDisabled
}

enum AdapterDecoder {
    private static let maxLineSize = 1 * 1024 * 1024

    static func decodeStreamLine(_ data: Data) throws -> AdapterStreamEnvelope {
        guard data.count <= maxLineSize else {
            throw AdapterDecodeError.lineTooLarge
        }
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = json as? [String: Any] else {
            throw AdapterDecodeError.invalidStructure
        }
        guard let type = dict["type"] as? String, type == "data" else {
            throw AdapterDecodeError.wrongType
        }
        guard let diff = dict["diff"] as? Bool, diff == false else {
            throw AdapterDecodeError.diffNotDisabled
        }
        let payloadDict = dict["payload"] as? [String: Any] ?? [:]
        let payload = try parsePayload(payloadDict)
        return AdapterStreamEnvelope(type: type, diff: diff, payload: payload)
    }

    static func decodeGetResponse(_ data: Data) throws -> AdapterPayload? {
        guard data.count <= maxLineSize else {
            throw AdapterDecodeError.lineTooLarge
        }
        // Validate that the data contains exactly one top-level JSON value
        // with no trailing content. JSONSerialization is lenient about trailing
        // data when `.allowFragments` is used, so we scan explicitly first.
        try validateSingleJSONValue(data)
        let json = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
        if json is NSNull {
            return nil
        }
        guard let dict = json as? [String: Any] else {
            throw AdapterDecodeError.invalidStructure
        }
        return try parsePayload(dict)
    }

    private static func parsePayload(_ dict: [String: Any]) throws -> AdapterPayload {
        let microsToSeconds: (Int64) -> TimeInterval = { Double($0) / 1_000_000 }

        let durationMicros = (dict["durationMicros"] as? Int64).map(microsToSeconds)
            ?? (dict["duration"] as? Double)
        let elapsedTimeMicros = (dict["elapsedTimeMicros"] as? Int64).map(microsToSeconds)
            ?? (dict["elapsedTime"] as? Double)
        let timestampMicros = dict["timestampEpochMicros"] as? Int64

        return AdapterPayload(
            bundleIdentifier: dict["bundleIdentifier"] as? String,
            isPlaying: dict["playing"] as? Bool ?? false,
            title: dict["title"] as? String,
            artist: dict["artist"] as? String,
            album: dict["album"] as? String,
            duration: durationMicros,
            elapsedTime: elapsedTimeMicros,
            timestampEpochMicros: timestampMicros,
            playbackRate: dict["playbackRate"] as? Double,
            uniqueIdentifier: dict["uniqueIdentifier"] as? String
        )
    }

    // MARK: - Single-value validation (rejects trailing JSON)

    /// Validates that `data` contains exactly one JSON value followed only by
    /// optional whitespace. Throws `.invalidStructure` for empty input, an
    /// incomplete value, or any trailing non-whitespace content.
    private static func validateSingleJSONValue(_ data: Data) throws {
        let count = data.count
        let i = skipWhitespace(data, from: 0)
        guard i < count else {
            throw AdapterDecodeError.invalidStructure
        }
        let end = try endOfValue(data, from: i)
        let after = skipWhitespace(data, from: end)
        guard after == count else {
            // Trailing non-whitespace content after the first JSON value.
            throw AdapterDecodeError.invalidStructure
        }
    }

    private static func skipWhitespace(_ data: Data, from start: Int) -> Int {
        var i = start
        while i < data.count {
            let b = data[i]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                i += 1
            } else {
                break
            }
        }
        return i
    }

    /// Returns the index just past the first JSON value starting at `start`.
    private static func endOfValue(_ data: Data, from start: Int) throws -> Int {
        let i = start
        guard i < data.count else {
            throw AdapterDecodeError.invalidStructure
        }
        let b = data[i]
        switch b {
        case 0x7B: // '{'
            return try endOfStruct(data, from: i, open: 0x7B, close: 0x7D)
        case 0x5B: // '['
            return try endOfStruct(data, from: i, open: 0x5B, close: 0x5D)
        case 0x22: // '"'
            return endOfString(data, from: i)
        case 0x74: // 't' -> true
            return try matchLiteral(data, from: i, literal: [0x74, 0x72, 0x75, 0x65])
        case 0x66: // 'f' -> false
            return try matchLiteral(data, from: i, literal: [0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E: // 'n' -> null
            return try matchLiteral(data, from: i, literal: [0x6E, 0x75, 0x6C, 0x6C])
        case 0x2D, 0x30...0x39: // '-' or digit
            return endOfNumber(data, from: i)
        default:
            throw AdapterDecodeError.invalidStructure
        }
    }

    private static func endOfStruct(_ data: Data, from start: Int, open: UInt8, close: UInt8) throws -> Int {
        var i = start + 1 // consume opening bracket
        var depth = 1
        var inString = false
        while i < data.count {
            let b = data[i]
            if inString {
                if b == 0x5C { // backslash escape: skip next byte
                    i += 2
                    continue
                }
                if b == 0x22 { // closing quote
                    inString = false
                }
                i += 1
                continue
            }
            if b == 0x22 { // opening quote
                inString = true
                i += 1
                continue
            }
            if b == open {
                depth += 1
            } else if b == close {
                depth -= 1
                if depth == 0 {
                    return i + 1
                }
            }
            i += 1
        }
        throw AdapterDecodeError.invalidStructure
    }

    private static func endOfString(_ data: Data, from start: Int) -> Int {
        var i = start + 1 // consume opening quote
        while i < data.count {
            let b = data[i]
            if b == 0x5C { // backslash escape: skip next byte
                i += 2
                continue
            }
            if b == 0x22 { // closing quote
                return i + 1
            }
            i += 1
        }
        return i // unterminated string; caller's trailing check will reject
    }

    private static func matchLiteral(_ data: Data, from start: Int, literal: [UInt8]) throws -> Int {
        let end = start + literal.count
        guard end <= data.count else {
            throw AdapterDecodeError.invalidStructure
        }
        for (offset, byte) in literal.enumerated() {
            if data[start + offset] != byte {
                throw AdapterDecodeError.invalidStructure
            }
        }
        return end
    }

    private static func endOfNumber(_ data: Data, from start: Int) -> Int {
        var i = start
        while i < data.count {
            let b = data[i]
            if (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x2B || b == 0x2E || b == 0x65 || b == 0x45 {
                i += 1
            } else {
                break
            }
        }
        return i
    }
}
