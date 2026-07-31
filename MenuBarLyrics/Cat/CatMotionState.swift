import CoreGraphics
import Foundation

/// The lifecycle phases of the cat sprite.
///
/// This type intentionally contains no AppKit objects. UI code can reduce an
/// event, render the returned state, and test every transition deterministically.
enum CatMotionPhase: Equatable, Sendable {
    case disabled
    case perched
    case enteringSurface
    case wandering
    case exitingSurface

    var isSurfaceMotion: Bool {
        switch self {
        case .enteringSurface, .wandering, .exitingSurface: true
        case .disabled, .perched: false
        }
    }
}

/// Values that tune movement without changing the event/state contract.
struct CatMotionConfiguration: Equatable, Sendable {
    var perchedSize: CGSize
    var wanderingSize: CGSize
    var surfaceTransitionDuration: TimeInterval
    var wanderingVelocity: CGVector

    static let `default` = CatMotionConfiguration(
        perchedSize: CGSize(width: 16, height: 16),
        wanderingSize: CGSize(width: 32, height: 32),
        surfaceTransitionDuration: 0.42,
        wanderingVelocity: CGVector(dx: 28, dy: 0)
    )

    static func scaled(menuBarSide: CGFloat) -> CatMotionConfiguration {
        // Settings now expose 32, 40, and 48pt. Preserve the selected side
        // exactly instead of applying the retired 16/24/32 bucket mapping.
        let side = min(48, max(32, menuBarSide.rounded()))
        return CatMotionConfiguration(
            perchedSize: CGSize(width: side, height: side),
            wanderingSize: CGSize(width: side * 2, height: side * 2),
            surfaceTransitionDuration: Self.default.surfaceTransitionDuration,
            wanderingVelocity: Self.default.wanderingVelocity
        )
    }
}

/// A position-and-size animation expressed entirely in screen coordinates.
struct CatMotionTransition: Equatable, Sendable {
    enum Destination: Equatable, Sendable {
        case surface
        case menuBar
    }

    var destination: Destination
    var startScreenOrigin: CGPoint
    var endScreenOrigin: CGPoint
    var startSize: CGSize
    var endSize: CGSize
    var elapsed: TimeInterval
    var duration: TimeInterval

    var progress: CGFloat {
        guard duration > 0 else { return 1 }
        return CGFloat(min(1, max(0, elapsed / duration)))
    }
}

/// All mutable motion truth owned by the cat controller.
///
/// `authoritativeScreenOrigin` is never derived from a missing play area. A
/// play area is only supplied to `advance` as a movement boundary.
struct CatMotionState: Equatable, Sendable {
    var phase: CatMotionPhase
    var isEnabled: Bool
    var isPlaying: Bool
    var isSurfaceVisible: Bool
    var authoritativeScreenOrigin: CGPoint?
    var spriteSize: CGSize
    var wanderingVelocity: CGVector
    var transition: CatMotionTransition?

    static func initial(configuration: CatMotionConfiguration = .default) -> CatMotionState {
        CatMotionState(
            phase: .disabled,
            isEnabled: false,
            isPlaying: false,
            isSurfaceVisible: false,
            authoritativeScreenOrigin: nil,
            spriteSize: configuration.perchedSize,
            wanderingVelocity: configuration.wanderingVelocity,
            transition: nil
        )
    }
}

/// External events accepted by the pure cat state machine.
///
/// Playback is deliberately passed in as a `Bool`; this layer never polls a
/// media framework or infers playback from timing.
enum CatMotionEvent: Equatable, Sendable {
    case playbackChanged(isPlaying: Bool)
    case surfaceOpened(playAreaScreenRect: CGRect?, entryScreenOrigin: CGPoint)
    case surfaceWillClose(currentScreenOrigin: CGPoint, menuBarTargetScreenOrigin: CGPoint)
    case surfaceClosed
    case enabledChanged(isEnabled: Bool, menuBarScreenOrigin: CGPoint?)
}

/// Pure reducer and motion integrator for the cat sprite.
enum CatMotionReducer {
    static func reduce(
        state: CatMotionState,
        event: CatMotionEvent,
        configuration: CatMotionConfiguration = .default
    ) -> CatMotionState {
        var next = state

        switch event {
        case let .playbackChanged(isPlaying):
            next.isPlaying = isPlaying

        case let .enabledChanged(isEnabled, menuBarScreenOrigin):
            if next.isEnabled == isEnabled {
                return next
            }
            next.isEnabled = isEnabled
            next.transition = nil

            if isEnabled {
                next.phase = .perched
                next.spriteSize = configuration.perchedSize
                if let menuBarScreenOrigin {
                    next.authoritativeScreenOrigin = menuBarScreenOrigin
                }
            } else {
                next.phase = .disabled
                next.isSurfaceVisible = false
                // Keep the last valid origin cached for a later re-enable.
            }

        case let .surfaceOpened(playAreaScreenRect, entryScreenOrigin):
            guard next.isEnabled else { return next }
            next.isSurfaceVisible = true

            // A missing authoritative origin cannot be reconstructed from a
            // play-area rectangle. Keep it nil instead of inventing (0, 0).
            guard let start = next.authoritativeScreenOrigin else {
                next.phase = .enteringSurface
                next.transition = nil
                return next
            }

            // Preserve a pending entry transition even when the play area is
            // temporarily nil. `advance` freezes it until a boundary exists.
            let destination = playAreaScreenRect.map {
                clampedOrigin(
                    entryScreenOrigin,
                    spriteSize: configuration.wanderingSize,
                    to: $0
                )
            } ?? entryScreenOrigin
            next.phase = .enteringSurface
            next.transition = CatMotionTransition(
                destination: .surface,
                startScreenOrigin: start,
                endScreenOrigin: destination,
                startSize: next.spriteSize,
                endSize: configuration.wanderingSize,
                elapsed: 0,
                duration: configuration.surfaceTransitionDuration
            )

        case let .surfaceWillClose(currentScreenOrigin, menuBarTargetScreenOrigin):
            guard next.isEnabled else { return next }

            // Snapshot synchronously while the surface still exists. The
            // transition can then finish after the popover/panel disappears.
            next.authoritativeScreenOrigin = currentScreenOrigin
            next.phase = .exitingSurface
            next.transition = CatMotionTransition(
                destination: .menuBar,
                startScreenOrigin: currentScreenOrigin,
                endScreenOrigin: menuBarTargetScreenOrigin,
                startSize: next.spriteSize,
                endSize: configuration.perchedSize,
                elapsed: 0,
                duration: configuration.surfaceTransitionDuration
            )

        case .surfaceClosed:
            next.isSurfaceVisible = false
            // Do not clear an exit transition: it intentionally owns all
            // geometry needed to rise after playAreaScreenRect becomes nil.
            if next.phase != .exitingSurface, next.isEnabled {
                next.phase = .perched
                next.transition = nil
                next.spriteSize = configuration.perchedSize
            }
        }

        return next
    }

    /// Advances motion by `deltaTime` without reading clocks or AppKit state.
    ///
    /// A surface entry and wandering step freeze when `playAreaScreenRect` is
    /// nil. A surface exit continues because `surfaceWillClose` already
    /// captured both authoritative endpoints before the surface was hidden.
    static func advance(
        state: CatMotionState,
        deltaTime: TimeInterval,
        playAreaScreenRect: CGRect?
    ) -> CatMotionState {
        guard state.isEnabled, deltaTime > 0 else { return state }

        switch state.phase {
        case .disabled, .perched:
            return state
        case .enteringSurface:
            guard let playAreaScreenRect else { return state }
            return advanceEnteringTransition(
                state: state,
                deltaTime: deltaTime,
                playAreaScreenRect: playAreaScreenRect
            )
        case .exitingSurface:
            return advanceTransition(state: state, deltaTime: deltaTime)
        case .wandering:
            guard let playAreaScreenRect,
                  let currentOrigin = state.authoritativeScreenOrigin else {
                return state
            }
            return advanceWandering(
                state: state,
                currentOrigin: currentOrigin,
                deltaTime: deltaTime,
                playAreaScreenRect: playAreaScreenRect
            )
        }
    }

    private static func advanceTransition(
        state: CatMotionState,
        deltaTime: TimeInterval
    ) -> CatMotionState {
        guard var transition = state.transition else { return state }
        var next = state
        transition.elapsed = min(transition.duration, transition.elapsed + deltaTime)

        // Smoothstep keeps the endpoints stationary and avoids a visual snap.
        let linearProgress = transition.progress
        let easedProgress = linearProgress * linearProgress * (3 - 2 * linearProgress)
        next.authoritativeScreenOrigin = interpolate(
            transition.startScreenOrigin,
            transition.endScreenOrigin,
            progress: easedProgress
        )
        next.spriteSize = interpolate(
            transition.startSize,
            transition.endSize,
            progress: easedProgress
        )
        next.transition = transition

        if linearProgress >= 1 {
            next.transition = nil
            switch transition.destination {
            case .surface:
                next.phase = .wandering
            case .menuBar:
                next.phase = .perched
            }
        }
        return next
    }

    private static func advanceEnteringTransition(
        state: CatMotionState,
        deltaTime: TimeInterval,
        playAreaScreenRect: CGRect
    ) -> CatMotionState {
        guard var transition = state.transition else { return state }
        transition.endScreenOrigin = clampedOrigin(
            transition.endScreenOrigin,
            spriteSize: transition.endSize,
            to: playAreaScreenRect
        )
        var boundedState = state
        boundedState.transition = transition
        return advanceTransition(state: boundedState, deltaTime: deltaTime)
    }

    private static func advanceWandering(
        state: CatMotionState,
        currentOrigin: CGPoint,
        deltaTime: TimeInterval,
        playAreaScreenRect: CGRect
    ) -> CatMotionState {
        var next = state
        var velocity = state.wanderingVelocity
        var candidate = CGPoint(
            x: currentOrigin.x + velocity.dx * CGFloat(deltaTime),
            y: currentOrigin.y + velocity.dy * CGFloat(deltaTime)
        )

        let minX = playAreaScreenRect.minX
        let minY = playAreaScreenRect.minY
        let maxX = max(minX, playAreaScreenRect.maxX - state.spriteSize.width)
        let maxY = max(minY, playAreaScreenRect.maxY - state.spriteSize.height)

        if candidate.x < minX || candidate.x > maxX {
            velocity.dx = -velocity.dx
            candidate.x = min(max(candidate.x, minX), maxX)
        }
        if candidate.y < minY || candidate.y > maxY {
            velocity.dy = -velocity.dy
            candidate.y = min(max(candidate.y, minY), maxY)
        }

        next.authoritativeScreenOrigin = candidate
        next.wanderingVelocity = velocity
        return next
    }

    private static func clampedOrigin(
        _ origin: CGPoint,
        spriteSize: CGSize,
        to bounds: CGRect
    ) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - spriteSize.width)),
            y: min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - spriteSize.height))
        )
    }

    private static func interpolate(_ start: CGPoint, _ end: CGPoint, progress: CGFloat) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }

    private static func interpolate(_ start: CGSize, _ end: CGSize, progress: CGFloat) -> CGSize {
        CGSize(
            width: start.width + (end.width - start.width) * progress,
            height: start.height + (end.height - start.height) * progress
        )
    }
}
