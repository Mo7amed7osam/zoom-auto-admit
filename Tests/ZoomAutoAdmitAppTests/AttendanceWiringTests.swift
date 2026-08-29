import Foundation
import XCTest
@testable import ZoomAutoAdmitApp
import ZoomAutoAdmitCore

final class AttendanceWiringTests: XCTestCase {
    func testAttendanceCoordinatorCreatesAndPersistsSessionImmediately() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attendanceStore = AttendanceStore(directory: directory.appendingPathComponent("Attendance"))
        let coordinator = AttendanceCoordinator(
            store: attendanceStore,
            schedulerLog: SchedulerLog(fileURL: directory.appendingPathComponent("scheduler.log"))
        )
        let group = StudentGroup(
            name: "Class A",
            students: [Student(officialName: "Student One")]
        )
        let schedule = ZoomSchedule(
            name: "Class meeting",
            recurrence: .daily,
            startTime: TimeOfDay(hour: 10, minute: 0),
            accountProfileID: UUID(),
            meeting: MeetingReference(name: "Class meeting", kind: .meetingID("12345678901")),
            attendanceGroupID: group.id
        )

        coordinator.start(group: group, schedule: schedule)
        let session = try XCTUnwrap(coordinator.currentSession)

        XCTAssertTrue(coordinator.isRecording)
        XCTAssertEqual(session.scheduleID, schedule.id)
        XCTAssertEqual(session.groupID, group.id)
        XCTAssertEqual(session.rosterSnapshot.count, 1)
        XCTAssertEqual(attendanceStore.load(id: session.id)?.id, session.id)
        coordinator.stop()
    }

    func testLinkedGroupDispatchesRequiredAttendanceStartCallback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-wiring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let profile = ZoomAccountProfile(name: "Account", accountIdentifier: "host@example.com")
        let group = StudentGroup(
            name: "Class A",
            students: [Student(officialName: "Student One")]
        )
        let schedule = ZoomSchedule(
            name: "Class meeting",
            recurrence: .daily,
            startTime: TimeOfDay(hour: 10, minute: 0),
            accountProfileID: profile.id,
            meeting: MeetingReference(name: "Class meeting", kind: .meetingID("12345678901")),
            attendanceGroupID: group.id
        )
        let store = ScheduleStore(fileURL: directory.appendingPathComponent("schedules.json"))
        XCTAssertTrue(store.save(SchedulerConfiguration(
            accountProfiles: [profile],
            schedules: [schedule],
            studentGroups: [group]
        )))

        let started = expectation(description: "linked attendance lifecycle callback")
        let coordinator = SchedulerCoordinator(
            state: AppState(monitoringEnabled: false),
            store: store,
            schedulerLog: SchedulerLog(fileURL: directory.appendingPathComponent("scheduler.log")),
            startAutoAdmit: {},
            stopAutoAdmit: {},
            startAttendance: { receivedGroup, receivedSchedule in
                XCTAssertEqual(receivedGroup.id, group.id)
                XCTAssertEqual(receivedGroup.students.count, 1)
                XCTAssertEqual(receivedSchedule.id, schedule.id)
                started.fulfill()
            },
            stopAttendance: { _ in }
        )

        coordinator.dispatchAttendanceStart(for: schedule)
        wait(for: [started], timeout: 1)
    }

    // MARK: Resume after relaunch

    private func resumeFixture(
        directory: URL,
        endTime: TimeOfDay?
    ) -> (store: AttendanceStore, log: SchedulerLog, group: StudentGroup, schedule: ZoomSchedule) {
        let store = AttendanceStore(directory: directory.appendingPathComponent("Attendance"))
        let log = SchedulerLog(fileURL: directory.appendingPathComponent("scheduler.log"))
        let group = StudentGroup(name: "Class A", students: [Student(officialName: "Student One")])
        let schedule = ZoomSchedule(
            name: "Class meeting",
            recurrence: .daily,
            startTime: TimeOfDay(hour: 10, minute: 0),
            endTime: endTime,
            accountProfileID: UUID(),
            meeting: MeetingReference(name: "Class meeting", kind: .meetingID("12345678901")),
            attendanceGroupID: group.id
        )
        return (store, log, group, schedule)
    }

    func testResumesAnOpenRegisterAfterARelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = resumeFixture(directory: directory, endTime: nil)

        // A previous process left the register open with evidence already in it.
        let first = AttendanceCoordinator(store: fixture.store, schedulerLog: fixture.log)
        first.start(group: fixture.group, schedule: fixture.schedule)
        let openSession = try XCTUnwrap(first.currentSession)
        first.stop()

        let second = AttendanceCoordinator(store: fixture.store, schedulerLog: fixture.log)
        XCTAssertNil(second.currentSession)
        XCTAssertTrue(second.resumeOpenSession(
            configuration: SchedulerConfiguration(schedules: [fixture.schedule], studentGroups: [fixture.group])
        ))
        XCTAssertTrue(second.isRecording, "snapshots must start again on their own")
        XCTAssertEqual(second.currentSession?.id, openSession.id, "the same register, not a second one")
        XCTAssertEqual(second.currentSession?.snapshots.count, openSession.snapshots.count)
        second.stop()
    }

    func testDoesNotResumeARegisterPastItsEndTime() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = resumeFixture(directory: directory, endTime: TimeOfDay(hour: 11, minute: 0))

        let started = Date()
        let first = AttendanceCoordinator(store: fixture.store, schedulerLog: fixture.log)
        first.start(group: fixture.group, schedule: fixture.schedule, at: started)
        first.stop()

        let second = AttendanceCoordinator(store: fixture.store, schedulerLog: fixture.log)
        XCTAssertFalse(second.resumeOpenSession(
            configuration: SchedulerConfiguration(schedules: [fixture.schedule], studentGroups: [fixture.group]),
            at: started.addingTimeInterval(26 * 60 * 60)
        ))
        XCTAssertFalse(second.isRecording)
    }

    func testDoesNotResumeWhenTheScheduleIsGone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-orphan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = resumeFixture(directory: directory, endTime: nil)

        let first = AttendanceCoordinator(store: fixture.store, schedulerLog: fixture.log)
        first.start(group: fixture.group, schedule: fixture.schedule)
        first.stop()

        let second = AttendanceCoordinator(store: fixture.store, schedulerLog: fixture.log)
        XCTAssertFalse(second.resumeOpenSession(configuration: SchedulerConfiguration()))
        XCTAssertFalse(second.isRecording)
    }

    func testDoesNotResumeAFinalizedRegister() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-closed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = resumeFixture(directory: directory, endTime: nil)

        let first = AttendanceCoordinator(store: fixture.store, schedulerLog: fixture.log)
        first.start(group: fixture.group, schedule: fixture.schedule)
        _ = first.finalize()

        let second = AttendanceCoordinator(store: fixture.store, schedulerLog: fixture.log)
        XCTAssertFalse(second.resumeOpenSession(
            configuration: SchedulerConfiguration(schedules: [fixture.schedule], studentGroups: [fixture.group])
        ))
    }

    // MARK: Live summary

    private func summary(
        startedAt: Date,
        lastSnapshotAt: Date?,
        lastAttemptAt: Date?,
        lastAttemptFailed: Bool,
        nextSnapshotAt: Date?,
        periodicEnabled: Bool = true,
        missedSnapshots: Int = 0
    ) -> AttendanceLiveSummary {
        AttendanceLiveSummary(
            groupName: "Class A",
            observedIdentities: 3,
            matchedStudents: 2,
            totalStudents: 4,
            startedAt: startedAt,
            lastSnapshotAt: lastSnapshotAt,
            lastAttemptAt: lastAttemptAt,
            lastAttemptFailed: lastAttemptFailed,
            nextSnapshotAt: nextSnapshotAt,
            periodicEnabled: periodicEnabled,
            missedSnapshots: missedSnapshots
        )
    }

    func testSummaryAlwaysReportsLastAndNextCheck() {
        let now = Date()
        let lines = summary(
            startedAt: now.addingTimeInterval(-20 * 60),
            lastSnapshotAt: now.addingTimeInterval(-5 * 60),
            lastAttemptAt: now.addingTimeInterval(-5 * 60),
            lastAttemptFailed: false,
            nextSnapshotAt: now.addingTimeInterval(10 * 60)
        ).lines(now: now)

        XCTAssertTrue(lines.contains { $0.hasPrefix("Last attendance check: ") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Next attendance check: ") })
    }

    func testSummaryStillShowsBothRowsBeforeTheFirstReadableSnapshot() {
        let now = Date()
        let live = summary(
            startedAt: now.addingTimeInterval(-60),
            lastSnapshotAt: nil,
            lastAttemptAt: nil,
            lastAttemptFailed: false,
            nextSnapshotAt: nil
        )

        XCTAssertTrue(live.lastCheckText(now: now).hasPrefix("None yet"))
        XCTAssertEqual(live.nextCheckText(now: now), "Retrying until the list is readable")
    }

    func testSummarySurfacesAnUnreadableParticipantsList() {
        let now = Date()
        let live = summary(
            startedAt: now.addingTimeInterval(-10 * 60),
            lastSnapshotAt: nil,
            lastAttemptAt: now.addingTimeInterval(-30),
            lastAttemptFailed: true,
            nextSnapshotAt: nil,
            missedSnapshots: 2
        )

        XCTAssertTrue(live.lastCheckText(now: now).hasSuffix("— list unreadable"))
        XCTAssertTrue(live.lines(now: now).contains("Missed snapshots: 2"))
    }

    func testSummaryFlagsAFailedRetryAfterAGoodSnapshot() {
        let now = Date()
        let live = summary(
            startedAt: now.addingTimeInterval(-30 * 60),
            lastSnapshotAt: now.addingTimeInterval(-15 * 60),
            lastAttemptAt: now.addingTimeInterval(-20),
            lastAttemptFailed: true,
            nextSnapshotAt: now.addingTimeInterval(-1)
        )

        XCTAssertTrue(live.lastCheckText(now: now).contains("retry"))
        XCTAssertEqual(live.nextCheckText(now: now), "Due now")
    }

    func testSummarySaysSoWhenPeriodicChecksAreOff() {
        let now = Date()
        let live = summary(
            startedAt: now,
            lastSnapshotAt: now,
            lastAttemptAt: now,
            lastAttemptFailed: false,
            nextSnapshotAt: nil,
            periodicEnabled: false
        )

        XCTAssertEqual(live.nextCheckText(now: now), "Periodic checks off")
    }

    func testUnlinkedScheduleDoesNotStartAttendance() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-unlinked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let profile = ZoomAccountProfile(name: "Account", accountIdentifier: "host@example.com")
        let schedule = ZoomSchedule(
            name: "No attendance",
            recurrence: .daily,
            startTime: TimeOfDay(hour: 10, minute: 0),
            accountProfileID: profile.id,
            meeting: MeetingReference(name: "Meeting", kind: .meetingID("12345678901"))
        )
        let store = ScheduleStore(fileURL: directory.appendingPathComponent("schedules.json"))
        XCTAssertTrue(store.save(SchedulerConfiguration(accountProfiles: [profile], schedules: [schedule])))
        let callback = expectation(description: "attendance callback remains unused")
        callback.isInverted = true
        let coordinator = SchedulerCoordinator(
            state: AppState(monitoringEnabled: false),
            store: store,
            schedulerLog: SchedulerLog(fileURL: directory.appendingPathComponent("scheduler.log")),
            startAutoAdmit: {},
            stopAutoAdmit: {},
            startAttendance: { _, _ in callback.fulfill() },
            stopAttendance: { _ in }
        )

        coordinator.dispatchAttendanceStart(for: schedule)
        wait(for: [callback], timeout: 0.1)
    }
}

/// A reviewer should confirm the matcher's judgement, not redo it by eye.
final class ReviewSuggestionTests: XCTestCase {
    private let roster = [
        Student(officialName: "Weaam Mohamed Elsayed Ismaiel"),
        Student(officialName: "Zahraa Hagag Abdelsamea Abdelrahman"),
        Student(officialName: "Ahmed Mumdoh Abd El Rahim Mohammed")
    ]

    private func observation(_ name: String) -> ParticipantObservation {
        ParticipantObservation(
            rawName: name,
            normalizedName: NameNormalizer.normalize(name),
            observedAt: [Date()]
        )
    }

    func testTheSuspectedZoomNameIsOfferedFirst() {
        let unrelated = observation("Youssef Ayoub")
        let suspected = observation("Dr.Weaam Mohamed Ismael")
        let ranked = AttendanceWindowController.rankedObservations(
            [unrelated, suspected],
            for: roster[0],
            suspected: suspected.id
        )

        XCTAssertEqual(ranked.first?.observation.id, suspected.id)
        XCTAssertTrue(ranked[0].title.contains("suggested"))
    }

    /// With nothing suspected yet, the best-scoring name still leads.
    func testTheBestScoringNameLeadsWithoutASuspicion() {
        let ranked = AttendanceWindowController.rankedObservations(
            [observation("Youssef Ayoub"), observation("Dr.Weaam Mohamed Ismael")],
            for: roster[0],
            suspected: nil
        )

        XCTAssertEqual(ranked.first?.observation.rawName, "Dr.Weaam Mohamed Ismael")
        XCTAssertTrue(ranked[0].title.contains("% match"))
    }

    func testTheReverseDirectionRanksStudents() {
        let ranked = AttendanceWindowController.rankedStudents(
            roster,
            for: "Zahraa Swelim",
            suspected: nil
        )

        XCTAssertEqual(ranked.first?.student.officialName, "Zahraa Hagag Abdelsamea Abdelrahman")
    }

    func testASuspectedStudentOutranksABetterScore() {
        let ranked = AttendanceWindowController.rankedStudents(
            roster,
            for: "Zahraa Swelim",
            suspected: roster[2].id
        )

        XCTAssertEqual(ranked.first?.student.id, roster[2].id)
        XCTAssertTrue(ranked[0].title.contains("suggested"))
    }

    /// Every candidate must still be reachable: ranking reorders the list, it
    /// never shortens it.
    func testRankingKeepsEveryCandidate() {
        let names = [observation("a"), observation("b"), observation("c")]
        XCTAssertEqual(
            AttendanceWindowController.rankedObservations(names, for: roster[0], suspected: nil).count,
            3
        )
        XCTAssertEqual(
            AttendanceWindowController.rankedStudents(roster, for: "anything", suspected: nil).count,
            roster.count
        )
    }

    /// A weak score is not dressed up as a number the reviewer might trust.
    func testWeakCandidatesShowNoPercentage() {
        let ranked = AttendanceWindowController.rankedObservations(
            [observation("Youssef Ayoub")],
            for: roster[0],
            suspected: nil
        )
        XCTAssertFalse(ranked[0].title.contains("%"))
        XCTAssertEqual(ranked[0].title, "Youssef Ayoub")
    }
}

/// Finalizing a register is the moment its knowledge is worth keeping.
final class FinalizeLearnsAliasesTests: XCTestCase {
    func testFinalizingWritesConfirmedNamesBackOntoTheRoster() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-learn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attendanceStore = AttendanceStore(directory: directory.appendingPathComponent("Attendance"))

        let student = Student(officialName: "Weaam Mohamed Elsayed Ismaiel")
        let group = StudentGroup(name: "Class A", students: [student])
        let schedule = ZoomSchedule(
            name: "Class meeting",
            recurrence: .daily,
            startTime: TimeOfDay(hour: 10, minute: 0),
            accountProfileID: UUID(),
            meeting: MeetingReference(name: "Class meeting", kind: .meetingID("12345678901")),
            attendanceGroupID: group.id
        )

        let observation = ParticipantObservation(
            rawName: "Dr.Weaam Mohamed Ismael",
            normalizedName: NameNormalizer.normalize("Dr.Weaam Mohamed Ismael"),
            observedAt: [Date()]
        )
        // A human already settled this pairing during the meeting.
        let open = AttendanceSession(
            groupID: group.id,
            groupName: group.name,
            scheduleID: schedule.id,
            meetingName: schedule.meeting.name,
            startedAt: Date(),
            rosterSnapshot: [student],
            observations: [observation],
            records: [AttendanceRecord(
                studentID: student.id,
                studentName: student.officialName,
                status: .present,
                matchedObservationID: observation.id,
                matchedZoomName: observation.rawName,
                matchSource: .manual,
                isManual: true
            )],
            snapshots: [AttendanceSnapshot(capturedAt: Date(), reason: .meetingStarted)]
        )
        XCTAssertTrue(attendanceStore.save(open))

        var configuration = SchedulerConfiguration(
            accountProfiles: [],
            schedules: [schedule],
            studentGroups: [group]
        )
        var writes = 0
        let coordinator = AttendanceCoordinator(
            store: attendanceStore,
            schedulerLog: SchedulerLog(fileURL: directory.appendingPathComponent("scheduler.log")),
            configurationProvider: { configuration },
            configurationWriter: { updated in
                configuration = updated
                writes += 1
            }
        )

        XCTAssertTrue(coordinator.resumeOpenSession(configuration: configuration))
        let finalized = try XCTUnwrap(coordinator.finalize())

        XCTAssertNotNil(finalized.finalizedAt)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(configuration.studentGroups[0].students[0].aliases, ["Dr.Weaam Mohamed Ismael"])
    }

    /// Nothing to learn means nothing is written: an untouched roster must not
    /// be rewritten on every finalize.
    func testFinalizingWithNothingNewWritesNoConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-learn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attendanceStore = AttendanceStore(directory: directory.appendingPathComponent("Attendance"))

        let group = StudentGroup(name: "Class A", students: [Student(officialName: "Student One")])
        let schedule = ZoomSchedule(
            name: "Class meeting",
            recurrence: .daily,
            startTime: TimeOfDay(hour: 10, minute: 0),
            accountProfileID: UUID(),
            meeting: MeetingReference(name: "Class meeting", kind: .meetingID("12345678901")),
            attendanceGroupID: group.id
        )
        let configuration = SchedulerConfiguration(schedules: [schedule], studentGroups: [group])

        var writes = 0
        let coordinator = AttendanceCoordinator(
            store: attendanceStore,
            schedulerLog: SchedulerLog(fileURL: directory.appendingPathComponent("scheduler.log")),
            configurationProvider: { configuration },
            configurationWriter: { _ in writes += 1 }
        )

        coordinator.start(group: group, schedule: schedule)
        _ = coordinator.finalize()

        XCTAssertEqual(writes, 0)
    }
}
