import Foundation

final class JSONLFramer {
    private let maxLineSize: Int
    private var buffer = Data()

    init(maxLineSize: Int = 1 * 1024 * 1024) {
        self.maxLineSize = maxLineSize
    }

    func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: 0..<newlineIndex)
            buffer.removeSubrange(0...newlineIndex)

            if lineData.isEmpty {
                continue
            }
            if lineData.count > maxLineSize {
                continue
            }
            lines.append(lineData)
        }

        // Prevent unbounded buffer growth: if no newline has been found and the
        // buffered remainder already exceeds the line limit, discard it. This
        // guards against a runaway sender that never terminates a line.
        if buffer.count > maxLineSize {
            buffer.removeAll()
        }

        return lines
    }

    func flush() -> Data? {
        guard !buffer.isEmpty, buffer.count <= maxLineSize else {
            buffer.removeAll()
            return nil
        }
        let remaining = buffer
        buffer.removeAll()
        return remaining
    }
}
