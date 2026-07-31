import AppKit

/// A cat-sized transparent window that moves directly in global screen space.
///
/// The window is intentionally not a full-screen overlay. A primary click is
/// reserved as a recovery affordance: when macOS has hidden the lyric status
/// item for lack of space, the still-visible cat can open the width settings.
@MainActor
final class CatSpriteWindow: NSPanel {
    var onPrimaryAction: (() -> Void)?

    init(initialFrame: NSRect, spriteView: NSView = NSView()) {
        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        spriteView.frame = NSRect(origin: .zero, size: initialFrame.size)
        spriteView.autoresizingMask = [.width, .height]
        spriteView.wantsLayer = true
        spriteView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = spriteView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            performPrimaryAction()
            return
        }
        super.sendEvent(event)
    }

    func performPrimaryAction() {
        onPrimaryAction?()
    }

    /// Applies an AppKit screen-coordinate origin and the interpolated sprite
    /// size without converting through a view or a surface window.
    func updateFrame(
        screenOrigin: CGPoint,
        size: CGSize,
        display: Bool = true
    ) {
        setFrame(
            NSRect(origin: screenOrigin, size: size),
            display: display,
            animate: false
        )
    }
}
