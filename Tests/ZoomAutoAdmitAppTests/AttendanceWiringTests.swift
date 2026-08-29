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
