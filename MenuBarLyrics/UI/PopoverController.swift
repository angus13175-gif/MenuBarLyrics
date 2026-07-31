import AppKit

/// Manages the lyrics display surface, either as a transient `NSPopover`
/// (default) or a pinned floating `NSPanel` that stays on screen across
/// Space switches.
///
/// Both surfaces host the same shared `LyricScrollView`. The pin button
/// toggles between the two modes. Toggling pin while the popover is
/// shown closes the popover and opens the panel, and vice versa.
///
/// The pinned panel is user-resizable and movable, with its size and
/// position persisted to `UserDefaults` so it is restored on the next show.
///
/// `@MainActor` because all AppKit types it touches are main-actor-isolated
/// under Swift 6.
@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var pinnedPanel: NSPanel?
    private let settings: AppSettings
    private(set) var lyricScrollView: LyricScrollView
    private weak var statusItemButton: NSStatusBarButton?
    private weak var activeBackgroundView: NSVisualEffectView?
    private var surfaceCloseInProgress = false
    private var surfaceOpenNotified = false
    private var suppressedPopoverClose: NSPopover?

    /// Called when the user clicks the settings (⚙) button.
    var onSettings: (() -> Void)?
    /// Called when the user clicks the quit (⏻) button.
    var onQuit: (() -> Void)?
    /// Fired after a lyrics surface becomes visible.
    var onSurfaceOpened: (() -> Void)?
    /// Fired synchronously while the surface is still available for coordinate
    /// conversion. The cat uses this to snapshot its screen position.
    var onSurfaceWillClose: (() -> Void)?
    /// Fired after the surface is no longer visible.
    var onSurfaceClosed: (() -> Void)?
    /// Reports the real, completed visibility state.
    var onVisibilityChanged: ((Bool) -> Void)?

    var isPinned: Bool { pinnedPanel?.isVisible ?? false }
    var isVisible: Bool { popover?.isShown ?? false || isPinned }

    init(statusItemButton: NSStatusBarButton?, settings: AppSettings) {
        self.settings = settings
        self.lyricScrollView = LyricScrollView(settings: settings)
        self.statusItemButton = statusItemButton
        super.init()
        lyricScrollView.applySettings()
    }

    func applySettings() {
        lyricScrollView.applySettings()
        activeBackgroundView?.alphaValue = CGFloat(settings.panelBackgroundOpacity)
        let size = savedPanelSize
        if let popover, popover.isShown, popover.contentSize != size {
            popover.contentSize = size
        }
        if let pinnedPanel, pinnedPanel.contentView?.frame.size != size {
            pinnedPanel.setContentSize(size)
        }
    }

    /// Toggles the transient popover: shows if hidden, hides if shown.
    /// If a pinned panel is visible it is dismissed instead.
    func toggle() {
        if isPinned {
            hidePinned()
        } else if popover?.isShown == true {
            hidePopover()
        } else {
            showPopover()
        }
    }

    /// Toggles the pinned panel: shows if hidden, hides if shown.
    func togglePin() {
        if isPinned {
            hidePinned()
        } else {
            let replacesVisiblePopover = popover?.isShown == true
            hidePopover(suppressLifecycle: replacesVisiblePopover)
            showPinned(notifyOpened: !replacesVisiblePopover)
        }
    }

    /// Pushes the latest state into the shared lyric scroll view.
    func update(renderState: LyricRenderState?, lyrics: LyricDocument?, nowPlaying: NowPlayingSnapshot?, lyricsState: LyricsState = .idle) {
        lyricScrollView.renderState = renderState
        lyricScrollView.lyrics = lyrics
        lyricScrollView.nowPlaying = nowPlaying
        lyricScrollView.lyricsState = lyricsState
    }

    /// Returns the actual lyric-view bounds in screen coordinates. This is the
    /// only panel roaming geometry exposed to the cat; no title-bar or button
    /// inset is reconstructed by hand.
    func playAreaScreenRect() -> NSRect? {
        guard isVisible, let window = lyricScrollView.window else { return nil }
        let windowRect = lyricScrollView.convert(lyricScrollView.bounds, to: nil)
        return window.convertToScreen(windowRect)
    }

    // MARK: - Panel sizing (persisted)

    private let panelMinSize = NSSize(width: 300, height: 400)
    private let panelMaxSize = NSSize(width: 600, height: 800)

    private enum Keys {
        static let panelX = "mbl.panelX"
        static let panelY = "mbl.panelY"
    }

    private var savedPanelSize: NSSize {
        NSSize(
            width: max(panelMinSize.width, min(panelMaxSize.width, CGFloat(settings.panelWidth))),
            height: max(panelMinSize.height, min(panelMaxSize.height, CGFloat(settings.panelHeight)))
        )
    }

    private func savePanelSize(_ size: NSSize) {
        if abs(settings.panelWidth - Double(size.width)) > 0.5 {
            settings.panelWidth = Double(size.width)
        }
        if abs(settings.panelHeight - Double(size.height)) > 0.5 {
            settings.panelHeight = Double(size.height)
        }
    }

    private var savedPanelOrigin: NSPoint? {
        let x = UserDefaults.standard.double(forKey: Keys.panelX)
        let y = UserDefaults.standard.double(forKey: Keys.panelY)
        // UserDefaults returns 0.0 for unset keys; treat the genuine zero
        // origin as unset so we still fall back to the status-item anchor.
        let hasX = UserDefaults.standard.object(forKey: Keys.panelX) != nil
        let hasY = UserDefaults.standard.object(forKey: Keys.panelY) != nil
        guard hasX && hasY else { return nil }
        return NSPoint(x: x, y: y)
    }

    private func savePanelOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set(Double(origin.x), forKey: Keys.panelX)
        UserDefaults.standard.set(Double(origin.y), forKey: Keys.panelY)
    }

    // Keep the three controls visually balanced while reducing their complete
    // footprint (circle, icon, and spacing) by 30 percent.
    private let buttonSize: CGFloat = 25.2
    private let buttonMargin: CGFloat = 5.6

    // MARK: - Transient Popover

    private func showPopover() {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.delegate = self
        let vc = NSViewController()
        let size = savedPanelSize
        let container = NSView(frame: NSRect(origin: .zero, size: size))

        // Background blur.
        let blur = NSVisualEffectView(frame: container.bounds)
        blur.blendingMode = .behindWindow
        blur.material = .hudWindow
        blur.state = .active
        blur.alphaValue = CGFloat(settings.panelBackgroundOpacity)
        blur.autoresizingMask = [.width, .height]
        container.addSubview(blur)
        activeBackgroundView = blur

        // Top-right controls: pin, settings, then a real app quit action.
        let pinButton = makeIconButton("pin.fill", toolTip: "置顶", action: #selector(pinTapped))
        pinButton.frame = buttonFrame(indexFromRight: 2, containerSize: size)
        pinButton.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(pinButton)

        let settingsButton = makeIconButton("gearshape.fill", toolTip: "设置", action: #selector(settingsTapped))
        settingsButton.frame = buttonFrame(indexFromRight: 1, containerSize: size)
        settingsButton.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(settingsButton)

        let quitButton = makeIconButton("power", toolTip: "退出 MenuBarLyrics", action: #selector(quitTapped))
        quitButton.frame = buttonFrame(indexFromRight: 0, containerSize: size)
        quitButton.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(quitButton)

        // Lyrics view: leave space at top for buttons and bottom for progress.
        let topInset = buttonSize + buttonMargin * 2
        let bottomInset: CGFloat = 0
        lyricScrollView.frame = NSRect(x: 0, y: bottomInset,
                                        width: size.width,
                                        height: size.height - topInset - bottomInset)
        lyricScrollView.autoresizingMask = [.width, .height]
        container.addSubview(lyricScrollView)

        vc.view = container
        pop.contentViewController = vc
        pop.contentSize = size

        popover = pop
        if let button = statusItemButton {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        if !pop.isShown {
            popover = nil
            activeBackgroundView = nil
        }
    }

    private func hidePopover(suppressLifecycle: Bool = false) {
        guard let pop = popover else { return }
        if suppressLifecycle {
            suppressedPopoverClose = pop
        } else {
            beginSurfaceClose()
        }
        pop.performClose(nil)

        // `performClose` normally drives the delegate synchronously. Keep a
        // fallback for unusual AppKit states where no close notification fires.
        if !pop.isShown, popover === pop {
            popover = nil
            activeBackgroundView = nil
            if suppressedPopoverClose === pop {
                suppressedPopoverClose = nil
            } else {
                finishSurfaceClose()
            }
        }
    }

    func popoverDidShow(_ notification: Notification) {
        guard let shownPopover = notification.object as? NSPopover,
              popover === shownPopover else { return }
        // Geometry is authoritative only after AppKit attaches the content
        // view to the popover window.
        notifySurfaceOpened()
    }

    func popoverWillClose(_ notification: Notification) {
        guard let closingPopover = notification.object as? NSPopover,
              suppressedPopoverClose !== closingPopover else { return }
        beginSurfaceClose()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closingPopover = notification.object as? NSPopover else { return }
        if popover === closingPopover {
            popover = nil
            activeBackgroundView = nil
        }
        if suppressedPopoverClose === closingPopover {
            suppressedPopoverClose = nil
            return
        }
        finishSurfaceClose()
    }

    // MARK: - Pinned Panel

    private func showPinned(notifyOpened: Bool = true) {
        let size = savedPanelSize
        // A borderless panel cannot be user-resized/moved, so use a titled,
        // resizable panel with a transparent full-size title bar to keep the
        // clean HUD look while allowing native resize & drag.
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        // Hide the title bar chrome but keep resize + drag.
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = panelMinSize
        panel.maxSize = panelMaxSize

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizingMask = [.width, .height]
        panel.contentView = container

        let blur = NSVisualEffectView(frame: container.bounds)
        blur.blendingMode = .behindWindow
        blur.material = .hudWindow
        blur.state = .active
        blur.alphaValue = CGFloat(settings.panelBackgroundOpacity)
        blur.autoresizingMask = [.width, .height]
        container.addSubview(blur)
        activeBackgroundView = blur

        let pinButton = makeIconButton("pin.fill", toolTip: "置顶", action: #selector(pinTapped))
        pinButton.frame = buttonFrame(indexFromRight: 2, containerSize: size)
        pinButton.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(pinButton)

        let settingsButton = makeIconButton("gearshape.fill", toolTip: "设置", action: #selector(settingsTapped))
        settingsButton.frame = buttonFrame(indexFromRight: 1, containerSize: size)
        settingsButton.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(settingsButton)

        let quitButton = makeIconButton("power", toolTip: "退出 MenuBarLyrics", action: #selector(quitTapped))
        quitButton.frame = buttonFrame(indexFromRight: 0, containerSize: size)
        quitButton.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(quitButton)

        // Lyrics view: leave space at top for buttons and bottom for progress.
        let topInset = buttonSize + buttonMargin * 2
        let bottomInset: CGFloat = 0
        lyricScrollView.frame = NSRect(x: 0, y: bottomInset,
                                        width: size.width,
                                        height: size.height - topInset - bottomInset)
        lyricScrollView.autoresizingMask = [.width, .height]
        container.addSubview(lyricScrollView)

        // Restore saved origin; otherwise position below the status item.
        if let saved = savedPanelOrigin {
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect.zero
            let clampedX = max(screenFrame.minX,
                               min(saved.x, screenFrame.maxX - size.width))
            let clampedY = max(screenFrame.minY,
                               min(saved.y, screenFrame.maxY - size.height))
            panel.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        } else if let button = statusItemButton, let window = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let anchor = window.convertToScreen(buttonRect)
            let screen = window.screen ?? NSScreen.main!
            let visible = screen.visibleFrame
            let x = max(visible.minX,
                        min(anchor.midX - size.width / 2, visible.maxX - size.width))
            let y = max(visible.minY,
                        min(anchor.minY - size.height, visible.maxY - size.height))
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Persist size/position changes as the user resizes or moves the panel.
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidResize(_:)),
            name: NSWindow.didResizeNotification, object: panel
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidMove(_:)),
            name: NSWindow.didMoveNotification, object: panel
        )

        pinnedPanel = panel
        panel.orderFront(nil)
        if notifyOpened { notifySurfaceOpened() }
    }

    private func hidePinned() {
        guard pinnedPanel != nil else { return }
        beginSurfaceClose()
        if let panel = pinnedPanel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: panel)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: panel)
            panel.orderOut(nil)
        }
        pinnedPanel = nil
        activeBackgroundView = nil
        finishSurfaceClose()
    }

    private func notifySurfaceOpened() {
        guard !surfaceOpenNotified else { return }
        surfaceOpenNotified = true
        surfaceCloseInProgress = false
        onSurfaceOpened?()
        onVisibilityChanged?(true)
    }

    private func beginSurfaceClose() {
        guard !surfaceCloseInProgress else { return }
        surfaceCloseInProgress = true
        onSurfaceWillClose?()
    }

    private func finishSurfaceClose() {
        guard surfaceCloseInProgress else { return }
        surfaceCloseInProgress = false
        surfaceOpenNotified = false
        onSurfaceClosed?()
        onVisibilityChanged?(false)
    }

    @objc private func panelDidResize(_ note: Notification) {
        guard let panel = note.object as? NSPanel, panel === pinnedPanel else { return }
        savePanelSize(panel.contentView?.frame.size ?? panel.frame.size)
    }

    @objc private func panelDidMove(_ note: Notification) {
        guard let panel = note.object as? NSPanel, panel === pinnedPanel else { return }
        savePanelOrigin(panel.frame.origin)
    }

    /// Creates a compact icon button with a subtle circular background.
    private func buttonFrame(indexFromRight: Int, containerSize: NSSize) -> NSRect {
        NSRect(
            x: containerSize.width - buttonMargin - buttonSize
                - CGFloat(indexFromRight) * (buttonSize + buttonMargin),
            y: containerSize.height - buttonSize - buttonMargin,
            width: buttonSize,
            height: buttonSize
        )
    }

    private func makeIconButton(_ symbolName: String, toolTip: String, action: Selector) -> NSButton {
        let btn = NSButton(title: "", target: self, action: action)
        btn.isBordered = false
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        btn.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(configuration)
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyDown
        btn.contentTintColor = .black
        btn.toolTip = toolTip
        btn.setAccessibilityLabel(toolTip)
        btn.wantsLayer = true
        btn.layer?.cornerRadius = buttonSize / 2
        btn.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        return btn
    }

    @objc private func pinTapped() {
        togglePin()
    }

    @objc private func settingsTapped() {
        onSettings?()
    }

    @objc private func quitTapped() {
        onQuit?()
    }
}
