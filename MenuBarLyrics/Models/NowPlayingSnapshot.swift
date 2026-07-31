import Foundation

public struct PlaybackSessionID: Hashable, Sendable {
    public let generation: UInt64

    public init(generation: UInt64) {
        self.generation = generation
    }
}

enum TrackIdentity: Hashable, Sendable {
    case stable(bundleIdentifier: String, uniqueIdentifier: String)
    case fallback(bundleIdentifier: String, normalizedTitle: String)
}

public struct LyricLookupKey: Hashable, Sendable, Codable {
    public let normalizedTitle: String
    public let normalizedArtist: String?
    public let normalizedAlbum: String?
    public let roundedDuration: Int?

    public init(
        normalizedTitle: String,
        normalizedArtist: String?,
        normalizedAlbum: String?,
        roundedDuration: Int?
    ) {
        self.normalizedTitle = normalizedTitle
        self.normalizedArtist = normalizedArtist
        self.normalizedAlbum = normalizedAlbum
        self.roundedDuration = roundedDuration
    }
}

public struct LyricRequestID: Hashable, Sendable {
    public let sessionID: PlaybackSessionID
    public let lookupKey: LyricLookupKey
    public let requestGeneration: UInt64

    public init(sessionID: PlaybackSessionID, lookupKey: LyricLookupKey, requestGeneration: UInt64) {
        self.sessionID = sessionID
        self.lookupKey = lookupKey
        self.requestGeneration = requestGeneration
    }
}

struct NowPlayingSnapshot: Sendable {
    let sessionID: PlaybackSessionID
    let identity: TrackIdentity
    let lyricLookupKey: LyricLookupKey
    let title: String
    let artist: String?
    let album: String?
    let duration: TimeInterval?
    let elapsedTime: TimeInterval?
    let remoteTimestamp: Date?
    let playbackRate: Double?
    let isPlaying: Bool
    let receivedAtContinuous: ContinuousClock.Instant
}
