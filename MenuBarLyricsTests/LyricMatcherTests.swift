import XCTest
@testable import MenuBarLyrics

final class LyricMatcherTests: XCTestCase {

    // MARK: - Helpers

    private func makeLookupKey(
        title: String = "song",
        artist: String? = "artist",
        album: String? = nil,
        duration: Int? = nil
    ) -> LyricLookupKey {
        LyricLookupKey(
            normalizedTitle: title,
            normalizedArtist: artist,
            normalizedAlbum: album,
            roundedDuration: duration
        )
    }

    // MARK: - normalize tests

    /// "Ｆｕｌｌｗｉｄｔｈ" (fullwidth) -> NFKC + lowercase -> "fullwidth".
    func testNormalizeNFKC() {
        let result = LyricMatcher.normalize("Ｆｕｌｌｗｉｄｔｈ")
        XCTAssertEqual(result, "fullwidth")
    }

    /// "  Hello   World  " -> collapse whitespace, lowercase, trim -> "hello world".
    func testNormalizeLowercaseAndWhitespace() {
        let result = LyricMatcher.normalize("  Hello   World  ")
        XCTAssertEqual(result, "hello world")
    }

    /// "：！？" (fullwidth punctuation) -> ":!?".
    func testNormalizeFullWidthPunctuation() {
        let result = LyricMatcher.normalize("：！？")
        XCTAssertEqual(result, ":!?")
    }

    // MARK: - scoreCandidate tests

    /// All fields match: title(+required), artist equal +35, album equal +20,
    /// duration within 2s +30 = 85 -> >= 60.
    func testScoreExactMatchAllFields() throws {
        let lookup = makeLookupKey(
            title: "song", artist: "artist", album: "album", duration: 200
        )
        let score = LyricMatcher.scoreCandidate(
            candidateTitle: "song",
            candidateArtist: "artist",
            candidateAlbum: "album",
            candidateDuration: 200,
            lookupKey: lookup
        )
        XCTAssertEqual(score, 85)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(score), LyricMatcher.acceptThreshold)
    }

    /// Different title -> nil (title match is required).
    func testScoreRejectsTitleMismatch() {
        let lookup = makeLookupKey(title: "song", artist: "artist", duration: 200)
        let score = LyricMatcher.scoreCandidate(
            candidateTitle: "completely different",
            candidateArtist: "artist",
            candidateAlbum: nil,
            candidateDuration: 200,
            lookupKey: lookup
        )
        XCTAssertNil(score)
    }

    /// "artist live version" vs "artist": title equal, artist contains +20,
    /// duration within 2s +30, version conflict -50 = 0 -> < 60.
    func testScoreVersionConflictHeavyPenalty() throws {
        let lookup = makeLookupKey(title: "song", artist: "artist", duration: 200)
        let score = LyricMatcher.scoreCandidate(
            candidateTitle: "song",
            candidateArtist: "artist live version",
            candidateAlbum: nil,
            candidateDuration: 200,
            lookupKey: lookup
        )
        XCTAssertEqual(score, 0)
        XCTAssertLessThan(try XCTUnwrap(score), LyricMatcher.acceptThreshold)
    }

    /// Duration diff exactly 2s: title + artist equal +35, duration +30 = 65 -> >= 60.
    func testScoreDurationWithin2Seconds() throws {
        let lookup = makeLookupKey(title: "song", artist: "artist", duration: 200)
        let score = LyricMatcher.scoreCandidate(
            candidateTitle: "song",
            candidateArtist: "artist",
            candidateAlbum: nil,
            candidateDuration: 202,
            lookupKey: lookup
        )
        XCTAssertEqual(score, 65)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(score), LyricMatcher.acceptThreshold)
    }

    /// Duration diff 10s: title + artist equal +35, duration -25 = 10 -> < 60.
    func testScoreDurationOver5SecondsPenalty() throws {
        let lookup = makeLookupKey(title: "song", artist: "artist", duration: 200)
        let score = LyricMatcher.scoreCandidate(
            candidateTitle: "song",
            candidateArtist: "artist",
            candidateAlbum: nil,
            candidateDuration: 210,
            lookupKey: lookup
        )
        XCTAssertEqual(score, 10)
        XCTAssertLessThan(try XCTUnwrap(score), LyricMatcher.acceptThreshold)
    }
}
