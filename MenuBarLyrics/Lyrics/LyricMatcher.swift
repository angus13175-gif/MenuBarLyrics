import Foundation

/// Normalizes lyric metadata and scores how well a candidate track matches a
/// `LyricLookupKey`.
///
/// Scoring (title match is required; absent title or title mismatch returns
/// `nil`):
/// - artist normalized equal: +35
/// - artist one contains the other: +20
/// - album normalized equal: +20
/// - album explicitly different (both present, not equal): -15
/// - duration diff <= 2s: +30
/// - duration diff > 2s and <= 5s: +10
/// - duration diff > 5s: -25
/// - version tag conflict (present in one side's text but not the other): -50
///
/// A candidate is accepted when its score meets `acceptThreshold` (60).
enum LyricMatcher {
    /// Minimum score for a candidate to be accepted as a lyric match.
    static let acceptThreshold = 60

    /// Version/descriptor words whose presence must agree between candidate
    /// and lookup to avoid a heavy penalty.
    private static let versionWords: Set<String> = [
        "live", "remaster", "acoustic", "instrumental", "remix",
        "demo", "session", "version", "edit", "karaoke",
    ]

    /// Normalizes a string for matching: NFKC compatibility decomposition,
    /// lowercasing, whitespace collapsing and trimming.
    static func normalize(_ input: String) -> String {
        let nfkc = input.precomposedStringWithCompatibilityMapping
        let lower = nfkc.lowercased()
        let collapsed = lower.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// Scores a candidate track against a lookup key.
    /// - Returns: The score, or `nil` if the candidate has no title or its
    ///   normalized title does not equal the lookup's normalized title (a
    ///   required precondition).
    static func scoreCandidate(
        candidateTitle: String?,
        candidateArtist: String?,
        candidateAlbum: String?,
        candidateDuration: Double?,
        lookupKey: LyricLookupKey
    ) -> Int? {
        guard let candidateTitle else { return nil }
        let normCandidateTitle = normalize(candidateTitle)
        guard normCandidateTitle == lookupKey.normalizedTitle else { return nil }

        var score = 0

        // Artist scoring.
        let normCandidateArtist = candidateArtist.map { normalize($0) }
        if let lookupArtist = lookupKey.normalizedArtist, let normCandidate = normCandidateArtist {
            if normCandidate == lookupArtist {
                score += 35
            } else if normCandidate.contains(lookupArtist) || lookupArtist.contains(normCandidate) {
                score += 20
            }
        }

        // Album scoring.
        let normCandidateAlbum = candidateAlbum.map { normalize($0) }
        if let lookupAlbum = lookupKey.normalizedAlbum {
            if let normCandidate = normCandidateAlbum {
                if normCandidate == lookupAlbum {
                    score += 20
                } else {
                    score -= 15
                }
            }
        }

        // Duration scoring.
        if let lookupDur = lookupKey.roundedDuration, let candidateDur = candidateDuration {
            let diff = abs(candidateDur - Double(lookupDur))
            if diff <= 2 { score += 30 }
            else if diff <= 5 { score += 10 }
            else { score -= 25 }
        }

        // Version-tag conflict: a descriptor present on one side but not the
        // other is a strong negative signal. Compare on whole word tokens so
        // that e.g. "live" does not spuriously match "alive" or "delivery".
        let candidateText = [normCandidateTitle, normCandidateArtist ?? "", normCandidateAlbum ?? ""]
            .joined(separator: " ")
        let lookupText = [lookupKey.normalizedTitle, lookupKey.normalizedArtist ?? "", lookupKey.normalizedAlbum ?? ""]
            .joined(separator: " ")
        let candidateWords = Set(candidateText.split(separator: " ").map(String.init))
        let lookupWords = Set(lookupText.split(separator: " ").map(String.init))
        for word in versionWords {
            let candidateHas = candidateWords.contains(word)
            let lookupHas = lookupWords.contains(word)
            if candidateHas != lookupHas {
                score -= 50
                break
            }
        }

        return score
    }
}
