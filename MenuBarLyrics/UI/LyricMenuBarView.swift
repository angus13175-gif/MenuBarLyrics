import AppKit
import CoreText
import CoreGraphics

struct KaraokeViewportLayout: Equatable {
    let scrollOffset: CGFloat
    let visibleFillWidth: CGFloat
}

/// Custom `NSView` that draws karaoke-style fill animation in the menu bar.
///
/// The view renders two layers: the unsung text in a dim color and the sung
/// text in the accent color, clipped to the filled width. When the filled
/// width exceeds 70% of the drawing width, the view scrolls left so the fill
/// front stays anchored near the right side of the visible area.
///
/// CoreText (`CTLine`) is used for text measurement, with the layout cached by
/// text string so repeated frames of the same line are cheap.
final class LyricMenuBarView: NSView {
    var renderState: LyricRenderState? {
        didSet { needsDisplay = true }
    }
    var lyrics: LyricDocument? {
        didSet { needsDisplay = true }
    }
    var menuWidth: CGFloat = 160 {
        didSet {
            if oldValue != menuWidth { invalidateIntrinsicContentSize() }
        }
    }
    /// Width reserved for the DJ cat at the leading edge of the status item.
    var catReservedWidth: CGFloat = 0 {
        didSet {
            guard oldValue != catReservedWidth else { return }
            lineLayoutCache = nil
            needsDisplay = true
        }
    }
    /// Suppresses the fallback music-note glyph while the cat is visible.
    var catVisible: Bool = false {
        didSet {
            if oldValue != catVisible { needsDisplay = true }
        }
    }

    private let settings: AppSettings
    private let horizontalPadding: CGFloat = 8
    private var lineLayoutCache: (signature: String, line: CTLine, totalWidth: CGFloat)?

    init(settings: AppSettings) {
        self.settings = settings
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applySettings() {
        lineLayoutCache = nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(24, menuWidth), height: NSStatusBar.system.thickness)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let drawingRect = Self.drawingRect(
            in: bounds,
            catReservedWidth: catReservedWidth,
            horizontalPadding: horizontalPadding
        )
        let contentOriginX = drawingRect.minX
        let drawingWidth = drawingRect.width

        guard let state = renderState, state.phase != .noMedia,
              state.phase != .helperUnavailable else {
            if !catVisible { drawIcon() }
            return
        }

        guard let lyrics, let lineIndex = state.lineIndex,
              lineIndex >= 0, lineIndex < lyrics.lines.count else {
            if !catVisible { drawIcon() }
            return
        }

        let line = lyrics.lines[lineIndex]
        let text = line.text.isEmpty ? "♪" : line.text

        var font = AppSettings.font(
            name: settings.menuBarFontName,
            size: settings.menuBarFontSize,
            weight: settings.menuBarFontWeight
        )

        // Shrink only when requested; the other modes preserve the selected
        // point size and either scroll or truncate.
        if settings.longLyricMode == .shrinkToFit {
            let initial = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: font])
            )
            let initialWidth = CGFloat(CTLineGetTypographicBounds(initial, nil, nil, nil))
            if initialWidth > drawingWidth, initialWidth > 0 {
                let fittedSize = max(8, font.pointSize * drawingWidth / initialWidth)
                font = AppSettings.font(
                    name: settings.menuBarFontName,
                    size: fittedSize,
                    weight: settings.menuBarFontWeight
                )
            }
        }

        // Get or create cached CTLine for measurement.
        let ctLine: CTLine
        let totalWidth: CGFloat
        let signature = "\(text)|\(font.fontName)|\(font.pointSize)|\(settings.menuBarFontWeight)"
        if let cached = lineLayoutCache, cached.signature == signature {
            ctLine = cached.line
            totalWidth = cached.totalWidth
        } else {
            let attrString = NSAttributedString(
                string: text,
                attributes: [.font: font]
            )
            ctLine = CTLineCreateWithAttributedString(attrString)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            totalWidth = CGFloat(width)
            lineLayoutCache = (signature, ctLine, totalWidth)
        }

        let clampedProgress = min(1, max(0, state.lineProgress))
        let filledWidth = totalWidth * CGFloat(clampedProgress)
        let karaokeLayout = Self.karaokeLayout(
            totalWidth: totalWidth,
            viewportWidth: drawingWidth,
            progress: clampedProgress
        )

        // Long auto-scrolling lines follow three continuous phases: fill to
        // 70% of the viewport, keep the color front fixed while the text moves
        // left, then finish filling after the tail becomes visible.
        let scrollOffset: CGFloat
        if settings.longLyricMode == .autoScroll {
            scrollOffset = karaokeLayout.scrollOffset
        } else {
            scrollOffset = 0
        }

        // Colors adapt to effective appearance.
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let unsungColor = AppSettings.color(
            fromHex: isDark
                ? settings.menuBarUnfilledColorDark
                : settings.menuBarUnfilledColorLight
        )
        let sungColor = AppSettings.color(
            fromHex: isDark
                ? settings.menuBarFilledColorDark
                : settings.menuBarFilledColorLight
        )

        // Paused state dims the unsung color.
        let displayUnsungColor: NSColor = state.phase == .paused
            ? unsungColor.withAlphaComponent(unsungColor.alphaComponent * 0.5)
            : unsungColor

        // Clip to the drawing rect, then translate by -scrollOffset so text
        // scrolls left as the fill advances.
        context.saveGState()
        context.clip(to: drawingRect)
        context.translateBy(x: -scrollOffset, y: 0)

        let textY = textOriginY(for: font.pointSize)

        // Draw the full text in the unsung color.
        let fullString = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: displayUnsungColor,
            ]
        )
        draw(fullString, atX: contentOriginX, atY: textY, drawingWidth: drawingWidth)

        // Draw the sung portion on top, clipped to the filled width. The clip
        // rect is in the untranslated coordinate space (we add scrollOffset
        // back because the context is already translated).
        if settings.fillAnimationEnabled,
           state.lineProgress > 0, state.phase != .paused {
            context.saveGState()
            let visibleFilledWidth: CGFloat
            switch settings.longLyricMode {
            case .autoScroll:
                visibleFilledWidth = karaokeLayout.visibleFillWidth
            case .truncate:
                visibleFilledWidth = drawingWidth * CGFloat(clampedProgress)
            case .shrinkToFit:
                visibleFilledWidth = min(filledWidth, drawingWidth)
            }
            let clipRect = CGRect(
                x: contentOriginX + scrollOffset,
                y: 0,
                width: visibleFilledWidth,
                height: bounds.height
            )
            context.clip(to: clipRect)
            let sungString = NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: sungColor,
                ]
            )
            draw(sungString, atX: contentOriginX, atY: textY, drawingWidth: drawingWidth)
            context.restoreGState()
        }

        context.restoreGState()
    }

    static func drawingRect(
        in bounds: NSRect,
        catReservedWidth: CGFloat,
        horizontalPadding: CGFloat = 8
    ) -> NSRect {
        let reservedWidth = max(0, catReservedWidth)
        let leadingInset = reservedWidth > 0 ? reservedWidth : horizontalPadding
        return NSRect(
            x: leadingInset,
            y: 0,
            width: max(0, bounds.width - leadingInset - horizontalPadding),
            height: bounds.height
        )
    }

    func textOriginY(for fontSize: CGFloat) -> CGFloat {
        (bounds.height - fontSize) / 2 - 1 - CGFloat(settings.menuBarVerticalOffset)
    }

    /// Maps full-line progress into the visible viewport. For short lines this
    /// is ordinary proportional fill. For long lines the fill front remains at
    /// 70% while the hidden tail scrolls into view, then advances to 100%.
    static func karaokeLayout(
        totalWidth: CGFloat,
        viewportWidth: CGFloat,
        progress: Double,
        anchorRatio: CGFloat = 0.7
    ) -> KaraokeViewportLayout {
        guard totalWidth.isFinite, viewportWidth.isFinite, progress.isFinite,
              anchorRatio.isFinite else {
            return KaraokeViewportLayout(scrollOffset: 0, visibleFillWidth: 0)
        }

        let contentWidth = max(0, totalWidth)
        let visibleWidth = max(0, viewportWidth)
        guard contentWidth > 0, visibleWidth > 0 else {
            return KaraokeViewportLayout(scrollOffset: 0, visibleFillWidth: 0)
        }

        let normalizedProgress = min(1, max(0, progress))
        let sungWidth = contentWidth * CGFloat(normalizedProgress)
        let anchor = visibleWidth * min(1, max(0, anchorRatio))
        let maxScroll = max(0, contentWidth - visibleWidth)
        let scrollOffset = min(maxScroll, max(0, sungWidth - anchor))
        let visibleFillWidth = min(visibleWidth, max(0, sungWidth - scrollOffset))

        return KaraokeViewportLayout(
            scrollOffset: scrollOffset,
            visibleFillWidth: visibleFillWidth
        )
    }

    private func draw(
        _ string: NSAttributedString,
        atX x: CGFloat,
        atY y: CGFloat,
        drawingWidth: CGFloat
    ) {
        if settings.longLyricMode == .truncate {
            let mutable = NSMutableAttributedString(attributedString: string)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            mutable.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: mutable.length))
            mutable.draw(
                with: NSRect(x: x, y: y, width: drawingWidth, height: bounds.height),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
        } else {
            string.draw(at: NSPoint(x: x, y: y))
        }
    }

    /// Draws the fallback ♪ icon centered in the bounds.
    private func drawIcon() {
        let icon = "♪" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: AppSettings.font(
                name: settings.menuBarFontName,
                size: settings.menuBarFontSize,
                weight: settings.menuBarFontWeight
            ),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = icon.size(withAttributes: attrs)
        let x = (bounds.width - size.width) / 2
        let y = (bounds.height - size.height) / 2 - CGFloat(settings.menuBarVerticalOffset)
        icon.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lineLayoutCache = nil
        needsDisplay = true
    }
}
