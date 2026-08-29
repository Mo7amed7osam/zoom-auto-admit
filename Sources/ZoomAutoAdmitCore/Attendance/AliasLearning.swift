import Foundation

/// Turns a manual correction into knowledge, so the same nickname resolves by
/// itself next week without any AI call.
///
/// Aliases live on the student inside their group, which is what keeps them
/// group-scoped: "Mohamed's iPhone" in Group A says nothing about anyone in
/// Group B, where a different Mohamed may well use the same phone name.
public enum AliasLearning {
    /// Records an observed Zoom name as an alias of a student.
    ///
    /// Refuses aliases that would be actively harmful: blanks, names already
    /// belonging to a different student on the same roster, and names identical
    /// to another student's official name.
    public static func learn(
        alias rawAlias: String,
        forStudent studentID: UUID,
        in group: StudentGroup
    ) -> Result<StudentGroup, AliasLearningError> {
        let alias = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = NameNormalizer.normalize(alias)

        guard !normalized.isEmpty else { return .failure(.emptyAlias) }
        guard let index = group.students.firstIndex(where: { $0.id == studentID }) else {
            return .failure(.unknownStudent)
        }

        // An alias that is somebody else's official name would quietly move
        // attendance from one student to another.
        if let clash = group.students.first(where: {
            $0.id != studentID && $0.normalizedOfficialName == normalized
        }) {
            return .failure(.conflictsWithStudent(clash.officialName))
        }

        if let clash = group.students.first(where: { student in
            student.id != studentID
                && student.aliases.contains { NameNormalizer.normalize($0) == normalized }
        }) {
            return .failure(.conflictsWithStudent(clash.officialName))
        }

        var updated = group
        let alreadyKnown = updated.students[index].aliases
            .contains { NameNormalizer.normalize($0) == normalized }
        if !alreadyKnown, updated.students[index].normalizedOfficialName != normalized {
            updated.students[index].aliases.append(alias)
        }
        return .success(updated)
    }

    /// Every confirmed pairing in a session, recorded as an alias.
    ///
    /// A match that had to be worked out once should never have to be worked
    /// out again: without this, the same nickname is sent to the AI every week
    /// and costs a review every week. Only settled records qualify — a pairing
    /// still sitting in Needs Review is a question, not knowledge, and teaching
    /// the roster from it would make a guess permanent.
    public static func learnConfirmedMatches(
        in session: AttendanceSession,
        group: StudentGroup
    ) -> ConfirmedLearningOutcome {
        var updated = group
        var learned: [LearnedAlias] = []
        var skipped: [String] = []

        for record in session.records where record.status == .present {
            guard let zoomName = record.matchedZoomName else { continue }

            switch learn(alias: zoomName, forStudent: record.studentID, in: updated) {
            case .success(let group):
                // `learn` is a no-op for an alias already known or identical to
                // the official name, so only a real addition is reported.
                let before = updated.students.first { $0.id == record.studentID }?.aliases.count ?? 0
                let after = group.students.first { $0.id == record.studentID }?.aliases.count ?? 0
                updated = group
                if after > before {
                    learned.append(LearnedAlias(
                        studentID: record.studentID,
                        studentName: record.studentName,
                        alias: zoomName
                    ))
                }
            case .failure(let error):
                skipped.append("\(zoomName) → \(record.studentName): \(error.message)")
            }
        }

        return ConfirmedLearningOutcome(group: updated, learned: learned, skipped: skipped)
    }

    public static func forget(
        alias rawAlias: String,
        forStudent studentID: UUID,
        in group: StudentGroup
    ) -> StudentGroup {
        let normalized = NameNormalizer.normalize(rawAlias)
        var updated = group
        guard let index = updated.students.firstIndex(where: { $0.id == studentID }) else { return group }
        updated.students[index].aliases.removeAll { NameNormalizer.normalize($0) == normalized }
        return updated
    }
}

/// One newly recorded alias, for the report shown after learning.
public struct LearnedAlias: Equatable {
    public let studentID: UUID
    public let studentName: String
    public let alias: String

    public init(studentID: UUID, studentName: String, alias: String) {
        self.studentID = studentID
        self.studentName = studentName
        self.alias = alias
    }
}

/// What a batch of learning changed, and what it refused.
public struct ConfirmedLearningOutcome: Equatable {
    public let group: StudentGroup
    public let learned: [LearnedAlias]
    /// Aliases refused by the safety rules, with the reason.
    public let skipped: [String]

    public init(group: StudentGroup, learned: [LearnedAlias], skipped: [String]) {
        self.group = group
        self.learned = learned
        self.skipped = skipped
    }

    public var didChangeGroup: Bool { !learned.isEmpty }
}

public enum AliasLearningError: Error, Equatable {
    case emptyAlias
    case unknownStudent
    case conflictsWithStudent(String)

    public var message: String {
        switch self {
        case .emptyAlias:
            return "That Zoom name is empty."
        case .unknownStudent:
            return "That student is not on this group's roster."
        case .conflictsWithStudent(let name):
            return "That name already belongs to \(name)."
        }
    }
}
