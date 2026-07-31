import AppKit
import QuartzCore

enum CatPlaybackMode: Equatable {
    case noMedia
    case paused
    case playing

    /// Enabling the feature must always produce a visible companion. Playback
    /// mode changes its behaviour, not whether the user's setting is honoured.
    var animation: CatAnimation {
        switch self {
        case .noMedia: .walk
        case .paused: .idle
        case .playing: .dj
        }
    }

    var reservesMenuBarWidth: Bool {
        self != .noMedia
    }
}

/// Coordinates the cat's pure motion state with the two real AppKit surfaces.
///
/// The sprite window is always cat-sized. Every position stored here is a
/// global screen coordinate, so closing a popover cannot invalidate an active
/// rise-to-menu-bar animation.
@MainActor
final class CatController {
    private let settings: AppSettings
    private weak var statusItemController: StatusItemController?
    private weak var popoverController: PopoverController?
    private let spriteView = CatSpriteView()
    private let spriteWindow: CatSpriteWindow
    private var configuration = CatMotionConfiguration.default

    private var motionState = CatMotionState.initial()
    private var timer: DispatchSourceTimer?
    private var lastTick: CFTimeInterval = 0
    private var animationElapsed: TimeInterval = 0
    private var menuBarVelocity: CGFloat = 18
    private var currentAnimation: CatAnimation?
    private var isSuspended = false
    private var awaitingMenuBarAnchor = false
    private var lastAppliedEnabled: Bool?
    private var lastAppliedCatSize: CGFloat?
    private var lastAppliedSkin: CatSkin?
    private var catHorizontalOffset: CGFloat = 0
    private var catVerticalOffset: CGFloat = 0
    private var playbackMode: CatPlaybackMode = .noMedia
    private var lastReservedMenuBarWidth: CGFloat = -1
    private var lastVisibility = false

    // Full-screen detection
    private var isOnFullScreenSpace = false
    private var fullScreenCheckWorkItem: DispatchWorkItem?
    private var fullScreenObservers: [NSObjectProtocol] = []

    var onReservedMenuBarWidthChanged: ((CGFloat) -> Void)?
    var onCatVisibilityChanged: ((Bool) -> Void)?
    /// Lets the visible cat recover a lyric status item that macOS has hidden
    /// due to insufficient menu-bar space.
    var onSettingsRequested: (() -> Void)?

    init(
        settings: AppSettings,
        statusItemController: StatusItemController,
        popoverController: PopoverController
    ) {
        self.settings = settings
        self.statusItemController = statusItemController
        self.popoverController = popoverController
        spriteWindow = CatSpriteWindow(
            initialFrame: NSRect(origin: .zero, size: configuration.perchedSize),
            spriteView: spriteView
        )
        spriteWindow.onPrimaryAction = { [weak self] in
            self?.onSettingsRequested?()
        }
        spriteView.frameToDraw = .sit
        spriteView.skin = settings.catSkin
        startFullScreenMonitoring()
    }

    func applySettings() {
        let enabled = settings.catEnabled
        let enabledChanged = lastAppliedEnabled != enabled
        let requestedCatSize = CGFloat(settings.catSize)
        let sizeChanged = lastAppliedCatSize != requestedCatSize
        let requestedSkin = settings.catSkin
        let skinChanged = lastAppliedSkin != requestedSkin
        let requestedCatHorizontalOffset = CGFloat(settings.catHorizontalOffset)
        let horizontalOffsetChanged = catHorizontalOffset != requestedCatHorizontalOffset
        let requestedCatVerticalOffset = CGFloat(settings.catVerticalOffset)
        let verticalOffsetChanged = catVerticalOffset != requestedCatVerticalOffset
        lastAppliedEnabled = enabled
        lastAppliedCatSize = requestedCatSize
        lastAppliedSkin = requestedSkin
        catHorizontalOffset = requestedCatHorizontalOffset
        catVerticalOffset = requestedCatVerticalOffset
        if skinChanged {
            spriteView.skin = requestedSkin
            currentAnimation = nil
            spriteView.needsDisplay = true
        }
        if sizeChanged {
            configuration = CatMotionConfiguration.scaled(menuBarSide: requestedCatSize)
            applyCurrentSizeToMotionState()
        }
        let menuOrigin = statusItemController?.menuBarScreenRect().map { menuBarOrigin(in: $0) }

        if enabledChanged {
            motionState = CatMotionReducer.reduce(
                state: motionState,
                event: .enabledChanged(
                    isEnabled: enabled,
                    menuBarScreenOrigin: menuOrigin
                ),
                configuration: configuration
            )

            // The switch can be enabled while a lyrics surface is already
            // open. Capture that fact now so later pause/resume events choose
            // the correct destination.
            if enabled {
                if popoverController?.isVisible == true {
                    beginSurfaceEntry()
                } else {
                    awaitingMenuBarAnchor = menuOrigin == nil
                }
            } else {
                awaitingMenuBarAnchor = false
            }
        }

        guard enabled, !isSuspended else {
            hideCat()
            return
        }

        reconcilePresentation(
            snapToDestination: enabledChanged || sizeChanged || skinChanged
                || horizontalOffsetChanged || verticalOffsetChanged
        )
        startTimer()
    }

    /// Playback truth comes only from `NowPlayingSnapshot.isPlaying`.
    func playbackChanged(isPlaying: Bool, hasMedia: Bool) {
        let nextMode: CatPlaybackMode = hasMedia
            ? (isPlaying ? .playing : .paused)
            : .noMedia
        let modeChanged = playbackMode != nextMode
        playbackMode = nextMode

        motionState = CatMotionReducer.reduce(
            state: motionState,
            event: .playbackChanged(isPlaying: isPlaying),
            configuration: configuration
        )

        if nextMode == .noMedia,
           motionState.isEnabled,
           (motionState.isSurfaceVisible || popoverController?.isVisible == true) {
            beginSurfaceEntry()
        }

        guard modeChanged, settings.catEnabled, !isSuspended else { return }
        reconcilePresentation(snapToDestination: nextMode == .playing)
    }

    func surfaceOpened() {
        beginSurfaceEntry()
        guard settings.catEnabled, !isSuspended else { return }
        reconcilePresentation(snapToDestination: motionState.isPlaying)
    }

    private func beginSurfaceEntry() {
        awaitingMenuBarAnchor = false
        let playArea = popoverController?.playAreaScreenRect()
        let entryOrigin = playArea.map(surfaceEntryOrigin)
            ?? motionState.authoritativeScreenOrigin
            ?? .zero
        motionState = CatMotionReducer.reduce(
            state: motionState,
            event: .surfaceOpened(
                playAreaScreenRect: playArea,
                entryScreenOrigin: entryOrigin
            ),
            configuration: configuration
        )
    }

    /// Called before AppKit hides the popover/panel. The current screen origin
    /// is copied synchronously into the exit transition, so the following
    /// `surfaceClosed()` never needs to query a disappearing view hierarchy.
    func surfaceWillClose() {
        guard settings.catEnabled else { return }
        let currentOrigin = motionState.authoritativeScreenOrigin ?? spriteWindow.frame.origin
        publish(reservesMenuBarWidth: playbackMode.reservesMenuBarWidth, visible: true)
        guard let menuRect = statusItemController?.menuBarScreenRect() else {
            // An auto-hidden menu bar can temporarily park its status window
            // off-screen. Keep the authoritative panel origin, hide the sprite,
            // and start the rise as soon as a real menu-bar anchor returns.
            motionState.authoritativeScreenOrigin = currentOrigin
            awaitingMenuBarAnchor = true
            spriteWindow.orderOut(nil)
            publish(djMode: false, visible: false)
            return
        }
        awaitingMenuBarAnchor = false
        motionState = CatMotionReducer.reduce(
            state: motionState,
            event: .surfaceWillClose(
                currentScreenOrigin: currentOrigin,
                menuBarTargetScreenOrigin: leadingMenuBarOrigin(in: menuRect)
            ),
            configuration: configuration
        )
        reconcilePresentation(snapToDestination: motionState.isPlaying)
    }

    func surfaceClosed() {
        motionState = CatMotionReducer.reduce(
            state: motionState,
            event: .surfaceClosed,
            configuration: configuration
        )
        guard settings.catEnabled, !isSuspended else { return }
        if awaitingMenuBarAnchor {
            spriteWindow.orderOut(nil)
            publish(djMode: false, visible: false)
            startTimer()
            return
        }
        reconcilePresentation(snapToDestination: motionState.isPlaying)
    }

    func suspend() {
        isSuspended = true
        stopTimer()
        spriteWindow.orderOut(nil)
    }

    func resume() {
        isSuspended = false
        applySettings()
    }

    func shutdown() {
        stopFullScreenMonitoring()
        stopTimer()
        spriteWindow.orderOut(nil)
    }

    private func reconcilePresentation(snapToDestination: Bool) {
        guard motionState.isEnabled else {
            hideCat()
            return
        }

        // Keep the cat hidden when another app is full-screen, even if some
        // other event (wake, settings change) triggered reconciliation.
        if isOnFullScreenSpace {
            spriteWindow.orderOut(nil)
            stopTimer()
            return
        }

        if awaitingMenuBarAnchor,
           statusItemController?.menuBarScreenRect() == nil {
            spriteWindow.orderOut(nil)
            publish(djMode: false, visible: false)
            startTimer()
            return
        }

        if motionState.phase.isSurfaceMotion {
            let reservesWidth = motionState.phase == .exitingSurface
                && playbackMode.reservesMenuBarWidth
            publish(reservesMenuBarWidth: reservesWidth, visible: true)
            renderCurrentState()
            spriteWindow.orderFrontRegardless()
            startTimer()
            return
        }

        if playbackMode == .paused {
            // MediaRemote commonly retains a stale paused browser/video item
            // across launches. Treat pause as an idle pose instead of hiding
            // an explicitly enabled feature.
            guard let menuRect = statusItemController?.menuBarScreenRect() else {
                awaitingMenuBarAnchor = true
                spriteWindow.orderOut(nil)
                publish(djMode: false, visible: false)
                startTimer()
                return
            }
            awaitingMenuBarAnchor = false
            motionState.phase = .perched
            motionState.transition = nil
            motionState.spriteSize = configuration.perchedSize
            motionState.authoritativeScreenOrigin = leadingMenuBarOrigin(in: menuRect)
            publish(reservesMenuBarWidth: true, visible: true)
            renderCurrentState()
            spriteWindow.orderFrontRegardless()
            startTimer()
            return
        }

        if playbackMode == .playing {
            guard let menuRect = statusItemController?.menuBarScreenRect() else {
                awaitingMenuBarAnchor = true
                spriteWindow.orderOut(nil)
                publish(djMode: false, visible: false)
                startTimer()
                return
            }
            motionState.phase = .perched
            motionState.transition = nil
            motionState.spriteSize = configuration.perchedSize
            motionState.authoritativeScreenOrigin = djOrigin(in: menuRect)
            publish(djMode: true, visible: true)
        } else {
            if snapToDestination, motionState.phase == .perched,
               let menuRect = statusItemController?.menuBarScreenRect() {
                motionState.authoritativeScreenOrigin = menuBarOrigin(in: menuRect)
            }
            publish(djMode: false, visible: true)
        }

        renderCurrentState()
        if motionState.authoritativeScreenOrigin != nil {
            spriteWindow.orderFrontRegardless()
        }
        startTimer()
    }

    private func tick() {
        guard motionState.isEnabled, !isSuspended else { return }
        let now = CACurrentMediaTime()
        let delta = lastTick > 0 ? min(0.1, max(0, now - lastTick)) : 0
        lastTick = now
        animationElapsed += delta

        if awaitingMenuBarAnchor,
           let menuRect = statusItemController?.menuBarScreenRect() {
            awaitingMenuBarAnchor = false
            if playbackMode == .playing {
                reconcilePresentation(snapToDestination: true)
                return
            }
            if playbackMode == .paused {
                reconcilePresentation(snapToDestination: true)
                return
            }
            let currentOrigin = motionState.authoritativeScreenOrigin ?? spriteWindow.frame.origin
            motionState = CatMotionReducer.reduce(
                state: motionState,
                event: .surfaceWillClose(
                    currentScreenOrigin: currentOrigin,
                    menuBarTargetScreenOrigin: leadingMenuBarOrigin(in: menuRect)
                ),
                configuration: configuration
            )
            publish(djMode: false, visible: true)
            spriteWindow.orderFrontRegardless()
        }

        let phaseBeforeAdvance = motionState.phase
        if motionState.phase.isSurfaceMotion {
            motionState = CatMotionReducer.advance(
                state: motionState,
                deltaTime: delta,
                playAreaScreenRect: popoverController?.playAreaScreenRect()
            )
        } else if playbackMode == .playing {
            if let menuRect = statusItemController?.menuBarScreenRect() {
                motionState.authoritativeScreenOrigin = djOrigin(in: menuRect)
            }
        } else if playbackMode == .paused {
            if let menuRect = statusItemController?.menuBarScreenRect() {
                motionState.authoritativeScreenOrigin = leadingMenuBarOrigin(in: menuRect)
            }
        } else if motionState.phase == .perched,
                  !motionState.isSurfaceVisible {
            advanceMenuBarRoaming(deltaTime: delta)
        }

        if phaseBeforeAdvance == .exitingSurface,
           motionState.phase == .perched {
            if playbackMode == .noMedia {
                // Restart roaming at the completed left-edge endpoint instead
                // of inheriting time or direction from the rising animation.
                menuBarVelocity = abs(menuBarVelocity)
                animationElapsed = 0
                currentAnimation = nil
                publish(reservesMenuBarWidth: false, visible: true)
            } else {
                reconcilePresentation(snapToDestination: true)
                return
            }
        }

        renderCurrentState()
    }

    private func advanceMenuBarRoaming(deltaTime: TimeInterval) {
        guard deltaTime > 0,
              let bounds = statusItemController?.menuBarScreenRect() else { return }

        guard var origin = motionState.authoritativeScreenOrigin else {
            motionState.authoritativeScreenOrigin = menuBarOrigin(in: bounds)
            return
        }

        let minX = bounds.minX + catHorizontalOffset
        let maxX = max(minX, bounds.maxX - configuration.perchedSize.width + catHorizontalOffset)
        origin.x += menuBarVelocity * CGFloat(deltaTime)
        if origin.x < minX || origin.x > maxX {
            menuBarVelocity = -menuBarVelocity
            origin.x = min(max(origin.x, minX), maxX)
        }
        origin.y = Self.menuBarY(
            in: bounds,
            catSide: configuration.perchedSize.height,
            verticalOffset: catVerticalOffset
        )
        motionState.authoritativeScreenOrigin = origin
    }

    private func renderCurrentState() {
        guard let origin = motionState.authoritativeScreenOrigin else {
            spriteWindow.orderOut(nil)
            return
        }

        let animation: CatAnimation
        switch motionState.phase {
        case .disabled:
            spriteWindow.orderOut(nil)
            return
        case .enteringSurface:
            animation = .falling
        case .exitingSurface:
            animation = .rising
        case .wandering:
            animation = .walk
        case .perched:
            animation = playbackMode.animation
        }

        let frames = animation.frames
        if currentAnimation != animation {
            currentAnimation = animation
            animationElapsed = 0
        }
        let frameNumber = Int(animationElapsed / animation.frameDuration)
        let frameIndex = animation.repeats
            ? frameNumber % frames.count
            : min(frameNumber, frames.count - 1)
        spriteView.frameToDraw = frames[frameIndex]
        spriteView.facingLeft = facingLeftForCurrentMotion()

        // Align the animated size to device pixels. Resting sizes are 16, 24,
        // or 32 points in the menu bar and exactly twice that in the panel.
        let backingScale = spriteWindow.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        let displaySize = max(
            16,
            (motionState.spriteSize.width * backingScale).rounded() / backingScale
        )
        let size = CGSize(width: displaySize, height: displaySize)
        spriteWindow.updateFrame(screenOrigin: origin, size: size)
        spriteView.needsDisplay = true
    }

    private func hideCat() {
        stopTimer()
        spriteWindow.orderOut(nil)
        currentAnimation = nil
        publish(djMode: false, visible: false)
    }

    private func publish(djMode: Bool, visible: Bool) {
        publish(reservesMenuBarWidth: djMode, visible: visible)
    }

    private func publish(reservesMenuBarWidth: Bool, visible: Bool) {
        let reservedWidth = Self.reservedMenuBarWidth(
            catSide: configuration.perchedSize.width,
            horizontalOffset: catHorizontalOffset,
            reserves: reservesMenuBarWidth
        )
        if abs(reservedWidth - lastReservedMenuBarWidth) > 0.5 {
            lastReservedMenuBarWidth = reservedWidth
            onReservedMenuBarWidthChanged?(reservedWidth)
        }
        if visible != lastVisibility {
            lastVisibility = visible
            onCatVisibilityChanged?(visible)
        }
    }

    private func startTimer() {
        guard timer == nil, motionState.isEnabled, !isSuspended else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: 1.0 / 15.0)
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        source.resume()
        timer = source
        lastTick = CACurrentMediaTime()
    }

    private func stopTimer() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        lastTick = 0
    }

    private func applyCurrentSizeToMotionState() {
        guard motionState.isEnabled else { return }
        switch motionState.phase {
        case .disabled:
            break
        case .perched:
            motionState.spriteSize = configuration.perchedSize
        case .wandering:
            motionState.spriteSize = configuration.wanderingSize
        case .enteringSurface:
            motionState.transition?.endSize = configuration.wanderingSize
        case .exitingSurface:
            motionState.transition?.endSize = configuration.perchedSize
        }
    }

    private func facingLeftForCurrentMotion() -> Bool {
        Self.facingLeft(
            phase: motionState.phase,
            wanderingVelocity: motionState.wanderingVelocity,
            menuBarVelocity: menuBarVelocity,
            transition: motionState.transition,
            playbackMode: playbackMode
        )
    }

    static func facingLeft(
        phase: CatMotionPhase,
        wanderingVelocity: CGVector,
        menuBarVelocity: CGFloat,
        transition: CatMotionTransition?,
        playbackMode: CatPlaybackMode
    ) -> Bool {
        switch phase {
        case .wandering:
            // The supplied roaming frames lean left before mirroring, so the
            // unmirrored animation belongs to leftward travel and the mirrored
            // animation belongs to rightward travel.
            return wanderingVelocity.dx > 0
        case .enteringSurface, .exitingSurface:
            guard let transition else { return false }
            return transition.endScreenOrigin.x < transition.startScreenOrigin.x
        case .perched:
            return playbackMode == .noMedia && menuBarVelocity > 0
        case .disabled:
            return false
        }
    }

    private func menuBarOrigin(in rect: CGRect) -> CGPoint {
        Self.menuBarOrigin(
            in: rect,
            catSide: configuration.perchedSize.width,
            horizontalOffset: catHorizontalOffset,
            verticalOffset: catVerticalOffset
        )
    }

    private func djOrigin(in rect: CGRect) -> CGPoint {
        Self.djOrigin(
            in: rect,
            catSide: configuration.perchedSize.width,
            horizontalOffset: catHorizontalOffset,
            verticalOffset: catVerticalOffset
        )
    }

    private func leadingMenuBarOrigin(in rect: CGRect) -> CGPoint {
        Self.leadingMenuBarOrigin(
            in: rect,
            catSide: configuration.perchedSize.width,
            horizontalOffset: catHorizontalOffset,
            verticalOffset: catVerticalOffset
        )
    }

    private func surfaceEntryOrigin(in rect: CGRect) -> CGPoint {
        Self.surfaceEntryOrigin(in: rect, catSide: configuration.wanderingSize.width)
    }

    static func menuBarOrigin(
        in rect: CGRect,
        catSide: CGFloat = 16,
        horizontalOffset: CGFloat = 0,
        verticalOffset: CGFloat = 0
    ) -> CGPoint {
        CGPoint(
            x: rect.midX - catSide / 2 + horizontalOffset,
            y: menuBarY(in: rect, catSide: catSide, verticalOffset: verticalOffset)
        )
    }

    static func djOrigin(
        in rect: CGRect,
        catSide: CGFloat = 16,
        horizontalOffset: CGFloat = 0,
        verticalOffset: CGFloat = 0
    ) -> CGPoint {
        leadingMenuBarOrigin(
            in: rect,
            catSide: catSide,
            horizontalOffset: horizontalOffset,
            verticalOffset: verticalOffset
        )
    }

    static func leadingMenuBarOrigin(
        in rect: CGRect,
        catSide: CGFloat = 16,
        horizontalOffset: CGFloat = 0,
        verticalOffset: CGFloat = 0
    ) -> CGPoint {
        CGPoint(
            x: rect.minX + horizontalOffset,
            y: menuBarY(in: rect, catSide: catSide, verticalOffset: verticalOffset)
        )
    }

    static func reservedMenuBarWidth(
        catSide: CGFloat,
        horizontalOffset: CGFloat,
        reserves: Bool
    ) -> CGFloat {
        reserves ? max(0, catSide + 2 + horizontalOffset) : 0
    }

    private static func menuBarY(
        in rect: CGRect,
        catSide: CGFloat,
        verticalOffset: CGFloat = 0
    ) -> CGFloat {
        min(rect.midY - catSide / 2, rect.maxY - catSide) - verticalOffset
    }

    static func surfaceEntryOrigin(in rect: CGRect, catSide: CGFloat = 32) -> CGPoint {
        CGPoint(
            x: rect.midX - catSide / 2,
            y: max(rect.minY, rect.maxY - catSide - 16)
        )
    }

    // MARK: - Full-screen detection

    private func startFullScreenMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        fullScreenObservers.append(
            center.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleFullScreenCheck()
            }
        )
        // Also check on screen parameter changes (display connect/disconnect,
        // resolution changes that may accompany fullscreen transitions).
        fullScreenObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleFullScreenCheck()
            }
        )
    }

    private func stopFullScreenMonitoring() {
        for observer in fullScreenObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        fullScreenObservers.removeAll()
        fullScreenCheckWorkItem?.cancel()
        fullScreenCheckWorkItem = nil
    }

    /// Debounces rapid space-change notifications so we don't hammer the
    /// window list. 200 ms is enough to coalesce fast Space swipes.
    private func scheduleFullScreenCheck() {
        fullScreenCheckWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.checkFullScreenAndReact()
        }
        fullScreenCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func checkFullScreenAndReact() {
        // Capture screen frames on the main thread (NSScreen is not
        // thread-safe), then run the expensive CGWindowList query off the
        // main thread.
        let screenFrames = NSScreen.screens.map { $0.frame }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let isFullScreen = Self.isAnyWindowFullScreen(screenFrames: screenFrames)
            DispatchQueue.main.async {
                self?.applyFullScreenState(isFullScreen)
            }
        }
    }

    private func applyFullScreenState(_ isFullScreen: Bool) {
        guard isFullScreen != isOnFullScreenSpace else { return }
        isOnFullScreenSpace = isFullScreen

        if isFullScreen {
            // Hide the cat without mutating visible state — we want the same
            // position, phase, and reserved width when we return.
            spriteWindow.orderOut(nil)
            // Keep the timer off while fullscreen to save energy.
            stopTimer()
        } else {
            // Restore the cat exactly where it was.
            guard settings.catEnabled, !isSuspended, motionState.isEnabled else { return }
            reconcilePresentation(snapToDestination: false)
        }
    }

    /// Returns `true` when any screen is covered by a full-screen window
    /// owned by another application.
    ///
    /// `screenFrames` must be captured on the main thread before calling;
    /// this method itself runs safely on any queue.
    static func isAnyWindowFullScreen(screenFrames: [CGRect] = NSScreen.screens.map { $0.frame }) -> Bool {
        guard !screenFrames.isEmpty else { return false }

        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for window in windowList {
            // Only consider normal window-level windows (layer 0). Full-screen
            // apps use layer 0; floating panels, the menu bar, and our own
            // `.popUpMenu` cat window are excluded automatically.
            guard let layer = window[kCGWindowLayer as String] as? Int32, layer == 0 else { continue }

            guard let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            guard let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let w = boundsDict["Width"],
                  let h = boundsDict["Height"] else { continue }
            let rect = CGRect(x: x, y: y, width: w, height: h)

            // A full-screen window fills one of the displays.
            for screenFrame in screenFrames {
                if abs(rect.minX - screenFrame.minX) < 1,
                   abs(rect.minY - screenFrame.minY) < 1,
                   abs(rect.width - screenFrame.width) < 1,
                   abs(rect.height - screenFrame.height) < 1 {
                    return true
                }
            }
        }

        return false
    }
}

@MainActor
private final class CatSpriteView: NSView {
    var frameToDraw: CatFrame = .sit
    var skin: CatSkin = .maoMao
    var facingLeft = false

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        CatRenderer.draw(
            frame: frameToDraw,
            skin: skin,
            facingLeft: facingLeft,
            in: bounds,
            context: context
        )
    }
}
