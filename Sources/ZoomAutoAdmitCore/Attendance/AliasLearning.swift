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
