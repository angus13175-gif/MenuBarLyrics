import Foundation
import CryptoKit

/// Persistent disk-based LRU cache for lyric documents.
///
/// Stores each cached lyric as an individual JSON file inside
/// `~/Library/Caches/MenuBarLyrics/lyrics/`. Filenames are derived from a
/// stable SHA-256 hash of the `LyricLookupKey` so entries survive across app
/// launches (the standard library's `Hasher` uses a per-process random seed
/// and is therefore unsuitable for persistent keys).
///
/// Eviction is least-recently-used: the cache is bounded by both a maximum
/// entry count (2000) and a maximum total size (20 MB), and the
/// least-recently-accessed files are deleted first when a bound is exceeded.
/// Access recency is tracked via the file's modification date, which is
/// "touched" on every read and write.
actor LyricDiskCache {
    private let cacheURL: URL
    private let maxEntries = 2000
    private let maxBytes = 20 * 1024 * 1024 // 20 MB

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            cacheURL = directoryURL
        } else {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            cacheURL = cachesDir.appendingPathComponent("MenuBarLyrics/lyrics", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    }

    /// Returns the cached candidate for `key`, if present, and touches the
    /// file's modification date so it is treated as recently used for LRU.
    func get(_ key: LyricLookupKey) -> RankedLyricCandidate? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(DiskCacheEntry.self, from: data) else {
            return nil
        }
        // Update access time for LRU (touch the file).
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return entry.candidate
    }

    /// Stores `candidate` under `key`, then evicts oldest entries if the cache
    /// has exceeded its size or count bounds.
    func set(_ key: LyricLookupKey, candidate: RankedLyricCandidate) {
        let entry = DiskCacheEntry(candidate: candidate, cachedAt: Date())
        guard let data = try? JSONEncoder().encode(entry) else { return }
        let url = fileURL(for: key)
        try? data.write(to: url, options: .atomic)
        evictIfNeeded()
    }

    /// Removes every cached file (the directory is recreated so subsequent
    /// writes succeed).
    func clear() {
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    }

    /// Total bytes consumed by all cache files.
    var totalSize: Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheURL,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Number of files currently in the cache.
    var entryCount: Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheURL,
            includingPropertiesForKeys: nil
        ) else { return 0 }
        return files.count
    }

    /// Derives a stable on-disk filename for `key` by hashing its components
    /// with SHA-256. The digest is hex-encoded and truncated to 32 characters
    /// (128 bits), which is more than sufficient to avoid collisions for the
    /// cache's expected cardinality while keeping filenames short.
    private func fileURL(for key: LyricLookupKey) -> URL {
        var digest = SHA256()
        digest.update(data: Data(key.normalizedTitle.utf8))
        if let artist = key.normalizedArtist {
            digest.update(data: Data("\u{0}".utf8))
            digest.update(data: Data(artist.utf8))
        }
        if let album = key.normalizedAlbum {
            digest.update(data: Data("\u{0}".utf8))
            digest.update(data: Data(album.utf8))
        }
        if let duration = key.roundedDuration {
            digest.update(data: Data("\u{0}".utf8))
            digest.update(data: Data(String(duration).utf8))
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let truncated = String(hash.prefix(32))
        return cacheURL.appendingPathComponent("\(truncated).json")
    }

    /// Deletes least-recently-used files until both the entry-count and
    /// total-size bounds are satisfied. Recency is the file modification date.
    private func evictIfNeeded() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        let totalSize = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

        if files.count <= maxEntries && totalSize <= maxBytes { return }

        // Sort by modification date (oldest first) and delete until under limits.
        let sorted = files.sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return d1 < d2
        }

        var currentSize = totalSize
        var currentCount = files.count

        for file in sorted {
            if currentCount <= maxEntries && currentSize <= maxBytes { break }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: file)
            currentSize -= size
            currentCount -= 1
        }
    }
}

/// On-disk representation of a single cached lyric. `cachedAt` is retained for
/// debugging/introspection; LRU recency is driven by the file modification
/// date so it survives even when the entry is rewritten.
private struct DiskCacheEntry: Codable {
    let candidate: RankedLyricCandidate
    let cachedAt: Date
}
