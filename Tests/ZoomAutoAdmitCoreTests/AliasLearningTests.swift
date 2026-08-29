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

/// A match worked out once must not have to be worked out again.
final class ConfirmedAliasLearningTests: XCTestCase {
    private func student(_ name: String, aliases: [String] = []) -> Student {
        Student(officialName: name, aliases: aliases)
    }

    private func session(
        group: StudentGroup,
        records: [AttendanceRecord]
    ) -> AttendanceSession {
        AttendanceSession(
            groupID: group.id,
            groupName: group.name,
            meetingName: "Class",
            startedAt: Date(),
            rosterSnapshot: group.students,
            records: records
        )
    }

    func testPresentMatchesBecomeAliases() {
        let zahraa = student("Zahraa Hagag Abdelsamea Abdelrahman")
        let group = StudentGroup(name: "G1", students: [zahraa])
        let outcome = AliasLearning.learnConfirmedMatches(
            in: session(group: group, records: [
                AttendanceRecord(
                    studentID: zahraa.id,
                    studentName: zahraa.officialName,
                    status: .present,
                    matchedZoomName: "Zahraa Swelim",
                    matchSource: .ai,
                    confidence: 0.93
                )
            ]),
            group: group
        )

        XCTAssertEqual(outcome.learned.map(\.alias), ["Zahraa Swelim"])
        XCTAssertEqual(outcome.group.students[0].aliases, ["Zahraa Swelim"])
        XCTAssertTrue(outcome.didChangeGroup)
    }

    /// The learned alias is what makes the next meeting resolve with no AI call.
    func testLearnedAliasResolvesTheSameNameNextTime() {
        let zahraa = student("Zahraa Hagag Abdelsamea Abdelrahman")
        let group = StudentGroup(name: "G1", students: [zahraa])
        let learned = AliasLearning.learnConfirmedMatches(
            in: session(group: group, records: [
                AttendanceRecord(
                    studentID: zahraa.id,
                    studentName: zahraa.officialName,
                    status: .present,
                    matchedZoomName: "Zahraa Swelim",
                    matchSource: .ai
                )
            ]),
            group: group
        ).group

        let observation = ParticipantObservation(
            rawName: "Zahraa Swelim",
            normalizedName: NameNormalizer.normalize("Zahraa Swelim"),
            observedAt: [Date()]
        )
        let outcome = DeterministicMatcher.match(
            students: learned.students,
            observations: [observation],
            autoAcceptConfidence: 0.9
        )

        XCTAssertEqual(outcome.accepted.count, 1)
        XCTAssertEqual(outcome.accepted.first?.source, .alias)
        XCTAssertTrue(outcome.review.isEmpty)
    }

    /// A question must never be recorded as knowledge.
    func testNeedsReviewAndAbsentRecordsTeachNothing() {
        let one = student("Aya Hussein Mohamed Mkhemar")
        let two = student("Doaa Hafez Abbas Shalaby")
        let group = StudentGroup(name: "G2", students: [one, two])
        let outcome = AliasLearning.learnConfirmedMatches(
            in: session(group: group, records: [
                AttendanceRecord(
                    studentID: one.id,
                    studentName: one.officialName,
                    status: .needsReview,
                    matchedZoomName: "Aya",
                    matchSource: .ai,
                    confidence: 0.61
                ),
                AttendanceRecord(
                    studentID: two.id,
                    studentName: two.officialName,
                    status: .absent,
                    matchedZoomName: "Doaa H",
                    matchSource: .none
                )
            ]),
            group: group
        )

        XCTAssertTrue(outcome.learned.isEmpty)
        XCTAssertFalse(outcome.didChangeGroup)
        XCTAssertEqual(outcome.group, group)
    }

    func testAnAliasIsNeverLearnedTwice() {
        let student = student("Weaam Mohamed Elsayed Ismaiel", aliases: ["Dr.Weaam Mohamed Ismael"])
        let group = StudentGroup(name: "G1", students: [student])
        let outcome = AliasLearning.learnConfirmedMatches(
            in: session(group: group, records: [
                AttendanceRecord(
                    studentID: student.id,
                    studentName: student.officialName,
                    status: .present,
                    matchedZoomName: "Dr.Weaam Mohamed Ismael",
                    matchSource: .alias
                )
            ]),
            group: group
        )

        XCTAssertTrue(outcome.learned.isEmpty)
        XCTAssertEqual(outcome.group.students[0].aliases, ["Dr.Weaam Mohamed Ismael"])
    }

    /// The safety rules still win: a name belonging to somebody else is refused
    /// rather than quietly moving attendance between students.
    func testAConflictingAliasIsSkippedAndReported() {
        let one = student("Mohamed Hatem Sadek Alsaeid")
        let two = student("mohamed hamam mohamed tamam")
        let group = StudentGroup(name: "G1", students: [one, two])
        let outcome = AliasLearning.learnConfirmedMatches(
            in: session(group: group, records: [
                AttendanceRecord(
                    studentID: one.id,
                    studentName: one.officialName,
                    status: .present,
                    matchedZoomName: two.officialName,
                    matchSource: .ai
                )
            ]),
            group: group
        )

        XCTAssertTrue(outcome.learned.isEmpty)
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertTrue(outcome.group.students.allSatisfy { $0.aliases.isEmpty })
    }
}
