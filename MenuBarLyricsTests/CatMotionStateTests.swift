import CoreGraphics
import XCTest
@testable import MenuBarLyrics

final class CatMotionStateTests: XCTestCase {
    private let configuration = CatMotionConfiguration(
        perchedSize: CGSize(width: 20, height: 20),
        wanderingSize: CGSize(width: 40, height: 30),
        surfaceTransitionDuration: 1,
        wanderingVelocity: CGVector(dx: 20, dy: 0)
    )

    func testInitialStateIsDisabledByDefault() {
        let state = CatMotionState.initial(configuration: configuration)

        XCTAssertEqual(state.phase, .disabled)
        XCTAssertFalse(state.isEnabled)
        XCTAssertNil(state.authoritativeScreenOrigin)
    }

    func testScaledConfigurationUsesSelectedMenuAndPanelSizes() {
        let standard = CatMotionConfiguration.scaled(menuBarSide: 32)
        let large = CatMotionConfiguration.scaled(menuBarSide: 40)
        let extraLarge = CatMotionConfiguration.scaled(menuBarSide: 48)

        XCTAssertEqual(standard.perchedSize.width, 32)
        XCTAssertEqual(standard.wanderingSize.width, 64)
        XCTAssertEqual(large.perchedSize.width, 40)
        XCTAssertEqual(large.wanderingSize.width, 80)
        XCTAssertEqual(extraLarge.perchedSize.width, 48)
        XCTAssertEqual(extraLarge.wanderingSize.width, 96)
    }

    func testSurfacePhasesTakePresentationPriority() {
        XCTAssertTrue(CatMotionPhase.enteringSurface.isSurfaceMotion)
        XCTAssertTrue(CatMotionPhase.wandering.isSurfaceMotion)
        XCTAssertTrue(CatMotionPhase.exitingSurface.isSurfaceMotion)
        XCTAssertFalse(CatMotionPhase.perched.isSurfaceMotion)
    }

    func testPlaybackChangedUsesExternalBooleanAsTruth() {
        let initial = CatMotionState.initial(configuration: configuration)
        let playing = CatMotionReducer.reduce(
            state: initial,
            event: .playbackChanged(isPlaying: true),
            configuration: configuration
        )
        let paused = CatMotionReducer.reduce(
            state: playing,
            event: .playbackChanged(isPlaying: false),
            configuration: configuration
        )

        XCTAssertTrue(playing.isPlaying)
        XCTAssertFalse(paused.isPlaying)
    }

    func testSurfaceWillCloseSnapshotsOriginBeforeSurfaceClosed() throws {
        var state = enabledState(origin: CGPoint(x: 100, y: 500))
        state.phase = .wandering
        state.isSurfaceVisible = true
        state.spriteSize = configuration.wanderingSize

        let snapshot = CGPoint(x: 430, y: 260)
        state = CatMotionReducer.reduce(
            state: state,
            event: .surfaceWillClose(
                currentScreenOrigin: snapshot,
                menuBarTargetScreenOrigin: CGPoint(x: 850, y: 890)
            ),
            configuration: configuration
        )

        XCTAssertEqual(state.phase, .exitingSurface)
        XCTAssertEqual(state.authoritativeScreenOrigin, snapshot)
        XCTAssertEqual(try XCTUnwrap(state.transition).startScreenOrigin, snapshot)

        state = CatMotionReducer.reduce(
            state: state,
            event: .surfaceClosed,
            configuration: configuration
        )
        XCTAssertFalse(state.isSurfaceVisible)
        XCTAssertEqual(state.phase, .exitingSurface)
        XCTAssertNotNil(state.transition)
    }

    func testExitContinuesAfterPlayAreaBecomesNil() {
        var state = enabledState(origin: CGPoint(x: 200, y: 200))
        state.spriteSize = configuration.wanderingSize
        state = CatMotionReducer.reduce(
            state: state,
            event: .surfaceWillClose(
                currentScreenOrigin: CGPoint(x: 200, y: 200),
                menuBarTargetScreenOrigin: CGPoint(x: 400, y: 800)
            ),
            configuration: configuration
        )
        state = CatMotionReducer.reduce(
            state: state,
            event: .surfaceClosed,
            configuration: configuration
        )

        let advanced = CatMotionReducer.advance(
            state: state,
            deltaTime: 0.5,
            playAreaScreenRect: nil
        )

        XCTAssertEqual(advanced.authoritativeScreenOrigin, CGPoint(x: 300, y: 500))
        XCTAssertEqual(advanced.spriteSize, CGSize(width: 30, height: 25))
    }

    func testNilPlayAreaFreezesWanderingAtLastAuthoritativePosition() {
        var state = enabledState(origin: CGPoint(x: 321, y: 654))
        state.phase = .wandering
        state.isPlaying = true
        state.spriteSize = configuration.wanderingSize

        let advanced = CatMotionReducer.advance(
            state: state,
            deltaTime: 1,
            playAreaScreenRect: nil
        )

        XCTAssertEqual(advanced.authoritativeScreenOrigin, CGPoint(x: 321, y: 654))
        XCTAssertNotEqual(advanced.authoritativeScreenOrigin, .zero)
    }

    func testNilPlayAreaFreezesPendingEntryThenResumesWhenBoundaryReturns() {
        var state = enabledState(origin: CGPoint(x: 100, y: 900))
        state = CatMotionReducer.reduce(
            state: state,
            event: .surfaceOpened(
                playAreaScreenRect: nil,
                entryScreenOrigin: CGPoint(x: 200, y: 300)
            ),
            configuration: configuration
        )

        let frozen = CatMotionReducer.advance(
            state: state,
            deltaTime: 0.5,
            playAreaScreenRect: nil
        )
        let resumed = CatMotionReducer.advance(
            state: frozen,
            deltaTime: 0.5,
            playAreaScreenRect: CGRect(x: 100, y: 100, width: 500, height: 500)
        )

        XCTAssertEqual(frozen.authoritativeScreenOrigin, CGPoint(x: 100, y: 900))
        XCTAssertNotNil(frozen.transition)
        XCTAssertEqual(resumed.authoritativeScreenOrigin, CGPoint(x: 150, y: 600))
    }

    func testPlaybackFlagDoesNotStopIdleWandering() {
        var state = enabledState(origin: CGPoint(x: 120, y: 80))
        state.phase = .wandering
        state.isPlaying = false
        state.spriteSize = configuration.wanderingSize

        let advanced = CatMotionReducer.advance(
            state: state,
            deltaTime: 1,
            playAreaScreenRect: CGRect(x: 100, y: 50, width: 300, height: 200)
        )

        XCTAssertEqual(advanced.authoritativeScreenOrigin, CGPoint(x: 140, y: 80))
        XCTAssertFalse(advanced.isPlaying)
    }

    func testWanderingUsesScreenRectOnlyAsBoundary() {
        var state = enabledState(origin: CGPoint(x: 250, y: 100))
        state.phase = .wandering
        state.isPlaying = true
        state.spriteSize = configuration.wanderingSize
        state.wanderingVelocity = CGVector(dx: 20, dy: 0)

        let advanced = CatMotionReducer.advance(
            state: state,
            deltaTime: 1,
            playAreaScreenRect: CGRect(x: 100, y: 50, width: 200, height: 100)
        )

        XCTAssertEqual(advanced.authoritativeScreenOrigin, CGPoint(x: 260, y: 100))
        XCTAssertEqual(advanced.wanderingVelocity.dx, -20)
    }

    func testSurfaceTransitionInterpolatesPositionAndSize() {
        var state = enabledState(origin: CGPoint(x: 100, y: 900))
        state = CatMotionReducer.reduce(
            state: state,
            event: .surfaceOpened(
                playAreaScreenRect: CGRect(x: 100, y: 100, width: 500, height: 500),
                entryScreenOrigin: CGPoint(x: 200, y: 300)
            ),
            configuration: configuration
        )

        let halfway = CatMotionReducer.advance(
            state: state,
            deltaTime: 0.5,
            playAreaScreenRect: CGRect(x: 100, y: 100, width: 500, height: 500)
        )

        XCTAssertEqual(halfway.authoritativeScreenOrigin, CGPoint(x: 150, y: 600))
        XCTAssertEqual(halfway.spriteSize, CGSize(width: 30, height: 25))
    }

    func testDisablingKeepsLastValidCoordinateCached() {
        let origin = CGPoint(x: -1200, y: 742)
        let enabled = enabledState(origin: origin)
        let disabled = CatMotionReducer.reduce(
            state: enabled,
            event: .enabledChanged(isEnabled: false, menuBarScreenOrigin: nil),
            configuration: configuration
        )

        XCTAssertEqual(disabled.phase, .disabled)
        XCTAssertEqual(disabled.authoritativeScreenOrigin, origin)
    }

    func testRepeatedEnableDoesNotCancelActiveTransition() {
        var state = enabledState(origin: CGPoint(x: 100, y: 900))
        state = CatMotionReducer.reduce(
            state: state,
            event: .surfaceOpened(
                playAreaScreenRect: CGRect(x: 100, y: 100, width: 400, height: 500),
                entryScreenOrigin: CGPoint(x: 200, y: 300)
            ),
            configuration: configuration
        )

        let repeated = CatMotionReducer.reduce(
            state: state,
            event: .enabledChanged(
                isEnabled: true,
                menuBarScreenOrigin: CGPoint(x: 900, y: 900)
            ),
            configuration: configuration
        )

        XCTAssertEqual(repeated.phase, .enteringSurface)
        XCTAssertEqual(repeated.transition, state.transition)
        XCTAssertEqual(repeated.authoritativeScreenOrigin, state.authoritativeScreenOrigin)
    }

    private func enabledState(origin: CGPoint) -> CatMotionState {
        CatMotionReducer.reduce(
            state: .initial(configuration: configuration),
            event: .enabledChanged(isEnabled: true, menuBarScreenOrigin: origin),
            configuration: configuration
        )
    }
}
