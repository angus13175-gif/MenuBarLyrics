import AppKit
import CoreGraphics

enum CatRenderSize: Sendable {
    case menuBar
    case panel

    var pixelScale: Int {
        switch self {
        case .menuBar: 1
        case .panel: 2
        }
    }

    var pointSize: CGSize {
        let side = CGFloat(16 * pixelScale)
        return CGSize(width: side, height: side)
    }
}

enum CatRenderer {
    @MainActor
    static func image(
        frame: CatFrame,
        size: CatRenderSize,
        skin: CatSkin = .maoMao
    ) -> NSImage {
        NSImage(size: size.pointSize, flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(frame: frame, skin: skin, in: bounds, context: context)
            return true
        }
    }

    @MainActor
    static func draw(
        frame: CatFrame,
        skin: CatSkin = .maoMao,
        in bounds: CGRect,
        context: CGContext
    ) {
        draw(frame: frame, skin: skin, facingLeft: false, in: bounds, context: context)
    }

    @MainActor
    static func draw(
        frame: CatFrame,
        skin: CatSkin = .maoMao,
        facingLeft: Bool,
        in bounds: CGRect,
        context: CGContext
    ) {
        guard let image = CatSpriteAssetStore.image(for: frame, skin: skin) else { return }
        draw(image: image, facingLeft: facingLeft, in: bounds, context: context)
    }

    private static func draw(
        image: CGImage,
        facingLeft: Bool,
        in bounds: CGRect,
        context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(false)
        context.interpolationQuality = .none

        let scale = min(
            bounds.width / CGFloat(image.width),
            bounds.height / CGFloat(image.height)
        )
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        let destination = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )

        if facingLeft {
            context.translateBy(x: bounds.midX * 2, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        context.draw(image, in: destination)
    }
}
