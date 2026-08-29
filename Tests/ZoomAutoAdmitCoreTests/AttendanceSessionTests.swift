import Foundation
import XCTest
@testable import ZoomAutoAdmitCore

final class AttendanceReconcilerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    private func student(_ name: String) -> Student { Student(officialName: name) }

    private func observation(_ name: String, seenAt seconds: TimeInterval = 0) -> ParticipantObservation {
        ParticipantObservation(
            rawName: name,
            normalizedName: NameNormalizer.normalize(name),
            observedAt: [at(seconds), at(seconds + 600)]
        )
    }

    private func session(
        students: [Student],
        observations: [ParticipantObservation]
    ) -> AttendanceSession {
        AttendanceSession(
            groupID: UUID(),
            groupName: "Group A",
            meetingName: "Week 2 Saturday",
            startedAt: base,
            rosterSnapshot: students,
            observations: observations
        )
    }

    /// Nobody is absent mid-meeting; students join late.
    func testUnseenStudentsAreNotSeenYetBeforeFinalization() {
        let roster = [student("Mohamed Ahmed Hassan"), student("Omar Khaled")]
        let live = AttendanceReconciler.reconcile(
            session: session(students: roster, observations: [observation("Mohamed Ahmed Hassan")]),
            autoAcceptConfidence: 0.9
        )

        XCTAssertEqual(live.records.first { $0.studentName == "Omar Khaled" }?.status, .notSeenYet)
        XCTAssertEqual(live.absentCount, 0)
        XCTAssertNil(live.finalizedAt)
    }

    func testFinalizationTurnsUnseenIntoAbsent() {
        let roster = [student("Mohamed Ahmed Hassan"), student("Omar Khaled")]
        let final = AttendanceReconciler.reconcile(
            session: session(students: roster, observations: [observation("Mohamed Ahmed Hassan")]),
            autoAcceptConfidence: 0.9,
            finalizing: true,
            at: at(7_200)
        )

        XCTAssertEqual(final.presentCount, 1)
        XCTAssertEqual(final.absentCount, 1)
        XCTAssertEqual(final.records.first { $0.studentName == "Omar Khaled" }?.status, .absent)
        XCTAssertEqual(final.finalizedAt, at(7_200))
        XCTAssertTrue(final.isFinalized)
    }

    /// The absolute rule: no observation, no Present.
    func testAStudentWithNoObservationCanNeverBePresent() {
        let roster = [student("Ghost Student")]
        let final = AttendanceReconciler.reconcile(
            session: session(students: roster, observations: []),
            autoAcceptConfidence: 0.5,
            finalizing: true
        )
        XCTAssertEqual(final.records[0].status, .absent)
        XCTAssertNil(final.records[0].matchedObservationID)
    }

    func testExactMatchIsPresentWithItsEvidence() {
        let roster = [student("Sara Mostafa Ali")]
        let result = AttendanceReconciler.reconcile(
            session: session(students: roster, observations: [observation("Sara Mostafa Ali")]),
            autoAcceptConfidence: 0.9
        )
        let record = result.records[0]

        XCTAssertEqual(record.status, .present)
        XCTAssertEqual(record.matchedZoomName, "Sara Mostafa Ali")
        XCTAssertEqual(record.matchSource, .exact)
        XCTAssertNotNil(record.matchedObservationID)
    }

    /// A device name is exactly the case that must not become a false Present.
    func testDeviceNameBecomesNeedsReviewNotPresent() {
        let roster = [student("Ahmed Mohamed Ali")]
        let result = AttendanceReconciler.reconcile(
            session: session(students: roster, observations: [observation("Ahmed's iPhone")]),
            autoAcceptConfidence: 0.9,
            finalizing: true
        )
        XCTAssertNotEqual(result.records[0].status, .present)
    }

    func testUnmatchedZoomNamesAreReported() {
        let roster = [student("Sara Mostafa Ali")]
        let result = AttendanceReconciler.reconcile(
            session: session(
                students: roster,
                observations: [observation("Sara Mostafa Ali"), observation("Galaxy S23", seenAt: 60)]
            ),
            autoAcceptConfidence: 0.9,
            finalizing: true
        )
        XCTAssertEqual(result.unmatchedZoomNames, ["Galaxy S23"])
    }

    // MARK: Manual decisions

    func testManualMatchWinsAndSurvivesReconciliation() {
        let roster = [student("Ahmed Tarek")]
        let observed = observation("Ahmed's iPhone")
        var current = session(students: roster, observations: [observed])

        current = AttendanceReconciler.applyManualMatch(
            session: current,
            studentID: roster[0].id,
            observationID: observed.id,
            status: .present
        )
        XCTAssertEqual(current.records[0].status, .present)
        XCTAssertEqual(current.records[0].matchSource, .manual)

        let reconciled = AttendanceReconciler.reconcile(
            session: current,
            autoAcceptConfidence: 0.9,
            finalizing: true
        )
        XCTAssertEqual(reconciled.records[0].status, .present, "a manual decision is not overwritten")
        XCTAssertTrue(reconciled.records[0].isManual)
    }

    /// Even by hand, Present needs evidence.
    func testManualPresentWithoutAnObservationDegradesToNeedsReview() {
        let roster = [student("Ahmed Tarek")]
        var current = session(students: roster, observations: [])
        current = AttendanceReconciler.applyManualMatch(
            session: current,
            studentID: roster[0].id,
            observationID: nil,
            status: .present
        )
        XCTAssertEqual(current.records[0].status, .needsReview)
    }

    func testManualMarkAbsentIsHonoured() {
        let roster = [student("Sara Mostafa Ali")]
        let observed = observation("Sara Mostafa Ali")
        var current = session(students: roster, observations: [observed])

        current = AttendanceReconciler.applyManualMatch(
            session: current,
            studentID: roster[0].id,
            observationID: nil,
            status: .absent
        )
        let reconciled = AttendanceReconciler.reconcile(session: current, autoAcceptConfidence: 0.9)
        XCTAssertEqual(reconciled.records[0].status, .absent, "the human overrides an exact match")
    }

    /// One Zoom identity cannot be evidence for two students.
    func testManualMatchStealsTheObservationFromAnotherStudent() {
        let first = student("Mohamed Ahmed")
        let second = student("Mohamed Ahmed Hassan")
        let observed = observation("Mohamed Ahmed")
        var current = session(students: [first, second], observations: [observed])
        current = AttendanceReconciler.reconcile(session: current, autoAcceptConfidence: 0.9)

        current = AttendanceReconciler.applyManualMatch(
            session: current,
            studentID: second.id,
            observationID: observed.id,
            status: .present
        )

        let holders = current.records.filter { $0.matchedObservationID == observed.id }
        XCTAssertEqual(holders.count, 1)
        XCTAssertEqual(holders[0].studentID, second.id)
    }

    func testClearingAMatchLetsAutomaticMatchingRunAgain() {
        let roster = [student("Sara Mostafa Ali")]
        let observed = observation("Sara Mostafa Ali")
        var current = session(students: roster, observations: [observed])

        current = AttendanceReconciler.applyManualMatch(
            session: current,
            studentID: roster[0].id,
            observationID: nil,
            status: .absent
        )
        current = AttendanceReconciler.clearMatch(session: current, studentID: roster[0].id)
        current = AttendanceReconciler.reconcile(session: current, autoAcceptConfidence: 0.9)

        XCTAssertEqual(current.records[0].status, .present)
    }

    // MARK: Snapshot immutability

    /// Editing the roster tomorrow must not rewrite yesterday's register.
    func testFinalizedSessionIsUnaffectedByLaterRosterEdits() {
        var group = StudentGroup(name: "Group A", students: [student("Sara Mostafa Ali")])
        let snapshot = group.students
        let finalized = AttendanceReconciler.reconcile(
            session: AttendanceSession(
                groupID: group.id,
                groupName: group.name,
                meetingName: "Week 2",
                startedAt: base,
                rosterSnapshot: snapshot,
                observations: [observation("Sara Mostafa Ali")]
            ),
            autoAcceptConfidence: 0.9,
            finalizing: true
        )

        group.students.append(student("Newly Enrolled"))
        group.students[0].officialName = "Renamed Person"

        XCTAssertEqual(finalized.rosterSnapshot.count, 1)
        XCTAssertEqual(finalized.records.map(\.studentName), ["Sara Mostafa Ali"])
    }
}

final class AttendanceExportTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func finalizedSession() -> AttendanceSession {
        let present = Student(officialName: "Sara Mostafa Ali")
        let absent = Student(officialName: "Omar Khaled")
        let observed = ParticipantObservation(
            rawName: "Sara M.",
            normalizedName: "sara m",
            observedAt: [base, base.addingTimeInterval(3_600)]
        )
        return AttendanceSession(
            groupID: UUID(),
            groupName: "Group A",
            meetingName: "Week 2",
            startedAt: base,
            finalizedAt: base.addingTimeInterval(7_200),
            rosterSnapshot: [present, absent],
            observations: [observed],
            records: [
                AttendanceRecord(
                    studentID: present.id,
                    studentName: present.officialName,
                    status: .present,
                    matchedObservationID: observed.id,
                    matchedZoomName: "Sara M.",
                    matchSource: .alias,
                    confidence: 1.0
                ),
                AttendanceRecord(studentID: absent.id, studentName: absent.officialName, status: .absent)
            ]
        )
    }

    func testCSVHasHeaderAndOneRowPerStudent() {
        let csv = AttendanceExport.csv(for: finalizedSession(), timeZone: TimeZone(identifier: "UTC")!)
        let lines = csv.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("Official Student Name,Status,Matched Zoom Name"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("Sara Mostafa Ali,Present,Sara M.,alias,1.00") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Omar Khaled,Absent,,,") })
    }

    func testCSVEscapesNamesContainingCommas() {
        XCTAssertEqual(AttendanceExport.escape("Hassan, Mohamed"), "\"Hassan, Mohamed\"")
        XCTAssertEqual(AttendanceExport.escape("plain"), "plain")
        XCTAssertEqual(AttendanceExport.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
    }

    func testAbsenceReportListsOnlyAbsentStudents() {
        let session = finalizedSession()
        XCTAssertEqual(AttendanceExport.absentNames(in: session), ["Omar Khaled"])
        XCTAssertTrue(AttendanceExport.absenceReport(for: session).contains("- Omar Khaled"))
        XCTAssertFalse(AttendanceExport.absenceReport(for: session).contains("Sara"))
    }
}

final class AttendanceStoreTests: XCTestCase {
    private func temporaryStore() -> (AttendanceStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-attendance-\(UUID().uuidString)")
        return (AttendanceStore(directory: directory), directory)
    }

    private func session(groupID: UUID, startedAt: Date) -> AttendanceSession {
        AttendanceSession(
            groupID: groupID,
            groupName: "Group",
            meetingName: "Week",
            startedAt: startedAt,
            rosterSnapshot: [Student(officialName: "Sara Mostafa")],
            observations: []
        )
    }

    func testSessionRoundTripsThroughDisk() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = session(groupID: UUID(), startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(store.save(original))
        XCTAssertEqual(store.load(id: original.id), original)
    }

    /// Each group keeps its own history; the two classes never mix.
    func testSessionsAreScopedToTheirGroup() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let groupA = UUID()
        let groupB = UUID()
        store.save(session(groupID: groupA, startedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        store.save(session(groupID: groupB, startedAt: Date(timeIntervalSince1970: 1_800_100_000)))

        XCTAssertEqual(store.sessions(forGroup: groupA).count, 1)
        XCTAssertEqual(store.sessions(forGroup: groupB).count, 1)
        XCTAssertEqual(store.sessions(forGroup: groupA).first?.groupID, groupA)
    }

    func testHistoryIsNewestFirst() {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let group = UUID()
        let older = session(groupID: group, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let newer = session(groupID: group, startedAt: Date(timeIntervalSince1970: 1_800_900_000))
        store.save(older)
        store.save(newer)

        XCTAssertEqual(store.loadAll().map(\.id), [newer.id, older.id])
    }

    /// One unreadable file must not take the archive down with it.
    func testCorruptFileIsSkippedNotFatal() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let good = session(groupID: UUID(), startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        store.save(good)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))

        XCTAssertEqual(store.loadAll().map(\.id), [good.id])
    }

    func testMissingDirectoryLoadsEmptyHistory() {
        let store = AttendanceStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("zoom-auto-admit-missing-\(UUID().uuidString)")
        )
        XCTAssertTrue(store.loadAll().isEmpty)
    }
}
