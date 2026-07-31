import Foundation
import AppKit
import CoreGraphics

/// Minimal key-value store interface that `AppSettings` depends on.
/// `UserDefaults` conforms automatically; tests supply an in-memory
/// implementation so they never create persistent plist residue.
protocol UserDefaultsStore: AnyObject {
    func set(_ value: Any?, forKey key: String)
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func integer(forKey key: String) -> Int
    func data(forKey key: String) -> Data?
    func addSuite(named suiteName: String)
}

extension UserDefaults: UserDefaultsStore {}

/// User-facing settings persisted via UserDefaults.
///
/// All properties use `@AppStorage`-compatible keys so they survive app
/// restarts. The `MenuWidth` enum is mapped to its `points` value for
/// storage (0 = iconOnly, 80 = compact, 160 = standard, 240 = wide).
///
/// `@MainActor` because it is read from UI code and written from the
/// settings window.
@MainActor
final class AppSettings: ObservableObject {

    static let menuBarVerticalOffsetRange = -8.0...12.0
    static let globalLyricOffsetRange = -5.0...5.0
    static let catSizeOptions = [32, 40, 48]
    static let catHorizontalOffsetRange = -16.0...16.0
    static let catVerticalOffsetRange = -10.0...10.0

    private let defaults: any UserDefaultsStore

    // MARK: - Menu bar settings

    /// Menu bar width in points (80–320, continuous).
    @Published var menuBarWidth: Double {
        didSet { defaults.set(menuBarWidth, forKey: Key.menuBarWidth) }
    }

    /// Menu bar font name (system font if nil/empty).
    @Published var menuBarFontName: String {
        didSet { defaults.set(menuBarFontName, forKey: Key.menuBarFontName) }
    }

    /// Menu bar font size (10–18).
    @Published var menuBarFontSize: Double {
        didSet { defaults.set(menuBarFontSize, forKey: Key.menuBarFontSize) }
    }

    /// Menu bar font weight (0.0 = ultra light … 1.0 = black).
    @Published var menuBarFontWeight: Double {
        didSet { defaults.set(menuBarFontWeight, forKey: Key.menuBarFontWeight) }
    }

    /// Positive values move the menu-bar lyric downward, in points.
    @Published var menuBarVerticalOffset: Double {
        didSet { defaults.set(menuBarVerticalOffset, forKey: Key.menuBarVerticalOffset) }
    }

    /// Filled (sung) color for light mode, as hex string.
    @Published var menuBarFilledColorLight: String {
        didSet { defaults.set(menuBarFilledColorLight, forKey: Key.menuBarFilledColorLight) }
    }

    /// Unfilled (unsung) color for light mode.
    @Published var menuBarUnfilledColorLight: String {
        didSet { defaults.set(menuBarUnfilledColorLight, forKey: Key.menuBarUnfilledColorLight) }
    }

    /// Filled color for dark mode.
    @Published var menuBarFilledColorDark: String {
        didSet { defaults.set(menuBarFilledColorDark, forKey: Key.menuBarFilledColorDark) }
    }

    /// Unfilled color for dark mode.
    @Published var menuBarUnfilledColorDark: String {
        didSet { defaults.set(menuBarUnfilledColorDark, forKey: Key.menuBarUnfilledColorDark) }
    }

    /// Whether the karaoke fill animation is enabled.
    @Published var fillAnimationEnabled: Bool {
        didSet { defaults.set(fillAnimationEnabled, forKey: Key.fillAnimationEnabled) }
    }

    /// Global lyric timing correction in seconds. Positive values delay
    /// lyrics; negative values advance them.
    @Published var globalLyricOffset: Double {
        didSet { defaults.set(globalLyricOffset, forKey: Key.globalLyricOffset) }
    }

    /// Whether the optional pixel cat companion is enabled.
    ///
    /// This remains opt-in until multi-display, full-screen, and power behavior
    /// have been validated on the running app.
    @Published var catEnabled: Bool {
        didSet { defaults.set(catEnabled, forKey: Key.catEnabled) }
    }

    /// The approved selectable cat artwork.
    @Published var catSkin: CatSkin {
        didSet { defaults.set(catSkin.rawValue, forKey: Key.catSkin) }
    }

    /// Menu-bar cat side length in points. The panel sprite is rendered at
    /// twice this size.
    @Published var catSize: Double {
        didSet { defaults.set(catSize, forKey: Key.catSize) }
    }

    /// Positive values move the menu-bar cat to the right, in points.
    @Published var catHorizontalOffset: Double {
        didSet { defaults.set(catHorizontalOffset, forKey: Key.catHorizontalOffset) }
    }

    /// Positive values move the menu-bar cat downward, in points.
    @Published var catVerticalOffset: Double {
        didSet { defaults.set(catVerticalOffset, forKey: Key.catVerticalOffset) }
    }

    /// Long lyric display mode.
    @Published var longLyricMode: LongLyricMode {
        didSet { defaults.set(longLyricMode.rawValue, forKey: Key.longLyricMode) }
    }

    // MARK: - Panel settings

    @Published var panelFontName: String {
        didSet { defaults.set(panelFontName, forKey: Key.panelFontName) }
    }

    @Published var panelFontSize: Double {
        didSet { defaults.set(panelFontSize, forKey: Key.panelFontSize) }
    }

    @Published var panelFontWeight: Double {
        didSet { defaults.set(panelFontWeight, forKey: Key.panelFontWeight) }
    }

    @Published var panelCurrentLineColor: String {
        didSet { defaults.set(panelCurrentLineColor, forKey: Key.panelCurrentLineColor) }
    }

    @Published var panelOtherLineColor: String {
        didSet { defaults.set(panelOtherLineColor, forKey: Key.panelOtherLineColor) }
    }

    @Published var panelLineSpacing: Double {
        didSet { defaults.set(panelLineSpacing, forKey: Key.panelLineSpacing) }
    }

    @Published var panelBackgroundOpacity: Double {
        didSet { defaults.set(panelBackgroundOpacity, forKey: Key.panelBackgroundOpacity) }
    }

    @Published var panelAutoResumeDelay: Double {
        didSet { defaults.set(panelAutoResumeDelay, forKey: Key.panelAutoResumeDelay) }
    }

    @Published var panelWidth: Double {
        didSet { defaults.set(panelWidth, forKey: Key.panelWidth) }
    }

    @Published var panelHeight: Double {
        didSet { defaults.set(panelHeight, forKey: Key.panelHeight) }
    }

    // MARK: - Init

    init(defaults: any UserDefaultsStore = UserDefaults.standard) {
        self.defaults = defaults
        let d = defaults
        // The original SwiftPM executable used the process-name preference
        // domain. Keep it as a read fallback when moving to a real bundle ID,
        // so installing the .app does not silently discard existing choices.
        if let std = defaults as? UserDefaults, std === UserDefaults.standard {
            d.addSuite(named: "MenuBarLyrics")
        }
        menuBarWidth = d.object(forKey: Key.menuBarWidth) as? Double ?? 160
        menuBarFontName = d.string(forKey: Key.menuBarFontName) ?? ""
        menuBarFontSize = d.object(forKey: Key.menuBarFontSize) as? Double ?? 13
        menuBarFontWeight = d.object(forKey: Key.menuBarFontWeight) as? Double ?? 0.5
        let storedVerticalOffset = d.object(forKey: Key.menuBarVerticalOffset) as? Double ?? 2
        menuBarVerticalOffset = min(
            Self.menuBarVerticalOffsetRange.upperBound,
            max(Self.menuBarVerticalOffsetRange.lowerBound, storedVerticalOffset)
        )
        menuBarFilledColorLight = d.string(forKey: Key.menuBarFilledColorLight) ?? "#007AFF"
        menuBarUnfilledColorLight = d.string(forKey: Key.menuBarUnfilledColorLight) ?? "#00000080"
        menuBarFilledColorDark = d.string(forKey: Key.menuBarFilledColorDark) ?? "#0A84FF"
        menuBarUnfilledColorDark = d.string(forKey: Key.menuBarUnfilledColorDark) ?? "#FFFFFFB3"
        fillAnimationEnabled = d.object(forKey: Key.fillAnimationEnabled) as? Bool ?? true
        let storedGlobalLyricOffset = d.object(forKey: Key.globalLyricOffset) as? Double ?? 0
        globalLyricOffset = min(
            Self.globalLyricOffsetRange.upperBound,
            max(Self.globalLyricOffsetRange.lowerBound, storedGlobalLyricOffset)
        )
        catEnabled = d.object(forKey: Key.catEnabled) as? Bool ?? false
        catSkin = CatSkin(rawValue: d.string(forKey: Key.catSkin) ?? "") ?? .maoMao
        let storedCatSize = Int(d.object(forKey: Key.catSize) as? Double ?? 32)
        catSize = Double(Self.catSizeOptions.contains(storedCatSize) ? storedCatSize : 32)
        let storedCatHorizontalOffset = d.object(forKey: Key.catHorizontalOffset) as? Double ?? 0
        catHorizontalOffset = min(
            Self.catHorizontalOffsetRange.upperBound,
            max(Self.catHorizontalOffsetRange.lowerBound, storedCatHorizontalOffset)
        )
        let storedCatVerticalOffset = d.object(forKey: Key.catVerticalOffset) as? Double ?? 0
        catVerticalOffset = min(
            Self.catVerticalOffsetRange.upperBound,
            max(Self.catVerticalOffsetRange.lowerBound, storedCatVerticalOffset)
        )
        longLyricMode = LongLyricMode(rawValue: d.integer(forKey: Key.longLyricMode)) ?? .autoScroll

        panelFontName = d.string(forKey: Key.panelFontName) ?? ""
        panelFontSize = d.object(forKey: Key.panelFontSize) as? Double ?? 13
        panelFontWeight = d.object(forKey: Key.panelFontWeight) as? Double ?? 0.5
        panelCurrentLineColor = d.string(forKey: Key.panelCurrentLineColor) ?? "#007AFF"
        panelOtherLineColor = d.string(forKey: Key.panelOtherLineColor) ?? "#00000099"
        panelLineSpacing = d.object(forKey: Key.panelLineSpacing) as? Double ?? 28
        panelBackgroundOpacity = d.object(forKey: Key.panelBackgroundOpacity) as? Double ?? 0.85
        panelAutoResumeDelay = d.object(forKey: Key.panelAutoResumeDelay) as? Double ?? 4.0
        panelWidth = d.object(forKey: Key.panelWidth) as? Double ?? 360
        panelHeight = d.object(forKey: Key.panelHeight) as? Double ?? 480
    }

    // MARK: - Key constants

    private enum Key {
        static let menuBarWidth = "mbl.menuBarWidth"
        static let menuBarFontName = "mbl.menuBarFontName"
        static let menuBarFontSize = "mbl.menuBarFontSize"
        static let menuBarFontWeight = "mbl.menuBarFontWeight"
        static let menuBarVerticalOffset = "mbl.menuBarVerticalOffset"
        static let menuBarFilledColorLight = "mbl.menuBarFilledColorLight"
        static let menuBarUnfilledColorLight = "mbl.menuBarUnfilledColorLight"
        static let menuBarFilledColorDark = "mbl.menuBarFilledColorDark"
        static let menuBarUnfilledColorDark = "mbl.menuBarUnfilledColorDark"
        static let fillAnimationEnabled = "mbl.fillAnimationEnabled"
        static let globalLyricOffset = "mbl.globalLyricOffset"
        static let catEnabled = "mbl.catEnabled"
        static let catSkin = "mbl.catSkin"
        static let catSize = "mbl.catSize"
        static let catHorizontalOffset = "mbl.catHorizontalOffset"
        static let catVerticalOffset = "mbl.catVerticalOffset"
        static let longLyricMode = "mbl.longLyricMode"

        static let panelFontName = "mbl.panelFontName"
        static let panelFontSize = "mbl.panelFontSize"
        static let panelFontWeight = "mbl.panelFontWeight"
        static let panelCurrentLineColor = "mbl.panelCurrentLineColor"
        static let panelOtherLineColor = "mbl.panelOtherLineColor"
        static let panelLineSpacing = "mbl.panelLineSpacing"
        static let panelBackgroundOpacity = "mbl.panelBackgroundOpacity"
        static let panelAutoResumeDelay = "mbl.panelAutoResumeDelay"
        static let panelWidth = "mbl.panelWidth"
        static let panelHeight = "mbl.panelHeight"
    }

    // MARK: - Helpers

    /// Available system fonts for the picker.
    static var availableFonts: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    /// Converts a hex color string to NSColor.
    static func color(fromHex hex: String) -> NSColor {
        var hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexStr.hasPrefix("#") { hexStr.removeFirst() }
        var rgba: UInt64 = 0
        Scanner(string: hexStr).scanHexInt64(&rgba)
        let r, g, b, a: CGFloat
        switch hexStr.count {
        case 8:
            r = CGFloat((rgba >> 24) & 0xFF) / 255
            g = CGFloat((rgba >> 16) & 0xFF) / 255
            b = CGFloat((rgba >> 8) & 0xFF) / 255
            a = CGFloat(rgba & 0xFF) / 255
        case 6:
            r = CGFloat((rgba >> 16) & 0xFF) / 255
            g = CGFloat((rgba >> 8) & 0xFF) / 255
            b = CGFloat(rgba & 0xFF) / 255
            a = 1.0
        default:
            return NSColor.controlAccentColor
        }
        return NSColor(red: r, green: g, blue: b, alpha: a)
    }

    /// Resolves a user-selected font family, size, and normalized weight.
    /// Falls back to the system font if the selected family is unavailable.
    static func font(name: String, size: Double, weight: Double) -> NSFont {
        let clampedSize = CGFloat(max(8, size))
        let clampedWeight = min(1, max(0, weight))
        let appKitWeight = NSFont.Weight(
            rawValue: CGFloat(-0.8 + clampedWeight * 1.42)
        )

        guard !name.isEmpty else {
            return NSFont.systemFont(ofSize: clampedSize, weight: appKitWeight)
        }

        let familyWeight = Int((clampedWeight * 15).rounded())
        return NSFontManager.shared.font(
            withFamily: name,
            traits: [],
            weight: familyWeight,
            size: clampedSize
        ) ?? NSFont.systemFont(ofSize: clampedSize, weight: appKitWeight)
    }

    /// Converts an AppKit color to an sRGB hex string including alpha.
    static func hexString(from color: NSColor) -> String {
        guard let color = color.usingColorSpace(.sRGB) else { return "#007AFFFF" }
        return String(
            format: "#%02X%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded()),
            Int((color.alphaComponent * 255).rounded())
        )
    }
}

/// How long lyrics are displayed in the menu bar when they don't fit.
enum LongLyricMode: Int, CaseIterable, Sendable {
    case autoScroll = 0
    case shrinkToFit = 1
    case truncate = 2

    var label: String {
        switch self {
        case .autoScroll: return "自动滚动"
        case .shrinkToFit: return "缩小适配"
        case .truncate: return "截断显示"
        }
    }
}
