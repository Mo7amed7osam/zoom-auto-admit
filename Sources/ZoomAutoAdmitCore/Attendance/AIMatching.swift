import Foundation

/// The minimal payload sent for AI matching.
///
/// Only unresolved names travel: no roster that already matched, no other
/// group's students, no schedule, no account, no logs. Students are referenced
/// by an opaque per-request identifier so the model never needs anything else
/// about them.
public struct AIMatchRequest: Equatable {
    public struct Candidate: Equatable {
        public let id: String
        public let officialName: String
    }

    public let students: [Candidate]
    public let zoomNames: [String]

    public init(students: [Candidate], zoomNames: [String]) {
        self.students = students
        self.zoomNames = zoomNames
    }

    public var isWorthSending: Bool { !students.isEmpty && !zoomNames.isEmpty }
}

/// What the model is allowed to say back.
public struct AIMatchProposal: Codable, Equatable {
    public let studentId: String
    public let zoomName: String
    public let confidence: Double
    public let reason: String?
}

public struct AIMatchResponse: Codable, Equatable {
    public let matches: [AIMatchProposal]
    public let unresolvedZoomNames: [String]?
}

public enum AIMatchError: Error, Equatable {
    case noAPIKey
    case notConfigured
    case network(String)
    case httpStatus(Int)
    case malformedResponse(String)

    public var message: String {
        switch self {
        case .noAPIKey: return "No OpenRouter API key is set."
        case .notConfigured: return "AI matching is turned off."
        case .network(let detail): return "OpenRouter could not be reached: \(detail)"
        case .httpStatus(let code): return "OpenRouter returned HTTP \(code)."
        case .malformedResponse(let detail): return "OpenRouter's reply could not be used: \(detail)"
        }
    }
}

/// Validates model output before it is allowed anywhere near the register.
///
/// Everything the model returns is untrusted. It may name a student who does
/// not exist, a Zoom name nobody used, the same person twice, or a confidence
/// outside any sane range. Each of those is discarded here rather than being
/// discovered later as a wrong attendance mark.
public enum AIMatchValidator {
    public struct ValidatedMatch: Equatable {
        public let studentID: UUID
        public let observationID: UUID
        public let zoomName: String
        public let confidence: Double
        public let reason: String?
    }

    public struct Result: Equatable {
        public let matches: [ValidatedMatch]
        /// Proposals thrown away, with the reason, for the log.
        public let rejected: [String]
    }

    public static func validate(
        _ response: AIMatchResponse,
        students: [Student],
        observations: [ParticipantObservation],
        studentIDs: [String: UUID]
    ) -> Result {
        var matches: [ValidatedMatch] = []
        var rejected: [String] = []
        var usedStudents = Set<UUID>()
        var usedObservations = Set<UUID>()

        for proposal in response.matches {
            guard let studentID = studentIDs[proposal.studentId],
                  students.contains(where: { $0.id == studentID }) else {
                rejected.append("unknown student id \(proposal.studentId)")
                continue
            }

            // The Zoom name must be one that was genuinely observed. This is
            // what stops the model inventing an attendee.
            let normalized = NameNormalizer.normalize(proposal.zoomName)
            guard let observation = observations.first(where: { $0.normalizedName == normalized })
                ?? observations.first(where: { NameNormalizer.normalize($0.rawName) == normalized }) else {
                rejected.append("zoom name not observed: \(proposal.zoomName)")
                continue
            }

            guard proposal.confidence.isFinite, proposal.confidence >= 0, proposal.confidence <= 1 else {
                rejected.append("confidence out of range for \(proposal.zoomName)")
                continue
            }

            guard !usedStudents.contains(studentID) else {
                rejected.append("duplicate student assignment for \(proposal.zoomName)")
                continue
            }
            guard !usedObservations.contains(observation.id) else {
                rejected.append("duplicate zoom name assignment: \(proposal.zoomName)")
                continue
            }

            usedStudents.insert(studentID)
            usedObservations.insert(observation.id)
            matches.append(ValidatedMatch(
                studentID: studentID,
                observationID: observation.id,
                zoomName: observation.rawName,
                confidence: proposal.confidence,
                reason: proposal.reason
            ))
        }

        return Result(matches: matches, rejected: rejected)
    }

    /// Pulls the JSON object out of a reply that may be wrapped in prose or a
    /// fenced code block, then decodes it strictly.
    public static func decode(_ text: String) throws -> AIMatchResponse {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String

        if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"), start < end {
            candidate = String(cleaned[start...end])
        } else {
            throw AIMatchError.malformedResponse("no JSON object in the reply")
        }

        do {
            return try JSONDecoder().decode(AIMatchResponse.self, from: Data(candidate.utf8))
        } catch {
            throw AIMatchError.malformedResponse("\(error)")
        }
    }
}
