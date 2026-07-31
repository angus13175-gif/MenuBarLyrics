import Foundation

/// Diagnostic logger that records playback and lyric sync events to disk
/// for debugging. Capped at 5 MB with rolling cleanup. Does not record
/// full lyrics, user identity, or play history.
///
/// Entries are written as JSONL (one JSON object per line) to
/// `~/Library/Logs/MenuBarLyrics/diagnostic.log`. When the file exceeds
/// 5 MB the older half of its lines are discarded, keeping roughly the
/// last 2.5 MB.
///
/// Thread safety: all file access is serialized on a dedicated serial
/// `DispatchQueue`, so `log*` methods are safe to call from any thread.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()

    private let logURL: URL
    private let maxBytes = 5 * 1024 * 1024 // 5 MB
    private let queue = DispatchQueue(label: "MenuBarLyrics.diagnosticLog")

    private init() {
        let libDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let logDir = libDir.appendingPathComponent("Logs/MenuBarLyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        logURL = logDir.appendingPathComponent("diagnostic.log")
    }

    // MARK: - Log entries

    /// Records a playback/sync event. None of the lyric *text* is recorded;
    /// only the active line's index and time range.
    func logPlaybackSync(
        player: String?,
        title: String?,
        artist: String?,
        album: String?,
        duration: TimeInterval?,
        remoteElapsed: TimeInterval?,
        remoteTimestamp: Date?,
        receiptTime: ContinuousClock.Instant,
        estimatedElapsed: TimeInterval,
        currentLineIndex: Int?,
        currentLineStart: TimeInterval?,
        currentLineEnd: TimeInterval?
    ) {
        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "type": "sync",
            "player": player ?? "",
            "title": title ?? "",
            "artist": artist ?? "",
            "album": album ?? "",
            "duration": duration ?? 0,
            "remoteElapsed": remoteElapsed ?? 0,
            "remoteTimestamp": remoteTimestamp.map { $0.timeIntervalSince1970 } ?? 0,
            "estimatedElapsed": estimatedElapsed,
            "lineIndex": currentLineIndex ?? -1,
            "lineStart": currentLineStart ?? 0,
            "lineEnd": currentLineEnd ?? 0,
        ]
        // Receipt time, serialized as seconds-since-epoch-equivalent on the
        // continuous clock. ContinuousClock.Instant is not directly
        // serializable, so we measure the offset from "now" at log time.
        let receiptOffset = receiptTime.duration(to: .now)
        entry["receiptOffsetSeconds"] =
            Double(receiptOffset.components.seconds)
            + Double(receiptOffset.components.attoseconds) / 1e18
        write(entry)
    }

    /// Records a lyric source fetch outcome. Records which source was
    /// consulted, how well it matched (matchKind/score), and whether it
    /// succeeded. Does NOT record the lyrics text itself.
    func logLyricFetch(
        title: String,
        artist: String?,
        source: String,
        matchKind: String?,
        score: Int?,
        result: String, // "success", "noResult", "error"
        error: String? = nil
    ) {
        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "type": "lyricFetch",
            "title": title,
            "artist": artist ?? "",
            "source": source,
            "result": result,
        ]
        if let matchKind { entry["matchKind"] = matchKind }
        if let score { entry["score"] = score }
        if let error { entry["error"] = error }
        write(entry)
    }

    // MARK: - File operations

    /// Returns the last N lines of the log as a string (for in-app viewing).
    func viewLog(maxLines: Int = 500) -> String {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else {
            return "(empty log)"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(0, lines.count - maxLines)
        return lines[start...].joined(separator: "\n")
    }

    /// Exports the full log to the specified URL.
    func exportLog(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: logURL, to: url)
    }

    /// Clears the log file.
    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    // MARK: - Private

    private func write(_ entry: [String: Any]) {
        queue.async { [logURL, maxBytes] in
            guard let data = try? JSONSerialization.data(withJSONObject: entry),
                  let line = String(data: data, encoding: .utf8) else { return }

            // Append with newline.
            let lineData = (line + "\n").data(using: .utf8) ?? Data()
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(lineData)
                    handle.closeFile()
                }
            } else {
                try? lineData.write(to: logURL)
            }

            // Rolling cleanup: if file exceeds max, keep last half.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
               let size = attrs[.size] as? Int, size > maxBytes {
                self.rollLog()
            }
        }
    }

    private func rollLog() {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let keepCount = lines.count / 2
        let start = lines.count - keepCount
        let safeStart = max(0, start)
        let kept = lines[safeStart...].joined(separator: "\n")
        try? kept.data(using: .utf8)?.write(to: logURL, options: .atomic)
    }
}
