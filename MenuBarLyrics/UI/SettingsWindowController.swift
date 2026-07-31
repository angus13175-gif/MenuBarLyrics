import AppKit
import Combine

/// Standard macOS settings window with tabbed sections (menu bar + panel).
///
/// Supports ⌘, to toggle. Uses a tab-based `NSTabViewController` as the
/// content view controller of an `NSWindowController`.
@MainActor
final class SettingsWindowController: NSWindowController {

    private let settings: AppSettings
    private let appState: AppState
    private let launchAtLoginController: LaunchAtLoginController
    private let tabViewController: NSTabViewController

    init(
        settings: AppSettings,
        appState: AppState,
        launchAtLoginController: LaunchAtLoginController
    ) {
        self.settings = settings
        self.appState = appState
        self.launchAtLoginController = launchAtLoginController
        self.tabViewController = NSTabViewController()
        super.init(window: nil)
        setupTabs()
        let window = NSWindow(contentViewController: tabViewController)
        window.title = "MenuBarLyrics 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupTabs() {
        tabViewController.tabStyle = .toolbar
        tabViewController.title = "MenuBarLyrics 设置"
        tabViewController.canPropagateSelectedChildViewControllerTitle = false

        let menuBarVC = SettingsMenuBarTab(settings: settings)
        menuBarVC.title = "菜单栏"
        let menuBarItem = NSTabViewItem(viewController: menuBarVC)
        menuBarItem.label = "菜单栏"
        menuBarItem.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "Menu Bar")
        tabViewController.addTabViewItem(menuBarItem)

        let panelVC = SettingsPanelTab(settings: settings, appState: appState)
        panelVC.title = "歌词面板"
        let panelItem = NSTabViewItem(viewController: panelVC)
        panelItem.label = "歌词面板"
        panelItem.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Panel")
        tabViewController.addTabViewItem(panelItem)

        let generalVC = SettingsGeneralTab(controller: launchAtLoginController)
        generalVC.title = "通用"
        let generalItem = NSTabViewItem(viewController: generalVC)
        generalItem.label = "通用"
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        tabViewController.addTabViewItem(generalItem)
    }

    func showSettingsWindow() {
        if let win = window, win.isVisible {
            win.orderOut(nil)
        } else {
            showWindow(nil)
            window?.title = "MenuBarLyrics 设置"
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Reveals the width controls instead of toggling the window. This is the
    /// recovery route used when the cat is visible but the lyric status item
    /// has been pushed out of the menu bar.
    func showMenuBarSettings() {
        tabViewController.selectedTabViewItemIndex = 0
        showWindow(nil)
        window?.title = "MenuBarLyrics 设置"
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Menu Bar Settings Tab

private final class SettingsMenuBarTab: NSViewController {

    private let settings: AppSettings
    private weak var widthSlider: NSSlider?

    private enum ColorSetting: String {
        case filledLight
        case unfilledLight
        case filledDark
        case unfilledDark
    }

    init(settings: AppSettings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scrollView = NSScrollView()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 600))

        var y: CGFloat = 580
        let leftMargin: CGFloat = 20
        let labelWidth: CGFloat = 120
        let controlX: CGFloat = leftMargin + labelWidth + 8
        let controlWidth: CGFloat = 280

        // Width slider
        addLabel("菜单栏宽度", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let widthSlider = NSSlider(value: settings.menuBarWidth, minValue: 80, maxValue: 320,
                                   target: self, action: #selector(widthChanged(_:)))
        widthSlider.isContinuous = true
        widthSlider.frame = NSRect(x: controlX, y: y, width: controlWidth, height: 20)
        container.addSubview(widthSlider)
        self.widthSlider = widthSlider
        y -= 30

        // Width presets
        addLabel("快捷预设", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let presets = NSStackView()
        presets.orientation = .horizontal
        presets.spacing = 8
        for pt in [80.0, 160.0, 240.0] {
            let btn = NSButton(title: "\(Int(pt))pt", target: self, action: #selector(presetTapped(_:)))
            btn.tag = Int(pt)
            btn.bezelStyle = .rounded
            btn.controlSize = .small
            presets.addArrangedSubview(btn)
        }
        presets.frame = NSRect(x: controlX, y: y, width: controlWidth, height: 24)
        container.addSubview(presets)
        y -= 35

        // Font family
        addLabel("字体", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let fontPopup = NSPopUpButton(frame: NSRect(x: controlX, y: y, width: controlWidth, height: 26))
        fontPopup.addItem(withTitle: "系统默认")
        for name in AppSettings.availableFonts {
            fontPopup.addItem(withTitle: name)
        }
        if !settings.menuBarFontName.isEmpty {
            fontPopup.selectItem(withTitle: settings.menuBarFontName)
        } else {
            fontPopup.selectItem(at: 0)
        }
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        container.addSubview(fontPopup)
        y -= 35

        // Font size
        addLabel("字号", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let sizeSlider = NSSlider(value: settings.menuBarFontSize, minValue: 10, maxValue: 18,
                                  target: self, action: #selector(sizeChanged(_:)))
        sizeSlider.isContinuous = true
        sizeSlider.frame = NSRect(x: controlX, y: y, width: controlWidth - 40, height: 20)
        container.addSubview(sizeSlider)
        let sizeLabel = NSTextField(labelWithString: "\(Int(settings.menuBarFontSize))pt")
        sizeLabel.frame = NSRect(x: controlX + controlWidth - 30, y: y, width: 30, height: 20)
        sizeLabel.tag = 100
        container.addSubview(sizeLabel)
        y -= 30

        // Font weight
        addLabel("字重", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let weightSlider = NSSlider(value: settings.menuBarFontWeight, minValue: 0, maxValue: 1,
                                    target: self, action: #selector(weightChanged(_:)))
        weightSlider.isContinuous = true
        weightSlider.frame = NSRect(x: controlX, y: y, width: controlWidth, height: 20)
        container.addSubview(weightSlider)
        y -= 35

        // Vertical alignment. Positive values move the lyric downward.
        addLabel("垂直位置", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let verticalRange = AppSettings.menuBarVerticalOffsetRange
        let verticalSlider = NSSlider(value: settings.menuBarVerticalOffset,
                                      minValue: verticalRange.lowerBound,
                                      maxValue: verticalRange.upperBound,
                                      target: self, action: #selector(verticalOffsetChanged(_:)))
        verticalSlider.isContinuous = true
        verticalSlider.numberOfTickMarks = Int(verticalRange.upperBound - verticalRange.lowerBound) + 1
        verticalSlider.allowsTickMarkValuesOnly = true
        verticalSlider.frame = NSRect(x: controlX, y: y, width: controlWidth - 70, height: 20)
        container.addSubview(verticalSlider)
        let verticalLabel = NSTextField(labelWithString: verticalOffsetLabel(settings.menuBarVerticalOffset))
        verticalLabel.frame = NSRect(x: controlX + controlWidth - 62, y: y, width: 62, height: 20)
        verticalLabel.tag = 101
        verticalLabel.alignment = .right
        container.addSubview(verticalLabel)
        y -= 35

        // Fill animation toggle
        let fillToggle = NSButton(checkboxWithTitle: "启用填充动画", target: self, action: #selector(fillToggled(_:)))
        fillToggle.frame = NSRect(x: controlX, y: y, width: controlWidth, height: 20)
        fillToggle.state = settings.fillAnimationEnabled ? .on : .off
        container.addSubview(fillToggle)
        y -= 30

        let catToggle = NSButton(
            checkboxWithTitle: "启用像素小猫",
            target: self,
            action: #selector(catToggled(_:))
        )
        catToggle.frame = NSRect(x: controlX, y: y, width: controlWidth, height: 20)
        catToggle.state = settings.catEnabled ? .on : .off
        catToggle.toolTip = "打开歌词面板时进入面板闲逛，播放时变成 DJ，暂停时停靠眨眼"
        catToggle.setAccessibilityLabel("启用像素小猫")
        container.addSubview(catToggle)
        y -= 30

        addLabel("小猫形象", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let catSkinPopup = NSPopUpButton(frame: NSRect(x: controlX, y: y, width: controlWidth, height: 26))
        for skin in CatSkin.allCases {
            catSkinPopup.addItem(withTitle: skin.displayName)
            catSkinPopup.lastItem?.image = CatRenderer.image(
                frame: .sit,
                size: .menuBar,
                skin: skin
            )
        }
        catSkinPopup.selectItem(at: CatSkin.allCases.firstIndex(of: settings.catSkin) ?? 0)
        catSkinPopup.target = self
        catSkinPopup.action = #selector(catSkinChanged(_:))
        catSkinPopup.setAccessibilityLabel("小猫形象")
        container.addSubview(catSkinPopup)
        y -= 35

        addLabel("小猫大小", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let catSizePopup = NSPopUpButton(frame: NSRect(x: controlX, y: y, width: controlWidth, height: 26))
        let catSizeTitles = ["标准（32pt）", "大（40pt）", "特大（48pt）"]
        for (title, size) in zip(catSizeTitles, AppSettings.catSizeOptions) {
            catSizePopup.addItem(withTitle: title)
            catSizePopup.lastItem?.tag = size
        }
        catSizePopup.selectItem(withTag: Int(settings.catSize))
        if catSizePopup.indexOfSelectedItem < 0 { catSizePopup.selectItem(withTag: 32) }
        catSizePopup.target = self
        catSizePopup.action = #selector(catSizeChanged(_:))
        catSizePopup.setAccessibilityLabel("小猫大小")
        container.addSubview(catSizePopup)
        y -= 35

        addLabel("小猫水平位置", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let catHorizontalRange = AppSettings.catHorizontalOffsetRange
        let catHorizontalSlider = NSSlider(
            value: settings.catHorizontalOffset,
            minValue: catHorizontalRange.lowerBound,
            maxValue: catHorizontalRange.upperBound,
            target: self,
            action: #selector(catHorizontalOffsetChanged(_:))
        )
        catHorizontalSlider.isContinuous = true
        catHorizontalSlider.numberOfTickMarks = Int(
            catHorizontalRange.upperBound - catHorizontalRange.lowerBound
        ) + 1
        catHorizontalSlider.allowsTickMarkValuesOnly = true
        catHorizontalSlider.frame = NSRect(x: controlX, y: y, width: controlWidth - 70, height: 20)
        catHorizontalSlider.setAccessibilityLabel("小猫水平位置")
        container.addSubview(catHorizontalSlider)
        let catHorizontalLabel = NSTextField(
            labelWithString: horizontalOffsetLabel(settings.catHorizontalOffset)
        )
        catHorizontalLabel.frame = NSRect(x: controlX + controlWidth - 70, y: y, width: 70, height: 20)
        catHorizontalLabel.tag = 103
        catHorizontalLabel.alignment = .right
        container.addSubview(catHorizontalLabel)
        y -= 35

        addLabel("小猫垂直位置", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let catVerticalRange = AppSettings.catVerticalOffsetRange
        let catVerticalSlider = NSSlider(
            value: settings.catVerticalOffset,
            minValue: catVerticalRange.lowerBound,
            maxValue: catVerticalRange.upperBound,
            target: self,
            action: #selector(catVerticalOffsetChanged(_:))
        )
        catVerticalSlider.isContinuous = true
        catVerticalSlider.numberOfTickMarks = Int(
            catVerticalRange.upperBound - catVerticalRange.lowerBound
        ) + 1
        catVerticalSlider.allowsTickMarkValuesOnly = true
        catVerticalSlider.frame = NSRect(x: controlX, y: y, width: controlWidth - 70, height: 20)
        catVerticalSlider.setAccessibilityLabel("小猫垂直位置")
        container.addSubview(catVerticalSlider)
        let catVerticalLabel = NSTextField(
            labelWithString: verticalOffsetLabel(settings.catVerticalOffset)
        )
        catVerticalLabel.frame = NSRect(x: controlX + controlWidth - 62, y: y, width: 62, height: 20)
        catVerticalLabel.tag = 102
        catVerticalLabel.alignment = .right
        container.addSubview(catVerticalLabel)
        y -= 35

        // Long lyric mode
        addLabel("长歌词模式", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let modePopup = NSPopUpButton(frame: NSRect(x: controlX, y: y, width: controlWidth, height: 26))
        for mode in LongLyricMode.allCases {
            modePopup.addItem(withTitle: mode.label)
        }
        modePopup.selectItem(at: settings.longLyricMode.rawValue)
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))
        container.addSubview(modePopup)
        y -= 35

        // Separator
        let sep = NSBox(frame: NSRect(x: leftMargin, y: y, width: 400, height: 1))
        sep.boxType = .separator
        container.addSubview(sep)
        y -= 30

        // Colors - light mode
        addLabel("浅色模式", at: NSRect(x: leftMargin, y: y, width: 400, height: 20), to: container, bold: true)
        y -= 28
        addColorRow("已填充颜色", hex: settings.menuBarFilledColorLight, setting: .filledLight,
                    at: &y, leftMargin: leftMargin, labelWidth: labelWidth, controlX: controlX, controlWidth: controlWidth, container: container)
        addColorRow("未填充颜色", hex: settings.menuBarUnfilledColorLight, setting: .unfilledLight,
                    at: &y, leftMargin: leftMargin, labelWidth: labelWidth, controlX: controlX, controlWidth: controlWidth, container: container)
        y -= 10

        // Colors - dark mode
        addLabel("深色模式", at: NSRect(x: leftMargin, y: y, width: 400, height: 20), to: container, bold: true)
        y -= 28
        addColorRow("已填充颜色", hex: settings.menuBarFilledColorDark, setting: .filledDark,
                    at: &y, leftMargin: leftMargin, labelWidth: labelWidth, controlX: controlX, controlWidth: controlWidth, container: container)
        addColorRow("未填充颜色", hex: settings.menuBarUnfilledColorDark, setting: .unfilledDark,
                    at: &y, leftMargin: leftMargin, labelWidth: labelWidth, controlX: controlX, controlWidth: controlWidth, container: container)

        // When many controls overflow the default container height, shift
        // every subview up so nothing lands below the bottom edge (y=0).
        // Then grow the container upward so the top row isn't clipped.
        let bottomPad: CGFloat = 20
        let topPad: CGFloat = 5
        if y < bottomPad {
            let shift = bottomPad - y
            for v in container.subviews { v.frame.origin.y += shift }
            container.frame = NSRect(x: 0, y: 0, width: 440,
                                     height: max(600, 580 + shift + bottomPad + topPad))
        } else {
            container.frame = NSRect(x: 0, y: 0, width: 440,
                                     height: max(600, 580 - y + bottomPad + topPad))
        }

        scrollView.documentView = container
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.frame = NSRect(x: 0, y: 0, width: 460, height: 500)
        view = scrollView
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // NSScrollView defaults to showing the bottom of the document.
        // Scroll to the top so the user sees the first settings first.
        guard let sv = view as? NSScrollView,
              let doc = sv.documentView else { return }
        let topY = max(0, doc.frame.height - sv.contentView.bounds.height)
        sv.contentView.scroll(to: NSPoint(x: 0, y: topY))
    }

    private func addLabel(_ title: String, at frame: NSRect, to view: NSView, bold: Bool = false) {
        let label = NSTextField(labelWithString: title)
        label.font = bold ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)
        label.frame = frame
        view.addSubview(label)
    }

    private func addColorRow(_ title: String, hex: String, setting: ColorSetting,
                             at y: inout CGFloat, leftMargin: CGFloat, labelWidth: CGFloat,
                             controlX: CGFloat, controlWidth: CGFloat, container: NSView) {
        addLabel(title, at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let well = NSColorWell(frame: NSRect(x: controlX, y: y, width: 60, height: 24))
        well.color = AppSettings.color(fromHex: hex)
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.identifier = NSUserInterfaceItemIdentifier(setting.rawValue)
        container.addSubview(well)
        y -= 30
    }

    @objc private func colorChanged(_ w: NSColorWell) {
        let hex = AppSettings.hexString(from: w.color)
        switch w.identifier?.rawValue {
        case ColorSetting.filledLight.rawValue: settings.menuBarFilledColorLight = hex
        case ColorSetting.unfilledLight.rawValue: settings.menuBarUnfilledColorLight = hex
        case ColorSetting.filledDark.rawValue: settings.menuBarFilledColorDark = hex
        case ColorSetting.unfilledDark.rawValue: settings.menuBarUnfilledColorDark = hex
        default: break
        }
    }

    @objc private func widthChanged(_ s: NSSlider) { settings.menuBarWidth = s.doubleValue }
    @objc private func presetTapped(_ b: NSButton) {
        let width = Double(b.tag)
        widthSlider?.doubleValue = width
        settings.menuBarWidth = width
    }
    @objc private func fontChanged(_ p: NSPopUpButton) {
        settings.menuBarFontName = p.indexOfSelectedItem == 0 ? "" : p.titleOfSelectedItem ?? ""
    }
    @objc private func sizeChanged(_ s: NSSlider) {
        settings.menuBarFontSize = s.doubleValue
        (view.window?.contentView?.viewWithTag(100) as? NSTextField)?.stringValue = "\(Int(s.doubleValue))pt"
    }
    @objc private func weightChanged(_ s: NSSlider) { settings.menuBarFontWeight = s.doubleValue }
    @objc private func verticalOffsetChanged(_ s: NSSlider) {
        let value = s.doubleValue.rounded()
        settings.menuBarVerticalOffset = value
        (view.window?.contentView?.viewWithTag(101) as? NSTextField)?.stringValue = verticalOffsetLabel(value)
    }
    @objc private func fillToggled(_ b: NSButton) { settings.fillAnimationEnabled = b.state == .on }
    @objc private func catToggled(_ b: NSButton) { settings.catEnabled = b.state == .on }
    @objc private func catSkinChanged(_ p: NSPopUpButton) {
        let index = min(max(0, p.indexOfSelectedItem), CatSkin.allCases.count - 1)
        settings.catSkin = CatSkin.allCases[index]
    }
    @objc private func catSizeChanged(_ p: NSPopUpButton) {
        settings.catSize = Double(p.selectedItem?.tag ?? 32)
    }
    @objc private func catHorizontalOffsetChanged(_ s: NSSlider) {
        let value = s.doubleValue.rounded()
        settings.catHorizontalOffset = value
        (view.window?.contentView?.viewWithTag(103) as? NSTextField)?.stringValue = horizontalOffsetLabel(value)
    }
    @objc private func catVerticalOffsetChanged(_ s: NSSlider) {
        let value = s.doubleValue.rounded()
        settings.catVerticalOffset = value
        (view.window?.contentView?.viewWithTag(102) as? NSTextField)?.stringValue = verticalOffsetLabel(value)
    }
    @objc private func modeChanged(_ p: NSPopUpButton) {
        settings.longLyricMode = LongLyricMode(rawValue: p.indexOfSelectedItem) ?? .autoScroll
    }

    private func verticalOffsetLabel(_ value: Double) -> String {
        if value > 0 { return "下移 \(Int(value))pt" }
        if value < 0 { return "上移 \(Int(-value))pt" }
        return "居中"
    }

    private func horizontalOffsetLabel(_ value: Double) -> String {
        if value > 0 { return "右移 \(Int(value))pt" }
        if value < 0 { return "左移 \(Int(-value))pt" }
        return "居中"
    }
}

// MARK: - Panel Settings Tab

private final class SettingsPanelTab: NSViewController {

    private let settings: AppSettings
    private let appState: AppState
    private var cancellables = Set<AnyCancellable>()
    private weak var globalOffsetValueLabel: NSTextField?
    private weak var offsetSlider: NSSlider?
    private weak var offsetValueLabel: NSTextField?
    private weak var offsetResetButton: NSButton?
    private weak var panelWidthSlider: NSSlider?
    private weak var panelHeightSlider: NSSlider?
    private weak var panelWidthValueLabel: NSTextField?
    private weak var panelHeightValueLabel: NSTextField?

    init(settings: AppSettings, appState: AppState) {
        self.settings = settings
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scrollView = NSScrollView()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 800))

        var y: CGFloat = 780
        let leftMargin: CGFloat = 20
        let labelWidth: CGFloat = 120
        let controlX: CGFloat = leftMargin + labelWidth + 8
        let controlWidth: CGFloat = 280

        addLabel("歌词偏移（全局）", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let globalRange = AppSettings.globalLyricOffsetRange
        let globalOffsetSlider = NSSlider(
            value: settings.globalLyricOffset,
            minValue: globalRange.lowerBound,
            maxValue: globalRange.upperBound,
            target: self,
            action: #selector(globalOffsetChanged(_:))
        )
        globalOffsetSlider.isContinuous = true
        globalOffsetSlider.numberOfTickMarks = 21
        globalOffsetSlider.frame = NSRect(x: controlX, y: y, width: controlWidth - 70, height: 20)
        globalOffsetSlider.setAccessibilityLabel("歌词偏移（全局）")
        container.addSubview(globalOffsetSlider)
        let globalOffsetLabel = NSTextField(labelWithString: offsetText(settings.globalLyricOffset))
        globalOffsetLabel.frame = NSRect(x: controlX + controlWidth - 62, y: y, width: 62, height: 20)
        globalOffsetLabel.alignment = .right
        container.addSubview(globalOffsetLabel)
        globalOffsetValueLabel = globalOffsetLabel
        y -= 30

        let globalOffsetHint = NSTextField(wrappingLabelWithString: "对所有歌曲生效；正数延后，负数提前。")
        globalOffsetHint.textColor = .secondaryLabelColor
        globalOffsetHint.font = .systemFont(ofSize: 11)
        globalOffsetHint.frame = NSRect(x: controlX, y: y, width: controlWidth, height: 22)
        container.addSubview(globalOffsetHint)
        y -= 34

        addLabel("歌词偏移（当前歌曲）", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let offsetSlider = NSSlider(value: appState.currentSongOffset, minValue: -5, maxValue: 5,
                                    target: self, action: #selector(offsetChanged(_:)))
        offsetSlider.isContinuous = true
        offsetSlider.numberOfTickMarks = 21
        offsetSlider.frame = NSRect(x: controlX, y: y, width: controlWidth - 70, height: 20)
        container.addSubview(offsetSlider)
        self.offsetSlider = offsetSlider

        let offsetLabel = NSTextField(labelWithString: offsetText(appState.currentSongOffset))
        offsetLabel.frame = NSRect(x: controlX + controlWidth - 62, y: y, width: 62, height: 20)
        offsetLabel.alignment = .right
        container.addSubview(offsetLabel)
        offsetValueLabel = offsetLabel
        y -= 30

        let offsetHint = NSTextField(wrappingLabelWithString: "正数让歌词延后，负数让歌词提前；每首歌曲单独保存。")
        offsetHint.textColor = .secondaryLabelColor
        offsetHint.font = .systemFont(ofSize: 11)
        offsetHint.frame = NSRect(x: controlX, y: y, width: controlWidth - 76, height: 30)
        container.addSubview(offsetHint)
        let resetButton = NSButton(title: "重置", target: self, action: #selector(resetOffset))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.frame = NSRect(x: controlX + controlWidth - 68, y: y + 4, width: 68, height: 24)
        container.addSubview(resetButton)
        offsetResetButton = resetButton
        y -= 42

        let topSeparator = NSBox(frame: NSRect(x: leftMargin, y: y, width: 400, height: 1))
        topSeparator.boxType = .separator
        container.addSubview(topSeparator)
        y -= 28

        // Font family
        addLabel("字体", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let fontPopup = NSPopUpButton(frame: NSRect(x: controlX, y: y, width: controlWidth, height: 26))
        fontPopup.addItem(withTitle: "系统默认")
        for name in AppSettings.availableFonts {
            fontPopup.addItem(withTitle: name)
        }
        fontPopup.selectItem(at: settings.panelFontName.isEmpty ? 0 : (fontPopup.itemTitles.firstIndex(of: settings.panelFontName) ?? 0))
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        container.addSubview(fontPopup)
        y -= 35

        // Font size
        addLabel("字号", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let sizeSlider = NSSlider(value: settings.panelFontSize, minValue: 10, maxValue: 18,
                                  target: self, action: #selector(sizeChanged(_:)))
        sizeSlider.isContinuous = true
        sizeSlider.frame = NSRect(x: controlX, y: y, width: controlWidth, height: 20)
        container.addSubview(sizeSlider)
        y -= 30

        // Font weight
        addLabel("字重", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let weightSlider = NSSlider(value: settings.panelFontWeight, minValue: 0, maxValue: 1,
                                    target: self, action: #selector(weightChanged(_:)))
        weightSlider.isContinuous = true
        weightSlider.frame = NSRect(x: controlX, y: y, width: controlWidth, height: 20)
        container.addSubview(weightSlider)
        y -= 35

        // Current line color
        addLabel("当前行颜色", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let currentColorWell = NSColorWell(frame: NSRect(x: controlX, y: y, width: 60, height: 24))
        currentColorWell.color = AppSettings.color(fromHex: settings.panelCurrentLineColor)
        currentColorWell.target = self
        currentColorWell.action = #selector(currentColorChanged(_:))
        container.addSubview(currentColorWell)
        y -= 30

        // Other line color
        addLabel("普通行颜色", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let otherColorWell = NSColorWell(frame: NSRect(x: controlX, y: y, width: 60, height: 24))
        otherColorWell.color = AppSettings.color(fromHex: settings.panelOtherLineColor)
        otherColorWell.target = self
        otherColorWell.action = #selector(otherColorChanged(_:))
        container.addSubview(otherColorWell)
        y -= 30

        // Line spacing
        addLabel("行距", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let spacingSlider = NSSlider(value: settings.panelLineSpacing, minValue: 20, maxValue: 40,
                                     target: self, action: #selector(spacingChanged(_:)))
        spacingSlider.isContinuous = true
        spacingSlider.frame = NSRect(x: controlX, y: y, width: controlWidth, height: 20)
        container.addSubview(spacingSlider)
        y -= 30

        // Background opacity
        addLabel("背景透明度", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let opacitySlider = NSSlider(value: settings.panelBackgroundOpacity, minValue: 0.3, maxValue: 1.0,
                                     target: self, action: #selector(opacityChanged(_:)))
        opacitySlider.isContinuous = true
        opacitySlider.frame = NSRect(x: controlX, y: y, width: controlWidth, height: 20)
        container.addSubview(opacitySlider)
        y -= 30

        // Auto resume delay
        addLabel("自动恢复跟随", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let delaySlider = NSSlider(value: settings.panelAutoResumeDelay, minValue: 1, maxValue: 10,
                                   target: self, action: #selector(delayChanged(_:)))
        delaySlider.isContinuous = true
        delaySlider.frame = NSRect(x: controlX, y: y, width: controlWidth, height: 20)
        container.addSubview(delaySlider)
        y -= 38

        let sizeSeparator = NSBox(frame: NSRect(x: leftMargin, y: y, width: 400, height: 1))
        sizeSeparator.boxType = .separator
        container.addSubview(sizeSeparator)
        y -= 28

        addLabel("面板尺寸", at: NSRect(x: leftMargin, y: y, width: 400, height: 20), to: container, bold: true)
        y -= 30

        addLabel("面板宽度", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let panelWidthSlider = NSSlider(value: settings.panelWidth, minValue: 300, maxValue: 600,
                                        target: self, action: #selector(panelWidthChanged(_:)))
        panelWidthSlider.isContinuous = true
        panelWidthSlider.frame = NSRect(x: controlX, y: y, width: controlWidth - 58, height: 20)
        container.addSubview(panelWidthSlider)
        self.panelWidthSlider = panelWidthSlider
        let widthLabel = NSTextField(labelWithString: dimensionText(settings.panelWidth))
        widthLabel.frame = NSRect(x: controlX + controlWidth - 52, y: y, width: 52, height: 20)
        widthLabel.alignment = .right
        container.addSubview(widthLabel)
        panelWidthValueLabel = widthLabel
        y -= 30

        addLabel("面板高度", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let panelHeightSlider = NSSlider(value: settings.panelHeight, minValue: 400, maxValue: 800,
                                         target: self, action: #selector(panelHeightChanged(_:)))
        panelHeightSlider.isContinuous = true
        panelHeightSlider.frame = NSRect(x: controlX, y: y, width: controlWidth - 58, height: 20)
        container.addSubview(panelHeightSlider)
        self.panelHeightSlider = panelHeightSlider
        let heightLabel = NSTextField(labelWithString: dimensionText(settings.panelHeight))
        heightLabel.frame = NSRect(x: controlX + controlWidth - 52, y: y, width: 52, height: 20)
        heightLabel.alignment = .right
        container.addSubview(heightLabel)
        panelHeightValueLabel = heightLabel
        y -= 32

        addLabel("尺寸预设", at: NSRect(x: leftMargin, y: y, width: labelWidth, height: 20), to: container)
        let presets = NSStackView()
        presets.orientation = .horizontal
        presets.spacing = 8
        for (title, tag) in [("紧凑", 0), ("标准", 1), ("宽大", 2)] {
            let button = NSButton(title: title, target: self, action: #selector(panelPresetTapped(_:)))
            button.tag = tag
            button.bezelStyle = .rounded
            button.controlSize = .small
            presets.addArrangedSubview(button)
        }
        presets.frame = NSRect(x: controlX, y: y, width: controlWidth, height: 24)
        container.addSubview(presets)
        y -= 35

        let bottomPad: CGFloat = 20
        let topPad: CGFloat = 5
        if y < bottomPad {
            let shift = bottomPad - y
            for v in container.subviews { v.frame.origin.y += shift }
            y = bottomPad
        }
        container.frame = NSRect(x: 0, y: 0, width: 440,
                                 height: max(800, 780 - y + bottomPad + topPad))
        scrollView.documentView = container
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.frame = NSRect(x: 0, y: 0, width: 460, height: 500)
        view = scrollView

        appState.$nowPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshOffsetControls() }
            .store(in: &cancellables)
        refreshOffsetControls()
    }

    private func addLabel(_ title: String, at frame: NSRect, to view: NSView, bold: Bool = false) {
        let label = NSTextField(labelWithString: title)
        label.font = bold ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)
        label.frame = frame
        view.addSubview(label)
    }

    private func refreshOffsetControls() {
        let enabled = appState.nowPlaying != nil
        let value = appState.currentSongOffset
        offsetSlider?.isEnabled = enabled
        offsetSlider?.doubleValue = value
        offsetValueLabel?.stringValue = enabled ? offsetText(value) : "无歌曲"
        offsetResetButton?.isEnabled = enabled && abs(value) > 0.001
    }

    private func offsetText(_ value: Double) -> String {
        String(format: "%+.1f 秒", value)
    }

    private func dimensionText(_ value: Double) -> String {
        "\(Int(value.rounded()))pt"
    }

    @objc private func fontChanged(_ p: NSPopUpButton) {
        settings.panelFontName = p.indexOfSelectedItem == 0 ? "" : p.titleOfSelectedItem ?? ""
    }
    @objc private func sizeChanged(_ s: NSSlider) { settings.panelFontSize = s.doubleValue }
    @objc private func weightChanged(_ s: NSSlider) { settings.panelFontWeight = s.doubleValue }
    @objc private func currentColorChanged(_ w: NSColorWell) {
        settings.panelCurrentLineColor = hexString(from: w.color)
    }
    @objc private func otherColorChanged(_ w: NSColorWell) {
        settings.panelOtherLineColor = hexString(from: w.color)
    }
    @objc private func spacingChanged(_ s: NSSlider) { settings.panelLineSpacing = s.doubleValue }
    @objc private func opacityChanged(_ s: NSSlider) { settings.panelBackgroundOpacity = s.doubleValue }
    @objc private func delayChanged(_ s: NSSlider) { settings.panelAutoResumeDelay = s.doubleValue }

    @objc private func globalOffsetChanged(_ s: NSSlider) {
        let value = (s.doubleValue * 10).rounded() / 10
        settings.globalLyricOffset = value
        globalOffsetValueLabel?.stringValue = offsetText(value)
        appState.tickPlayback()
    }

    @objc private func offsetChanged(_ s: NSSlider) {
        let value = (s.doubleValue * 10).rounded() / 10
        appState.setSongOffset(value)
        offsetValueLabel?.stringValue = offsetText(value)
        offsetResetButton?.isEnabled = abs(value) > 0.001
    }

    @objc private func resetOffset() {
        appState.resetSongOffset()
        refreshOffsetControls()
    }

    @objc private func panelWidthChanged(_ slider: NSSlider) {
        let value = slider.doubleValue.rounded()
        settings.panelWidth = value
        panelWidthValueLabel?.stringValue = dimensionText(value)
    }

    @objc private func panelHeightChanged(_ slider: NSSlider) {
        let value = slider.doubleValue.rounded()
        settings.panelHeight = value
        panelHeightValueLabel?.stringValue = dimensionText(value)
    }

    @objc private func panelPresetTapped(_ button: NSButton) {
        let size: (Double, Double)
        switch button.tag {
        case 0: size = (320, 420)
        case 2: size = (480, 640)
        default: size = (360, 480)
        }
        settings.panelWidth = size.0
        settings.panelHeight = size.1
        panelWidthSlider?.doubleValue = size.0
        panelHeightSlider?.doubleValue = size.1
        panelWidthValueLabel?.stringValue = dimensionText(size.0)
        panelHeightValueLabel?.stringValue = dimensionText(size.1)
    }

    private func hexString(from color: NSColor) -> String {
        AppSettings.hexString(from: color)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard let sv = view as? NSScrollView,
              let doc = sv.documentView else { return }
        let topY = max(0, doc.frame.height - sv.contentView.bounds.height)
        sv.contentView.scroll(to: NSPoint(x: 0, y: topY))
    }
}

// MARK: - General Settings Tab

private final class SettingsGeneralTab: NSViewController {
    private let controller: LaunchAtLoginController
    private var cancellables = Set<AnyCancellable>()
    private weak var launchToggle: NSButton?
    private weak var statusLabel: NSTextField?
    private weak var approvalButton: NSButton?

    init(controller: LaunchAtLoginController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 500))
        let launchToggle = NSButton(
            checkboxWithTitle: "登录 Mac 时自动启动 MenuBarLyrics",
            target: self,
            action: #selector(launchAtLoginChanged(_:))
        )
        launchToggle.allowsMixedState = true
        launchToggle.frame = NSRect(x: 28, y: 420, width: 390, height: 24)
        container.addSubview(launchToggle)
        self.launchToggle = launchToggle

        let statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 50, y: 365, width: 360, height: 45)
        container.addSubview(statusLabel)
        self.statusLabel = statusLabel

        let approvalButton = NSButton(
            title: "打开登录项设置",
            target: self,
            action: #selector(openLoginItemsSettings)
        )
        approvalButton.bezelStyle = .rounded
        approvalButton.frame = NSRect(x: 50, y: 325, width: 138, height: 28)
        container.addSubview(approvalButton)
        self.approvalButton = approvalButton

        let hint = NSTextField(wrappingLabelWithString: "为保证开机后能够找到软件，请将 MenuBarLyrics.app 保留在“应用程序”文件夹，不要从压缩包或下载目录直接运行。")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 28, y: 245, width: 390, height: 55)
        container.addSubview(hint)
        view = container

        Publishers.CombineLatest3(
            controller.$isEnabled,
            controller.$requiresApproval,
            controller.$statusText
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in self?.refreshUI() }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.controller.refresh() }
            .store(in: &cancellables)

        controller.refresh()
        refreshUI()
    }

    private func refreshUI() {
        if controller.isEnabled {
            launchToggle?.state = .on
        } else if controller.requiresApproval {
            launchToggle?.state = .mixed
        } else {
            launchToggle?.state = .off
        }
        statusLabel?.stringValue = controller.statusText
        approvalButton?.isHidden = !controller.requiresApproval
    }

    @objc private func launchAtLoginChanged(_ button: NSButton) {
        controller.setEnabled(button.state != .off)
        refreshUI()
    }

    @objc private func openLoginItemsSettings() {
        controller.openSystemSettings()
    }
}
