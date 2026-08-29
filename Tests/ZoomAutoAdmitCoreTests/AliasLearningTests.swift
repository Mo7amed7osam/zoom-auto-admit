import Foundation
import XCTest
@testable import ZoomAutoAdmitCore

final class AliasLearningTests: XCTestCase {
    private func groupA() -> StudentGroup {
        StudentGroup(name: "Group A", students: [
            Student(officialName: "Mohamed Ahmed Hassan"),
            Student(officialName: "Sara Mostafa Ali")
        ])
    }

    func testLearnedAliasResolvesWithoutAINextTime() throws {
        var group = groupA()
        let student = group.students[0]

        group = try AliasLearning.learn(alias: "Mohamed's iPhone", forStudent: student.id, in: group).get()
        XCTAssertEqual(group.students[0].aliases, ["Mohamed's iPhone"])

        // The deterministic matcher now resolves it with no AI involved.
        let observation = ParticipantObservation(
            rawName: "Mohamed's iPhone",
            normalizedName: NameNormalizer.normalize("Mohamed's iPhone"),
            observedAt: [Date()]
        )
        let outcome = DeterministicMatcher.match(
            students: group.students,
            observations: [observation],
            autoAcceptConfidence: 0.9
        )
        XCTAssertEqual(outcome.accepted.count, 1)
        XCTAssertEqual(outcome.accepted[0].source, .alias)
        XCTAssertEqual(outcome.accepted[0].studentID, student.id)
    }

    func testLearningIsIdempotent() throws {
        var group = groupA()
        let id = group.students[0].id
        group = try AliasLearning.learn(alias: "Mohamed's iPhone", forStudent: id, in: group).get()
        group = try AliasLearning.learn(alias: "mohamed's   iPhone", forStudent: id, in: group).get()

        XCTAssertEqual(group.students[0].aliases.count, 1, "the same alias is not stored twice")
    }

    /// An alias that is another student's name would silently move attendance.
    func testAliasCannotStealAnotherStudentsName() {
        let group = groupA()
        let result = AliasLearning.learn(
            alias: "Sara Mostafa Ali",
            forStudent: group.students[0].id,
            in: group
        )
        XCTAssertEqual(result, .failure(.conflictsWithStudent("Sara Mostafa Ali")))
    }

    func testAliasCannotBeClaimedByTwoStudents() throws {
        var group = groupA()
        group = try AliasLearning.learn(alias: "The iPhone", forStudent: group.students[0].id, in: group).get()

        let result = AliasLearning.learn(alias: "The iPhone", forStudent: group.students[1].id, in: group)
        XCTAssertEqual(result, .failure(.conflictsWithStudent("Mohamed Ahmed Hassan")))
    }

    func testEmptyAliasIsRejected() {
        let group = groupA()
        XCTAssertEqual(
            AliasLearning.learn(alias: "   ", forStudent: group.students[0].id, in: group),
            .failure(.emptyAlias)
        )
    }

    func testUnknownStudentIsRejected() {
        XCTAssertEqual(
            AliasLearning.learn(alias: "Anything", forStudent: UUID(), in: groupA()),
            .failure(.unknownStudent)
        )
    }

    func testAliasEqualToTheOwnOfficialNameIsNotStored() throws {
        var group = groupA()
        group = try AliasLearning.learn(
            alias: "Mohamed Ahmed Hassan",
            forStudent: group.students[0].id,
            in: group
        ).get()
        XCTAssertTrue(group.students[0].aliases.isEmpty, "an official name is not an alias")
    }

    /// The rule that keeps the two classes independent.
    func testAliasesNeverCrossGroups() throws {
        var groupA = self.groupA()
        let groupB = StudentGroup(name: "Group B", students: [Student(officialName: "Mohamed Sayed")])

        groupA = try AliasLearning.learn(
            alias: "Mohamed's iPhone",
            forStudent: groupA.students[0].id,
            in: groupA
        ).get()

        XCTAssertTrue(groupB.students.allSatisfy { $0.aliases.isEmpty })

        // The same nickname in Group B resolves to nobody.
        let observation = ParticipantObservation(
            rawName: "Mohamed's iPhone",
            normalizedName: NameNormalizer.normalize("Mohamed's iPhone"),
            observedAt: [Date()]
        )
        let outcome = DeterministicMatcher.match(
            students: groupB.students,
            observations: [observation],
            autoAcceptConfidence: 0.9
        )
        XCTAssertTrue(outcome.accepted.isEmpty, "a Group A alias must say nothing about Group B")
    }

    func testForgettingAnAliasRemovesIt() throws {
        var group = groupA()
        let id = group.students[0].id
        group = try AliasLearning.learn(alias: "Mohamed's iPhone", forStudent: id, in: group).get()
        group = AliasLearning.forget(alias: "mohamed's iphone", forStudent: id, in: group)

        XCTAssertTrue(group.students[0].aliases.isEmpty)
    }
}
