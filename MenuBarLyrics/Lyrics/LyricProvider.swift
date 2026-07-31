import Foundation

/// Protocol abstraction for lyric sources, enabling independent extension.
protocol LyricProvider: Sendable {
    var source: LyricSource { get }
    func fetchLyrics(
        lookupKey: LyricLookupKey,
        displayTitle: String,
        displayArtist: String?,
        displayAlbum: String?
    ) async throws -> RankedLyricCandidate?
}
