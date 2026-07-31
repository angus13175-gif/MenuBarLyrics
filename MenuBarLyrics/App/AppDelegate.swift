import AppKit
import CoreVideo
import Combine

/// Application delegate that wires the full data pipeline together and drives
/// the menu bar UI.
///
/// On launch it creates the `AppState`, lyric repository (`LRCLIBClient` +
/// `QQMusicClient`), and `MediaRemoteDataSource`, resolves the perl adapter
/// paths (bundle resources first, dev fallback second), and starts a
/// `CVDisplayLink` that drives `appState.tickPlayback()` each frame.
///
/// The UI layer consists of a `StatusItemController` (owns the `NSStatusItem`
/// and embedded `LyricMenuBarView`) and a `PopoverController` (transient
/// popover / pinned panel with the full lyric scroll view). Both are updated
/// reactively via Combine subscriptions to `AppState`'s published state.
///
/// `@MainActor` is stated explicitly so all app-state mutations are statically
/// guaranteed to run on the main thread under Swift 6 concurrency.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MediaRemoteDataSourceDelegate,
                          StatusItemControllerDelegate {
    private var appState: AppState!
    private var dataSource: MediaRemoteDataSource!
    private var displayLink: CVDisplayLink?
    private var displayLinkStarted = false
    private var statusItemController: StatusItemController!
    private var popoverController: PopoverController!
    private var catController: CatController!
    private var settings: AppSettings!
    private var launchAtLoginController: LaunchAtLoginController!
    private var settingsWindowController: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()

        // Configure settings (must be before UI setup).
        settings = AppSettings()
        launchAtLoginController = LaunchAtLoginController()
        appState.configure(settings: settings)

        // Configure the lyric repository.
        let lrclib = LRCLIBClient()
        let qq = QQMusicClient()
        let netease = NetEaseClient()
        let repo = LyricRepository(providers: [lrclib, qq, netease])
        appState.configure(lyricRepo: repo)

        // Configure the now-playing data source.
        dataSource = MediaRemoteDataSource()
        dataSource.delegate = self

        // Resolve adapter paths: bundled resources first, dev fallback second.
        let bundle = Bundle.main
        var scriptPath = bundle.path(forResource: "mediaremote-adapter", ofType: "pl") ?? ""
        var frameworkPath = bundle.privateFrameworksPath.map {
            ($0 as NSString).appendingPathComponent("MediaRemoteAdapter.framework")
        } ?? ""
        if !FileManager.default.fileExists(atPath: frameworkPath) {
            frameworkPath = ""
        }

        if scriptPath.isEmpty || frameworkPath.isEmpty {
            // Dev fallback: derive project root from this source file's location.
            // AppDelegate.swift lives at <project>/MenuBarLyrics/App/AppDelegate.swift,
            // so going up 3 levels gives the project root.
            let devBase = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // App/
                .deletingLastPathComponent()  // MenuBarLyrics/
                .deletingLastPathComponent()  // project root
                .path
            scriptPath = "\(devBase)/third-party/mediaremote-adapter/bin/mediaremote-adapter.pl"
            frameworkPath = "\(devBase)/MenuBarLyrics/Resources/MediaRemoteAdapter.framework"
        }

        dataSource.configure(scriptPath: scriptPath, frameworkPath: frameworkPath)
        dataSource.start()

        // UI: replace the raw status item with the full controller + popover.
        statusItemController = StatusItemController(settings: settings)
        statusItemController.delegate = self
        popoverController = PopoverController(
            statusItemButton: statusItemController.statusItemButton,
            settings: settings
        )
        popoverController.onSettings = { [weak self] in
            self?.showSettings()
        }
        popoverController.onQuit = {
            NSApp.terminate(nil)
        }
        catController = CatController(
            settings: settings,
            statusItemController: statusItemController,
            popoverController: popoverController
        )
        popoverController.onSurfaceOpened = { [weak self] in
            self?.catController.surfaceOpened()
        }
        popoverController.onSurfaceWillClose = { [weak self] in
            self?.catController.surfaceWillClose()
        }
        popoverController.onSurfaceClosed = { [weak self] in
            self?.catController.surfaceClosed()
        }
        catController.onReservedMenuBarWidthChanged = { [weak self] width in
            self?.statusItemController.setCatReservedWidth(width)
        }
        catController.onCatVisibilityChanged = { [weak self] isVisible in
            self?.statusItemController.setCatVisible(isVisible)
        }
        catController.onSettingsRequested = { [weak self] in
            self?.showMenuBarSettings()
        }
        popoverController.lyricScrollView.onResearchLyrics = { [weak self] in
            self?.appState.researchLyrics()
        }

        // Subscribe to state changes so the UI updates reactively. The
        // render-state publisher fires on every display-link tick (via
        // tickPlayback), driving the karaoke animation.
        appState.$renderState.sink { [weak self] state in
            self?.updateUI()
            self?.updateDisplayLinkState(phase: state?.phase)
        }.store(in: &cancellables)

        appState.$lyricsState.sink { [weak self] _ in
            self?.updateUI()
        }.store(in: &cancellables)

        appState.$nowPlaying.sink { [weak self] snapshot in
            self?.catController.playbackChanged(
                isPlaying: snapshot?.isPlaying ?? false,
                hasMedia: snapshot != nil
            )
        }.store(in: &cancellables)

        appState.$mediaState.sink { [weak self] state in
            if case .unavailable = state {
                self?.updateUI()
            }
        }.store(in: &cancellables)

        // Every setting is consumed by the rendering views. objectWillChange
        // fires before mutation, so hop to the next main-queue turn before
        // reading the new values. This keeps sliders and color wells live.
        settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.applySettings()
            }
        }.store(in: &cancellables)
        applySettings()

        // Observe system wake/sleep so we can restart the helper (which may be
        // dead after sleep) and save power by halting the display link.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        workspace.addObserver(
            self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )

        // Start the display link only if the initial phase requires animation.
        updateDisplayLinkState(phase: appState.renderState?.phase)

        // Set up a minimal main menu so ⌘, opens the settings window.
        setupMainMenu()
    }

    /// Creates a minimal application menu with a Settings item bound to ⌘,.
    /// Accessory-policy apps do not show the menu bar, but the key equivalent
    /// still works because the menu is installed in the main menu.
    private func setupMainMenu() {
        let mainMenu = NSMenu(title: "MenuBarLyrics")

        let appMenuItem = NSMenuItem(title: "MenuBarLyrics", action: nil, keyEquivalent: "")
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "MenuBarLyrics")
        appMenuItem.submenu = appMenu

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings),
                                       keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 MenuBarLyrics", action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q")
        appMenu.addItem(quitItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        dataSource?.stop()
        stopDisplayLink()
        catController?.shutdown()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        launchAtLoginController?.refresh()
    }

    /// Pushes the current app state into both UI controllers.
    private func updateUI() {
        let renderState = appState.renderState
        let lyrics = appState.currentLyrics
        statusItemController.update(
            renderState: renderState,
            lyrics: lyrics,
            width: CGFloat(settings.menuBarWidth)
        )
        popoverController.update(
            renderState: renderState,
            lyrics: lyrics,
            nowPlaying: appState.nowPlaying,
            lyricsState: appState.lyricsState
        )
    }

    private func applySettings() {
        statusItemController.applySettings(width: CGFloat(settings.menuBarWidth))
        popoverController.applySettings()
        catController.applySettings()
        updateUI()
    }

    // MARK: - System wake / sleep

    /// After the system wakes, the perl helper may be dead and the playback
    /// clock frozen. Restart the data source to force a fresh snapshot.
    @objc private func systemDidWake() {
        catController.resume()
        dataSource.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.dataSource.start()
        }
    }

    /// Stop the display link while sleeping to save power; it will be restarted
    /// on demand by `updateDisplayLinkState` once playback resumes.
    @objc private func systemWillSleep() {
        catController.suspend()
        if let link = displayLink, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
        displayLinkStarted = false
    }

    // MARK: - Settings

    /// Shows the settings window, creating it on first use. Toggles visibility
    /// if already open. Bound to ⌘, via the main menu.
    @objc func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                settings: settings,
                appState: appState,
                launchAtLoginController: launchAtLoginController
            )
        }
        launchAtLoginController.refresh()
        settingsWindowController?.showSettingsWindow()
    }

    /// Opens the first settings tab without toggling it closed. This path is
    /// used by the cat, which remains visible even when macOS cannot allocate
    /// space for the lyric status item.
    private func showMenuBarSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                settings: settings,
                appState: appState,
                launchAtLoginController: launchAtLoginController
            )
        }
        launchAtLoginController.refresh()
        settingsWindowController?.showMenuBarSettings()
    }

    // MARK: - StatusItemControllerDelegate

    func statusItemClicked() {
        popoverController.toggle()
    }

    // MARK: - MediaRemoteDataSourceDelegate

    func dataSource(_ ds: MediaRemoteDataSource, didUpdateSnapshot snapshot: NowPlayingSnapshot?) {
        appState.updateSnapshot(snapshot)
    }

    func dataSource(_ ds: MediaRemoteDataSource, didChangeMediaState state: MediaState) {
        appState.updateMediaState(state)
    }

    // MARK: - Display link

    /// Creates and starts a CVDisplayLink whose output callback hops to the main
    /// queue to drive `appState.tickPlayback()` each frame. The callback is a C
    /// function pointer, so an `Unmanaged` reference carries `self` across the
    /// boundary.
    private func startDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()

        // The output callback runs on the display-link's own queue, not the main
        // actor. It must not touch actor-isolated state directly; instead it
        // hops to the main queue where `appState` lives.
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, ctx in
            guard let ctx else { return kCVReturnSuccess }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                delegate.appState.tickPlayback()
            }
            return kCVReturnSuccess
        }, opaqueSelf)

        CVDisplayLinkStart(link)
        displayLink = link
        displayLinkStarted = true
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        displayLinkStarted = false
    }

    /// Starts or stops the display link based on whether the current playback
    /// phase requires animation. The link runs while `.playing`,
    /// `.loadingLyrics`, or `.explicitInstrumental` (the clock must keep
    /// advancing through instrumental gaps to reach the next lyric line);
    /// it is stopped for paused/no-media/no-lyrics/unavailable states to
    /// avoid burning a 60fps wake-up when nothing is animating.
    private func updateDisplayLinkState(phase: PlaybackPhase?) {
        let shouldRun = phase == .playing
            || phase == .loadingLyrics
            || phase == .explicitInstrumental

        if shouldRun && !displayLinkStarted {
            if displayLink == nil {
                startDisplayLink()
            } else {
                CVDisplayLinkStart(displayLink!)
            }
            displayLinkStarted = true
        } else if !shouldRun && displayLinkStarted {
            if let link = displayLink {
                CVDisplayLinkStop(link)
            }
            displayLinkStarted = false
        }
    }
}
