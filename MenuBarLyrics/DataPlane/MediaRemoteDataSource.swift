import Foundation

protocol MediaRemoteDataSourceDelegate: AnyObject {
    @MainActor func dataSource(_ ds: MediaRemoteDataSource, didUpdateSnapshot: NowPlayingSnapshot?)
    @MainActor func dataSource(_ ds: MediaRemoteDataSource, didChangeMediaState: MediaState)
}

final class MediaRemoteDataSource: PerlHelperDelegate, @unchecked Sendable {
    weak var delegate: MediaRemoteDataSourceDelegate?

    private let helper = PerlHelper()
    private var sessionGeneration: UInt64 = 0
    private var currentIdentity: TrackIdentity?
    private var noMediaGraceTimer: DispatchSourceTimer?

    func configure(scriptPath: String, frameworkPath: String) {
        helper.configure(scriptPath: scriptPath, frameworkPath: frameworkPath)
        helper.delegate = self
    }

    func start() {
        helper.start()
    }

    func stop() {
        helper.stop()
    }

    // MARK: - PerlHelperDelegate

    func perlHelper(_ helper: PerlHelper, didReceivePayload payload: AdapterPayload) {
        let snapshot = reduceToSnapshot(payload: payload)
        if let snapshot {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.delegate?.dataSource(self, didUpdateSnapshot: snapshot)
                }
            }
        }
    }

    func perlHelper(_ helper: PerlHelper, didReceiveError error: String) {
        // Log diagnostics only
    }

    func perlHelper(_ helper: PerlHelper, didChangeState state: PerlHelper.State) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                switch state {
                case .starting:
                    self.delegate?.dataSource(self, didChangeMediaState: .starting)
                case .ready:
                    self.delegate?.dataSource(self, didChangeMediaState: .ready)
                case .stopped:
                    break
                case .reconnecting(let attempt):
                    self.delegate?.dataSource(self, didChangeMediaState: .reconnecting(attempt: attempt))
                case .unavailable(let reason):
                    // Pattern match on the structured reason instead of parsing
                    // a free-form string.
                    let failure: MediaFailure
                    switch reason {
                    case .fatalExit(let code):
                        failure = .fatalAdapterExit(code: code)
                    case .transientRetriesExhausted:
                        failure = .transientRetriesExhausted
                    case .startupTimeout:
                        failure = .startupTimeout
                    case .launchFailed:
                        // A launch failure means the adapter never started; map
                        // it to a startup timeout for the media layer.
                        failure = .startupTimeout
                    }
                    self.delegate?.dataSource(self, didChangeMediaState: .unavailable(failure))
                }
            }
        }
    }

    // MARK: - Snapshot reduction

    private func reduceToSnapshot(payload: AdapterPayload) -> NowPlayingSnapshot? {
        if payload.title == nil && payload.bundleIdentifier == nil {
            handleNoMedia()
            return nil
        }

        guard let title = payload.title, let bundleId = payload.bundleIdentifier else {
            return nil
        }

        cancelNoMediaGrace()

        let normalizedTitle = LyricMatcher.normalize(title)
        let newIdentity: TrackIdentity
        if let uniqueId = payload.uniqueIdentifier, !uniqueId.isEmpty {
            newIdentity = .stable(bundleIdentifier: bundleId, uniqueIdentifier: uniqueId)
        } else {
            newIdentity = .fallback(bundleIdentifier: bundleId, normalizedTitle: normalizedTitle)
        }

        let shouldRecreateSession: Bool
        if let current = currentIdentity {
            switch (current, newIdentity) {
            case (.stable(let oldBundle, let oldId), .stable(let newBundle, let newId)):
                shouldRecreateSession = oldBundle != newBundle || oldId != newId
            case (.fallback(let oldBundle, let oldTitle), .fallback(let newBundle, let newTitle)):
                shouldRecreateSession = oldBundle != newBundle || oldTitle != newTitle
            default:
                shouldRecreateSession = true
            }
        } else {
            shouldRecreateSession = true
        }

        if shouldRecreateSession {
            sessionGeneration += 1
            currentIdentity = newIdentity
        }

        let lookupKey = LyricLookupKey(
            normalizedTitle: normalizedTitle,
            normalizedArtist: payload.artist.map { LyricMatcher.normalize($0) },
            normalizedAlbum: payload.album.map { LyricMatcher.normalize($0) },
            roundedDuration: payload.duration.map { Int($0.rounded()) }
        )

        let timestamp: Date?
        if let micros = payload.timestampEpochMicros {
            timestamp = Date(timeIntervalSince1970: Double(micros) / 1_000_000)
        } else {
            timestamp = nil
        }

        return NowPlayingSnapshot(
            sessionID: PlaybackSessionID(generation: sessionGeneration),
            identity: newIdentity,
            lyricLookupKey: lookupKey,
            title: title,
            artist: payload.artist,
            album: payload.album,
            duration: payload.duration,
            elapsedTime: payload.elapsedTime,
            remoteTimestamp: timestamp,
            playbackRate: payload.playbackRate,
            isPlaying: payload.isPlaying,
            receivedAtContinuous: .now
        )
    }

    private func handleNoMedia() {
        cancelNoMediaGrace()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.sessionGeneration += 1
                self.currentIdentity = nil
                self.delegate?.dataSource(self, didUpdateSnapshot: nil)
            }
        }
        timer.resume()
        noMediaGraceTimer = timer
    }

    private func cancelNoMediaGrace() {
        noMediaGraceTimer?.cancel()
        noMediaGraceTimer = nil
    }
}
