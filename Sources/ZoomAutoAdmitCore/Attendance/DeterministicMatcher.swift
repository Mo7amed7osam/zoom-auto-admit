import Foundation

/// A single student-to-observation pairing under consideration.
public struct MatchCandidate: Equatable {
    public let studentID: UUID
    public let observationID: UUID
    public let score: Double
    public let source: MatchSource
    public let reason: String

    public init(studentID: UUID, observationID: UUID, score: Double, source: MatchSource, reason: String) {
        self.studentID = studentID
        self.observationID = observationID
        self.score = score
        self.source = source
        self.reason = reason
    }
}

public struct MatchingOutcome: Equatable {
    /// Confident pairings, one student to one observation.
    public var accepted: [MatchCandidate]
    /// Plausible but not confident enough to record without a human.
    public var review: [MatchCandidate]
    public var unmatchedStudentIDs: [UUID]
    public var unmatchedObservationIDs: [UUID]

    public init(
        accepted: [MatchCandidate] = [],
        review: [MatchCandidate] = [],
        unmatchedStudentIDs: [UUID] = [],
        unmatchedObservationIDs: [UUID] = []
    ) {
        self.accepted = accepted
        self.review = review
        self.unmatchedStudentIDs = unmatchedStudentIDs
        self.unmatchedObservationIDs = unmatchedObservationIDs
    }
}

/// Local matching, run before any AI is considered.
///
/// Ordering is exact, then learned alias, then token overlap, then fuzzy
/// similarity. Most of a class resolves here, which keeps the AI layer for the
/// genuinely ambiguous handful — cheaper, faster, less data leaving the machine,
/// and far less room for a confident-sounding wrong answer.
public enum DeterministicMatcher {
    /// Below this, a pairing is not even worth showing to a human.
    public static let reviewFloor = 0.55
    /// Device-style names never auto-accept, however well they score.
    public static let deviceNameCeiling = 0.5

    public static func match(
        students: [Student],
        observations: [ParticipantObservation],
        autoAcceptConfidence: Double
    ) -> MatchingOutcome {
        var candidates: [MatchCandidate] = []

        for student in students {
            let officialTokens = NameNormalizer.tokens(student.officialName)
            let officialNormalized = NameNormalizer.normalize(student.officialName)
            let aliasSet = Set(student.aliases.map(NameNormalizer.normalize))

            for observation in observations {
                let observed = observation.normalizedName
                guard !observed.isEmpty else { continue }

                var best: (score: Double, source: MatchSource, reason: String)?

                if observed == officialNormalized {
                    best = (1.0, .exact, "Name matches the roster exactly")
                } else if aliasSet.contains(observed) {
                    best = (1.0, .alias, "Known alias for this student")
                } else {
                    let observedTokens = NameNormalizer.tokens(observation.rawName)
                    let token = NameSimilarity.tokenSimilarity(
                        observed: observedTokens,
                        official: officialTokens
                    )
                    let whole = max(
                        NameSimilarity.jaroWinkler(observed, officialNormalized),
                        NameSimilarity.levenshteinSimilarity(observed, officialNormalized)
                    )
                    if token >= whole {
                        best = (token, .token, tokenReason(observedTokens, officialTokens))
                    } else {
                        best = (whole, .fuzzy, "Names are similar")
                    }
                }

                guard var candidate = best else { continue }

                // A device name may well be a student, but it is not evidence —
                // unless a human already told us whose device it is. An exact
                // roster name or a learned alias outranks the heuristic.
                let isHumanConfirmed = candidate.source == .exact || candidate.source == .alias
                if !isHumanConfirmed,
                   NameNormalizer.looksLikeDeviceName(observation.rawName)
                    || NameNormalizer.isLowSignal(observation.rawName) {
                    candidate.score = min(candidate.score, deviceNameCeiling)
                    candidate.reason += "; Zoom name looks like a device"
                }

                guard candidate.score >= reviewFloor else { continue }
                candidates.append(MatchCandidate(
                    studentID: student.id,
                    observationID: observation.id,
                    score: candidate.score,
                    source: candidate.source,
                    reason: candidate.reason
                ))
            }
        }

        return assign(
            candidates: candidates,
            students: students,
            observations: observations,
            autoAcceptConfidence: autoAcceptConfidence
        )
    }

    /// Greedy one-to-one assignment, strongest pairing first.
    ///
    /// Independent yes/no scoring would happily mark two students present from
    /// one Zoom name, or claim one student joined twice under different names.
    /// Taking the strongest pairing first and then removing both sides keeps the
    /// register honest.
    private static func assign(
        candidates: [MatchCandidate],
        students: [Student],
        observations: [ParticipantObservation],
        autoAcceptConfidence: Double
    ) -> MatchingOutcome {
        let ordered = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.studentID.uuidString < $1.studentID.uuidString
        }

        var usedStudents = Set<UUID>()
        var usedObservations = Set<UUID>()
        var accepted: [MatchCandidate] = []
        var review: [MatchCandidate] = []

        for candidate in ordered {
            guard !usedStudents.contains(candidate.studentID),
                  !usedObservations.contains(candidate.observationID) else {
                continue
            }
            if candidate.score >= autoAcceptConfidence {
                accepted.append(candidate)
            } else {
                review.append(candidate)
            }
            usedStudents.insert(candidate.studentID)
            usedObservations.insert(candidate.observationID)
        }

        return MatchingOutcome(
            accepted: accepted,
            review: review,
            unmatchedStudentIDs: students.map(\.id).filter { !usedStudents.contains($0) },
            unmatchedObservationIDs: observations.map(\.id).filter { !usedObservations.contains($0) }
        )
    }

    private static func tokenReason(_ observed: [String], _ official: [String]) -> String {
        let shared = Set(observed).intersection(official)
        if shared.isEmpty { return "Name parts are similar" }
        if observed.count < official.count {
            return "Shares \(shared.count) name part(s); middle name omitted"
        }
        return "Shares \(shared.count) name part(s)"
    }
}
