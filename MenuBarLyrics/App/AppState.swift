import Foundation
import Combine

/// The top-level application state object that ties the data plane, lyric
/// pipeline, and sync engine together.
///
/// `AppState` is `@MainActor`-isolated: all mutations of its published state
/// happen on the main thread. It owns the `PlaybackClock` and `LyricSyncEngine`
/// and holds a reference to a `LyricRepository` (configured after init).
///
/// The flow on each now-playing snapshot:
/// 1. The clock is recalibrated from the snapshot.
/// 2. If the playback session changed, a new lyric fetch is initiated.
/// 3. The render state is recomputed from the interpolated elapsed time.
///
/// On each display-link tick (`tickPlayback()`), only the render state is
/// recomputed, advancing the active line using clock interpolation.
///
/// Anti-racing: lyric fetches are tagged with a monotonically increasing
/// `requestGeneration`. Only the result whose `requestGeneration` still matches
/// `currentRequestID` is written back, so stale fetches from a previous song
/// cannot clobber the current lyrics state.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var mediaState: MediaState = .starting
    @Published private(set) var nowPlaying: NowPlayingSnapshot?
    @Published private(set) var lyricsState: LyricsState = .idle
    @Published private(set) var renderState: LyricRenderState?
    @Published var preferredMenuWidth: MenuWidth = .standard
    @Published var isPinned: Bool = false

    private let clock = PlaybackClock()
    private let syncEngine = LyricSyncEngine()
    private(set) var lyricRepo: LyricRepository?
    private var currentRequestID: LyricRequestID?
    private(set) var settings: AppSettings?

    /// Per-song lyric offset in seconds (-5 to +5). Positive = lyrics delayed
    /// (appear later), negative = lyrics advanced (appear earlier).
    /// Stored per LyricLookupKey, persisted via UserDefaults.
    private var songOffsets: [LyricLookupKey: TimeInterval] = [:]
    private let offsetsKey = "mbl.songOffsets"
    private let defaults: any UserDefaultsStore
    private let lyricDebounceDuration: Duration
    private let automaticRetryDelay: Duration
    private var pendingFetchTask: Task<Void, Never>?

    private struct SongOffsetRecord: Codable {
        let key: LyricLookupKey
        let offset: TimeInterval
    }

    /// Continuous-clock instant of the last recorded diagnostic sync entry.
    /// Used to throttle sync logging to roughly once per 5 seconds so the
    /// log does not grow on every display-link frame.
    private var lastDiagnosticSyncLog: ContinuousClock.Instant?

    init(
        defaults: any UserDefaultsStore = UserDefaults.standard,
        lyricDebounceDuration: Duration = .milliseconds(350),
        automaticRetryDelay: Duration = .seconds(1)
    ) {
        self.defaults = defaults
        self.lyricDebounceDuration = lyricDebounceDuration
        self.automaticRetryDelay = automaticRetryDelay
    }

    /// Extracts the loaded `LyricDocument` from `lyricsState`, if any.
    var currentLyrics: LyricDocument? {
        if case .loaded(_, let doc) = lyricsState { return doc }
        return nil
    }

    /// Injects the lyric repository. Called once during app launch, before any
    /// snapshots arrive.
    func configure(lyricRepo: LyricRepository) {
        self.lyricRepo = lyricRepo
    }

    /// Injects the settings object so AppState can read user preferences.
    func configure(settings: AppSettings) {
        self.settings = settings
        loadSongOffsets()
    }

    // MARK: - Per-song offset

    /// Gets the lyric offset for the current song, or 0 if none set.
    var currentSongOffset: TimeInterval {
        guard let np = nowPlaying else { return 0 }
        return songOffsets[np.lyricLookupKey] ?? 0
    }

    /// Sets the lyric offset for the current song (-5 to +5 seconds).
    /// Positive = lyrics delayed, negative = lyrics advanced.
    func setSongOffset(_ offset: TimeInterval) {
        guard let np = nowPlaying else { return }
        let clamped = max(-5.0, min(5.0, offset))
        songOffsets[np.lyricLookupKey] = clamped
        saveSongOffsets()
        updateRenderState()
    }

    /// Resets the offset for the current song to 0.
    func resetSongOffset() {
        guard let np = nowPlaying else { return }
        songOffsets.removeValue(forKey: np.lyricLookupKey)
        saveSongOffsets()
        updateRenderState()
    }

    private func loadSongOffsets() {
        guard let data = defaults.data(forKey: offsetsKey) else { return }

        if let records = try? JSONDecoder().decode([SongOffsetRecord].self, from: data) {
            songOffsets = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0.offset) })
            return
        }

        // Migrate the first implementation, which stored a pipe-delimited
        // dictionary and then accidentally discarded it during loading.
        guard let legacy = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else {
            return
        }
        for (serializedKey, offset) in legacy {
            let parts = serializedKey.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { continue }
            let duration = Int(parts[3]).flatMap { $0 == 0 ? nil : $0 }
            let key = LyricLookupKey(
                normalizedTitle: String(parts[0]),
                normalizedArtist: parts[1].isEmpty ? nil : String(parts[1]),
                normalizedAlbum: parts[2].isEmpty ? nil : String(parts[2]),
                roundedDuration: duration
            )
            songOffsets[key] = max(-5, min(5, offset))
        }
        saveSongOffsets()
    }

    private func saveSongOffsets() {
        let records = songOffsets.map { SongOffsetRecord(key: $0.key, offset: $0.value) }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: offsetsKey)
        }
    }

    /// Main entry point for new playback data from the data source.
    ///
    /// A `nil` snapshot signals "no media" and resets all derived state.
    func updateSnapshot(_ snapshot: NowPlayingSnapshot?) {
        if let snapshot {
            let previousSnapshot = nowPlaying
            let prevSessionID = previousSnapshot?.sessionID
            nowPlaying = snapshot
            clock.update(snapshot: snapshot)

            if prevSessionID != snapshot.sessionID {
                // Cancel any in-flight fetch for the previous session so a
                // stale result cannot clobber the new track's lyrics.
                if let prev = prevSessionID {
                    Task { [lyricRepo] in
                        await lyricRepo?.cancelRequests(for: prev)
                    }
                }
                scheduleLyricsFetch(for: snapshot)
            } else if previousSnapshot?.lyricLookupKey != snapshot.lyricLookupKey,
                      shouldRefreshLyricsForMetadataChange {
                // MediaRemote commonly emits a new title with stale duration,
                // then corrects artist/album/duration in later snapshots for
                // the same playback session. Restart the cancellable debounce
                // so the network request uses the completed metadata.
                scheduleLyricsFetch(for: snapshot)
            }
            updateRenderState()
        } else {
            pendingFetchTask?.cancel()
            pendingFetchTask = nil
            nowPlaying = nil
            if case .ready = mediaState {
                mediaState = .noMedia
            }
            renderState = LyricRenderState(
                sessionID: nil,
                lineIndex: nil,
                lineProgress: 0,
                phase: .noMedia,
                estimatedElapsed: 0,
                duration: nil
            )
            lyricsState = .idle
            currentRequestID = nil
        }
    }

    /// Updates the coarse media-availability state. When the helper becomes
    /// unavailable, an explicit `helperUnavailable` render state is published so
    /// the UI can show a diagnostic.
    func updateMediaState(_ state: MediaState) {
        mediaState = state
        if case .unavailable = state {
            renderState = LyricRenderState(
                sessionID: nil,
                lineIndex: nil,
                lineProgress: 0,
                phase: .helperUnavailable,
                estimatedElapsed: 0,
                duration: nil
            )
        }
    }

    /// Called every frame by the display link. Recomputes the render state using
    /// clock interpolation so the active line advances smoothly between
    /// snapshots.
    func tickPlayback() {
        guard nowPlaying != nil else { return }
        updateRenderState()
    }

    // MARK: - Render state

    private func updateRenderState() {
        guard let np = nowPlaying else {
            renderState = nil
            return
        }
        let rawElapsed = clock.estimatedElapsed(now: .now)
        // Global and per-song corrections are additive. Positive values delay
        // lyrics (look at an earlier position); negative values advance them.
        let elapsed = Self.adjustedLyricElapsed(
            rawElapsed: rawElapsed,
            globalOffset: settings?.globalLyricOffset ?? 0,
            songOffset: songOffsets[np.lyricLookupKey] ?? 0
        )
        let state = syncEngine.computeState(
            elapsed: elapsed,
            playing: np.isPlaying,
            lyrics: currentLyrics,
            sessionID: np.sessionID,
            duration: np.duration
        )
        renderState = state

        // Diagnostic sync logging, throttled to roughly once per 5 seconds
        // so we don't write an entry on every display-link frame.
        let now = ContinuousClock.now
        let shouldLog: Bool
        if let last = lastDiagnosticSyncLog {
            let delta = last.duration(to: now)
            let deltaSeconds = Double(delta.components.seconds)
                + Double(delta.components.attoseconds) / 1e18
            shouldLog = deltaSeconds >= 5.0
        } else {
            shouldLog = true
        }
        if shouldLog {
            lastDiagnosticSyncLog = now

            // Extract the player bundle id for logging.
            let playerBundleId: String?
            switch np.identity {
            case .stable(let bundle, _): playerBundleId = bundle
            case .fallback(let bundle, _): playerBundleId = bundle
            }

            // Determine the current line's time range from the lyrics
            // document, if a line is active. Only the time range (not the
            // lyric text) is recorded.
            var lineStart: TimeInterval?
            var lineEnd: TimeInterval?
            if let idx = state.lineIndex, let lyrics = currentLyrics,
               idx >= 0 && idx < lyrics.lines.count {
                let line = lyrics.lines[idx]
                lineStart = line.startTime
                lineEnd = line.intervalEndTime
                    ?? (idx + 1 < lyrics.lines.count ? lyrics.lines[idx + 1].startTime : nil)
                    ?? np.duration
            }

            DiagnosticLog.shared.logPlaybackSync(
                player: playerBundleId,
                title: np.title,
                artist: np.artist,
                album: np.album,
                duration: np.duration,
                remoteElapsed: np.elapsedTime,
                remoteTimestamp: np.remoteTimestamp,
                receiptTime: np.receivedAtContinuous,
                estimatedElapsed: state.estimatedElapsed,
                currentLineIndex: state.lineIndex,
                currentLineStart: lineStart,
                currentLineEnd: lineEnd
            )
        }
    }

    static func adjustedLyricElapsed(
        rawElapsed: TimeInterval,
        globalOffset: TimeInterval,
        songOffset: TimeInterval
    ) -> TimeInterval {
        rawElapsed - globalOffset - songOffset
    }

    // MARK: - Lyric fetching

    /// Re-searches lyrics for the current track, bypassing negative cache.
    /// Called when the user clicks "重新搜索" in the panel.
    func researchLyrics() {
        guard let snapshot = nowPlaying else { return }
        // Clearing the negative cache and starting the request are kept in the
        // same task, so the fetch can never race ahead of the cache clear.
        scheduleLyricsFetch(
            for: snapshot,
            delay: .zero,
            clearNegativeCache: true
        )
    }

    private var shouldRefreshLyricsForMetadataChange: Bool {
        if case .loaded = lyricsState { return false }
        return true
    }

    /// Schedules a cancellable lyric lookup. Any same-session metadata update
    /// replaces the pending task, and the request is executed only if the
    /// latest snapshot still matches its lookup key.
    private func scheduleLyricsFetch(
        for snapshot: NowPlayingSnapshot,
        delay: Duration? = nil,
        clearNegativeCache: Bool = false,
        automaticRetryAttempt: Int = 0
    ) {
        pendingFetchTask?.cancel()

        let requestID = LyricRequestID(
            sessionID: snapshot.sessionID,
            lookupKey: snapshot.lyricLookupKey,
            requestGeneration: (currentRequestID?.requestGeneration ?? 0) + 1
        )
        currentRequestID = requestID
        lyricsState = .loading(requestID)

        let waitDuration = delay ?? lyricDebounceDuration
        pendingFetchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: waitDuration)
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.currentRequestID == requestID,
                  let latest = self.nowPlaying,
                  latest.sessionID == requestID.sessionID,
                  latest.lyricLookupKey == requestID.lookupKey else { return }

            if clearNegativeCache {
                await self.lyricRepo?.clearNegativeCache(for: requestID.lookupKey)
                guard !Task.isCancelled, self.currentRequestID == requestID else { return }
            }

            self.pendingFetchTask = nil
            await self.performLyricRequest(
                requestID: requestID,
                snapshot: latest,
                automaticRetryAttempt: automaticRetryAttempt
            )
        }
    }

    /// Runs the actual fetch on the main actor and applies the result, gated by
    /// the anti-racing check.
    @MainActor
    private func performLyricRequest(
        requestID: LyricRequestID,
        snapshot: NowPlayingSnapshot,
        automaticRetryAttempt: Int
    ) async {
        guard let repo = lyricRepo else { return }

        let title = snapshot.title
        let artist = snapshot.artist
        let album = snapshot.album
        let playerBundleId: String?
        switch snapshot.identity {
        case .stable(let bundle, _): playerBundleId = bundle
        case .fallback(let bundle, _): playerBundleId = bundle
        }

        let result = await repo.fetchLyricsAsync(
            requestID: requestID,
            displayTitle: title,
            displayArtist: artist,
            displayAlbum: album,
            playerBundleId: playerBundleId
        )

        // Anti-racing: only write back if this is still the current request.
        // A newer song would have bumped requestGeneration, invalidating this.
        guard currentRequestID == requestID else { return }

        switch result {
        case .success(let candidate):
            if let candidate {
                lyricsState = .loaded(requestID, candidate.document)
                DiagnosticLog.shared.logLyricFetch(
                    title: title,
                    artist: artist,
                    source: Self.sourceName(for: candidate.document.source),
                    matchKind: Self.matchKindName(for: candidate.matchKind),
                    score: candidate.score,
                    result: "success"
                )
            } else {
                lyricsState = .noResult(requestID)
                DiagnosticLog.shared.logLyricFetch(
                    title: title,
                    artist: artist,
                    source: "unknown",
                    matchKind: nil,
                    score: nil,
                    result: "noResult"
                )
                scheduleAutomaticRetryIfNeeded(
                    for: snapshot,
                    requestID: requestID,
                    attempt: automaticRetryAttempt
                )
            }
        case .failure(let error):
            lyricsState = .failed(requestID, error)
            DiagnosticLog.shared.logLyricFetch(
                title: title,
                artist: artist,
                source: "unknown",
                matchKind: nil,
                score: nil,
                result: "error",
                error: Self.errorName(for: error)
            )
            scheduleAutomaticRetryIfNeeded(
                for: snapshot,
                requestID: requestID,
                attempt: automaticRetryAttempt
            )
        }
        updateRenderState()
    }

    /// A first genuine no-result can be caused by metadata/API settling. Retry
    /// once with the latest snapshot and bypass the short negative cache—the
    /// same recovery that previously required clicking “重新搜索”.
    private func scheduleAutomaticRetryIfNeeded(
        for snapshot: NowPlayingSnapshot,
        requestID: LyricRequestID,
        attempt: Int
    ) {
        guard attempt == 0,
              currentRequestID == requestID,
              nowPlaying?.sessionID == snapshot.sessionID else { return }
        scheduleLyricsFetch(
            for: nowPlaying ?? snapshot,
            delay: automaticRetryDelay,
            clearNegativeCache: true,
            automaticRetryAttempt: 1
        )
    }

    /// Maps a `LyricSource` to a stable string for the diagnostic log.
    private static func sourceName(for source: LyricSource) -> String {
        switch source {
        case .lrclib: return "lrclib"
        case .qqExperimental: return "qqExperimental"
        case .netease: return "netease"
        }
    }

    /// Maps a `LyricMatchKind` to a stable string for the diagnostic log.
    private static func matchKindName(for kind: LyricMatchKind) -> String {
        switch kind {
        case .exact: return "exact"
        case .search: return "search"
        }
    }

    /// Maps a `LyricError` to a stable string for the diagnostic log.
    private static func errorName(for error: LyricError) -> String {
        switch error {
        case .transport: return "transport"
        case .http(let status): return "http\(status)"
        case .responseTooLarge: return "responseTooLarge"
        case .decoding: return "decoding"
        case .parsing: return "parsing"
        }
    }
}
