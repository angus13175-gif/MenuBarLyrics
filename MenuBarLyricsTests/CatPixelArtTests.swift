import AppKit
import CryptoKit
import XCTest
@testable import MenuBarLyrics

final class CatPixelArtTests: XCTestCase {
    func testSkinNamesUseApprovedSelectionOrder() {
        XCTAssertEqual(CatSkin.allCases.map(\.displayName), ["猫猫", "胖猫猫", "喵喵", "咪咪"])
    }

    @MainActor
    func testBundledSheetsAreByteIdenticalToApprovedSources() throws {
        let approvedHashes: [CatSkin: String] = [
            .maoMao: "1f4ceccd1158056b95e242b233d0e5ae15eb005bc9778fe48c99176113163553",
            .pangMaoMao: "65a7d3e43fe13fbff8527fdc38e427b42a3e4e1e9837c363135aa5bb9af3ec4a",
            .miaoMiao: "c35949957440d871030db7e2d93fbd636ac0d66d5d9a687058502b8b40918712",
            .miMi: "6c5a4cae877f8903de8488bfe494fc2111af4dba1ec1dbfb07772988afafcfba",
        ]

        for skin in CatSkin.allCases {
            let url = try XCTUnwrap(CatSpriteAssetStore.sourceURL(for: skin), skin.displayName)
            let digest = SHA256.hash(data: try Data(contentsOf: url))
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(digest, approvedHashes[skin], skin.displayName)
        }
    }

    @MainActor
    func testApprovedSheetPixelDimensionsArePreserved() {
        XCTAssertEqual(CatSpriteAssetStore.sourcePixelSize(for: .maoMao), CGSize(width: 1402, height: 1122))
        for skin in [CatSkin.pangMaoMao, .miaoMiao, .miMi] {
            XCTAssertEqual(CatSpriteAssetStore.sourcePixelSize(for: skin), CGSize(width: 1536, height: 1024))
        }
    }

    func testAllTwelveApprovedCellsAreMapped() {
        let cells = Set(CatFrame.allCases.map(\.sheetCell))
        XCTAssertEqual(cells.count, 12)
        XCTAssertEqual(cells.filter { $0.row == 0 }.count, 4)
        XCTAssertEqual(cells.filter { $0.row == 1 }.count, 4)
        XCTAssertEqual(cells.filter { $0.row == 2 }.count, 4)
    }

    func testAnimationFamiliesUseTheApprovedRows() {
        XCTAssertEqual(Set(CatAnimation.idle.frames.map(\.sheetCell)), Set((0..<4).map { CatSheetCell(column: $0, row: 0) }))
        XCTAssertEqual(Set(CatAnimation.walk.frames.map(\.sheetCell)), Set((0..<4).map { CatSheetCell(column: $0, row: 1) }))
        XCTAssertEqual(Set(CatAnimation.dj.frames.map(\.sheetCell)), Set((0..<4).map { CatSheetCell(column: $0, row: 2) }))
        XCTAssertTrue(CatAnimation.idle.repeats)
        XCTAssertTrue(CatAnimation.walk.repeats)
        XCTAssertTrue(CatAnimation.dj.repeats)
        XCTAssertFalse(CatAnimation.falling.repeats)
        XCTAssertFalse(CatAnimation.rising.repeats)
    }

    @MainActor
    func testEveryApprovedCellProducesTransparentArtwork() throws {
        for skin in CatSkin.allCases {
            for frame in CatFrame.allCases {
                let image = try XCTUnwrap(CatSpriteAssetStore.image(for: frame, skin: skin), "\(skin.rawValue)-\(frame.rawValue)")
                XCTAssertGreaterThan(image.width, 40)
                XCTAssertGreaterThan(image.height, 40)
                let alphas = try alphaValues(of: image)
                XCTAssertTrue(alphas.contains(0), "sheet background must be transparent: \(skin.rawValue)-\(frame.rawValue)")
                XCTAssertTrue(alphas.contains { $0 > 240 }, "cat artwork must remain opaque: \(skin.rawValue)-\(frame.rawValue)")
            }
        }
    }

    @MainActor
    func testEveryVisibleForegroundPixelKeepsItsExactSourceRGB() throws {
        let frames: [CatFrame] = [
            .sit, .blink, .idleExcited, .idleMusic,
            .walkA, .walkB, .playA, .playB,
            .djA, .djB, .djC, .djD,
        ]
        for skin in CatSkin.allCases {
            for frame in frames {
                let source = try XCTUnwrap(CatSpriteAssetStore.sourceCellImage(for: frame, skin: skin))
                let output = try XCTUnwrap(CatSpriteAssetStore.image(for: frame, skin: skin))
                let sourceBytes = try rgbaBytes(of: source)
                let outputBytes = try rgbaBytes(of: output)
                XCTAssertEqual(source.width, output.width)
                XCTAssertEqual(source.height, output.height)
                var foregroundPixels = 0
                var mismatchedForegroundPixels = 0
                for offset in stride(from: 0, to: outputBytes.count, by: 4)
                    where outputBytes[offset + 3] > 8 {
                    foregroundPixels += 1
                    if outputBytes[offset] != sourceBytes[offset]
                        || outputBytes[offset + 1] != sourceBytes[offset + 1]
                        || outputBytes[offset + 2] != sourceBytes[offset + 2] {
                        mismatchedForegroundPixels += 1
                    }
                }
                XCTAssertGreaterThan(foregroundPixels, 500, "\(skin.rawValue)-\(frame.rawValue)")
                XCTAssertEqual(mismatchedForegroundPixels, 0, "\(skin.rawValue)-\(frame.rawValue)")
            }
        }
    }

    @MainActor
    func testMiMiBlueEyesSurviveBackgroundRemoval() throws {
        let image = try XCTUnwrap(CatSpriteAssetStore.image(for: .sit, skin: .miMi))
        let bytes = try rgbaBytes(of: image)
        let bluePixels = stride(from: 0, to: bytes.count, by: 4).count { offset in
            let red = Int(bytes[offset])
            let green = Int(bytes[offset + 1])
            let blue = Int(bytes[offset + 2])
            return bytes[offset + 3] > 240 && red < 120 && blue > 140 && blue > red + 70 && blue > green + 20
        }
        XCTAssertGreaterThan(bluePixels, 20)
    }

    @MainActor
    func testOnlyExteriorBackgroundIsTransparent() throws {
        for skin in CatSkin.allCases {
            for frame in [CatFrame.sit, .walkA, .playA, .djA] {
                let image = try XCTUnwrap(CatSpriteAssetStore.image(for: frame, skin: skin))
                let bytes = try rgbaBytes(of: image)
                let centerX = image.width / 2
                let centerY = image.height / 2
                let centerAlpha = bytes[(centerY * image.width + centerX) * 4 + 3]
                XCTAssertGreaterThan(
                    centerAlpha,
                    240,
                    "the outer contour must protect the character interior: \(skin.rawValue)-\(frame.rawValue)"
                )
            }
        }
    }

    @MainActor
    func testPangMaoMaoAndMiMiHaveNoWhiteCellDividerAtHorizontalEdges() throws {
        for skin in [CatSkin.pangMaoMao, .miMi] {
            for frame in CatFrame.allCases {
                let image = try XCTUnwrap(CatSpriteAssetStore.image(for: frame, skin: skin))
                let bytes = try rgbaBytes(of: image)
                let minimumRun = image.width / 4

                for y in 0..<image.height {
                    var leftRun = 0
                    while leftRun < image.width,
                          isNeutralWhite(bytes, width: image.width, x: leftRun, y: y) {
                        leftRun += 1
                    }
                    var rightRun = 0
                    while rightRun < image.width,
                          isNeutralWhite(bytes, width: image.width, x: image.width - 1 - rightRun, y: y) {
                        rightRun += 1
                    }
                    XCTAssertLessThan(leftRun, minimumRun, "\(skin.rawValue)-\(frame.rawValue) left divider")
                    XCTAssertLessThan(rightRun, minimumRun, "\(skin.rawValue)-\(frame.rawValue) right divider")
                }
            }
        }
    }

    @MainActor
    func testMiaoMiaoProneFrameHasNoOpaqueSheetBackgroundInHeadphoneGap() throws {
        let image = try XCTUnwrap(CatSpriteAssetStore.image(for: .walkA, skin: .miaoMiao))
        let bytes = try rgbaBytes(of: image)
        let remainingBackgroundPixels = stride(from: 0, to: bytes.count, by: 4).count { offset in
            isSheetBackground(bytes, offset: offset)
        }

        XCTAssertEqual(remainingBackgroundPixels, 0)
    }

    @MainActor
    func testPangMaoMaoIdleFramesHaveNoWhiteVerticalCellDividers() throws {
        for frame in CatAnimation.idle.frames {
            let image = try XCTUnwrap(CatSpriteAssetStore.image(for: frame, skin: .pangMaoMao))
            let bytes = try rgbaBytes(of: image)
            let minimumRun = image.height / 4

            for x in 0..<image.width {
                var topRun = 0
                while topRun < image.height,
                      isNeutralWhite(bytes, width: image.width, x: x, y: topRun) {
                    topRun += 1
                }
                var bottomRun = 0
                while bottomRun < image.height,
                      isNeutralWhite(
                        bytes,
                        width: image.width,
                        x: x,
                        y: image.height - 1 - bottomRun
                      ) {
                    bottomRun += 1
                }
                XCTAssertLessThan(topRun, minimumRun, "\(frame.rawValue) top divider")
                XCTAssertLessThan(bottomRun, minimumRun, "\(frame.rawValue) bottom divider")
            }
        }
    }

    @MainActor
    func testPangMaoMaoTransitionFramesHaveNoWhiteVerticalCellDividers() throws {
        for frame in [CatFrame.fallA, .fallB, .riseA, .riseB] {
            let image = try XCTUnwrap(CatSpriteAssetStore.image(for: frame, skin: .pangMaoMao))
            let bytes = try rgbaBytes(of: image)
            let minimumRun = image.height / 4

            for x in 0..<image.width {
                var topRun = 0
                while topRun < image.height,
                      isNeutralWhite(bytes, width: image.width, x: x, y: topRun) {
                    topRun += 1
                }
                var bottomRun = 0
                while bottomRun < image.height,
                      isNeutralWhite(
                        bytes,
                        width: image.width,
                        x: x,
                        y: image.height - 1 - bottomRun
                      ) {
                    bottomRun += 1
                }
                XCTAssertLessThan(topRun, minimumRun, "\(frame.rawValue) top divider")
                XCTAssertLessThan(bottomRun, minimumRun, "\(frame.rawValue) bottom divider")
            }
        }
    }

    @MainActor
    func testPangMaoMaoAndMiMiDJFramesHaveNoWhiteVerticalCellDividers() throws {
        for skin in [CatSkin.pangMaoMao, .miMi] {
            for frame in [CatFrame.djA, .djB, .djC, .djD] {
                let image = try XCTUnwrap(CatSpriteAssetStore.image(for: frame, skin: skin))
                let bytes = try rgbaBytes(of: image)
                let minimumRun = image.height / 4

                for x in 0..<image.width {
                    var topRun = 0
                    while topRun < image.height,
                          isNeutralWhite(bytes, width: image.width, x: x, y: topRun) {
                        topRun += 1
                    }
                    var bottomRun = 0
                    while bottomRun < image.height,
                          isNeutralWhite(
                            bytes,
                            width: image.width,
                            x: x,
                            y: image.height - 1 - bottomRun
                          ) {
                        bottomRun += 1
                    }
                    XCTAssertLessThan(
                        topRun,
                        minimumRun,
                        "\(skin.rawValue)-\(frame.rawValue) top divider"
                    )
                    XCTAssertLessThan(
                        bottomRun,
                        minimumRun,
                        "\(skin.rawValue)-\(frame.rawValue) bottom divider"
                    )
                }
            }
        }
    }

    @MainActor
    func testRendererProducesNativeSizeImages() {
        XCTAssertEqual(CatRenderer.image(frame: .sit, size: .menuBar).size, NSSize(width: 16, height: 16))
        XCTAssertEqual(CatRenderer.image(frame: .djD, size: .panel, skin: .miMi).size, NSSize(width: 32, height: 32))
    }

    @MainActor
    func testFacingLeftMirrorsRenderedArtwork() {
        let side = 64
        let right = renderedBytes(facingLeft: false, side: side)
        let left = renderedBytes(facingLeft: true, side: side)
        XCTAssertNotEqual(right, left)
        for y in 0..<side {
            for x in 0..<side {
                let rightIndex = (y * side + x) * 4
                let leftIndex = (y * side + (side - 1 - x)) * 4
                XCTAssertEqual(
                    Array(right[rightIndex..<(rightIndex + 4)]),
                    Array(left[leftIndex..<(leftIndex + 4)])
                )
            }
        }
    }

    private func rgbaBytes(of image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    private func alphaValues(of image: CGImage) throws -> [UInt8] {
        let bytes = try rgbaBytes(of: image)
        return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
    }

    private func isNeutralWhite(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> Bool {
        let offset = (y * width + x) * 4
        let red = Int(bytes[offset])
        let green = Int(bytes[offset + 1])
        let blue = Int(bytes[offset + 2])
        return bytes[offset + 3] > 8
            && red >= 232
            && green >= 232
            && blue >= 232
            && max(red, green, blue) - min(red, green, blue) <= 12
    }

    private func isSheetBackground(_ bytes: [UInt8], offset: Int) -> Bool {
        let red = Int(bytes[offset])
        let green = Int(bytes[offset + 1])
        let blue = Int(bytes[offset + 2])
        return bytes[offset + 3] > 8
            && red >= 135
            && green >= 150
            && blue >= 165
            && blue >= red + 5
            && blue >= green + 2
    }

    @MainActor
    private func renderedBytes(facingLeft: Bool, side: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        bytes.withUnsafeMutableBytes { storage in
            let context = CGContext(
                data: storage.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            CatRenderer.draw(
                frame: .walkB,
                skin: .maoMao,
                facingLeft: facingLeft,
                in: CGRect(x: 0, y: 0, width: side, height: side),
                context: context
            )
        }
        return bytes
    }
}
