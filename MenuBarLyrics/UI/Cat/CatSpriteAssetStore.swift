import CoreGraphics
import Foundation
import ImageIO

/// Loads the four approved 4×3 sprite sheets and returns transparent frame
/// images without redrawing the cats. Opaque character pixels retain the RGB
/// values from the supplied PNG; only the pale blue sheet background and grid
/// are removed.
@MainActor
enum CatSpriteAssetStore {
    private struct FrameKey: Hashable {
        let skin: CatSkin
        let cell: CatSheetCell
    }

    private static var sheets: [CatSkin: CGImage] = [:]
    private static var frames: [FrameKey: CGImage] = [:]

    static func image(for frame: CatFrame, skin: CatSkin) -> CGImage? {
        image(for: frame.sheetCell, skin: skin)
    }

    static func sourceURL(for skin: CatSkin) -> URL? {
        let fileName = "\(skin.spriteSheetResourceName).png"
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("CatSpriteSheets", isDirectory: true)
            .appendingPathComponent(fileName),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }

        // `swift run` and unit tests execute before app packaging. Resolve the
        // checked-in originals relative to this source file in that case.
        let sourceTree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Cat
            .deletingLastPathComponent() // UI
            .deletingLastPathComponent() // MenuBarLyrics
            .appendingPathComponent("Resources/CatSpriteSheets", isDirectory: true)
            .appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: sourceTree.path) ? sourceTree : nil
    }

    static func sourcePixelSize(for skin: CatSkin) -> CGSize? {
        guard let sheet = sheet(for: skin) else { return nil }
        return CGSize(width: sheet.width, height: sheet.height)
    }

    /// Exposes the unmodified source cell for pixel-fidelity regression tests.
    static func sourceCellImage(for frame: CatFrame, skin: CatSkin) -> CGImage? {
        guard let source = sheet(for: skin) else { return nil }
        return crop(cell: frame.sheetCell, from: source)
    }

    static func clearCache() {
        sheets.removeAll()
        frames.removeAll()
    }

    private static func image(for cell: CatSheetCell, skin: CatSkin) -> CGImage? {
        let key = FrameKey(skin: skin, cell: cell)
        if let cached = frames[key] { return cached }
        let clearsEnclosedBackground = skin == .miaoMiao
            && cell == CatSheetCell(column: 0, row: 1)
        guard let source = sheet(for: skin),
              let cropped = crop(cell: cell, from: source),
              let transparent = removeSheetBackground(
                from: cropped,
                clearAllSheetBackground: clearsEnclosedBackground
              ) else { return nil }
        let clearsPangTransitionDividers = skin == .pangMaoMao
            && cell.row == 1
            && (0...2).contains(cell.column)
        let clearsPangIdleDividers = skin == .pangMaoMao
            && cell.row == 0
        let clearsDJDividers = (skin == .pangMaoMao || skin == .miMi)
            && cell.row == 2
        let clearsVerticalDividers = clearsPangIdleDividers
            || clearsPangTransitionDividers
            || clearsDJDividers
        let cleaned = skin == .pangMaoMao || skin == .miMi
            ? removeBorderDividerLines(
                from: transparent,
                includeVerticalRuns: clearsVerticalDividers
              )
            : transparent
        frames[key] = cleaned
        return cleaned
    }

    private static func sheet(for skin: CatSkin) -> CGImage? {
        if let cached = sheets[skin] { return cached }
        guard let url = sourceURL(for: skin),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: true] as CFDictionary
              ) else { return nil }
        sheets[skin] = image
        return image
    }

    private static func crop(cell: CatSheetCell, from sheet: CGImage) -> CGImage? {
        guard (0..<4).contains(cell.column), (0..<3).contains(cell.row) else { return nil }

        func edge(_ index: Int, count: Int, total: Int) -> Int {
            Int((Double(total) * Double(index) / Double(count)).rounded())
        }

        let minX = edge(cell.column, count: 4, total: sheet.width)
        let maxX = edge(cell.column + 1, count: 4, total: sheet.width)
        let minY = edge(cell.row, count: 3, total: sheet.height)
        let maxY = edge(cell.row + 1, count: 3, total: sheet.height)

        // Remove the white divider itself while retaining every loose motion
        // mark inside the cell.
        let dividerInset = 5
        let rect = CGRect(
            x: minX + dividerInset,
            y: minY + dividerInset,
            width: max(1, maxX - minX - dividerInset * 2),
            height: max(1, maxY - minY - dividerInset * 2)
        )
        return sheet.cropping(to: rect)
    }

    private static func removeSheetBackground(
        from image: CGImage,
        clearAllSheetBackground: Bool = false
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func isSheetBackground(_ index: Int) -> Bool {
            let offset = index * 4
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            // The sheet is a cool pale blue. Character whites are neutral or
            // warm, so requiring a real blue cast prevents the flood fill from
            // entering cream/white/light-gray fur through small outline gaps.
            return red >= 135
                && green >= 150
                && blue >= 165
                && blue >= red + 5
                && blue >= green + 2
        }

        var removed = [Bool](repeating: false, count: width * height)
        var queue: [Int] = []
        queue.reserveCapacity(width * height / 2)

        func seed(_ index: Int) {
            guard !removed[index], isSheetBackground(index) else { return }
            removed[index] = true
            queue.append(index)
        }
        for x in 0..<width {
            seed(x)
            seed((height - 1) * width + x)
        }
        for y in 0..<height {
            seed(y * width)
            seed(y * width + width - 1)
        }

        // The headphone arch encloses a background hole that is not connected
        // to the cell border. Seed only cool-blue pixels in the central end
        // bands; fur and facial pixels fail the blue-cast predicate.
        let gapMinX = width / 8
        let gapMaxX = width - gapMinX
        let bandHeight = max(1, height * 2 / 5)
        for y in 0..<height where y < bandHeight || y >= height - bandHeight {
            for x in gapMinX..<gapMaxX {
                seed(y * width + x)
            }
        }

        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let x = index % width
            let y = index / width
            let neighbors = [
                x > 0 ? index - 1 : -1,
                x + 1 < width ? index + 1 : -1,
                y > 0 ? index - width : -1,
                y + 1 < height ? index + width : -1,
            ]
            for neighbor in neighbors where neighbor >= 0 {
                guard !removed[neighbor], isSheetBackground(neighbor) else { continue }
                removed[neighbor] = true
                queue.append(neighbor)
            }
        }

        for index in 0..<removed.count
            where removed[index] || (clearAllSheetBackground && isSheetBackground(index)) {
            let offset = index * 4
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = 0
        }

        return makeImage(
            pixels: pixels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bitmapInfo: bitmapInfo
        )
    }

    /// The approved 胖猫猫 and 咪咪 sheets contain bright horizontal cell
    /// dividers that extend to a cell edge. Remove only long, neutral-white
    /// runs attached to the left or right canvas edge; white fur stays intact
    /// because it is separated from the cell boundary by the blue background.
    private static func removeBorderDividerLines(
        from image: CGImage,
        includeVerticalRuns: Bool = false
    ) -> CGImage {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return image }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func isDividerWhite(x: Int, y: Int) -> Bool {
            let offset = y * bytesPerRow + x * 4
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            return pixels[offset + 3] > 8
                && red >= 232
                && green >= 232
                && blue >= 232
                && max(red, green, blue) - min(red, green, blue) <= 12
        }

        func clear(x: Int, y: Int) {
            let offset = y * bytesPerRow + x * 4
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = 0
        }

        let minimumRun = max(8, width / 4)
        for y in 0..<height {
            var leftRun = 0
            while leftRun < width, isDividerWhite(x: leftRun, y: y) {
                leftRun += 1
            }
            if leftRun >= minimumRun {
                for x in 0..<leftRun { clear(x: x, y: y) }
            }

            var rightRun = 0
            while rightRun < width, isDividerWhite(x: width - 1 - rightRun, y: y) {
                rightRun += 1
            }
            if rightRun >= minimumRun {
                for offset in 0..<rightRun { clear(x: width - 1 - offset, y: y) }
            }
        }

        if includeVerticalRuns {
            let minimumVerticalRun = max(8, height / 4)
            for x in 0..<width {
                var topRun = 0
                while topRun < height, isDividerWhite(x: x, y: topRun) {
                    topRun += 1
                }
                if topRun >= minimumVerticalRun {
                    for y in 0..<topRun { clear(x: x, y: y) }
                }

                var bottomRun = 0
                while bottomRun < height,
                      isDividerWhite(x: x, y: height - 1 - bottomRun) {
                    bottomRun += 1
                }
                if bottomRun >= minimumVerticalRun {
                    for offset in 0..<bottomRun {
                        clear(x: x, y: height - 1 - offset)
                    }
                }
            }
        }

        return makeImage(
            pixels: pixels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bitmapInfo: bitmapInfo
        ) ?? image
    }

    private static func makeImage(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bitmapInfo: UInt32
    ) -> CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
