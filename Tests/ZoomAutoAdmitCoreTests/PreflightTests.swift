import Foundation
import XCTest
import ZoomAXSupport
@testable import ZoomAutoAdmitCore

/// The pre-flight check exists to move failures from "the class is starting"
/// to "you still have five minutes".
final class PreflightCheckerTests: XCTestCase {
    private let startsAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let email = "depi+11@eyouthlearning.com"

    private func profile(_ identifier: String? = nil) -> ZoomAccountProfile {
        ZoomAccountProfile(name: "DEPI", accountIdentifier: identifier ?? email)
    }

    private func schedule(
        groupID: UUID? = nil,
        meeting: MeetingReference = MeetingReference(name: "Week 2", kind: .meetingID("94698416251"))
    ) -> ZoomSchedule {
        ZoomSchedule(
            name: "Saturday DEPI",
            recurrence: .selectedWeekdays([.saturday]),
            startTime: TimeOfDay(hour: 18, minute: 0),
            accountProfileID: UUID(),
            meeting: meeting,
            attendanceGroupID: groupID
        )
    }

    private func check(
        _ automation: FakePreflightAutomation,
        schedule: ZoomSchedule? = nil,
        profile: ZoomAccountProfile? = nil,
        group: StudentGroup? = nil
    ) -> PreflightReport {
        PreflightChecker.check(
            schedule: schedule ?? self.schedule(),
            profile: profile ?? self.profile(),
            group: group,
            startsAt: startsAt,
            automation: automation
        )
    }

    func testEverythingReadyReportsNoIssues() {
        let report = check(FakePreflightAutomation(activeEmail: email))
        XCTAssertTrue(report.isReady)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(report.headline, "Saturday DEPI is ready")
    }

    func testMissingAccessibilityIsBlockingAndStopsFurtherChecks() {
        let automation = FakePreflightAutomation(activeEmail: email)
        automation.trusted = false

        let report = check(automation)

        XCTAssertFalse(report.isReady)
        XCTAssertEqual(report.issues.map(\.kind), [.accessibilityMissing])
        XCTAssertEqual(automation.accountMenuReads, 0, "nothing else can be known without it")
    }

    /// Zoom not running is recoverable — the workflow launches it.
    func testZoomNotRunningIsOnlyAWarning() {
        let automation = FakePreflightAutomation(activeEmail: email)
        automation.process = nil

        let report = check(automation)

        XCTAssertTrue(report.isReady)
        XCTAssertEqual(report.warnings.map(\.kind), [.zoomNotRunning])
    }

    /// This is the off-Space case: Zoom is running but answers nothing.
    func testUnreachableZoomIsBlocking() {
        let automation = FakePreflightAutomation(activeEmail: email)
        automation.accountMenuReadable = false

        let report = check(automation)

        XCTAssertFalse(report.isReady)
        XCTAssertEqual(report.blocking.map(\.kind), [.zoomUnreachable])
        XCTAssertNotNil(report.blocking.first?.remedy)
    }

    func testAccountNotSignedInIsBlocking() {
        let report = check(
            FakePreflightAutomation(activeEmail: email),
            profile: profile("nobody@example.com")
        )

        XCTAssertFalse(report.isReady)
        XCTAssertEqual(report.blocking.map(\.kind), [.accountNotFound])
    }

    func testAmbiguousAccountIsBlocking() {
        // Three saved accounts share this display name.
        let report = check(
            FakePreflightAutomation(activeEmail: email),
            profile: profile("eyouth coordinator")
        )

        XCTAssertFalse(report.isReady)
        XCTAssertEqual(report.blocking.map(\.kind), [.accountAmbiguous])
    }

    func testMissingMeetingIDIsBlocking() {
        let report = check(
            FakePreflightAutomation(activeEmail: email),
            schedule: schedule(meeting: MeetingReference(name: "Week 2", kind: .meetingID("   ")))
        )

        XCTAssertFalse(report.isReady)
        XCTAssertTrue(report.blocking.contains { $0.kind == .meetingNotConfigured })
    }

    func testInstantMeetingNeedsNoID() {
        let report = check(
            FakePreflightAutomation(activeEmail: email),
            schedule: schedule(meeting: MeetingReference(name: "Personal", kind: .instantMeeting))
        )
        XCTAssertTrue(report.isReady)
    }

    /// Attendance problems must not stop the meeting from running.
    func testEmptyRosterIsOnlyAWarning() {
        let group = StudentGroup(name: "Group A", students: [])
        let report = check(
            FakePreflightAutomation(activeEmail: email),
            schedule: schedule(groupID: group.id),
            group: group
        )

        XCTAssertTrue(report.isReady)
        XCTAssertEqual(report.warnings.map(\.kind), [.rosterEmpty])
    }

    func testMissingLinkedGroupIsAWarning() {
        let report = check(
            FakePreflightAutomation(activeEmail: email),
            schedule: schedule(groupID: UUID()),
            group: nil
        )

        XCTAssertTrue(report.isReady)
        XCTAssertEqual(report.warnings.map(\.kind), [.noAttendanceGroup])
    }

    func testScheduleWithoutAttendanceSaysNothingAboutRosters() {
        let report = check(FakePreflightAutomation(activeEmail: email), schedule: schedule(groupID: nil))
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testMeetingAlreadyRunningIsAWarning() {
        let automation = FakePreflightAutomation(activeEmail: email)
        automation.meetingActive = true

        let report = check(automation)

        XCTAssertTrue(report.isReady)
        XCTAssertEqual(report.warnings.map(\.kind), [.meetingAlreadyRunning])
    }

    func testSeveralProblemsAreAllReported() {
        let automation = FakePreflightAutomation(activeEmail: email)
        let group = StudentGroup(name: "Group A", students: [])
        let report = check(
            automation,
            schedule: schedule(groupID: group.id, meeting: MeetingReference(name: "W", kind: .meetingID(""))),
            profile: profile("nobody@example.com"),
            group: group
        )

        XCTAssertEqual(Set(report.issues.map(\.kind)), [.meetingNotConfigured, .accountNotFound, .rosterEmpty])
        XCTAssertEqual(report.blocking.count, 2)
        XCTAssertTrue(report.headline.contains("2 problems"))
        XCTAssertTrue(report.detail.contains("—"), "the remedy travels with the message")
    }

    /// Read-only: a check must never start, switch or press anything.
    func testCheckingChangesNothing() {
        let automation = FakePreflightAutomation(activeEmail: email)
        _ = check(automation)

        XCTAssertEqual(automation.startedMeetings, 0)
        XCTAssertEqual(automation.accountSwitches, 0)
        XCTAssertEqual(automation.activations, 0)
    }
}

private final class FakePreflightAutomation: ZoomAutomating {
    var trusted = true
    var process: ZoomProcess? = ZoomProcess(pid: 4242, bundleIdentifier: "us.zoom.xos")
    var accountMenuReadable = true
    var meetingActive = false

    private(set) var accountMenuReads = 0
    private(set) var startedMeetings = 0
    private(set) var accountSwitches = 0
    private(set) var activations = 0

    private let activeEmail: String
    private let savedAccounts: [(display: String, email: String)] = [
        ("eyouth coordinator", "depi+11@eyouthlearning.com"),
        ("Mohamed Hosam", "mohamed.hosam2310@gmail.com"),
        ("eyouth Coordinator", "depi4.2025_45@teml.net"),
        ("eyouth coordinator", "depi+10@eyouthlearning.com")
    ]

    init(activeEmail: String) { self.activeEmail = activeEmail }

    func isAccessibilityTrusted() -> Bool { trusted }
    func zoomProcess() -> ZoomProcess? { process }
    func launchZoom() -> Bool { true }

    func readAccountMenu() -> ZoomAccountSnapshot? {
        accountMenuReads += 1
        guard accountMenuReadable else { return nil }
        let entries = savedAccounts.enumerated().map { index, account in
            AccountMenuEntry(
                rawTitle: "\(account.display)(\(account.email))",
                displayName: account.display,
                email: account.email,
                isActive: account.email == activeEmail,
                enabled: true,
                indexPath: [1, 0, 19, 0, index]
            )
        }
        return ZoomAccountSnapshot(entries: entries, activeAccount: entries.first { $0.isActive })
    }

    func selectAccount(_ entry: AccountMenuEntry) -> AccountSelectionOutcome {
        accountSwitches += 1
        return .pressed
    }

    func meetingPresence(for process: ZoomProcess) -> MeetingPresence {
        ZoomAXSupport.classifyMeetingPresence(
            axWindowTitles: meetingActive ? ["Zoom Meeting"] : ["Zoom Workplace"],
            hasMeetingStructure: false,
            axHierarchyAvailable: true,
            location: .currentSpaceBackground
        )
    }

    func startMeeting(_ meeting: MeetingReference) -> MeetingStartOutcome {
        startedMeetings += 1
        return .requested(method: "test")
    }

    func meetingWindowSignature(for process: ZoomProcess) -> Set<CGWindowID> { [] }
    func isReadyToStartMeeting(for process: ZoomProcess) -> Bool { true }
    func participantsPanelState(for process: ZoomProcess) -> ZoomAXSupport.ParticipantsPanelState { .closed }
    func openParticipantsPanel(for process: ZoomProcess) -> PreJoinActionOutcome { .pressed }
    func preJoinPreview(for process: ZoomProcess) -> PreJoinPreview? { nil }
    func pressPreJoinControl(_ control: PreJoinControl) -> PreJoinActionOutcome { .pressed }
    func pressPreJoinStart() -> PreJoinActionOutcome { .pressed }
    func capturePreJoinDiagnostics(reason: String) {}
    func activateZoom() { activations += 1 }
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(_ interval: TimeInterval) {}
}
