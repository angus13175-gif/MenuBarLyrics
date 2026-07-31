import Foundation

/// Parses LRC (synchronized lyrics) text into a `LyricDocument`.
///
/// Handles standard `[mm:ss.xx]` and `[mm:ss.xxx]` time tags, multiple time tags
/// on a single line, the global `[offset:+/-N]` directive (milliseconds), LRC
/// metadata tag lines (`[ti:]`, `[ar:]`, …), production-credit lines and
/// copyright lines. Produces a sorted, de-duplicated line list with interval
/// end times computed from the next line's start (or the supplied `duration`
/// for the final line).
enum LRCParser {
    private static let timeTagPattern = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]"#
    )
    private static let offsetPattern = try! NSRegularExpression(
        pattern: #"\[offset:\s*([+-]?\d+)\]"#
    )

    /// Production-credit line prefixes to filter out. Uses multi-character
    /// prefixes only (single-char forms like "词"/"曲" are intentionally NOT
    /// filtered to avoid dropping genuine lyric lines).
    private static let metaPrefixes: Set<String> = [
        "作词", "作曲", "编曲", "制作人", "混音", "母带", "和声", "录音",
        "封面", "企划", "制作公司", "吉他", "贝斯", "鼓手", "键盘", "弦乐",
        "人声处理", "采样", "缩混", "统筹", "监制",
        "OP", "SP", "演唱", "配唱", "后期", "乐器", "钢琴",
    ]

    /// Parses LRC text into a `LyricDocument`.
    /// - Parameters:
    ///   - lrcText: Raw LRC text.
    ///   - lookupKey: The lookup key this document satisfies.
    ///   - source: The lyric source the text came from.
    ///   - sourceRecordIdentifier: Opaque identifier for the source record.
    ///   - duration: Track duration in seconds, used as the end time of the
    ///     final line. Pass `nil` to leave the final line open-ended.
    /// - Returns: A `LyricDocument`, or `nil` if no parseable lyric lines were
    ///   found.
    static func parse(
        _ lrcText: String,
        lookupKey: LyricLookupKey,
        source: LyricSource,
        sourceRecordIdentifier: String?,
        duration: TimeInterval?
    ) -> LyricDocument? {
        // Extract global offset (milliseconds -> seconds), if present.
        var globalOffset: TimeInterval = 0
        if let match = offsetPattern.firstMatch(in: lrcText, range: NSRange(lrcText.startIndex..., in: lrcText)),
           let range = Range(match.range(at: 1), in: lrcText),
           let offsetMs = Int(lrcText[range]) {
            globalOffset = Double(offsetMs) / 1000.0
        }

        var entries: [(time: TimeInterval, text: String)] = []

        for line in lrcText.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = line.trimmingCharacters(in: .whitespaces)

            // Skip LRC metadata tag lines.
            if stripped.hasPrefix("[ti:") || stripped.hasPrefix("[ar:")
                || stripped.hasPrefix("[al:") || stripped.hasPrefix("[by:")
                || stripped.hasPrefix("[offset:") || stripped.hasPrefix("[re:")
                || stripped.hasPrefix("[ve:") {
                continue
            }

            let nsLine = stripped as NSString
            let matches = timeTagPattern.matches(in: stripped, range: NSRange(location: 0, length: nsLine.length))
            if matches.isEmpty { continue }

            // Remove all time tags from the line to obtain the lyric text.
            var text = stripped
            for match in matches.reversed() {
                let range = Range(match.range, in: text)!
                text.removeSubrange(range)
            }
            text = text.trimmingCharacters(in: .whitespaces)

            // Filter production-credit lines (only when non-empty, so empty
            // instrumental markers survive).
            if !text.isEmpty && shouldFilterMeta(text) { continue }
            // Filter copyright notices.
            if text.contains("未经著作权人") || text.contains("版权所有") { continue }

            for match in matches {
                let minutes = Int(nsLine.substring(with: match.range(at: 1))) ?? 0
                let secondsStr = nsLine.substring(with: match.range(at: 2))
                let seconds = Double(secondsStr) ?? 0
                let time = Double(minutes) * 60 + seconds + globalOffset
                if time >= 0 {
                    entries.append((time, text))
                }
            }
        }

        entries.sort { $0.time < $1.time }
        guard !entries.isEmpty else { return nil }

        // De-duplicate consecutive identical timestamps, keeping the last
        // non-empty text for each timestamp.
        var deduped: [(time: TimeInterval, text: String)] = []
        for entry in entries {
            if let lastIdx = deduped.indices.last, deduped[lastIdx].time == entry.time {
                if !entry.text.isEmpty {
                    deduped[lastIdx] = entry
                }
            } else {
                deduped.append(entry)
            }
        }

        let lines: [LyricLine] = deduped.enumerated().map { index, entry in
            let endTime: TimeInterval?
            if index + 1 < deduped.count {
                endTime = deduped[index + 1].time
            } else {
                endTime = duration
            }
            return LyricLine(startTime: entry.time, intervalEndTime: endTime, text: entry.text)
        }

        return LyricDocument(
            lookupKey: lookupKey,
            lines: lines,
            source: source,
            sourceRecordIdentifier: sourceRecordIdentifier,
            globalOffset: globalOffset
        )
    }

    private static func shouldFilterMeta(_ text: String) -> Bool {
        for prefix in metaPrefixes {
            if text.hasPrefix(prefix) { return true }
        }
        return false
    }
}
