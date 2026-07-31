import Foundation
import CoreGraphics

struct LyricRenderState: Sendable {
    let sessionID: PlaybackSessionID?
    let lineIndex: Int?
    let lineProgress: Double
    let phase: PlaybackPhase
    let estimatedElapsed: TimeInterval
    let duration: TimeInterval?
}

enum PlaybackPhase: Sendable {
    case noMedia
    case loadingLyrics
    case playing
    case paused
    case explicitInstrumental
    case noLyrics
    case helperUnavailable
}

enum MediaState: Sendable {
    case starting
    case ready
    case noMedia
    case reconnecting(attempt: Int)
    case unavailable(MediaFailure)
}

enum MediaFailure: Sendable {
    case startupTimeout
    case fatalAdapterExit(code: Int32)
    case transientRetriesExhausted
}

enum LyricsState: Sendable {
    case idle
    case loading(LyricRequestID)
    case loaded(LyricRequestID, LyricDocument)
    case noResult(LyricRequestID)
    case failed(LyricRequestID, LyricError)
}

enum MenuWidth: Sendable {
    case compact   // 80pt
    case standard  // 160pt
    case wide      // 240pt
    case iconOnly  // 24pt

    var points: CGFloat {
        switch self {
        case .compact: return 80
        case .standard: return 160
        case .wide: return 240
        case .iconOnly: return 24
        }
    }
}
