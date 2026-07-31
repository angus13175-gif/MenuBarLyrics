import AppKit

/// Delegate notified when the menu bar status item is clicked.
///
/// `@MainActor` because the click handler runs on the main thread and the
/// conforming controller (`AppDelegate`) is main-actor-isolated.
@MainActor
protocol StatusItemControllerDelegate: AnyObject {
    func statusItemClicked()
}

/// Manages the `NSStatusItem` and embeds a `LyricMenuBarView` inside its
/// status bar button.
///
/// The status bar button hosts the custom lyric view via Auto Layout
/// constraints, and forwards click events to its delegate. Updates to the
/// render state, lyrics, and menu width are forwarded to the embedded view.
///
/// `@MainActor` because all AppKit types it touches are main-actor-isolated
/// under Swift 6.
@MainActor
final class StatusItemController {
    static let autosaveName = "MainLyricsStatusItem"

    private let statusItem: NSStatusItem
    private let lyricView: LyricMenuBarView
    private var lastKnownMenuBarScreenRect: NSRect?
    weak var delegate: StatusItemControllerDelegate?

    /// The status bar button, exposed so a popover can anchor to it.
    var statusItemButton: NSStatusBarButton? {
        statusItem.button
    }

    init(settings: AppSettings) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.autosaveName
        lyricView = LyricMenuBarView(settings: settings)

        if let button = statusItem.button {
            button.addSubview(lyricView)
            lyricView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                lyricView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                lyricView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                lyricView.topAnchor.constraint(equalTo: button.topAnchor),
                lyricView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }

        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
    }

    /// Pushes the latest render state, lyrics, and width into the lyric view
    /// and adjusts the status item length to match the chosen menu width.
    func update(renderState: LyricRenderState?, lyrics: LyricDocument?, width: CGFloat) {
        lyricView.renderState = renderState
        lyricView.lyrics = lyrics
        lyricView.menuWidth = width
        applyLengthIfNeeded(width)
    }

    func applySettings(width: CGFloat) {
        lyricView.menuWidth = width
        lyricView.applySettings()
        applyLengthIfNeeded(width)
    }

    /// Render-state updates can arrive at display-link frequency. Reassigning
    /// an unchanged status-item length causes menu-bar managers such as Thaw to
    /// repeatedly reconsider the item's placement, so geometry is changed only
    /// when the user actually changes the width setting.
    private func applyLengthIfNeeded(_ requestedWidth: CGFloat) {
        let target = max(24, requestedWidth)
        guard Self.shouldApplyLength(current: statusItem.length, target: target) else { return }
        statusItem.length = target
    }

    static func shouldApplyLength(current: CGFloat, target: CGFloat) -> Bool {
        current < 0 || abs(current - target) > 0.5
    }

    func setCatReservedWidth(_ width: CGFloat) {
        lyricView.catReservedWidth = max(0, width)
    }

    func setCatVisible(_ visible: Bool) {
        lyricView.catVisible = visible
    }

    /// Returns the actual hosted lyric view bounds in global screen
    /// coordinates. Cat placement never assumes a status-bar origin.
    func menuBarScreenRect() -> NSRect? {
        let screens = NSScreen.screens
        if let window = lyricView.window {
            let windowRect = lyricView.convert(lyricView.bounds, to: nil)
            let screenRect = window.convertToScreen(windowRect)

            // macOS temporarily parks status-item windows far off-screen while
            // an automatically hidden menu bar is collapsed. Cache genuine
            // geometry, but never expose the parking coordinate to the cat.
            if Self.isUsableMenuBarScreenRect(
                screenRect,
                screenFrames: screens.map(\.frame)
            ) {
                lastKnownMenuBarScreenRect = screenRect
                return screenRect
            }
        }

        if let cached = lastKnownMenuBarScreenRect,
           Self.isUsableMenuBarScreenRect(cached, screenFrames: screens.map(\.frame)) {
            return cached
        }

        // On launch with an auto-hidden menu bar there may never have been a
        // valid status-item coordinate to cache. Use a stable top-of-screen
        // anchor so an enabled cat is immediately visible, then switch to the
        // real status-item bounds as soon as AppKit publishes them.
        guard let screen = lyricView.window?.screen ?? NSScreen.main ?? screens.first else {
            return nil
        }
        return Self.fallbackMenuBarScreenRect(
            screenFrame: screen.frame,
            preferredWidth: max(24, lyricView.bounds.width)
        )
    }

    static func fallbackMenuBarScreenRect(
        screenFrame: NSRect,
        preferredWidth: CGFloat,
        trailingClearance: CGFloat = 200
    ) -> NSRect {
        let width = min(max(24, preferredWidth), max(24, screenFrame.width))
        let height = max(16, NSStatusBar.system.thickness)
        let x = max(screenFrame.minX, screenFrame.maxX - width - trailingClearance)
        return NSRect(
            x: x,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    /// Rejects the two off-screen parking patterns used by an automatically
    /// hidden menu bar: a far-away x coordinate and an otherwise valid-looking
    /// rectangle at the bottom of a display. Negative-coordinate displays are
    /// accepted as long as the anchor is in that display's top menu-bar band.
    static func isUsableMenuBarScreenRect(
        _ rect: NSRect,
        screenFrames: [NSRect]
    ) -> Bool {
        screenFrames.contains { screenFrame in
            guard screenFrame.intersects(rect) else { return false }
            let topBandHeight = max(64, NSStatusBar.system.thickness * 2)
            return rect.midY >= screenFrame.maxY - topBandHeight
                && rect.midY <= screenFrame.maxY + 8
        }
    }

    @objc private func handleClick() {
        delegate?.statusItemClicked()
    }
}
