import AppKit
import XCTest
@testable import MenuBarLyrics

@MainActor
final class CatSpriteWindowTests: XCTestCase {
    func testWindowIsCatSizedTransparentNonactivatingAndClickable() {
        let window = CatSpriteWindow(
            initialFrame: NSRect(x: 120, y: 340, width: 28, height: 32)
        )

        XCTAssertEqual(window.frame, NSRect(x: 120, y: 340, width: 28, height: 32))
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(window.styleMask.contains(.borderless))
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
    }

    func testPrimaryActionInvokesRecoveryHandler() {
        let expectation = expectation(description: "primary action")
        let window = CatSpriteWindow(
            initialFrame: NSRect(x: 120, y: 340, width: 28, height: 32)
        )
        window.onPrimaryAction = {
            expectation.fulfill()
        }

        window.performPrimaryAction()

        wait(for: [expectation], timeout: 0)
    }

    func testUpdateFrameUsesGlobalScreenCoordinatesAndInterpolatedSize() {
        let window = CatSpriteWindow(
            initialFrame: NSRect(x: 0, y: 0, width: 20, height: 20)
        )

        window.updateFrame(
            screenOrigin: CGPoint(x: -800, y: 725),
            size: CGSize(width: 31, height: 27),
            display: false
        )

        XCTAssertEqual(window.frame.origin, CGPoint(x: -800, y: 725))
        XCTAssertEqual(window.frame.size, CGSize(width: 31, height: 27))
        XCTAssertEqual(window.contentView?.frame.size, CGSize(width: 31, height: 27))
    }
}
