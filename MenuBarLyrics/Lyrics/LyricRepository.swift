import Foundation

/// Coordinates lyric fetching across multiple `LyricProvider` sources with
/// positive caching, short-lived negative caching, and in-flight request
/// deduplication.
///
/// Positive cache: stores successful candidates for the app's lifetime.
/// Negative cache: a 5-minute TTL applied only when a lookup genuinely finds
///   nothing (a thrown error never populates the negative cache, so transient
///   network failures can be retried).
/// In-flight deduplication: concurrent calls for the same `LyricLookupKey`
///   share a single underlying fetch task. Each caller awaits that shared task
///   and wraps the result with its own `LyricRequestID`, so the shared task is
///   caller-agnostic and never inherits a particular caller's session.
///
/// Source selection: LRCLIB and the player-corresponding source (if any) are
/// queried in parallel as primary sources. If neither yields a match, the
/// remaining providers are tried sequentially as a fallback.
actor LyricRepository {
    private let providers: [LyricProvider]
    private let diskCache: LyricDiskCache
    private var positiveCache: [LyricLookupKey: CacheEntry] = [:]
    private var negativeCache: [LyricLookupKey: Date] = [:]
    private var inFlight: [LyricLookupKey: Task<RankedLyricCandidate?, Error>] = [:]
    private let negativeCacheTTL: TimeInterval

    init(
        providers: [LyricProvider],
        negativeCacheTTL: TimeInterval = 300,
        diskCache: LyricDiskCache = LyricDiskCache()
    ) {
        self.providers = providers
        self.negativeCacheTTL = negativeCacheTTL
        self.diskCache = diskCache
    }

    /// Fetches lyrics for the given request.
    ///
    /// Returns `.success(candidate)` for a match (from cache or freshly
    /// fetched), `.success(nil)` when no match exists (and the negative cache
    /// is updated), or `.failure` for a transport/decoding error. Errors never
    /// populate the negative cache.
    func fetchLyricsAsync(
        requestID: LyricRequestID,
        displayTitle: String,
        displayArtist: String?,
        displayAlbum: String?,
        playerBundleId: String?
    ) async -> Result<RankedLyricCandidate?, LyricError> {
        let lookupKey = requestID.lookupKey

        // 1. Positive cache.
        if let cached = positiveCache[lookupKey] {
            return .success(cached.candidate)
        }

        // 2. Negative cache (only for genuine no-match, never for errors).
        if let negDate = negativeCache[lookupKey],
           Date().timeIntervalSince(negDate) < negativeCacheTTL {
            return .success(nil)
        }

        // 3. Deduplicate in-flight requests for the same lookup key.
        //
        //    The disk-cache read is performed inside the shared task (see
        //    `makeFetchTask`) rather than here so that an `await` suspension
        //    does not occur between the in-flight check and task registration.
        //    Performing the disk read here would let a concurrent caller race
        //    past the registration window and spawn a duplicate network fetch,
        //    breaking the deduplication guarantee.
        let task: Task<RankedLyricCandidate?, Error>
        let isNewTask: Bool
        if let existing = inFlight[lookupKey] {
            task = existing
            isNewTask = false
        } else {
            task = makeFetchTask(
                lookupKey: lookupKey,
                displayTitle: displayTitle,
                displayArtist: displayArtist,
                displayAlbum: displayAlbum,
                playerBundleId: playerBundleId
            )
            inFlight[lookupKey] = task
            isNewTask = true
        }

        // Await the shared, caller-agnostic task.
        let outcome: Result<RankedLyricCandidate?, LyricError>
        do {
            let candidate = try await task.value
            outcome = .success(candidate)
        } catch let lyricError as LyricError {
            outcome = .failure(lyricError)
        } catch {
            outcome = .failure(.decoding)
        }

        // Only the task's owner mutates shared caches.
        if isNewTask {
            inFlight[lookupKey] = nil
            switch outcome {
            case .success(let candidate):
                if let candidate {
                    positiveCache[lookupKey] = CacheEntry(
                        candidate: candidate, cachedAt: Date()
                    )
                    // Persist to disk so the match survives app restarts.
                    await diskCache.set(lookupKey, candidate: candidate)
                } else {
                    negativeCache[lookupKey] = Date()
                }
            case .failure:
                // Errors are not negative-cached so they can be retried.
                break
            }
        }

        return outcome
    }

    /// Builds the shared fetch task.
    ///
    /// First consults the persistent disk cache (which survives app restarts);
    /// only on a miss does it query the network. Performing the disk read here,
    /// inside the shared task, ensures concurrent callers for the same lookup
    /// key still share a single fetch (deduplication): an `await` here does not
    /// race with in-flight task registration the way it would if the read sat
    /// in `fetchLyricsAsync`.
    ///
    /// Network phase: the primary sources (LRCLIB + player-corresponding
    /// source) are queried in parallel. If both fail to find a match, the
    /// remaining providers are tried sequentially as a fallback.
    ///
    /// Errors propagate (and are therefore not negative-cached): a transient
    /// transport failure on every consulted source surfaces as a `.failure`
    /// rather than being silently masked as a no-match.
    private func makeFetchTask(
        lookupKey: LyricLookupKey,
        displayTitle: String,
        displayArtist: String?,
        displayAlbum: String?,
        playerBundleId: String?
    ) -> Task<RankedLyricCandidate?, Error> {
        let primary = primarySources(for: playerBundleId)
        let primarySourcesSet = Set(primary.map { $0.source })
        let fallback = providers.filter { !primarySourcesSet.contains($0.source) }
        let diskCache = self.diskCache
        return Task {
            // Persistent disk cache: short-circuit before any network I/O.
            if let cached = await diskCache.get(lookupKey) {
                return cached
            }

            if let candidate = try await fetchFromSources(
                primary,
                lookupKey: lookupKey,
                displayTitle: displayTitle,
                displayArtist: displayArtist,
                displayAlbum: displayAlbum
            ) {
                return candidate
            }
            for provider in fallback {
                if let candidate = try await provider.fetchLyrics(
                    lookupKey: lookupKey,
                    displayTitle: displayTitle,
                    displayArtist: displayArtist,
                    displayAlbum: displayAlbum
                ) {
                    return candidate
                }
            }
            return nil
        }
    }

    /// Selects the primary sources for a given player bundle id: always LRCLIB,
    /// plus the player-corresponding source if one is registered.
    private func primarySources(for bundleId: String?) -> [LyricProvider] {
        var sources = [LyricProvider]()
        // Always include LRCLIB.
        if let lrclib = providers.first(where: { $0.source == .lrclib }) {
            sources.append(lrclib)
        }
        // Add player-corresponding source.
        if let bundleId {
            let targetSource: LyricSource?
            switch bundleId {
            case "com.netease.163music": targetSource = .netease
            case "com.tencent.QQMusicMac": targetSource = .qqExperimental
            default: targetSource = nil
            }
            if let target = targetSource, let provider = providers.first(where: { $0.source == target }) {
                sources.append(provider)
            }
        }
        return sources
    }

    /// Queries the given sources in parallel and returns the first non-nil
    /// result.
    ///
    /// A thrown error on one source does not abort the other: each result is
    /// captured as a `Result` so that a transient failure on one source still
    /// allows the other to produce a match. Only when *every* source either
    /// errors or returns nil do we surface an error (the first encountered) so
    /// it propagates as a `.failure` rather than being silently masked as a
    /// no-match (which would populate the negative cache).
    private func fetchFromSources(
        _ sources: [LyricProvider],
        lookupKey: LyricLookupKey,
        displayTitle: String,
        displayArtist: String?,
        displayAlbum: String?
    ) async throws -> RankedLyricCandidate? {
        if sources.isEmpty { return nil }
        if sources.count == 1 {
            return try await sources[0].fetchLyrics(
                lookupKey: lookupKey,
                displayTitle: displayTitle,
                displayArtist: displayArtist,
                displayAlbum: displayAlbum
            )
        }

        // Wrap each async call in a Result so a failure on one source does not
        // mask a match on the other.
        func run(_ provider: LyricProvider) async -> Result<RankedLyricCandidate?, Error> {
            do {
                return .success(try await provider.fetchLyrics(
                    lookupKey: lookupKey,
                    displayTitle: displayTitle,
                    displayArtist: displayArtist,
                    displayAlbum: displayAlbum
                ))
            } catch {
                return .failure(error)
            }
        }

        // Query both primary sources in parallel.
        async let r1 = run(sources[0])
        async let r2 = run(sources[1])
        let (result1, result2) = await (r1, r2)

        // Prefer a match from either source.
        if case .success(let candidate?) = result1 { return candidate }
        if case .success(let candidate?) = result2 { return candidate }

        // No match: surface the first error so it propagates as a failure
        // (and is therefore not negative-cached). If both genuinely returned
        // nil, fall through to return nil.
        if case .failure(let error) = result1 { throw error }
        if case .failure(let error) = result2 { throw error }
        return nil
    }

    /// Cancels all in-flight fetch tasks and clears the in-flight table.
    ///
    /// Called when the playback session changes so that a stale fetch for the
    /// previous track cannot write back over the current one. In-flight tasks
    /// are keyed by `LyricLookupKey` rather than session, so all pending tasks
    /// are cancelled; the anti-racing generation check in `AppState` further
    /// guarantees stale results are dropped even if a task completes just before
    /// cancellation takes effect.
    func cancelRequests(for sessionID: PlaybackSessionID) {
        for (_, task) in inFlight {
            task.cancel()
        }
        inFlight.removeAll()
    }

    /// Clears all caches. Primarily for testing.
    func clearCaches() {
        positiveCache.removeAll()
        negativeCache.removeAll()
    }

    /// Clears the persistent disk cache. Used by the clear-cache button so the
    /// user can force re-fetching lyrics from the network.
    func clearDiskCache() async {
        await diskCache.clear()
    }

    /// Clears the negative cache for a specific lookup key so a re-search
    /// can actually run instead of returning the cached "no result".
    func clearNegativeCache(for key: LyricLookupKey) {
        negativeCache.removeValue(forKey: key)
    }
}
