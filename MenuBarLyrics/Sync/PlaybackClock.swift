import Foundation

/// Maps remote now-playing snapshots to a continuous local elapsed time using
/// monotonic-clock interpolation with playback-rate support.
///
/// On each snapshot, the clock records a calibrated elapsed position, the
/// continuous-clock instant at which it was received, and an effective rate
/// (0 when paused). Subsequent queries interpolate forward using the monotonic
/// clock so the reported elapsed time advances smoothly between updates.
///
/// `PlaybackClock` is `@MainActor`-isolated: it is only ever touched from
/// `AppState`, which is itself `@MainActor`. The display-link callback hops to
/// the main thread before calling `tickPlayback`, so no cross-actor access
/// occurs.
@MainActor
final class PlaybackClock {

    /// Elapsed position captured at the last update, already adjusted for any
    /// remote-timestamp skew.
    private var calibratedElapsed: TimeInterval = 0

    /// Continuous-clock instant captured at the last update; the interpolation
    /// anchor. `estimatedElapsed(now:)` measures `anchor -> now` from here.
    private var anchorContinuous: ContinuousClock.Instant = .now

    /// The rate actually applied during interpolation: the validated playback
    /// rate when playing, or 0 when paused.
    private var effectiveRate: Double = 0

    /// Track duration used to clamp the reported elapsed time.
    private var duration: TimeInterval? = nil

    /// Whether playback is active at the last update.
    private(set) var isPlaying: Bool = false

    /// Whether `update` has been called at least once. The first update always
    /// hard-anchors regardless of deviation (there is no prior prediction to
    /// compare against).
    private var hasUpdated: Bool = false

    /// Threshold below which a snapshot's deviation from the clock's prediction
    /// is treated as ordinary drift (smoothed) rather than a seek (hard
    /// re-anchor).
    private let seekThreshold: TimeInterval = 0.35

    /// Deviations at or below this value are considered negligible and
    /// hard-anchored without smoothing. This prevents tiny persistent drift
    /// from accumulating into visible lag.
    private let negligibleDriftThreshold: TimeInterval = 0.10

    /// Updates the clock from a fresh now-playing snapshot.
    ///
    /// - effectiveRate = playing ? validatedRate : 0
    ///   validatedRate clamps the reported rate to [0.25, 4.0]; values that are
    ///   NaN, non-finite, out of range, or non-positive fall back to 1.0.
    /// - If a remote timestamp is present and its age at receipt is in [0, 60]s,
    ///   the elapsed position is advanced by that age scaled by the effective
    ///   rate to compensate for transport latency.
    /// - Otherwise the snapshot's reported elapsed time is used as-is.
    /// - Seek detection: the snapshot's elapsed is compared against the value the
    ///   clock predicted for the snapshot's receipt time. A deviation at or below
    ///   `seekThreshold` is smoothed (blend 80% old / 20% new) to avoid jitter;
    ///   a larger deviation hard re-anchors (a seek was detected). The first
    ///   update always hard-anchors.
    func update(snapshot: NowPlayingSnapshot) {
        let rawRate = snapshot.playbackRate ?? (snapshot.isPlaying ? 1.0 : 0)
        let validatedRate: Double
        if rawRate.isFinite && rawRate >= 0.25 && rawRate <= 4.0 {
            validatedRate = rawRate
        } else {
            validatedRate = 1.0
        }

        let snapshotElapsed = snapshot.elapsedTime ?? 0

        // Predict where the clock *would* be at the snapshot's receipt time,
        // based on the previous anchor. Used to detect seeks vs. drift.
        let predictedElapsed: TimeInterval
        if hasUpdated && isPlaying {
            let delta = anchorContinuous.duration(to: snapshot.receivedAtContinuous)
            let deltaSeconds = Double(delta.components.seconds)
                + Double(delta.components.attoseconds) / 1e18
            predictedElapsed = calibratedElapsed + deltaSeconds * effectiveRate
        } else {
            predictedElapsed = calibratedElapsed
        }

        let deviation = abs(predictedElapsed - snapshotElapsed)

        // The new effective rate applies to the timestamp-based calibration
        // below and becomes the interpolation rate for subsequent queries.
        let newEffectiveRate = snapshot.isPlaying ? validatedRate : 0

        // Compute the calibrated elapsed position for this snapshot.
        let baseCalibrated: TimeInterval
        if let remoteTs = snapshot.remoteTimestamp {
            let wallNow = Date()
            let ageAtReceipt = wallNow.timeIntervalSince(remoteTs)
            if ageAtReceipt >= 0 && ageAtReceipt <= 60 {
                baseCalibrated = snapshotElapsed + ageAtReceipt * newEffectiveRate
            } else {
                baseCalibrated = snapshotElapsed
            }
        } else {
            baseCalibrated = snapshotElapsed
        }

        // Apply smoothing for small drift; hard re-anchor for seeks, first
        // update, or negligible drift.
        //
        // - deviation <= negligibleDriftThreshold (0.10s): hard anchor. The
        //   difference is too small to justify smoothing, which would
        //   introduce its own lag. Just adopt the new value.
        // - negligible < deviation <= seekThreshold (0.10-0.35s): 50/50 blend
        //   between the PREDICTED value (where the clock thinks it is) and
        //   the snapshot value. Blending the old calibratedElapsed directly
        //   would ignore the time elapsed since the last anchor, causing
        //   cumulative lag. The old 80/20 blend had this exact bug.
        // - deviation > seekThreshold: hard anchor (seek detected).
        if !hasUpdated || deviation <= negligibleDriftThreshold || deviation > seekThreshold {
            calibratedElapsed = baseCalibrated
        } else {
            calibratedElapsed = predictedElapsed * 0.5 + baseCalibrated * 0.5
        }

        effectiveRate = newEffectiveRate
        isPlaying = snapshot.isPlaying
        duration = snapshot.duration
        anchorContinuous = snapshot.receivedAtContinuous
        hasUpdated = true
    }

    /// Estimates the current elapsed time at `now` by interpolating from the
    /// anchor using the effective rate, then clamping to [0, duration].
    ///
    /// When paused, the calibrated elapsed position is returned unchanged.
    func estimatedElapsed(now: ContinuousClock.Instant) -> TimeInterval {
        let elapsed: TimeInterval
        if isPlaying {
            // `anchor.duration(to: now)` is positive when `now` is after the
            // anchor (the direction we want for forward playback).
            let delta = anchorContinuous.duration(to: now)
            let deltaSeconds = Double(delta.components.seconds)
                + Double(delta.components.attoseconds) / 1e18
            elapsed = calibratedElapsed + deltaSeconds * effectiveRate
        } else {
            elapsed = calibratedElapsed
        }

        if elapsed < 0 { return 0 }
        if let dur = duration, elapsed > dur { return dur }
        return elapsed
    }
}
