import CoreGraphics
import Foundation
import XCTest
import ZoomAXSupport
@testable import ZoomAutoAdmitCore

/// The pre-join stage of the scheduled workflow: ensure the microphone and
/// camera are off, verify it, and only then press Start.
final class PreJoinWorkflowTests: XCTestCase {
    private let email = "mohamed.hosam2310@gmail.com"

    private func profile() -> ZoomAccountProfile {
        ZoomAccountProfile(name: "Personal", accountIdentifier: "mohamed.hosam2310@gmail.com")
    }

    private func schedule(
        profile: ZoomAccountProfile,
        mutesMicrophone: Bool = true,
        disablesCamera: Bool = true
    ) -> ZoomSchedule {
        ZoomSchedule(
            name: "Personal test",
            recurrence: .daily,
            startTime: TimeOfDay(hour: 18, minute: 0),
            accountProfileID: profile.id,
            meeting: MeetingReference(name: "Personal room", kind: .instantMeeting),
            mutesMicrophoneBeforeJoining: mutesMicrophone,
            disablesCameraBeforeJoining: disablesCamera
        )
    }

    private func makeAutomation() -> FakePreJoinAutomation {
        let automation = FakePreJoinAutomation(activeEmail: email)
        automation.showsPreJoinPreview = true
        return automation
    }

    private func run(
        _ automation: FakePreJoinAutomation,
        schedule: ZoomSchedule,
        profile: ZoomAccountProfile
    ) -> (ZoomWorkflowResult, [ZoomWorkflowState], [String]) {
        var states: [ZoomWorkflowState] = []
        var details: [String] = []
        let runner = ZoomWorkflowRunner(automation: automation, timeouts: .immediate) { state, detail in
            states.append(state)
            if let detail { details.append(detail) }
        }
        let result = runner.run(schedule: schedule, profile: profile)
        return (result, states, details)
    }

    /// Both devices on: both are turned off, verified, then Start is pressed.
    func testBothDevicesOnAreTurnedOffAndVerifiedBeforeStart() {
        let automation = makeAutomation()
        automation.microphoneState = .on
        automation.cameraState = .on
        let target = profile()

        let (result, states, _) = run(automation, schedule: schedule(profile: target), profile: target)

        XCTAssertEqual(result, .completed(autoAdmitStarted: true))
        XCTAssertEqual(automation.pressedPreJoinControls, [.microphone, .camera])
        XCTAssertEqual(automation.startPressCount, 1)

        // The ordering the workflow promises.
        let expected: [ZoomWorkflowState] = [
            .preJoinPreviewDetected,
            .ensuringMicrophoneOff,
            .microphoneOffVerified,
            .ensuringCameraOff,
            .cameraOffVerified,
            .pressingStart
        ]
        for state in expected {
            XCTAssertTrue(states.contains(state), "missing state \(state.rawValue)")
        }
        XCTAssertLessThan(
            states.firstIndex(of: .microphoneOffVerified) ?? .max,
            states.firstIndex(of: .pressingStart) ?? 0,
            "Start must come after the microphone is verified off"
        )
        XCTAssertLessThan(
            states.firstIndex(of: .cameraOffVerified) ?? .max,
            states.firstIndex(of: .pressingStart) ?? 0,
            "Start must come after the camera is verified off"
        )
    }

    /// Already off: nothing is pressed. Blind toggling here would switch a
    /// muted microphone back on.
    func testAlreadyOffDevicesAreNotToggled() {
        let automation = makeAutomation()
        automation.microphoneState = .off
        automation.cameraState = .off
        let target = profile()

        let (result, _, details) = run(automation, schedule: schedule(profile: target), profile: target)

        XCTAssertEqual(result, .completed(autoAdmitStarted: true))
        XCTAssertEqual(automation.pressedPreJoinControls, [], "Nothing may be pressed when already off")
        XCTAssertEqual(automation.startPressCount, 1)
        XCTAssertTrue(details.contains("Microphone state: OFF — no action"))
        XCTAssertTrue(details.contains("Camera state: OFF — no action"))
    }

    func testOnlyTheDeviceThatIsOnGetsPressed() {
        let automation = makeAutomation()
        automation.microphoneState = .on
        automation.cameraState = .off
        let target = profile()

        _ = run(automation, schedule: schedule(profile: target), profile: target)

        XCTAssertEqual(automation.pressedPreJoinControls, [.microphone])
    }

    // MARK: Abort rather than guess

    func testUnknownMicrophoneStateAborts() {
        let automation = makeAutomation()
        automation.microphoneState = .unknown
        let target = profile()

        let (result, _, _) = run(automation, schedule: schedule(profile: target), profile: target)

        XCTAssertEqual(result, .failed(.preJoinStateUnknown(.microphone)))
        XCTAssertEqual(automation.pressedPreJoinControls, [])
        XCTAssertEqual(automation.startPressCount, 0, "Nothing may start with an unreadable microphone")
        XCTAssertFalse(automation.capturedDiagnostics.isEmpty, "The hierarchy should be captured for diagnosis")
    }

    func testUnknownCameraStateAborts() {
        let automation = makeAutomation()
        automation.microphoneState = .off
        automation.cameraState = .unknown
        let target = profile()

        let (result, _, _) = run(automation, schedule: schedule(profile: target), profile: target)

        XCTAssertEqual(result, .failed(.preJoinStateUnknown(.camera)))
        XCTAssertEqual(automation.startPressCount, 0)
    }

    func testMissingMicrophoneControlAborts() {
        let automation = makeAutomation()
        automation.microphonePresent = false
        let target = profile()

        let (result, _, _) = run(automation, schedule: schedule(profile: target), profile: target)

        XCTAssertEqual(result, .failed(.preJoinControlNotFound(.microphone)))
        XCTAssertEqual(automation.startPressCount, 0)
    }

    func testAmbiguousControlAborts() {
        let automation = makeAutomation()
        automation.ambiguousKinds = [.microphone]
        let target = profile()

        let (result, _, _) = run(automation, schedule: schedule(profile: target), profile: target)

        XCTAssertEqual(result, .failed(.preJoinControlAmbiguous(.microphone)))
        XCTAssertEqual(automation.pressedPreJoinControls, [])
    }

    /// Pressed, but Zoom still reports the microphone as live.
    func testMicrophoneThatDoesNotTurnOffAbortsBeforeStart() {
        let automation = makeAutomation()
        automation.microphoneState = .on
        automation.microphoneTogglesCorrectly = false
        let target = profile()

        let (result, _, _) = run(automation, schedule: schedule(profile: target), profile: target)

        XCTAssertEqual(result, .failed(.preJoinNotVerified(.microphone)))
        XCTAssertEqual(automation.startPressCount, 0, "Start must not be pressed with a live microphone")
    }

    func testMissingStartButtonAborts() {
        let automation = makeAutomation()
        automation.microphoneState = .off
        automation.cameraState = .off
        automation.startPresent = false
        let target = profile()

        let (result, _, _) = run(automation, schedule: schedule(profile: target), profile: target)

        XCTAssertEqual(result, .failed(.preJoinStartNotFound))
        XCTAssertFalse(automation.capturedDiagnostics.isEmpty)
    }

    // MARK: Optional behaviour

    func testScheduleCanOptOutOfMutingWithoutAffectingTheCamera() {
        let automation = makeAutomation()
        automation.microphoneState = .on
        automation.cameraState = .on
        let target = profile()

        let (result, _, _) = run(
            automation,
            schedule: schedule(profile: target, mutesMicrophone: false),
            profile: target
        )

        XCTAssertEqual(result, .completed(autoAdmitStarted: true))
        XCTAssertEqual(automation.pressedPreJoinControls, [.camera])
    }

    /// Zoom can be configured to skip the preview entirely; that must go
    /// straight to meeting verification rather than failing.
    func testNoPreviewGoesStraightToTheMeeting() {
        let automation = FakePreJoinAutomation(activeEmail: email)
        automation.showsPreJoinPreview = false
        let target = profile()

        let (result, states, _) = run(automation, schedule: schedule(profile: target), profile: target)

        XCTAssertEqual(result, .completed(autoAdmitStarted: true))
        XCTAssertFalse(states.contains(.preJoinPreviewDetected))
        XCTAssertEqual(automation.startPressCount, 0)
    }

    // MARK: Participants panel

    /// Auto Admit is blind while the panel is closed, so the workflow opens it.
    func testClosedParticipantsPanelIsOpenedAfterTheMeetingStarts() {
        let automation = makeAutomation()
        automation.microphoneState = .off
        automation.cameraState = .off
        automation.participantsPanel = .closed
        let target = profile()

        let (result, states, _) = run(automation, schedule: schedule(profile: target), profile: target)

        XCTAssertEqual(result, .completed(autoAdmitStarted: true))
        XCTAssertEqual(automation.participantsOpenAttempts, 1)
        XCTAssertEqual(automation.participantsPanel, .open)
        XCTAssertTrue(states.contains(.participantsPanelReady))
    }

    /// The same control closes the panel, so an already-open panel is left alone.
    func testOpenParticipantsPanelIsNotToggledShut() {
        let automation = makeAutomation()
        automation.microphoneState = .off
        automation.cameraState = .off
        automation.participantsPanel = .open
        let target = profile()

        _ = run(automation, schedule: schedule(profile: target), profile: target)

        XCTAssertEqual(automation.participantsOpenAttempts, 0)
        XCTAssertEqual(automation.participantsPanel, .open)
    }

    /// The meeting is already running by this point; failing the whole workflow
    /// would help nobody, so this is reported and Auto Admit still starts.
    func testFailureToOpenTheParticipantsPanelIsNotFatal() {
        let automation = makeAutomation()
        automation.microphoneState = .off
        automation.cameraState = .off
        automation.participantsPanel = .closed
        automation.participantsToggleWorks = false
        let target = profile()

        let (result, _, details) = run(automation, schedule: schedule(profile: target), profile: target)

        XCTAssertEqual(result, .completed(autoAdmitStarted: true))
        XCTAssertTrue(
            details.contains { $0.contains("Could not open the Participants panel") },
            "the problem must be reported, got \(details)"
        )
    }

    func testDefaultScheduleTurnsBothDevicesOffAndEnablesAutoAdmit() {
        let schedule = ZoomSchedule(
            name: "Defaults",
            recurrence: .daily,
            startTime: TimeOfDay(hour: 18, minute: 0),
            accountProfileID: UUID(),
            meeting: MeetingReference(name: "M", kind: .instantMeeting)
        )
        XCTAssertTrue(schedule.mutesMicrophoneBeforeJoining)
        XCTAssertTrue(schedule.disablesCameraBeforeJoining)
        XCTAssertTrue(schedule.enablesAutoAdmit)
    }

    /// Schedules written before the pre-join settings existed must load with the
    /// safe defaults rather than failing to decode.
    func testSchedulesSavedBeforePreJoinSettingsStillLoad() throws {
        let json = """
        {
          "accountProfiles": [
            {"id": "\(UUID().uuidString)", "name": "Personal", "accountIdentifier": "a@b.com"}
          ],
          "schedules": [
            {
              "id": "\(UUID().uuidString)",
              "name": "Old schedule",
              "isEnabled": true,
              "recurrence": {"kind": "daily"},
              "startTime": {"hour": 18, "minute": 0},
              "accountProfileID": "\(UUID().uuidString)",
              "meeting": {"name": "M", "kind": {"kind": "instantMeeting"}},
              "enablesAutoAdmit": true,
              "launchZoomMinutesEarly": 2
            }
          ]
        }
        """
        let configuration = try JSONDecoder().decode(
            SchedulerConfiguration.self,
            from: Data(json.utf8)
        )
        let schedule = try XCTUnwrap(configuration.schedules.first)
        XCTAssertTrue(schedule.mutesMicrophoneBeforeJoining)
        XCTAssertTrue(schedule.disablesCameraBeforeJoining)
    }
}

/// Reuses the account behaviour of the main workflow fake and adds pre-join.
private final class FakePreJoinAutomation: ZoomAutomating {
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

    private(set) var pressedPreJoinControls: [PreJoinControlKind] = []
    private(set) var startPressCount = 0
    private(set) var capturedDiagnostics: [String] = []

    private let activeEmail: String
    private var meetingStarted = false
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    init(activeEmail: String) {
        self.activeEmail = activeEmail
    }

    func isAccessibilityTrusted() -> Bool { true }

    func zoomProcess() -> ZoomProcess? { ZoomProcess(pid: 4242, bundleIdentifier: "us.zoom.xos") }

    func launchZoom() -> Bool { true }

    func readAccountMenu() -> ZoomAccountSnapshot? {
        let entry = AccountMenuEntry(
            rawTitle: "Mohamed Hosam(\(activeEmail))",
            displayName: "Mohamed Hosam",
            email: activeEmail,
            isActive: true,
            enabled: true,
            indexPath: [1, 0, 19, 0, 0]
        )
        return ZoomAccountSnapshot(entries: [entry], activeAccount: entry)
    }

    func selectAccount(_ entry: AccountMenuEntry) -> AccountSelectionOutcome { .pressed }

    /// Off-Space meetings are modelled by reporting a new window-server window
    /// while Accessibility still sees nothing.
    var meetingWindowIDs: Set<CGWindowID> = [1]

    func meetingWindowSignature(for process: ZoomProcess) -> Set<CGWindowID> {
        meetingWindowIDs
    }

    func isReadyToStartMeeting(for process: ZoomProcess) -> Bool { true }

    var participantsPanel: ZoomAXSupport.ParticipantsPanelState = .open
    var participantsToggleWorks = true
    private(set) var participantsOpenAttempts = 0

    func participantsPanelState(for process: ZoomProcess) -> ZoomAXSupport.ParticipantsPanelState {
        participantsPanel
    }

    func openParticipantsPanel(for process: ZoomProcess) -> PreJoinActionOutcome {
        participantsOpenAttempts += 1
        guard participantsToggleWorks else {
            return .rejected("the Participants control could not be identified")
        }
        participantsPanel = .open
        return .pressed
    }

    func meetingPresence(for process: ZoomProcess) -> MeetingPresence {
        ZoomAXSupport.classifyMeetingPresence(
            axWindowTitles: meetingStarted ? ["Zoom Meeting"] : ["Zoom Workplace"],
            hasMeetingStructure: false,
            axHierarchyAvailable: true,
            location: .currentSpaceBackground
        )
    }

    func startMeeting(_ meeting: MeetingReference) -> MeetingStartOutcome {
        if showsPreJoinPreview {
            previewOpen = true
        } else {
            meetingStarted = true
        }
        return .requested(method: "test")
    }

    func preJoinPreview(for process: ZoomProcess) -> PreJoinPreview? {
        guard previewOpen else { return nil }
        return ZoomAXSupport.PreJoinPreview(
            windowTitle: "Mohamed Hosam's Zoom Meeting",
            windowIndexPath: [],
            microphone: microphonePresent && !ambiguousKinds.contains(.microphone)
                ? ZoomAXSupport.PreJoinControl(
                    kind: .microphone,
                    state: microphoneState,
                    matchedText: microphoneState == .on ? "Mute" : "Unmute",
                    evidence: "AXDescription",
                    enabled: true,
                    indexPath: [0]
                )
                : nil,
            camera: cameraPresent && !ambiguousKinds.contains(.camera)
                ? ZoomAXSupport.PreJoinControl(
                    kind: .camera,
                    state: cameraState,
                    matchedText: cameraState == .on ? "Stop Video" : "Start Video",
                    evidence: "AXDescription",
                    enabled: true,
                    indexPath: [1]
                )
                : nil,
            start: startPresent
                ? ZoomAXSupport.PreJoinStartControl(matchedText: "Start", enabled: true, indexPath: [2])
                : nil,
            ambiguousKinds: ambiguousKinds
        )
    }

    func pressPreJoinControl(_ control: PreJoinControl) -> PreJoinActionOutcome {
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
        startPressCount += 1
        previewOpen = false
        meetingStarted = true
        return .pressed
    }

    func capturePreJoinDiagnostics(reason: String) {
        capturedDiagnostics.append(reason)
    }

    func activateZoom() {}

    func now() -> Date { clock }

    func sleep(_ interval: TimeInterval) {
        clock = clock.addingTimeInterval(max(interval, 0.05))
    }
}
