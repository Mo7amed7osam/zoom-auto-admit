import Foundation
import XCTest
import ZoomAXSupport
@testable import ZoomAutoAdmitCore

/// Snapshot semantics, pinned to the live capture: two PANELIST rows, one of
/// them the host running this app.
final class AttendanceSnapshotRecorderTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private func row(
        _ name: String,
        roles: Set<ZoomAXSupport.ParticipantRole> = [],
        indexPath: [Int] = [0]
    ) -> ZoomAXSupport.ParticipantRow {
        ZoomAXSupport.ParticipantRow(rawText: name, displayName: name, roles: roles, indexPath: indexPath)
    }

    private func readout(
        _ admitted: [ZoomAXSupport.ParticipantRow],
        waiting: [ZoomAXSupport.ParticipantRow] = [],
        count: Int? = nil
    ) -> ZoomAXSupport.ParticipantsReadout {
        ZoomAXSupport.ParticipantsReadout(
            listAvailable: true,
            admitted: admitted,
            waiting: waiting,
            reportedCount: count
        )
    }

    private func recorder(ignoring ignored: [String] = []) -> AttendanceSnapshotRecorder {
        AttendanceSnapshotRecorder(
            group: StudentGroup(name: "Group A", students: [], ignoredParticipantNames: ignored)
        )
    }

    // MARK: Evidence is a union

    /// The core change: identities accumulate, they are never withdrawn.
    func testIdentitiesUnionAcrossSnapshots() {
        let recorder = self.recorder()
        recorder.capture(readout([row("Ahmed"), row("Mohamed", indexPath: [1])]), reason: .meetingStarted, at: at(0))
        recorder.capture(
            readout([row("Ahmed"), row("Mohamed", indexPath: [1]), row("Sara", indexPath: [2])]),
            reason: .periodic,
            at: at(15)
        )
        recorder.capture(readout([row("Mohamed"), row("Sara", indexPath: [1])]), reason: .periodic, at: at(30))

        XCTAssertEqual(
            Set(recorder.observations.map(\.rawName)),
            ["Ahmed", "Mohamed", "Sara"],
            "Ahmed missing from the last snapshot is still evidence he was there"
        )
        XCTAssertEqual(recorder.observedIdentityCount, 3)
    }

    func testObservationTimingReflectsSightingsOnly() {
        let recorder = self.recorder()
        recorder.capture(readout([row("Mohamed")]), reason: .meetingStarted, at: at(0))
        recorder.capture(readout([row("Mohamed")]), reason: .periodic, at: at(15))
        recorder.capture(readout([]), reason: .periodic, at: at(30))
        recorder.capture(readout([row("Mohamed")]), reason: .periodic, at: at(45))

        let mohamed = recorder.observations[0]
        XCTAssertEqual(mohamed.firstObservedAt, at(0))
        XCTAssertEqual(mohamed.lastObservedAt, at(45))
        XCTAssertEqual(mohamed.observationCount, 3, "seen in three snapshots, not four")
        XCTAssertEqual(mohamed.observedAt, [at(0), at(15), at(45)])
    }

    func testMissingFromOneSnapshotRemovesNobody() {
        let recorder = self.recorder()
        recorder.capture(readout([row("Sara")]), reason: .meetingStarted, at: at(0))
        recorder.capture(readout([]), reason: .periodic, at: at(15))

        XCTAssertEqual(recorder.observations.count, 1)
        XCTAssertEqual(recorder.observations[0].observationCount, 1)
    }

    /// An unreadable list is a missed snapshot, never an empty meeting.
    func testUnavailableListIsAMissedSnapshotNotAnEmptyOne() {
        let recorder = self.recorder()
        recorder.capture(readout([row("Sara")]), reason: .meetingStarted, at: at(0))
        XCTAssertNil(recorder.capture(.unavailable, reason: .periodic, at: at(15)))

        XCTAssertEqual(recorder.missedSnapshots, 1)
        XCTAssertEqual(recorder.snapshots.count, 1, "a missed attempt is not a snapshot")
        XCTAssertEqual(recorder.observations.count, 1, "and it removes nobody")
    }

    // MARK: Exclusions

    func testHostAndSelfAreNeverEvidence() {
        let recorder = self.recorder()
        recorder.capture(
            readout([
                row("Mohamed Hosam", roles: [.host, .me]),
                row("A CoHost", roles: [.coHost], indexPath: [1]),
                row("eyouth coordinator", indexPath: [2])
            ]),
            reason: .meetingStarted,
            at: at(0)
        )

        XCTAssertEqual(recorder.observations.map(\.rawName), ["eyouth coordinator"])
    }

    func testIgnoredNamesAreNeverEvidence() {
        let recorder = self.recorder(ignoring: ["eyouth coordinator"])
        recorder.capture(
            readout([row("eyouth coordinator"), row("Real Student", indexPath: [1])]),
            reason: .meetingStarted,
            at: at(0)
        )

        XCTAssertEqual(recorder.observations.map(\.rawName), ["Real Student"])
    }

    /// Waiting Room is not attendance, in any code path.
    func testWaitingRoomIsNeverEvidence() {
        let recorder = self.recorder()
        let snapshot = recorder.capture(
            readout([row("Admitted")], waiting: [row("Still Waiting", indexPath: [9])]),
            reason: .meetingStarted,
            at: at(0)
        )

        XCTAssertEqual(snapshot?.participants.map(\.rawZoomName), ["Admitted"])
        XCTAssertEqual(recorder.observations.map(\.rawName), ["Admitted"])
    }

    // MARK: Snapshot records

    func testSnapshotCarriesReasonAndReportedCount() {
        let recorder = self.recorder()
        let snapshot = recorder.capture(
            readout([row("Sara")], count: 2),
            reason: .postAdmit,
            at: at(3)
        )

        XCTAssertEqual(snapshot?.reason, .postAdmit)
        XCTAssertEqual(snapshot?.reportedCount, 2)
        XCTAssertEqual(snapshot?.capturedAt, at(3))
        XCTAssertEqual(recorder.lastSnapshotAt, at(3))
    }

    func testNameVariantsMergeIntoOneIdentity() {
        let recorder = self.recorder()
        recorder.capture(readout([row("Sara Mostafa")]), reason: .meetingStarted, at: at(0))
        recorder.capture(readout([row("sara   mostafa")]), reason: .periodic, at: at(15))

        XCTAssertEqual(recorder.observations.count, 1)
        XCTAssertEqual(recorder.observations[0].observationCount, 2)
        XCTAssertTrue(recorder.observations[0].observedAliases.contains("sara   mostafa"))
    }
}

final class SnapshotScheduleTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testPeriodicIsDueOnlyAfterTheInterval() {
        let schedule = SnapshotSchedule(interval: 15 * 60)

        XCTAssertTrue(schedule.isPeriodicDue(now: base, lastSnapshotAt: nil), "the first one is always due")
        XCTAssertFalse(schedule.isPeriodicDue(now: base.addingTimeInterval(14 * 60), lastSnapshotAt: base))
        XCTAssertTrue(schedule.isPeriodicDue(now: base.addingTimeInterval(15 * 60), lastSnapshotAt: base))
        XCTAssertEqual(schedule.nextPeriodicDate(after: base), base.addingTimeInterval(15 * 60))
    }

    func testIntervalCannotBeSetBelowTheFloor() {
        XCTAssertEqual(SnapshotSchedule(interval: 30).interval, SnapshotSchedule.minimumInterval)
        XCTAssertEqual(SnapshotSchedule(interval: 60 * 60).interval, 60 * 60)
        XCTAssertEqual(SnapshotSchedule().interval, 15 * 60, "default is fifteen minutes")
    }

    func testPostAdmitDelayIsBounded() {
        XCTAssertEqual(SnapshotSchedule(postAdmitDelay: 0).postAdmitDelay, SnapshotSchedule.minimumPostAdmitDelay)
        XCTAssertEqual(SnapshotSchedule(postAdmitDelay: 9_999).postAdmitDelay, SnapshotSchedule.maximumPostAdmitDelay)
        XCTAssertEqual(SnapshotSchedule().postAdmitDelay, 8, "default is eight seconds")
    }

    func testDisablingPeriodicStopsItBeingDue() {
        let schedule = SnapshotSchedule(periodicEnabled: false)
        XCTAssertFalse(schedule.isPeriodicDue(now: base.addingTimeInterval(3_600), lastSnapshotAt: base))
        XCTAssertNil(schedule.nextPeriodicDate(after: base))
    }
}

final class PostAdmitCoalescerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// Admitting a burst of students is one attendance event, not five.
    func testBurstOfAdmitsProducesOneSnapshot() {
        var coalescer = PostAdmitCoalescer()

        let due = coalescer.noteAdmit(at: base, delay: 8)
        coalescer.noteAdmit(at: base.addingTimeInterval(2), delay: 8)
        coalescer.noteAdmit(at: base.addingTimeInterval(4), delay: 8)

        XCTAssertEqual(coalescer.admitsInBurst, 3)
        XCTAssertEqual(due, base.addingTimeInterval(8))
        XCTAssertEqual(coalescer.dueAt, base.addingTimeInterval(8), "later admits join the pending snapshot")
        XCTAssertFalse(coalescer.isDue(at: base.addingTimeInterval(7)))
        XCTAssertTrue(coalescer.isDue(at: base.addingTimeInterval(8)))
    }

    func testNothingIsPendingBeforeAnAdmit() {
        let coalescer = PostAdmitCoalescer()
        XCTAssertFalse(coalescer.isPending)
        XCTAssertFalse(coalescer.isDue(at: base.addingTimeInterval(3_600)))
    }

    func testResettingClearsTheBurst() {
        var coalescer = PostAdmitCoalescer()
        coalescer.noteAdmit(at: base, delay: 8)
        coalescer.reset()

        XCTAssertFalse(coalescer.isPending)
        XCTAssertEqual(coalescer.admitsInBurst, 0)
    }

    func testASecondBurstSchedulesAgain() {
        var coalescer = PostAdmitCoalescer()
        coalescer.noteAdmit(at: base, delay: 8)
        coalescer.reset()

        let due = coalescer.noteAdmit(at: base.addingTimeInterval(600), delay: 8)
        XCTAssertEqual(due, base.addingTimeInterval(608))
    }
}

/// Finalization must rest on every snapshot taken, not the last one.
final class SnapshotFinalizationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private func observation(_ name: String, at moments: [Date]) -> ParticipantObservation {
        ParticipantObservation(
            rawName: name,
            normalizedName: NameNormalizer.normalize(name),
            observedAt: moments
        )
    }

    func testFinalizationUsesTheUnionOfAllSnapshots() {
        let early = Student(officialName: "Ahmed Tarek Ali")
        let late = Student(officialName: "Sara Mostafa Ali")

        // Ahmed only ever appeared in the first snapshot; Sara only in the last.
        let session = AttendanceSession(
            groupID: UUID(),
            groupName: "Group A",
            meetingName: "Week 2",
            startedAt: base,
            rosterSnapshot: [early, late],
            observations: [
                observation("Ahmed Tarek Ali", at: [at(0)]),
                observation("Sara Mostafa Ali", at: [at(45)])
            ]
        )

        let finalized = AttendanceReconciler.reconcile(
            session: session,
            autoAcceptConfidence: 0.9,
            finalizing: true,
            at: at(60)
        )

        XCTAssertEqual(finalized.presentCount, 2, "one sighting anywhere is enough evidence")
        XCTAssertEqual(finalized.absentCount, 0)
    }

    func testStudentsStayNotSeenYetUntilFinalization() {
        let student = Student(officialName: "Omar Khaled")
        let live = AttendanceReconciler.reconcile(
            session: AttendanceSession(
                groupID: UUID(),
                groupName: "Group A",
                meetingName: "Week 2",
                startedAt: base,
                rosterSnapshot: [student],
                observations: []
            ),
            autoAcceptConfidence: 0.9
        )

        XCTAssertEqual(live.records[0].status, .notSeenYet)
        XCTAssertEqual(live.absentCount, 0, "a missed snapshot must never read as absence")
    }

    func testSessionRetainsItsSnapshotEvidence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-snapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = AttendanceSession(
            groupID: UUID(),
            groupName: "Group A",
            meetingName: "Week 2",
            startedAt: base,
            rosterSnapshot: [Student(officialName: "Sara Mostafa Ali")],
            observations: [observation("Sara M.", at: [at(0), at(15)])],
            snapshots: [
                AttendanceSnapshot(
                    capturedAt: at(0),
                    reason: .meetingStarted,
                    reportedCount: 2,
                    participants: [SnapshotParticipant(rawZoomName: "Sara M.", normalizedZoomName: "sara m")]
                ),
                AttendanceSnapshot(capturedAt: at(15), reason: .periodic, reportedCount: 2, participants: [])
            ],
            missedSnapshotCount: 1
        )

        let store = AttendanceStore(directory: url)
        XCTAssertTrue(store.save(session))

        let reloaded = try XCTUnwrap(store.load(id: session.id))
        XCTAssertEqual(reloaded, session)
        XCTAssertEqual(reloaded.snapshots.count, 2)
        XCTAssertEqual(reloaded.snapshots[0].reason, .meetingStarted)
        XCTAssertEqual(reloaded.missedSnapshotCount, 1)
        XCTAssertEqual(reloaded.evidenceSource, .accessibilitySnapshots)
        XCTAssertEqual(reloaded.observations[0].observationCount, 2)
    }

    /// Sessions written by the interval-based version must still load.
    func testLegacySessionWithoutSnapshotsStillDecodes() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "groupID": "\(UUID().uuidString)",
          "groupName": "Group A",
          "meetingName": "Week 2",
          "startedAt": "2026-08-29T18:00:00Z",
          "rosterSnapshot": [],
          "observations": [
            {
              "id": "\(UUID().uuidString)",
              "rawName": "Sara M.",
              "normalizedName": "sara m",
              "firstSeen": "2026-08-29T18:00:00Z",
              "lastSeen": "2026-08-29T19:00:00Z",
              "observedAliases": [],
              "sawHostRole": false
            }
          ],
          "records": [],
          "unmatchedZoomNames": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(AttendanceSession.self, from: Data(json.utf8))

        XCTAssertTrue(session.snapshots.isEmpty)
        XCTAssertEqual(session.evidenceSource, .accessibilitySnapshots)
        // The old record knew two moments; it must not pretend to know more.
        XCTAssertEqual(session.observations[0].observationCount, 2)
        XCTAssertNotNil(session.observations[0].firstObservedAt)
    }

    /// The absolute rule survives the refactor.
    func testAICannotMarkAnUnobservedStudentPresent() {
        let student = Student(officialName: "Ghost Student")
        let session = AttendanceReconciler.reconcile(
            session: AttendanceSession(
                groupID: UUID(),
                groupName: "Group A",
                meetingName: "Week 2",
                startedAt: base,
                rosterSnapshot: [student],
                observations: []
            ),
            autoAcceptConfidence: 0.9
        )

        let summary = AIReconciliation.apply(
            AIMatchResponse(
                matches: [AIMatchProposal(studentId: "s0", zoomName: "Ghost Student", confidence: 0.99, reason: nil)],
                unresolvedZoomNames: []
            ),
            to: session,
            ids: ["s0": student.id],
            autoAcceptConfidence: 0.9
        )

        XCTAssertEqual(summary.appliedCount, 0)
        XCTAssertNotEqual(summary.session.records[0].status, .present)
        XCTAssertEqual(summary.rejected.count, 1)
    }
}
