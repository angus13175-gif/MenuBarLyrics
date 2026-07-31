import AppKit

/// Scrollable lyrics view backed by a real `NSScrollView`.
///
/// Renders every lyric line as an `NSTextField` inside a *flipped* document
/// view, so the surface genuinely scrolls (mouse wheel / trackpad) instead of
/// only painting a fixed ±4-line window. The current line is highlighted
/// (larger font, accent color) and auto-centered; when the user scrolls
/// manually, auto-follow pauses and a "回到当前歌词" (back to current) button
/// appears, resuming automatically after ~4s of inactivity. A thin progress
/// bar is pinned to the bottom of the scroll view, independent of scroll
/// position.
///
/// Coordinate notes: the document view overrides `isFlipped` to return `true`,
/// so line 0 lives at the top (`y = 0`) and line `i` at `y = i * lineHeight`.
/// The clip view honors the document's flipped state, making `bounds.origin.y`
/// the distance scrolled from the top.
final class LyricScrollView: NSScrollView {

    // MARK: - Public state

    var lyrics: LyricDocument? {
        didSet {
            if !sameDocument(oldValue, lyrics) {
                rebuildLines()
            }
            updateProgressBar()
        }
    }
    var renderState: LyricRenderState? {
        didSet {
            if oldValue?.lineIndex != renderState?.lineIndex {
                updateCurrentLine()
            }
            updateProgressBar()
        }
    }
    var nowPlaying: NowPlayingSnapshot? {
        didSet {
            updateProgressBar()
            if !lyricDocumentView.hasLines {
                let title = nowPlaying?.title.trimmingCharacters(in: .whitespaces) ?? ""
                lyricDocumentView.placeholderText = title.isEmpty ? "No lyrics" : title
                lyricDocumentView.needsDisplay = true
            }
        }
    }

    /// Lyrics loading state for status display (loading / no result / failed).
    var lyricsState: LyricsState = .idle {
        didSet {
            if statusKind(of: oldValue) != statusKind(of: lyricsState) {
                updateStatusDisplay()
            }
        }
    }

    /// Called when user clicks "重新搜索" (re-search).
    var onResearchLyrics: (() -> Void)?

    /// Exposed internally for layout regression tests.
    var progressBarLayoutFrame: NSRect { progressBar.frame }
    var effectiveLineHeight: CGFloat { lineHeight }

    // MARK: - Layout constants

    private let settings: AppSettings
    private var lineHeight: CGFloat {
        max(CGFloat(settings.panelLineSpacing), CGFloat(settings.panelFontSize) + 8)
    }
    private var currentLineFontSize: CGFloat { CGFloat(settings.panelFontSize + 2) }
    private var otherFontSize: CGFloat { CGFloat(settings.panelFontSize) }
    private let horizontalPadding: CGFloat = 16
    private let progressBarHeight: CGFloat = 6
    private let progressBarBottomInset: CGFloat = 8

    // MARK: - Subviews

    /// Custom flipped document view that hosts every lyric line (and draws a
    /// centered placeholder when there is nothing to show).
    private let lyricDocumentView = LyricDocumentView()
    private var lineViews: [NSTextField] = []

    /// True while the user is manually browsing, pausing auto-follow.
    private var isManualScrolling = false
    private var manualScrollTimer: DispatchSourceTimer?
    private var currentLineIndex: Int? = nil

    private lazy var progressBar = ProgressBarView()
    private lazy var backButton: NSButton = {
        let btn = NSButton(title: "回到当前歌词", target: self, action: #selector(backToCurrent))
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.isHidden = true
        return btn
    }()

    /// "重新搜索" button shown when no lyrics found.
    private lazy var researchButton: NSButton = {
        let btn = NSButton(title: "重新搜索", target: self, action: #selector(researchTapped))
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.isHidden = true
        return btn
    }()

    // MARK: - Init

    init(settings: AppSettings) {
        self.settings = settings
        super.init(frame: .zero)
        setupScrollView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applySettings() {
        for field in lineViews {
            field.font = AppSettings.font(
                name: settings.panelFontName,
                size: Double(otherFontSize),
                weight: settings.panelFontWeight
            )
            field.textColor = AppSettings.color(fromHex: settings.panelOtherLineColor)
        }
        if let currentLineIndex {
            updateCurrentLine(lineIndexOverride: currentLineIndex, shouldScroll: false)
        }
        lyricDocumentView.font = AppSettings.font(
            name: settings.panelFontName,
            size: settings.panelFontSize,
            weight: settings.panelFontWeight
        )
        lyricDocumentView.textColor = AppSettings.color(fromHex: settings.panelOtherLineColor)
        lyricDocumentView.needsDisplay = true
        relayout()
    }

    private enum StatusKind: Equatable {
        case idle, loading, loaded, noResult, failed
    }

    private func statusKind(of state: LyricsState) -> StatusKind {
        switch state {
        case .idle: return .idle
        case .loading: return .loading
        case .loaded: return .loaded
        case .noResult: return .noResult
        case .failed: return .failed
        }
    }

    private func sameDocument(_ lhs: LyricDocument?, _ rhs: LyricDocument?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.lookupKey == rhs.lookupKey
                && lhs.source == rhs.source
                && lhs.sourceRecordIdentifier == rhs.sourceRecordIdentifier
                && lhs.globalOffset == rhs.globalOffset
                && lhs.lines.count == rhs.lines.count
        default:
            return false
        }
    }

    private func setupScrollView() {
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder

        // Reserve space at the bottom for the progress bar and overlay buttons
        // so lyric content never scrolls under them.
        contentView.automaticallyAdjustsContentInsets = false
        contentView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 28, right: 0)

        lyricDocumentView.wantsLayer = true
        self.documentView = lyricDocumentView

        // Fixed overlays live on the scroll view itself (not the document
        // view) so they never scroll with the content.
        addSubview(backButton)
        addSubview(progressBar)
        addSubview(researchButton)
    }

    deinit {
        manualScrollTimer?.cancel()
    }

    // MARK: - Resize handling

    /// Repositions fixed overlays and resizes the document view / line widths
    /// to match the current bounds. `super.setFrameSize` runs NSScrollView's
    /// `tile()` first, so any origin we set here wins.
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        relayout()
    }

    private func relayout() {
        let w = bounds.width
        guard w > 0 else { return }

        // NSScrollView is flipped on macOS: y=0 is the top. Positioning the
        // bar at a small y therefore put it over the toolbar buttons. Compute
        // its y from the lower edge explicitly.
        let progressY = max(0, bounds.height - progressBarBottomInset - progressBarHeight)
        progressBar.frame = NSRect(
            x: horizontalPadding,
            y: progressY,
            width: max(0, w - 2 * horizontalPadding),
            height: progressBarHeight
        )

        // "Back to current" button centered horizontally, just above the bar.
        let btnSize = backButton.fittingSize
        backButton.frame = NSRect(
            x: (w - btnSize.width) / 2,
            y: max(0, progressY - btnSize.height - 6),
            width: btnSize.width,
            height: btnSize.height
        )

        // "重新搜索" button centered, above back button.
        let researchSize = researchButton.fittingSize
        researchButton.frame = NSRect(
            x: (w - researchSize.width) / 2,
            y: max(0, progressY - btnSize.height - researchSize.height - 10),
            width: researchSize.width,
            height: researchSize.height
        )

        // Document view width tracks the visible width; height grows to fit all
        // lines (but never shorter than the viewport, so the placeholder and
        // short lyrics center nicely).
        let contentHeight = CGFloat(lineViews.count) * lineHeight
        let visibleHeight = contentView.bounds.height
        let docHeight = max(visibleHeight, contentHeight)
        lyricDocumentView.frame = NSRect(x: 0, y: 0, width: w, height: docHeight)

        let fieldWidth = max(0, w - 2 * horizontalPadding)
        for (i, field) in lineViews.enumerated() {
            var f = field.frame
            f.origin.y = CGFloat(i) * lineHeight
            f.size.width = fieldWidth
            field.frame = f
        }

        // Keep the current line centered after a resize (unless browsing).
        if !isManualScrolling, let idx = currentLineIndex {
            scrollToLine(idx, animated: false)
        }
    }

    // MARK: - Building lines

    private func rebuildLines() {
        lineViews.forEach { $0.removeFromSuperview() }
        lineViews.removeAll()
        currentLineIndex = nil

        guard let lyrics, !lyrics.lines.isEmpty else {
            let title = nowPlaying?.title.trimmingCharacters(in: .whitespaces) ?? ""
            lyricDocumentView.placeholderText = title.isEmpty ? "No lyrics" : title
            lyricDocumentView.hasLines = false
            relayout()
            lyricDocumentView.needsDisplay = true
            return
        }

        lyricDocumentView.hasLines = true
        let fieldWidth = max(0, bounds.width - 2 * horizontalPadding)

        for (i, line) in lyrics.lines.enumerated() {
            let text = line.text.isEmpty ? "♪" : line.text
            let field = NSTextField(labelWithString: text)
            field.font = AppSettings.font(
                name: settings.panelFontName,
                size: Double(otherFontSize),
                weight: settings.panelFontWeight
            )
            field.textColor = AppSettings.color(fromHex: settings.panelOtherLineColor)
            field.alignment = .left
            field.isSelectable = false
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.cell?.truncatesLastVisibleLine = true
            // Flipped doc: line 0 at the top -> y = i * lineHeight.
            field.frame = NSRect(
                x: horizontalPadding,
                y: CGFloat(i) * lineHeight,
                width: fieldWidth,
                height: lineHeight
            )
            lyricDocumentView.addSubview(field)
            lineViews.append(field)
        }

        relayout()

        // Re-apply styling / scroll if a render state is already present.
        if let state = renderState, let idx = state.lineIndex {
            updateCurrentLine(lineIndexOverride: idx)
        }
    }

    // MARK: - Current line styling & auto-scroll

    private func updateCurrentLine(lineIndexOverride: Int? = nil, shouldScroll: Bool = true) {
        let idx = lineIndexOverride ?? renderState?.lineIndex
        guard let lyrics, !lyrics.lines.isEmpty,
              let lineIndex = idx, lineIndex >= 0, lineIndex < lineViews.count else {
            return
        }

        for (i, field) in lineViews.enumerated() {
            let isCurrent = (i == lineIndex)
            let distance = abs(i - lineIndex)
            field.font = AppSettings.font(
                name: settings.panelFontName,
                size: Double(isCurrent ? currentLineFontSize : otherFontSize),
                weight: settings.panelFontWeight
            )
            field.textColor = isCurrent
                ? AppSettings.color(fromHex: settings.panelCurrentLineColor)
                : AppSettings.color(fromHex: settings.panelOtherLineColor)
                    .withAlphaComponent(max(0.2, 1.0 - CGFloat(distance) * 0.15))
        }

        if shouldScroll, !isManualScrolling {
            scrollToLine(lineIndex, animated: true)
        }
        currentLineIndex = lineIndex
    }

    /// Centers the given line index within the visible clip-view area.
    private func scrollToLine(_ index: Int, animated: Bool) {
        guard let lyrics, !lyrics.lines.isEmpty else { return }
        let visibleHeight = contentView.bounds.height
        guard visibleHeight > 0 else { return }

        let docHeight = CGFloat(lyrics.lines.count) * lineHeight
        // Flipped doc: line i occupies y in [i*lineHeight, (i+1)*lineHeight].
        let lineTop = CGFloat(index) * lineHeight
        let targetOrigin = lineTop - (visibleHeight - lineHeight) / 2
        let clampedOrigin = max(0, min(targetOrigin, docHeight - visibleHeight))
        let targetPoint = NSPoint(x: 0, y: clampedOrigin)

        let clip = contentView
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(targetPoint)
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.reflectScrolledClipView(self.contentView)
            })
        } else {
            clip.setBoundsOrigin(targetPoint)
            reflectScrolledClipView(clip)
        }
    }

    // MARK: - Manual scroll detection

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        // Only react to actual scroll deltas (covers wheel + trackpad +
        // momentum). Programmatic scrolls never enter here, so they never
        // trip the "manual" state.
        guard !lineViews.isEmpty else { return }
        guard event.scrollingDeltaY != 0 || event.scrollingDeltaX != 0 else { return }
        isManualScrolling = true
        backButton.isHidden = false
        resetManualScrollTimer()
    }

    /// Resets (or starts) the ~4s inactivity timer that resumes auto-follow.
    private func resetManualScrollTimer() {
        manualScrollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(1, settings.panelAutoResumeDelay))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.isManualScrolling = false
            self.backButton.isHidden = true
            if let idx = self.currentLineIndex {
                self.scrollToLine(idx, animated: true)
            }
        }
        timer.resume()
        manualScrollTimer = timer
    }

    @objc private func backToCurrent() {
        isManualScrolling = false
        backButton.isHidden = true
        manualScrollTimer?.cancel()
        if let idx = currentLineIndex {
            scrollToLine(idx, animated: true)
        }
    }

    // MARK: - Lyrics loading status

    /// Updates the placeholder text and "重新搜索" button based on lyricsState.
    private func updateStatusDisplay() {
        // Only show status when there are no loaded lyrics
        let hasLyrics = lyrics != nil && !(lyrics?.lines.isEmpty ?? true)

        switch lyricsState {
        case .idle:
            researchButton.isHidden = true
            if !hasLyrics {
                let title = nowPlaying?.title.trimmingCharacters(in: .whitespaces) ?? ""
                lyricDocumentView.placeholderText = title.isEmpty ? "" : title
            }
        case .loading:
            researchButton.isHidden = true
            if !hasLyrics {
                lyricDocumentView.placeholderText = "正在查找歌词…"
            }
        case .loaded:
            researchButton.isHidden = true
        case .noResult:
            researchButton.isHidden = hasLyrics
            if !hasLyrics {
                lyricDocumentView.placeholderText = "未找到同步歌词"
            }
        case .failed:
            researchButton.isHidden = hasLyrics
            if !hasLyrics {
                lyricDocumentView.placeholderText = "歌词获取失败"
            }
        }
        lyricDocumentView.needsDisplay = true
        relayout()
    }

    @objc private func researchTapped() {
        onResearchLyrics?()
    }

    // MARK: - Progress bar

    private func updateProgressBar() {
        guard let np = nowPlaying,
              let duration = np.duration ?? renderState?.duration,
              duration > 0 else {
            progressBar.progress = 0
            return
        }
        let elapsed = renderState?.estimatedElapsed ?? np.elapsedTime ?? 0
        let progress = CGFloat(min(1.0, max(0.0, elapsed / duration)))
        progressBar.progress = progress
    }
}

// MARK: - Document view (flipped; draws a placeholder when empty)

private final class LyricDocumentView: NSView {
    override var isFlipped: Bool { true }

    var placeholderText: String = "No lyrics" { didSet { needsDisplay = true } }
    var hasLines: Bool = false { didSet { needsDisplay = true } }
    var font: NSFont = .systemFont(ofSize: 13) { didSet { needsDisplay = true } }
    var textColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard !hasLines else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let h: CGFloat = 20
        let rect = NSRect(
            x: 16,
            y: bounds.height / 2 - h / 2,
            width: max(0, bounds.width - 32),
            height: h
        )
        (placeholderText as NSString).draw(in: rect, withAttributes: attrs)
    }
}

// MARK: - Progress bar

private final class ProgressBarView: NSView {
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
        if progress > 0 {
            let fillRect = NSRect(
                x: 0, y: 0,
                width: bounds.width * progress,
                height: bounds.height
            )
            NSColor.controlAccentColor.setFill()
            fillRect.fill()
        }
    }
}
