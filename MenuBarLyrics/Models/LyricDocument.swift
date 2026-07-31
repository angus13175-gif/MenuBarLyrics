import Foundation

public enum LyricSource: Sendable, Hashable, Codable {
    case lrclib
    case qqExperimental
    case netease
}

public struct LyricLine: Sendable, Codable {
    public let startTime: TimeInterval
    public let intervalEndTime: TimeInterval?
    public let text: String

    public init(startTime: TimeInterval, intervalEndTime: TimeInterval?, text: String) {
        self.startTime = startTime
        self.intervalEndTime = intervalEndTime
        self.text = text
    }
}

public struct LyricDocument: Sendable, Codable {
    public let lookupKey: LyricLookupKey
    public let lines: [LyricLine]
    public let source: LyricSource
    public let sourceRecordIdentifier: String?
    public let globalOffset: TimeInterval

    public init(
        lookupKey: LyricLookupKey,
        lines: [LyricLine],
        source: LyricSource,
        sourceRecordIdentifier: String?,
        globalOffset: TimeInterval
    ) {
        self.lookupKey = lookupKey
        self.lines = lines
        self.source = source
        self.sourceRecordIdentifier = sourceRecordIdentifier
        self.globalOffset = globalOffset
    }
}

public enum LyricError: Error, Sendable {
    case transport(URLError.Code)
    case http(status: Int)
    case responseTooLarge
    case decoding
    case parsing
}

public enum LyricMatchKind: Int, Sendable, Codable {
    case search = 0
    case exact = 1
}

public struct RankedLyricCandidate: Sendable, Codable {
    public let document: LyricDocument
    public let matchKind: LyricMatchKind
    public let score: Int

    public init(document: LyricDocument, matchKind: LyricMatchKind, score: Int) {
        self.document = document
        self.matchKind = matchKind
        self.score = score
    }
}

struct LyricResponse: Sendable {
    let requestID: LyricRequestID
    let result: Result<RankedLyricCandidate?, LyricError>
}

public struct CacheEntry: Sendable {
    public let candidate: RankedLyricCandidate
    public let cachedAt: Date

    public init(candidate: RankedLyricCandidate, cachedAt: Date) {
        self.candidate = candidate
        self.cachedAt = cachedAt
    }
}
