import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
import ZoomAXSupport
@testable import ZoomAutoAdmitCore

final class ZoomWorkflowTests: XCTestCase {
    private let depiEmail = "depi+11@eyouthlearning.com"
    private let otherEmail = "mohamed.hosam2310@gmail.com"

    private func profile(_ identifier: String) -> ZoomAccountProfile {
        ZoomAccountProfile(name: "DEPI", accountIdentifier: identifier)
    }

    private func schedule(
        profile: ZoomAccountProfile,
        meeting: MeetingReference = MeetingReference(name: "Week 2 Saturday", kind: .meetingID("123 4567 8901")),
        autoAdmit: Bool = true
    ) -> ZoomSchedule {
        ZoomSchedule(
            name: "Saturday DEPI",
            recurrence: .selectedWeekdays([.saturday]),
            startTime: TimeOfDay(hour: 18, minute: 0),
            accountProfileID: profile.id,
            meeting: meeting,
            enablesAutoAdmit: autoAdmit
        )
    }

    private func run(
        _ automation: FakeZoomAutomation,
        profile: ZoomAccountProfile,
        schedule: ZoomSchedule
    ) -> (result: ZoomWorkflowResult, states: [ZoomWorkflowState]) {
        var states: [ZoomWorkflowState] = []
        let runner = ZoomWorkflowRunner(
            automation: automation,
            timeouts: .immediate
        ) { state, _ in states.append(state) }
        let result = runner.run(schedule: schedule, profile: profile)
        return (result, states)
    }

    // MARK: Account handling

    /// 3. The required account is already signed in, so nothing is pressed.
    func testCorrectAccountAlreadyActiveDoesNotSwitch() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        let target = profile(depiEmail)

        let (result, states) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .completed(autoAdmitStarted: true))
        XCTAssertEqual(automation.selectedAccounts, [])
        XCTAssertFalse(states.contains(.switchingAccount))
    }

    /// 4. The wrong account is active, so exactly the configured one is pressed.
    func testWrongAccountSwitchesToTheExactConfiguredAccount() {
        let automation = FakeZoomAutomation(activeEmail: otherEmail)
        automation.activeEmailAfterSelection = depiEmail
        let target = profile(depiEmail)

        let (result, states) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .completed(autoAdmitStarted: true))
        XCTAssertEqual(automation.selectedAccounts, [depiEmail])
        XCTAssertTrue(states.contains(.switchingAccount))
        XCTAssertTrue(states.contains(.verifyingAccount))
    }

    /// 5. The switch is pressed but the active account does not change: the
    /// meeting must not be started.
    func testAccountSwitchVerificationFailureStopsBeforeTheMeeting() {
        let automation = FakeZoomAutomation(activeEmail: otherEmail)
        automation.activeEmailAfterSelection = otherEmail // the switch silently fails
        let target = profile(depiEmail)

        let (result, _) = run(automation, profile: target, schedule: schedule(profile: target))

        guard case .failed(.accountSwitchNotVerified(let expected, let actual)) = result else {
            return XCTFail("Expected a verification failure, got \(result)")
        }
        XCTAssertEqual(expected, depiEmail)
        XCTAssertEqual(actual, otherEmail)
        XCTAssertTrue(automation.startedMeetings.isEmpty, "A wrong account must never start the meeting")
    }

    func testRejectedAccountPressStopsBeforeTheMeeting() {
        let automation = FakeZoomAutomation(activeEmail: otherEmail)
        automation.selectionOutcome = .rejected("menu item identifier changed")
        let target = profile(depiEmail)

        let (result, _) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .failed(.accountSwitchRejected("menu item identifier changed")))
        XCTAssertTrue(automation.startedMeetings.isEmpty)
    }

    /// 6. Several saved accounts match, so the workflow aborts instead of guessing.
    func testAmbiguousAccountMatchAborts() {
        let automation = FakeZoomAutomation(activeEmail: otherEmail)
        let target = profile("eyouth coordinator") // three accounts share this display name

        let (result, _) = run(automation, profile: target, schedule: schedule(profile: target))

        guard case .failed(.accountAmbiguous(_, let matches)) = result else {
            return XCTFail("Expected ambiguity, got \(result)")
        }
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(automation.selectedAccounts, [])
        XCTAssertTrue(automation.startedMeetings.isEmpty)
    }

    func testUnknownAccountAborts() {
        let automation = FakeZoomAutomation(activeEmail: otherEmail)
        let target = profile("nobody@example.com")

        let (result, _) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .failed(.accountNotFound("nobody@example.com")))
        XCTAssertTrue(automation.startedMeetings.isEmpty)
    }

    func testUnreadableAccountMenuAborts() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        automation.accountMenuReadable = false
        let target = profile(depiEmail)

        let (result, _) = run(automation, profile: target, schedule: schedule(profile: target))

        // Zoom never becomes ready, so the workflow stops at the UI wait.
        XCTAssertEqual(result, .failed(.zoomUIUnavailable))
        XCTAssertTrue(automation.startedMeetings.isEmpty)
    }

    // MARK: Meeting handling

    /// 7. The configured meeting is started, by ID, exactly as configured.
    func testConfiguredMeetingIsStartedByID() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        let target = profile(depiEmail)

        let (result, _) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .completed(autoAdmitStarted: true))
        XCTAssertEqual(automation.startedMeetings.count, 1)
        XCTAssertEqual(automation.startedMeetings.first?.kind, .meetingID("123 4567 8901"))
    }

    /// 8. A meeting with no usable identifier is never started.
    func testMissingMeetingIDAborts() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        let target = profile(depiEmail)
        let empty = schedule(
            profile: target,
            meeting: MeetingReference(name: "Week 2 Saturday", kind: .meetingID("   "))
        )

        let (result, _) = run(automation, profile: target, schedule: empty)

        XCTAssertEqual(result, .failed(.meetingNotConfigured("meeting ID has no digits")))
        XCTAssertTrue(automation.startedMeetings.isEmpty)
    }

    /// 9. Zoom refusing the start request aborts rather than trying something else.
    /// With ID-based starting there is no meeting list to be ambiguous about;
    /// the ambiguity guard lives on accounts, where collisions genuinely occur.
    func testRejectedMeetingStartAborts() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        automation.meetingStartOutcome = .rejected("Zoom has no Start meeting menu item")
        let target = profile(depiEmail)

        let (result, _) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .failed(.meetingStartRejected("Zoom has no Start meeting menu item")))
    }

    /// 10. The press succeeded but no meeting appeared.
    func testStartPressWithoutAMeetingWindowFails() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        automation.meetingBecomesActive = false
        let target = profile(depiEmail)

        let (result, states) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .failed(.meetingNotVerified))
        XCTAssertTrue(states.contains(.verifyingMeeting))
        XCTAssertFalse(states.contains(.monitoringWaitingRoom), "Auto Admit must not start unverified")
    }

    /// 11. A verified meeting hands over to the existing Auto Admit monitor.
    func testVerifiedMeetingHandsOverToAutoAdmit() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        let target = profile(depiEmail)

        let (result, states) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .completed(autoAdmitStarted: true))
        XCTAssertEqual(states.last, .completed)
        XCTAssertTrue(states.contains(.monitoringWaitingRoom))
    }

    func testScheduleWithAutoAdmitOffStartsTheMeetingWithoutMonitoring() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        let target = profile(depiEmail)

        let (result, states) = run(
            automation,
            profile: target,
            schedule: schedule(profile: target, autoAdmit: false)
        )

        XCTAssertEqual(result, .completed(autoAdmitStarted: false))
        XCTAssertFalse(states.contains(.monitoringWaitingRoom))
    }

    func testInstantMeetingUsesTheZoomMenuInsteadOfAnID() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        let target = profile(depiEmail)

        let (result, _) = run(
            automation,
            profile: target,
            schedule: schedule(
                profile: target,
                meeting: MeetingReference(name: "Personal room", kind: .instantMeeting)
            )
        )

        XCTAssertEqual(result, .completed(autoAdmitStarted: true))
        XCTAssertEqual(automation.startedMeetings.first?.kind, .instantMeeting)
    }

    // MARK: Safety

    /// 12. A call already in progress is never disturbed.
    func testExistingActiveMeetingIsNotDisrupted() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        automation.meetingActiveFromTheStart = true
        let target = profile(depiEmail)

        let (result, states) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .failed(.anotherMeetingActive))
        XCTAssertTrue(automation.startedMeetings.isEmpty, "No second meeting may be started")
        XCTAssertEqual(automation.selectedAccounts, [], "No account may be switched under a live call")
        XCTAssertEqual(automation.activateCount, 0, "A live call must not even be brought forward")
        XCTAssertFalse(states.contains(.monitoringWaitingRoom))
    }

    /// Regression test for a live failure: switching accounts makes Zoom sign
    /// out and back in, which restarts the process under a new pid. The workflow
    /// kept using the pid captured before the switch, so every later
    /// Accessibility call went to a dead process and a perfectly good start
    /// request was reported as "The meeting did not start".
    func testZoomRestartingForTheAccountSwitchIsFollowedToItsNewProcess() {
        let automation = FakeZoomAutomation(activeEmail: otherEmail)
        automation.activeEmailAfterSelection = depiEmail
        automation.pidAfterAccountSwitch = 5150
        let target = profile(depiEmail)

        let (result, _) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .completed(autoAdmitStarted: true))
        XCTAssertEqual(
            automation.processUsedForStart?.pid,
            5150,
            "The meeting must be started against the process Zoom restarted into"
        )
    }

    /// Regression test for a live failure: the meeting really started, but its
    /// window opened on another Desktop where Accessibility cannot see it, so
    /// the workflow reported "The meeting did not start" for a running meeting
    /// and never handed over to Auto Admit.
    func testMeetingOnAnotherDesktopIsVerifiedByItsNewWindow() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        // Accessibility never sees the meeting: only the home window is listed.
        automation.meetingBecomesActive = false
        automation.windowIDsAfterStart = [1, 99]
        let target = profile(depiEmail)

        let (result, states) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .completed(autoAdmitStarted: true))
        XCTAssertTrue(states.contains(.meetingStarted))
        XCTAssertTrue(states.contains(.monitoringWaitingRoom))
    }

    /// The converse: nothing new appeared and Accessibility saw nothing either,
    /// so the failure must still be reported rather than assumed successful.
    func testNoNewWindowAndNoAccessibilityEvidenceStillFails() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        automation.meetingBecomesActive = false
        automation.windowIDsAfterStart = [1]
        let target = profile(depiEmail)

        let (result, _) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .failed(.meetingNotVerified))
    }

    func testUntrustedAccessibilityStopsImmediately() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        automation.trusted = false
        let target = profile(depiEmail)

        let (result, _) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .failed(.accessibilityNotTrusted))
        XCTAssertEqual(automation.accountMenuReads, 0)
    }

    func testZoomIsLaunchedWhenNotRunning() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        automation.process = nil
        automation.processAppearsAfterLaunch = true
        let target = profile(depiEmail)

        let (result, states) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .completed(autoAdmitStarted: true))
        XCTAssertEqual(automation.launchCount, 1)
        XCTAssertTrue(states.contains(.launchingZoom))
        XCTAssertTrue(states.contains(.waitingForZoom))
    }

    func testZoomThatNeverLaunchesFails() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        automation.process = nil
        automation.canLaunch = false
        let target = profile(depiEmail)

        let (result, _) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .failed(.zoomWouldNotLaunch))
    }

    /// 16. Zoom sitting in the background, covered, with its windows on another
    /// Space is exactly the state discovery found it in. The workflow reads the
    /// menu bar, which stays available, and never asks whether Zoom is frontmost.
    func testWorkflowRunsWithZoomBackgroundedAndWindowsOffSpace() {
        let automation = FakeZoomAutomation(activeEmail: otherEmail)
        automation.activeEmailAfterSelection = depiEmail
        automation.windowsAvailable = false
        let target = profile(depiEmail)

        let (result, _) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .completed(autoAdmitStarted: true))
        XCTAssertEqual(automation.selectedAccounts, [depiEmail])
    }

    /// A meeting state that stays unreadable must stop the workflow, never fall
    /// through into starting a meeting on top of a possible live call.
    func testUnresolvableMeetingStateStopsTheWorkflow() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        automation.windowsAvailable = false
        automation.activationRevealsWindows = false
        let target = profile(depiEmail)

        let (result, _) = run(automation, profile: target, schedule: schedule(profile: target))

        XCTAssertEqual(result, .failed(.meetingStateUnknown))
        XCTAssertTrue(automation.startedMeetings.isEmpty)
    }

    /// Zoom is only ever brought forward for the two steps that need it, and the
    /// handover to Auto Admit adds no further activation.
    func testZoomIsActivatedOnlyForSwitchingAndStarting() {
        let automation = FakeZoomAutomation(activeEmail: depiEmail)
        let target = profile(depiEmail)

        _ = run(automation, profile: target, schedule: schedule(profile: target))
        XCTAssertEqual(automation.activateCount, 1, "Only the meeting start needed the foreground")

        let switching = FakeZoomAutomation(activeEmail: otherEmail)
        switching.activeEmailAfterSelection = depiEmail
        _ = run(switching, profile: target, schedule: schedule(profile: target))
        XCTAssertEqual(switching.activateCount, 2, "Account switch plus meeting start")
    }
}

/// Records every outward action, and offers no way at all to end a meeting,
/// sign out, or leave a call.
private final class FakeZoomAutomation: ZoomAutomating {
    var trusted = true
    var process: ZoomProcess? = ZoomProcess(pid: 4242, bundleIdentifier: "us.zoom.xos")
    var canLaunch = true
    var processAppearsAfterLaunch = false
    var accountMenuReadable = true
    var windowsAvailable = true
    var activationRevealsWindows = true
    var meetingActiveFromTheStart = false
    var meetingBecomesActive = true
    var selectionOutcome: AccountSelectionOutcome = .pressed
    var meetingStartOutcome: MeetingStartOutcome?
    var activeEmailAfterSelection: String?

    private(set) var selectedAccounts: [String] = []
    private(set) var startedMeetings: [MeetingReference] = []
    private(set) var activateCount = 0
    private(set) var launchCount = 0
    private(set) var accountMenuReads = 0

    private var activeEmail: String
    private var meetingStarted = false
    var showsPreJoinPreview = false
    var previewOpen = false
    var microphonePresent = true
    var cameraPresent = true
    var startPresent = true
    var microphoneState: ToggleState = .on
    var cameraState: ToggleState = .on
    var microphoneTogglesCorrectly = true
    var cameraTogglesCorrectly = true
    var ambiguousKinds: Set<PreJoinControlKind> = []
    var preJoinPressOutcome: PreJoinActionOutcome?
    var startPressOutcome: PreJoinActionOutcome?
    private(set) var pressedPreJoinControls: [PreJoinControlKind] = []
    private(set) var startPressCount = 0
    private(set) var capturedDiagnostics: [String] = []
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    /// Mirrors the five accounts captured from the live Zoom client, including
    /// the three that share the display name "eyouth coordinator".
    private let savedAccounts: [(display: String, email: String)] = [
        ("eyouth coordinator", "depi+11@eyouthlearning.com"),
        ("Mohamed Hosam", "mohamed.hosam2310@gmail.com"),
        ("eyouth Coordinator", "depi4.2025_45@teml.net"),
        ("deci+50 deci+50", "deci+50@eyouthlearning.com"),
        ("eyouth coordinator", "depi+10@eyouthlearning.com")
    ]

    init(activeEmail: String) {
        self.activeEmail = activeEmail
    }

    func isAccessibilityTrusted() -> Bool { trusted }

    func zoomProcess() -> ZoomProcess? { process }

    func launchZoom() -> Bool {
        launchCount += 1
        guard canLaunch else { return false }
        if processAppearsAfterLaunch {
            process = ZoomProcess(pid: 4242, bundleIdentifier: "us.zoom.xos")
        }
        return true
    }

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
                indexPath: [1, 0, 4, 0, index]
            )
        }
        return ZoomAccountSnapshot(
            entries: entries,
            activeAccount: entries.first { $0.isActive }
        )
    }

    func selectAccount(_ entry: AccountMenuEntry) -> AccountSelectionOutcome {
        guard case .pressed = selectionOutcome else { return selectionOutcome }
        selectedAccounts.append(entry.email ?? entry.rawTitle)
        if let activeEmailAfterSelection {
            activeEmail = activeEmailAfterSelection
        }
        // Zoom relaunches under a new pid to complete an account switch.
        if let pidAfterAccountSwitch {
            process = ZoomProcess(pid: pidAfterAccountSwitch, bundleIdentifier: "us.zoom.xos")
        }
        return .pressed
    }

    /// Off-Space meetings are modelled by reporting a new window-server window
    /// while Accessibility still sees nothing.
    var meetingWindowIDs: Set<CGWindowID> = [1]
    /// Window-server state once the start request has been made.
    var windowIDsAfterStart: Set<CGWindowID>?
    var pidAfterAccountSwitch: pid_t?
    private(set) var processUsedForStart: ZoomProcess?

    func meetingWindowSignature(for process: ZoomProcess) -> Set<CGWindowID> {
        meetingWindowIDs
    }

    func isReadyToStartMeeting(for process: ZoomProcess) -> Bool { true }

    func meetingPresence(for process: ZoomProcess) -> MeetingPresence {
        // A pid that no longer exists can answer nothing at all.
        guard process.pid == self.process?.pid else {
            return ZoomAXSupport.classifyMeetingPresence(
                axWindowTitles: [],
                hasMeetingStructure: false,
                axHierarchyAvailable: false,
                location: .notFound
            )
        }
        processUsedForStart = process
        let active = meetingActiveFromTheStart || meetingStarted
        return ZoomAXSupport.classifyMeetingPresence(
            axWindowTitles: active ? ["Zoom Meeting"] : ["Zoom Workplace"],
            hasMeetingStructure: false,
            // Off-Space Zoom exposes no windows to Accessibility at all.
            axHierarchyAvailable: windowsAvailable,
            location: windowsAvailable ? .currentSpaceBackground : .otherSpaceOrFullscreen
        )
    }

    func startMeeting(_ meeting: MeetingReference) -> MeetingStartOutcome {
        if let meetingStartOutcome, case .rejected = meetingStartOutcome {
            return meetingStartOutcome
        }
        startedMeetings.append(meeting)
        if let windowIDsAfterStart { meetingWindowIDs = windowIDsAfterStart }
        if showsPreJoinPreview {
            previewOpen = true
        } else if meetingBecomesActive {
            meetingStarted = true
        }
        return meetingStartOutcome ?? .requested(method: "test")
    }

    func preJoinPreview(for process: ZoomProcess) -> PreJoinPreview? {
        guard previewOpen else { return nil }
        return ZoomAXSupport.PreJoinPreview(
            windowTitle: "Mohamed Hosam's Zoom Meeting",
            windowIndexPath: [],
            microphone: microphoneControl,
            camera: cameraControl,
            start: startControl,
            ambiguousKinds: ambiguousKinds
        )
    }

    func pressPreJoinControl(_ control: PreJoinControl) -> PreJoinActionOutcome {
        if let outcome = preJoinPressOutcome, case .rejected = outcome { return outcome }
        pressedPreJoinControls.append(control.kind)
        switch control.kind {
        case .microphone:
            if microphoneTogglesCorrectly { microphoneState = .off }
        case .camera:
            if cameraTogglesCorrectly { cameraState = .off }
        }
        return .pressed
    }

    func pressPreJoinStart() -> PreJoinActionOutcome {
        if let outcome = startPressOutcome, case .rejected = outcome { return outcome }
        startPressCount += 1
        previewOpen = false
        if meetingBecomesActive { meetingStarted = true }
        return .pressed
    }

    func capturePreJoinDiagnostics(reason: String) {
        capturedDiagnostics.append(reason)
    }

    private var microphoneControl: PreJoinControl? {
        guard microphonePresent else { return nil }
        return ZoomAXSupport.PreJoinControl(
            kind: .microphone,
            state: microphoneState,
            matchedText: microphoneState == .on ? "Mute" : "Unmute",
            evidence: "AXDescription",
            enabled: true,
            indexPath: [0]
        )
    }

    private var cameraControl: PreJoinControl? {
        guard cameraPresent else { return nil }
        return ZoomAXSupport.PreJoinControl(
            kind: .camera,
            state: cameraState,
            matchedText: cameraState == .on ? "Stop Video" : "Start Video",
            evidence: "AXDescription",
            enabled: true,
            indexPath: [1]
        )
    }

    private var startControl: ZoomAXSupport.PreJoinStartControl? {
        guard startPresent else { return nil }
        return ZoomAXSupport.PreJoinStartControl(matchedText: "Start", enabled: true, indexPath: [2])
    }

    /// Bringing Zoom forward also brings its Space forward, which is what makes
    /// its windows readable again.
    func activateZoom() {
        activateCount += 1
        if activationRevealsWindows { windowsAvailable = true }
    }

    func now() -> Date { clock }

    func sleep(_ interval: TimeInterval) {
        // Virtual time: the runner's bounded waits terminate without real delay.
        clock = clock.addingTimeInterval(max(interval, 0.05))
    }
}
