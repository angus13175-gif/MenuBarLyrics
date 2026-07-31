import XCTest
import AppKit
@testable import MenuBarLyrics

/// In-memory key-value store that never touches disk — no cfprefsd, no
/// ~/Library/Preferences plist files. Used by tests to keep the user's
/// preferences folder clean.
private final class InMemoryDefaults: UserDefaultsStore {
    private var storage: [String: Any] = [:]

    func set(_ value: Any?, forKey key: String) { storage[key] = value }
    func object(forKey key: String) -> Any? { storage[key] }
    func string(forKey key: String) -> String? { storage[key] as? String }
    func integer(forKey key: String) -> Int { storage[key] as? Int ?? 0 }
    func data(forKey key: String) -> Data? { storage[key] as? Data }
    func addSuite(named suiteName: String) {}
    func removePersistentDomain(forName domainName: String) { storage.removeAll() }
    func synchronize() -> Bool { true }
}

@MainActor
final class MenuBarLyricsTests: XCTestCase {

    private func makeDefaults() -> InMemoryDefaults {
        InMemoryDefaults()
    }

    private func makeSnapshot(title: String = "Song") -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            sessionID: PlaybackSessionID(generation: 1),
            identity: .stable(bundleIdentifier: "com.test.player", uniqueIdentifier: "track-1"),
            lyricLookupKey: LyricLookupKey(
                normalizedTitle: title.lowercased(),
                normalizedArtist: "artist",
                normalizedAlbum: "album",
                roundedDuration: 240
            ),
            title: title,
            artist: "Artist",
            album: "Album",
            duration: 240,
            elapsedTime: 42,
            remoteTimestamp: nil,
            playbackRate: 1,
            isPlaying: true,
            receivedAtContinuous: .now
        )
    }

    func testMenuBarWidthRemainsContinuous() {
        let settings = AppSettings(defaults: makeDefaults())
        let view = LyricMenuBarView(settings: settings)
        view.menuWidth = 159

        XCTAssertEqual(view.intrinsicContentSize.width, 159)
    }

    func testProgressBarIsThickAndPinnedToVisualBottom() {
        let settings = AppSettings(defaults: makeDefaults())
        let view = LyricScrollView(settings: settings)
        view.setFrameSize(NSSize(width: 360, height: 400))

        XCTAssertEqual(view.progressBarLayoutFrame.height, 6)
        XCTAssertEqual(view.progressBarLayoutFrame.maxY, 392)
        XCTAssertGreaterThan(view.progressBarLayoutFrame.minY, 380)
    }

    func testPanelLineHeightReadsLiveSettings() {
        let settings = AppSettings(defaults: makeDefaults())

        let view = LyricScrollView(settings: settings)
        settings.panelFontSize = 18
        settings.panelLineSpacing = 37

        XCTAssertEqual(view.effectiveLineHeight, 37)
    }

    func testPositiveVerticalOffsetMovesMenuBarLyricDown() {
        let settings = AppSettings(defaults: makeDefaults())
        let view = LyricMenuBarView(settings: settings)
        view.frame = NSRect(x: 0, y: 0, width: 160, height: 24)

        settings.menuBarVerticalOffset = 0
        let centeredY = view.textOriginY(for: 13)
        settings.menuBarVerticalOffset = 2
        let movedDownY = view.textOriginY(for: 13)

        XCTAssertEqual(centeredY - movedDownY, 2, accuracy: 0.001)
    }

    func testCatReservationReplacesLeadingTextPadding() {
        let bounds = NSRect(x: 0, y: 0, width: 160, height: 24)

        XCTAssertEqual(
            LyricMenuBarView.drawingRect(in: bounds, catReservedWidth: 26),
            NSRect(x: 26, y: 0, width: 126, height: 24)
        )
        XCTAssertEqual(
            LyricMenuBarView.drawingRect(in: bounds, catReservedWidth: 0),
            NSRect(x: 8, y: 0, width: 144, height: 24)
        )
    }

    func testShortLyricFillsNormallyWithoutScrolling() {
        let layout = LyricMenuBarView.karaokeLayout(
            totalWidth: 80,
            viewportWidth: 100,
            progress: 0.5
        )

        XCTAssertEqual(layout.scrollOffset, 0, accuracy: 0.001)
        XCTAssertEqual(layout.visibleFillWidth, 40, accuracy: 0.001)
    }

    func testLongLyricKeepsFillFrontAtSeventyPercentWhileScrolling() {
        let layout = LyricMenuBarView.karaokeLayout(
            totalWidth: 200,
            viewportWidth: 100,
            progress: 0.6
        )

        XCTAssertEqual(layout.scrollOffset, 50, accuracy: 0.001)
        XCTAssertEqual(layout.visibleFillWidth, 70, accuracy: 0.001)
    }

    func testLongLyricFinishesFillingAfterTailAppears() {
        let tailAppearing = LyricMenuBarView.karaokeLayout(
            totalWidth: 200,
            viewportWidth: 100,
            progress: 0.85
        )
        let finishing = LyricMenuBarView.karaokeLayout(
            totalWidth: 200,
            viewportWidth: 100,
            progress: 0.925
        )
        let completed = LyricMenuBarView.karaokeLayout(
            totalWidth: 200,
            viewportWidth: 100,
            progress: 1
        )

        XCTAssertEqual(tailAppearing.scrollOffset, 100, accuracy: 0.001)
        XCTAssertEqual(tailAppearing.visibleFillWidth, 70, accuracy: 0.001)
        XCTAssertEqual(finishing.scrollOffset, 100, accuracy: 0.001)
        XCTAssertEqual(finishing.visibleFillWidth, 85, accuracy: 0.001)
        XCTAssertEqual(completed.visibleFillWidth, 100, accuracy: 0.001)
    }

    func testPanelSizePersists() {
        let defaults = makeDefaults()
        let first = AppSettings(defaults: defaults)
        first.panelWidth = 480
        first.panelHeight = 640

        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.panelWidth, 480)
        XCTAssertEqual(second.panelHeight, 640)
    }

    func testPixelCatIsOptInAndPersistsWhenEnabled() {
        let defaults = makeDefaults()
        let initial = AppSettings(defaults: defaults)
        XCTAssertFalse(initial.catEnabled)
        XCTAssertEqual(initial.catSkin, .maoMao)
        XCTAssertEqual(initial.catSize, 32)
        XCTAssertEqual(initial.catHorizontalOffset, 0)
        XCTAssertEqual(initial.catVerticalOffset, 0)
        XCTAssertEqual(AppSettings.catSizeOptions, [32, 40, 48])
        XCTAssertEqual(AppSettings.catHorizontalOffsetRange, -16...16)
        XCTAssertEqual(AppSettings.catVerticalOffsetRange, -10...10)

        initial.catEnabled = true
        initial.catSkin = .miMi
        initial.catSize = 32
        initial.catHorizontalOffset = -8
        initial.catVerticalOffset = -7
        let restored = AppSettings(defaults: defaults)
        XCTAssertTrue(restored.catEnabled)
        XCTAssertEqual(restored.catSkin, .miMi)
        XCTAssertEqual(restored.catSize, 32)
        XCTAssertEqual(restored.catHorizontalOffset, -8)
        XCTAssertEqual(restored.catVerticalOffset, -7)
    }

    func testCatHorizontalOffsetClampsStoredValuesToSixteenPointsEachWay() {
        let defaults = makeDefaults()
        defaults.set(20.0, forKey: "mbl.catHorizontalOffset")
        XCTAssertEqual(AppSettings(defaults: defaults).catHorizontalOffset, 16)

        defaults.set(-20.0, forKey: "mbl.catHorizontalOffset")
        XCTAssertEqual(AppSettings(defaults: defaults).catHorizontalOffset, -16)
    }

    func testCatVerticalOffsetClampsStoredValuesToTenPointsEachWay() {
        let defaults = makeDefaults()
        defaults.set(14.0, forKey: "mbl.catVerticalOffset")
        XCTAssertEqual(AppSettings(defaults: defaults).catVerticalOffset, 10)

        defaults.set(-14.0, forKey: "mbl.catVerticalOffset")
        XCTAssertEqual(AppSettings(defaults: defaults).catVerticalOffset, -10)
    }

    func testRemovedCatSizesMigrateToNewMinimum() {
        let defaults = makeDefaults()
        defaults.set(24.0, forKey: "mbl.catSize")

        XCTAssertEqual(AppSettings(defaults: defaults).catSize, 32)
    }

    func testMenuBarVerticalOffsetSupportsAdditionalDownwardPositions() {
        XCTAssertEqual(AppSettings.menuBarVerticalOffsetRange.lowerBound, -8)
        XCTAssertEqual(AppSettings.menuBarVerticalOffsetRange.upperBound, 12)

        let defaults = makeDefaults()
        defaults.set(12.0, forKey: "mbl.menuBarVerticalOffset")
        XCTAssertEqual(AppSettings(defaults: defaults).menuBarVerticalOffset, 12)
    }

    func testGlobalLyricOffsetPersistsAndClamps() {
        let defaults = makeDefaults()
        let initial = AppSettings(defaults: defaults)
        XCTAssertEqual(initial.globalLyricOffset, 0)
        XCTAssertEqual(AppSettings.globalLyricOffsetRange, -5...5)

        initial.globalLyricOffset = 1.7
        XCTAssertEqual(AppSettings(defaults: defaults).globalLyricOffset, 1.7)

        defaults.set(8.0, forKey: "mbl.globalLyricOffset")
        XCTAssertEqual(AppSettings(defaults: defaults).globalLyricOffset, 5)
    }

    func testGlobalAndPerSongOffsetsAreAdditive() {
        XCTAssertEqual(
            AppState.adjustedLyricElapsed(rawElapsed: 20, globalOffset: 1.5, songOffset: -0.5),
            19
        )
    }

    func testSongOffsetPersistsPerSongAndClamps() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let snapshot = makeSnapshot()

        let first = AppState(defaults: defaults)
        first.configure(settings: settings)
        first.updateSnapshot(snapshot)
        first.setSongOffset(8)
        XCTAssertEqual(first.currentSongOffset, 5)

        let restored = AppState(defaults: defaults)
        restored.configure(settings: AppSettings(defaults: defaults))
        restored.updateSnapshot(snapshot)
        XCTAssertEqual(restored.currentSongOffset, 5)

        restored.updateSnapshot(makeSnapshot(title: "Another Song"))
        XCTAssertEqual(restored.currentSongOffset, 0)
    }

    // MARK: - Zero disk footprint

    /// `makeDefaults()` returns an in-memory store. Writing to it must not
    /// create any `MenuBarLyricsTests.*.plist` files in
    /// `~/Library/Preferences`.
    func testMakeDefaultsLeavesNoPreferenceFileResidue() {
        let defaults = makeDefaults()
        defaults.set(480.0, forKey: "mbl.panelWidth")
        defaults.synchronize()

        let prefsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences")
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: prefsDir.path) else {
            XCTFail("Cannot read Preferences directory")
            return
        }
        let residue = names.filter { $0.hasPrefix("MenuBarLyricsTests.") && $0.hasSuffix(".plist") }
        XCTAssertEqual(
            residue.count, 0,
            "InMemoryDefaults must not materialize any plist files in \(prefsDir.path); found \(residue)"
        )
    }
}
