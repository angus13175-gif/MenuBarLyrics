import Foundation

/// Pure state mapper that converts an elapsed time plus a lyric document into a
/// `LyricRenderState`. It performs no scroll-offset computation and holds no
/// mutable state; the caller threads elapsed time through it each render.
struct LyricSyncEngine {

    /// Computes the render state for the given playback position.
    ///
    /// - When lyrics are absent or empty, returns `.noLyrics` with no line.
    /// - When elapsed precedes the first lyric line, returns `.loadingLyrics`
    ///   with `lineIndex` nil (lyrics are present but playback has not reached
    ///   them yet).
    /// - Otherwise binary-searches for the largest line whose `startTime` is
    ///   `<= elapsed`, computes clamped line progress over the line's interval,
    ///   and derives the phase from the line text and playing flag.
    func computeState(
        elapsed: TimeInterval,
        playing: Bool,
        lyrics: LyricDocument?,
        sessionID: PlaybackSessionID?,
        duration: TimeInterval?
    ) -> LyricRenderState {

        guard let lyrics, !lyrics.lines.isEmpty else {
            return LyricRenderState(
                sessionID: sessionID,
                lineIndex: nil,
                lineProgress: 0,
                phase: .noLyrics,
                estimatedElapsed: elapsed,
                duration: duration
            )
        }

        let lines = lyrics.lines

        // Before the first line: lyrics exist but playback hasn't reached them.
        if elapsed < lines[0].startTime {
            return LyricRenderState(
                sessionID: sessionID,
                lineIndex: nil,
                lineProgress: 0,
                phase: .loadingLyrics,
                estimatedElapsed: elapsed,
                duration: duration
            )
        }

        let lineIndex = findCurrentLine(in: lines, elapsed: elapsed)
        let line = lines[lineIndex]
        let isInstrumental = line.text.isEmpty

        // End time for the current line: explicit interval end, otherwise the
        // next line's start, otherwise the track duration.
        let endTime: TimeInterval? = line.intervalEndTime
            ?? (lineIndex + 1 < lines.count ? lines[lineIndex + 1].startTime : nil)
            ?? duration

        let progress: Double
        if let endTime {
            let span = endTime - line.startTime
            progress = span > 0
                ? min(1.0, max(0.0, (elapsed - line.startTime) / span))
                : 1.0
        } else {
            progress = 1.0
        }

        let phase: PlaybackPhase
        if isInstrumental {
            phase = .explicitInstrumental
        } else if playing {
            phase = .playing
        } else {
            phase = .paused
        }

        return LyricRenderState(
            sessionID: sessionID,
            lineIndex: lineIndex,
            lineProgress: progress,
            phase: phase,
            estimatedElapsed: elapsed,
            duration: duration
        )
    }

    /// Binary search for the largest index whose `startTime <= elapsed`.
    /// Caller guarantees `lines` is non-empty and `elapsed >= lines[0].startTime`.
    private func findCurrentLine(in lines: [LyricLine], elapsed: TimeInterval) -> Int {
        var lo = 0
        var hi = lines.count - 1
        var result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].startTime <= elapsed {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return result
    }
}
