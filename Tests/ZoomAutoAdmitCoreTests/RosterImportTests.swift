import Foundation
import XCTest
@testable import ZoomAutoAdmitCore

final class RosterImportTests: XCTestCase {
    func testPlainNameListIsImported() {
        let result = RosterImporter.merge("""
        Mohamed Ahmed Hassan
        Youssef Ali Mahmoud
        Sara Mostafa Ali
        """, into: [])

        XCTAssertEqual(result.students.map(\.officialName), [
            "Mohamed Ahmed Hassan",
            "Youssef Ali Mahmoud",
            "Sara Mostafa Ali"
        ])
        XCTAssertEqual(result.addedCount, 3)
        XCTAssertTrue(result.skippedLines.isEmpty)
    }

    func testHeaderedCSVWithIDAndEmail() {
        let result = RosterImporter.merge("""
        Student ID,Name,Email
        S-1,Mohamed Ahmed Hassan,mohamed@example.com
        S-2,Sara Mostafa Ali,sara@example.com
        """, into: [])

        XCTAssertEqual(result.students.count, 2)
        XCTAssertEqual(result.students[0].externalID, "S-1")
        XCTAssertEqual(result.students[0].officialName, "Mohamed Ahmed Hassan")
        XCTAssertEqual(result.students[0].email, "mohamed@example.com")
    }

    /// A first line that is not a header is a student, not a lost record.
    func testFirstLineIsKeptWhenItIsNotAHeader() {
        let result = RosterImporter.merge("Mohamed Ahmed\nSara Ali", into: [])
        XCTAssertEqual(result.students.count, 2)
        XCTAssertEqual(result.students[0].officialName, "Mohamed Ahmed")
    }

    func testQuotedFieldsWithCommasSurvive() {
        let result = RosterImporter.merge("""
        Name,Email
        "Hassan, Mohamed Ahmed",m@example.com
        """, into: [])

        XCTAssertEqual(result.students.first?.officialName, "Hassan, Mohamed Ahmed")
        XCTAssertEqual(result.students.first?.email, "m@example.com")
    }

    func testSemicolonAndTabSeparatorsWork() {
        XCTAssertEqual(RosterImporter.splitCSVLine("a;b;c"), ["a", "b", "c"])
        XCTAssertEqual(RosterImporter.splitCSVLine("a\tb"), ["a", "b"])
    }

    func testArabicNamesImportUnchanged() {
        let result = RosterImporter.merge("عبدالرحمن محمد علي\nمريم أحمد", into: [])
        XCTAssertEqual(result.students.map(\.officialName), ["عبدالرحمن محمد علي", "مريم أحمد"])
    }

    /// Re-importing the class list must not duplicate anybody.
    func testReimportUpdatesRatherThanDuplicates() {
        let first = RosterImporter.merge("Mohamed Ahmed Hassan\nSara Mostafa", into: [])
        let second = RosterImporter.merge("Mohamed Ahmed Hassan\nSara Mostafa\nOmar Khaled", into: first.students)

        XCTAssertEqual(second.students.count, 3)
        XCTAssertEqual(second.addedCount, 1)
        XCTAssertEqual(second.updatedCount, 2)
    }

    /// Learned aliases are what make future meetings match without AI; a
    /// re-import must never throw them away.
    func testReimportPreservesLearnedAliasesAndIdentity() {
        var existing = RosterImporter.merge("Mohamed Ahmed Hassan", into: []).students
        existing[0].aliases = ["Mohamed's iPhone"]
        let originalID = existing[0].id

        let result = RosterImporter.merge("Mohamed Ahmed Hassan", into: existing)

        XCTAssertEqual(result.students.count, 1)
        XCTAssertEqual(result.students[0].aliases, ["Mohamed's iPhone"])
        XCTAssertEqual(result.students[0].id, originalID, "identity must survive a re-import")
    }

    func testExternalIDWinsOverNameWhenMatching() {
        var existing = RosterImporter.merge("Student ID,Name\nS-1,Mohamed Ahmed", into: []).students
        existing[0].aliases = ["Mohamed"]

        // Same student, name corrected in the institution's records.
        let result = RosterImporter.merge("Student ID,Name\nS-1,Mohamed Ahmed Hassan", into: existing)

        XCTAssertEqual(result.students.count, 1, "the ID identifies the student, not the name")
        XCTAssertEqual(result.students[0].officialName, "Mohamed Ahmed Hassan")
        XCTAssertEqual(result.students[0].aliases, ["Mohamed"])
    }

    func testBlankAndJunkLinesAreReportedNotSilentlyDropped() {
        let result = RosterImporter.merge("Mohamed Ahmed\n\n,,\n123\nSara Ali", into: [])
        XCTAssertEqual(result.students.map(\.officialName), ["Mohamed Ahmed", "Sara Ali"])
        XCTAssertEqual(result.skippedLines, [",,", "123"])
    }
}

final class ScheduleGroupLinkTests: XCTestCase {
    private func group(_ name: String) -> StudentGroup {
        StudentGroup(name: name, students: [Student(officialName: "A Student")])
    }

    private func schedule(groupID: UUID?) -> ZoomSchedule {
        ZoomSchedule(
            name: "Saturday",
            recurrence: .selectedWeekdays([.saturday]),
            startTime: TimeOfDay(hour: 18, minute: 0),
            accountProfileID: UUID(),
            meeting: MeetingReference(name: "Week 2", kind: .meetingID("12345678901")),
            attendanceGroupID: groupID
        )
    }

    func testScheduleResolvesItsOwnGroup() {
        let groupA = group("Group A")
        let groupB = group("Group B")
        let configuration = SchedulerConfiguration(
            schedules: [schedule(groupID: groupB.id)],
            studentGroups: [groupA, groupB]
        )

        XCTAssertEqual(configuration.group(for: configuration.schedules[0])?.name, "Group B")
    }

    func testScheduleWithoutAGroupSimplyRecordsNothing() {
        let configuration = SchedulerConfiguration(
            schedules: [schedule(groupID: nil)],
            studentGroups: [group("Group A")]
        )
        XCTAssertNil(configuration.group(for: configuration.schedules[0]))
    }

    func testGroupsAndLinkSurvivePersistence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-groups-\(UUID().uuidString)")
            .appendingPathComponent("schedules.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var groupA = group("Group A")
        groupA.students[0].aliases = ["Mohamed's iPhone"]
        groupA.ignoredParticipantNames = ["eyouth coordinator"]

        let configuration = SchedulerConfiguration(
            accountProfiles: [ZoomAccountProfile(name: "P", accountIdentifier: "a@b.com")],
            schedules: [schedule(groupID: groupA.id)],
            studentGroups: [groupA]
        )

        let store = ScheduleStore(fileURL: url)
        XCTAssertTrue(store.save(configuration))

        let reloaded = ScheduleStore(fileURL: url).load()
        XCTAssertEqual(reloaded, configuration)
        XCTAssertEqual(reloaded.group(for: reloaded.schedules[0])?.students.first?.aliases, ["Mohamed's iPhone"])
        XCTAssertEqual(reloaded.studentGroups.first?.ignoredParticipantNames, ["eyouth coordinator"])
    }

    /// Schedules written before attendance existed must keep loading.
    func testSchedulesSavedBeforeGroupsStillLoad() throws {
        let json = """
        {
          "accountProfiles": [],
          "schedules": [
            {
              "id": "\(UUID().uuidString)",
              "name": "Old",
              "isEnabled": true,
              "recurrence": {"kind": "daily"},
              "startTime": {"hour": 18, "minute": 0},
              "accountProfileID": "\(UUID().uuidString)",
              "meeting": {"name": "M", "kind": {"kind": "instantMeeting"}}
            }
          ]
        }
        """
        let configuration = try JSONDecoder().decode(SchedulerConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(configuration.schedules.count, 1)
        XCTAssertNil(configuration.schedules[0].attendanceGroupID)
        XCTAssertTrue(configuration.studentGroups.isEmpty)
    }

    /// Aliases learned in one group must never leak into the other.
    func testAliasesAreScopedToTheirGroup() {
        var groupA = StudentGroup(name: "Group A", students: [
            Student(officialName: "Mohamed Ahmed Hassan", aliases: ["Mohamed's iPhone"])
        ])
        let groupB = StudentGroup(name: "Group B", students: [
            Student(officialName: "Mohamed Sayed")
        ])
        groupA.ignoredParticipantNames = ["coordinator"]

        XCTAssertTrue(groupA.students[0].aliases.contains("Mohamed's iPhone"))
        XCTAssertTrue(groupB.students.allSatisfy { $0.aliases.isEmpty })
        XCTAssertTrue(groupA.isIgnored("Coordinator"))
        XCTAssertFalse(groupB.isIgnored("Coordinator"))
    }
}
