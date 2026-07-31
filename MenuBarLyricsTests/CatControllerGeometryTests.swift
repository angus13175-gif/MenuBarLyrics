import CoreGraphics
import XCTest
@testable import MenuBarLyrics

@MainActor
final class CatControllerGeometryTests: XCTestCase {
    func testPausedPlaybackUsesVisibleIdleAnimation() {
        XCTAssertEqual(CatPlaybackMode.paused.animation.frames, CatAnimation.idle.frames)
        XCTAssertEqual(CatPlaybackMode.playing.animation.frames, CatAnimation.dj.frames)
        XCTAssertEqual(CatPlaybackMode.noMedia.animation.frames, CatAnimation.walk.frames)
        XCTAssertTrue(CatPlaybackMode.paused.reservesMenuBarWidth)
        XCTAssertTrue(CatPlaybackMode.playing.reservesMenuBarWidth)
        XCTAssertFalse(CatPlaybackMode.noMedia.reservesMenuBarWidth)
    }

    func testMenuBarOriginCentersSixteenPixelCatInActualBounds() {
        let rect = CGRect(x: -600, y: 900, width: 160, height: 24)

        XCTAssertEqual(
            CatController.menuBarOrigin(in: rect),
            CGPoint(x: -528, y: 904)
        )
    }

    func testDJOriginUsesFarLeadingReservedSlot() {
        let rect = CGRect(x: 800, y: 1000, width: 160, height: 24)

        XCTAssertEqual(
            CatController.djOrigin(in: rect),
            CGPoint(x: 800, y: 1004)
        )
    }

    func testSurfaceReturnTargetIsTheFarLeadingEdge() {
        let rect = CGRect(x: 800, y: 1000, width: 160, height: 24)

        XCTAssertEqual(
            CatController.leadingMenuBarOrigin(in: rect, catSide: 32),
            CGPoint(x: 800, y: 992)
        )
    }

    func testSurfaceEntryOriginIsInsideActualPlayArea() {
        let rect = CGRect(x: 100, y: 200, width: 360, height: 420)

        XCTAssertEqual(
            CatController.surfaceEntryOrigin(in: rect),
            CGPoint(x: 264, y: 572)
        )
    }

    func testSelectedCatSizeChangesMenuAndSurfaceGeometry() {
        let menuRect = CGRect(x: 800, y: 1000, width: 160, height: 24)
        XCTAssertEqual(
            CatController.menuBarOrigin(in: menuRect, catSide: 32),
            CGPoint(x: 864, y: 992)
        )

        let playArea = CGRect(x: 100, y: 200, width: 360, height: 420)
        XCTAssertEqual(
            CatController.surfaceEntryOrigin(in: playArea, catSide: 64),
            CGPoint(x: 248, y: 540)
        )
    }

    func testCatVerticalOffsetMovesEveryMenuBarAnchorTenPointsEachWay() {
        let menuRect = CGRect(x: 800, y: 1000, width: 160, height: 24)

        XCTAssertEqual(
            CatController.menuBarOrigin(in: menuRect, catSide: 32, verticalOffset: 10),
            CGPoint(x: 864, y: 982)
        )
        XCTAssertEqual(
            CatController.djOrigin(in: menuRect, catSide: 32, verticalOffset: -10),
            CGPoint(x: 800, y: 1002)
        )
        XCTAssertEqual(
            CatController.leadingMenuBarOrigin(in: menuRect, catSide: 32, verticalOffset: 10),
            CGPoint(x: 800, y: 982)
        )
    }

    func testCatHorizontalOffsetMovesEveryMenuBarAnchor() {
        let menuRect = CGRect(x: 800, y: 1000, width: 160, height: 24)

        XCTAssertEqual(
            CatController.menuBarOrigin(in: menuRect, catSide: 32, horizontalOffset: -8),
            CGPoint(x: 856, y: 992)
        )
        XCTAssertEqual(
            CatController.djOrigin(in: menuRect, catSide: 32, horizontalOffset: 6),
            CGPoint(x: 806, y: 992)
        )
        XCTAssertEqual(
            CatController.leadingMenuBarOrigin(in: menuRect, catSide: 32, horizontalOffset: -8),
            CGPoint(x: 792, y: 992)
        )
    }

    func testHorizontalOffsetAdjustsReservedLyricWidthWithCatPosition() {
        XCTAssertEqual(
            CatController.reservedMenuBarWidth(catSide: 40, horizontalOffset: -8, reserves: true),
            34
        )
        XCTAssertEqual(
            CatController.reservedMenuBarWidth(catSide: 40, horizontalOffset: 6, reserves: true),
            48
        )
        XCTAssertEqual(
            CatController.reservedMenuBarWidth(catSide: 40, horizontalOffset: -8, reserves: false),
            0
        )
    }

    func testRoamingAnimationMatchesHorizontalTravelDirection() {
        XCTAssertFalse(
            CatController.facingLeft(
                phase: .wandering,
                wanderingVelocity: CGVector(dx: -28, dy: 0),
                menuBarVelocity: 18,
                transition: nil,
                playbackMode: .noMedia
            )
        )
        XCTAssertTrue(
            CatController.facingLeft(
                phase: .wandering,
                wanderingVelocity: CGVector(dx: 28, dy: 0),
                menuBarVelocity: -18,
                transition: nil,
                playbackMode: .noMedia
            )
        )
        XCTAssertFalse(
            CatController.facingLeft(
                phase: .perched,
                wanderingVelocity: .zero,
                menuBarVelocity: -18,
                transition: nil,
                playbackMode: .noMedia
            )
        )
        XCTAssertTrue(
            CatController.facingLeft(
                phase: .perched,
                wanderingVelocity: .zero,
                menuBarVelocity: 18,
                transition: nil,
                playbackMode: .noMedia
            )
        )
    }

    func testStatusItemLengthOnlyChangesWhenWidthActuallyChanges() {
        XCTAssertEqual(StatusItemController.autosaveName, "MainLyricsStatusItem")
        XCTAssertFalse(StatusItemController.shouldApplyLength(current: 160, target: 160.2))
        XCTAssertTrue(StatusItemController.shouldApplyLength(current: 160, target: 240))
        XCTAssertTrue(StatusItemController.shouldApplyLength(current: -1, target: 160))
    }

    func testMenuAnchorRejectsHiddenBottomParkingPosition() {
        XCTAssertFalse(
            StatusItemController.isUsableMenuBarScreenRect(
                CGRect(x: 120, y: 0, width: 160, height: 24),
                screenFrames: [CGRect(x: 0, y: 0, width: 1710, height: 1112)]
            )
        )
    }

    func testMenuAnchorAcceptsTopBandOnNegativeCoordinateDisplay() {
        XCTAssertTrue(
            StatusItemController.isUsableMenuBarScreenRect(
                CGRect(x: -1500, y: 1056, width: 160, height: 24),
                screenFrames: [CGRect(x: -1920, y: 0, width: 1920, height: 1080)]
            )
        )
    }

    func testFallbackAnchorStaysVisibleAtTopOfScreen() {
        let anchor = StatusItemController.fallbackMenuBarScreenRect(
            screenFrame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
            preferredWidth: 268,
            trailingClearance: 200
        )

        XCTAssertEqual(anchor.minX, 1242)
        XCTAssertEqual(anchor.maxY, 1112)
        XCTAssertTrue(
            StatusItemController.isUsableMenuBarScreenRect(
                anchor,
                screenFrames: [CGRect(x: 0, y: 0, width: 1710, height: 1112)]
            )
        )
    }
}
