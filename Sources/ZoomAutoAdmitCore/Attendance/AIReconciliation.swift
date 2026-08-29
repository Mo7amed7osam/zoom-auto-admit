import Foundation

/// Applies AI proposals on top of a locally reconciled register.
///
/// The AI layer only ever sees what local matching could not settle, and only
/// ever *proposes*. Everything it returns is validated first, and a proposal
/// below the group's threshold becomes Needs Review rather than Present — a
/// false Needs Review costs a glance, a false Present costs a wrong register.
public enum AIReconciliation {
    public struct Summary: Equatable {
        public let session: AttendanceSession
        public let appliedCount: Int
        public let reviewCount: Int
        public let rejected: [String]
        public let failure: AIMatchError?

        public var aiWasUnavailable: Bool { failure != nil }
    }

    /// Builds the request from a locally reconciled session.
    ///
    /// Only students with no decision yet and Zoom names nobody claimed are
    /// included; anything already resolved stays local and costs nothing.
    public static func request(for session: AttendanceSession) -> (request: AIMatchRequest, ids: [String: UUID]) {
        let unresolvedStatuses: Set<AttendanceStatus> = [.notSeenYet, .absent, .needsReview]
        let unresolved = session.records
            .filter { !$0.isManual && unresolvedStatuses.contains($0.status) }
            .compactMap { record in session.rosterSnapshot.first { $0.id == record.studentID } }

        let claimed = Set(
            session.records
                .filter { $0.status == .present }
                .compactMap(\.matchedObservationID)
        )
        let freeNames = session.observations
            .filter { !claimed.contains($0.id) }
            .map(\.rawName)

        var ids: [String: UUID] = [:]
        var candidates: [AIMatchRequest.Candidate] = []
        for (index, student) in unresolved.enumerated() {
            // Opaque per-request ids: the model never receives a real UUID and
            // cannot reference anything outside this request.
            let key = "s\(index)"
            ids[key] = student.id
            candidates.append(.init(id: key, officialName: student.officialName))
        }

        return (AIMatchRequest(students: candidates, zoomNames: freeNames), ids)
    }

    /// Folds validated proposals into the session.
    public static func apply(
        _ response: AIMatchResponse,
        to session: AttendanceSession,
        ids: [String: UUID],
        autoAcceptConfidence: Double
    ) -> Summary {
        let validated = AIMatchValidator.validate(
            response,
            students: session.rosterSnapshot,
            observations: session.observations,
            studentIDs: ids
        )

        var updated = session
        var applied = 0
        var review = 0

        for match in validated.matches {
            guard let index = updated.records.firstIndex(where: { $0.studentID == match.studentID }) else {
                continue
            }
            // A human decision is never overwritten by the model.
            guard !updated.records[index].isManual else { continue }
            // Nor is a student the local matcher already settled confidently.
            guard updated.records[index].status != .present
                || updated.records[index].matchSource == .ai else { continue }

            let confident = match.confidence >= autoAcceptConfidence
            updated.records[index].status = confident ? .present : .needsReview
            updated.records[index].matchedObservationID = match.observationID
            updated.records[index].matchedZoomName = match.zoomName
            updated.records[index].matchSource = .ai
            updated.records[index].confidence = match.confidence
            updated.records[index].reason = match.reason

            if confident { applied += 1 } else { review += 1 }
        }

        let claimed = Set(
            updated.records
                .filter { $0.status == .present }
                .compactMap(\.matchedObservationID)
        )
        updated.unmatchedZoomNames = updated.observations
            .filter { !claimed.contains($0.id) }
            .map(\.rawName)

        return Summary(
            session: updated,
            appliedCount: applied,
            reviewCount: review,
            rejected: validated.rejected,
            failure: nil
        )
    }

    /// Result when AI could not be reached: local results stand untouched.
    public static func unavailable(_ error: AIMatchError, session: AttendanceSession) -> Summary {
        Summary(session: session, appliedCount: 0, reviewCount: 0, rejected: [], failure: error)
    }
}
