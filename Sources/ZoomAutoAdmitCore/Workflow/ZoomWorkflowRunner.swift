import Foundation
import ZoomAXSupport

/// The scheduled-start state machine.
///
/// Every step is condition-based: the runner waits for an expected Accessibility
/// condition to become true within a bounded timeout, rather than sleeping for a
/// fixed guess. Any step that cannot be verified stops the workflow instead of
/// carrying on with a wrong account or a meeting that never started.
public final class ZoomWorkflowRunner {
    public typealias StateObserver = (ZoomWorkflowState, String?) -> Void

    private let automation: ZoomAutomating
    private let timeouts: ZoomWorkflowTimeouts
    private let observer: StateObserver
    private(set) public var state: ZoomWorkflowState = .idle

    public init(
        automation: ZoomAutomating,
        timeouts: ZoomWorkflowTimeouts = ZoomWorkflowTimeouts(),
        observer: @escaping StateObserver = { _, _ in }
    ) {
        self.automation = automation
        self.timeouts = timeouts
        self.observer = observer
    }

    public func run(schedule: ZoomSchedule, profile: ZoomAccountProfile) -> ZoomWorkflowResult {
        transition(to: .scheduleTriggered, detail: "Schedule \(schedule.name)")

        guard automation.isAccessibilityTrusted() else {
            return fail(.accessibilityNotTrusted)
        }

        // 1. Zoom must be running.
        guard var process = ensureZoomRunning() else {
            return fail(state == .launchingZoom ? .zoomWouldNotLaunch : .zoomUIUnavailable)
        }

        // 2. Refuse to disturb a call that is already in progress.
        transition(to: .checkingAccount, detail: "Checking whether a meeting is already running")
        switch resolveMeetingState(process: process) {
        case .active:
            return fail(.anotherMeetingActive)
        case .unknown:
            return fail(.meetingStateUnknown)
        case .notActive:
            break
        }

        // 3. Account.
        switch ensureAccount(profile: profile) {
        case .failure(let failure):
            return fail(failure)
        case .success:
            break
        }

        // Switching accounts makes Zoom sign out and back in, which restarts the
        // process. Everything after this point must address the *new* pid:
        // holding the old one sends every later Accessibility call to a dead
        // process, which looks exactly like "the meeting never started".
        guard let settled = waitForStableZoomProcess(previous: process) else {
            return fail(.zoomUIUnavailable)
        }
        process = settled

        // 4. Meeting.
        transition(to: .findingMeeting, detail: schedule.meeting.displayText)
        if case .meetingID(let raw) = schedule.meeting.kind,
           MeetingReference.normalizedMeetingID(raw).isEmpty {
            return fail(.meetingNotConfigured("meeting ID has no digits"))
        }

        transition(to: .startingMeeting, detail: "Starting \(schedule.meeting.name)")
        // Baseline of Zoom's meeting-sized windows, so a window that appears in
        // response to the start request can be recognised even when it opens on
        // another Space where Accessibility cannot follow it.
        let windowsBeforeStart = automation.meetingWindowSignature(for: process)
        // Starting a meeting is the one step that genuinely needs Zoom in front.
        automation.activateZoom()
        switch automation.startMeeting(schedule.meeting) {
        case .rejected(let reason):
            return fail(.meetingStartRejected(reason))
        case .requested(let method):
            transition(to: .verifyingMeeting, detail: "Start requested via \(method)")
        }

        // 5. Zoom usually shows a join preview before the meeting begins. It is
        // not guaranteed — the preview can be switched off in Zoom's settings —
        // so this waits for *either* the preview or a meeting, and only handles
        // the preview if one actually appears. The wait is short because a
        // preview that is coming appears within a second or two; spending the
        // full meeting timeout here only delays the real verification.
        _ = waitUntil(timeout: timeouts.preJoinAppearance) { [automation] in
            automation.preJoinPreview(for: process) != nil
                || automation.meetingPresence(for: process).state == .active
        }

        if automation.meetingPresence(for: process).state != .active,
           automation.preJoinPreview(for: process) != nil {
            if case .failure(let failure) = handlePreJoinPreview(schedule: schedule) {
                return fail(failure)
            }
        }

        // 6. A successful press proves nothing; wait for real meeting evidence.
        //
        // Two independent kinds of evidence are accepted, because Accessibility
        // alone is not enough: when the meeting window opens on another Desktop
        // it never enters Zoom's AXWindows, and waiting only for an AX title
        // reports "the meeting did not start" for a meeting that is plainly
        // running. The window server still sees that window.
        var verifiedBy: String?
        let started = waitUntil(timeout: timeouts.meetingStart) { [automation] in
            let presence = automation.meetingPresence(for: process)
            if presence.state == .active {
                verifiedBy = presence.evidenceDescription
                return true
            }
            let newWindows = automation.meetingWindowSignature(for: process)
                .subtracting(windowsBeforeStart)
            if !newWindows.isEmpty {
                verifiedBy = "new-meeting-window(\(newWindows.count))"
                return true
            }
            return false
        }
        guard started else {
            return fail(.meetingNotVerified)
        }
        transition(to: .meetingStarted, detail: "Meeting verified (\(verifiedBy ?? "unknown"))")

        guard schedule.enablesAutoAdmit else {
            transition(to: .completed, detail: "Meeting started; Auto Admit off for this schedule")
            state = .completed
            return .completed(autoAdmitStarted: false)
        }

        transition(to: .monitoringWaitingRoom, detail: "Handing over to Auto Admit")
        transition(to: .autoAdmitStarted, detail: "Auto Admit active")
        transition(to: .completed, detail: "Workflow completed")
        state = .completed
        return .completed(autoAdmitStarted: true)
    }

    // MARK: Pre-join preview

    /// Ensures the microphone and camera are off before the meeting is started.
    ///
    /// Zoom labels these controls with the action they perform rather than the
    /// state they are in, so every decision here is made from the control's own
    /// accessible text and re-checked after pressing. Anything that cannot be
    /// read confidently aborts the workflow: the failure mode of guessing is an
    /// open microphone in a live meeting.
    private func handlePreJoinPreview(schedule: ZoomSchedule) -> Result<Void, ZoomWorkflowFailure> {
        transition(to: .preJoinPreviewDetected, detail: "Pre-join preview detected")

        if schedule.mutesMicrophoneBeforeJoining {
            if case .failure(let failure) = ensureDeviceOff(
                kind: .microphone,
                working: .ensuringMicrophoneOff,
                verified: .microphoneOffVerified
            ) {
                return .failure(failure)
            }
        } else {
            observer(.preJoinPreviewDetected, "Microphone: left as-is for this schedule")
        }

        if schedule.disablesCameraBeforeJoining {
            if case .failure(let failure) = ensureDeviceOff(
                kind: .camera,
                working: .ensuringCameraOff,
                verified: .cameraOffVerified
            ) {
                return .failure(failure)
            }
        } else {
            observer(.preJoinPreviewDetected, "Camera: left as-is for this schedule")
        }

        // Only now is Start allowed to be pressed.
        guard let preview = currentPreview() else {
            return .failure(.preJoinPreviewLost)
        }
        guard let start = preview.start else {
            automation.capturePreJoinDiagnostics(reason: "Start button not identified")
            return .failure(.preJoinStartNotFound)
        }
        guard start.enabled else {
            return .failure(.preJoinStartRejected("the Start button is disabled"))
        }

        observer(.pressingStart, "Start button found")
        transition(to: .pressingStart, detail: "Pressing Start")
        switch automation.pressPreJoinStart() {
        case .pressed:
            return .success(())
        case .rejected(let reason):
            automation.capturePreJoinDiagnostics(reason: "Start press rejected: \(reason)")
            return .failure(.preJoinStartRejected(reason))
        }
    }

    private func ensureDeviceOff(
        kind: PreJoinControlKind,
        working: ZoomWorkflowState,
        verified verifiedState: ZoomWorkflowState
    ) -> Result<Void, ZoomWorkflowFailure> {
        guard let preview = currentPreview() else {
            return .failure(.preJoinPreviewLost)
        }
        guard !preview.ambiguousKinds.contains(kind) else {
            automation.capturePreJoinDiagnostics(reason: "\(kind.displayName) ambiguous")
            return .failure(.preJoinControlAmbiguous(kind))
        }
        guard let control = preview.control(for: kind) else {
            automation.capturePreJoinDiagnostics(reason: "\(kind.displayName) control not found")
            return .failure(.preJoinControlNotFound(kind))
        }

        switch control.state {
        case .off:
            observer(working, "\(kind.displayName) state: OFF — no action")
            transition(to: verifiedState, detail: "\(kind.displayName) already off")
            return .success(())

        case .unknown:
            automation.capturePreJoinDiagnostics(reason: "\(kind.displayName) state unknown")
            return .failure(.preJoinStateUnknown(kind))

        case .on:
            observer(working, "\(kind.displayName) state: ON")
            transition(to: working, detail: "Turning \(kind.displayName.lowercased()) OFF")
            switch automation.pressPreJoinControl(control) {
            case .rejected(let reason):
                automation.capturePreJoinDiagnostics(reason: "\(kind.displayName) press rejected: \(reason)")
                return .failure(.preJoinPressRejected(kind, reason))
            case .pressed:
                break
            }

            // Re-read rather than assume the press did what it claimed.
            let becameOff = waitUntil(timeout: timeouts.accountSwitch) { [weak self] in
                self?.currentPreview()?.control(for: kind)?.state == .off
            }
            guard becameOff else {
                automation.capturePreJoinDiagnostics(reason: "\(kind.displayName) did not turn off")
                return .failure(.preJoinNotVerified(kind))
            }
            observer(verifiedState, "\(kind.displayName) state verified: OFF")
            transition(to: verifiedState, detail: "\(kind.displayName) off")
            return .success(())
        }
    }

    private func currentPreview() -> PreJoinPreview? {
        guard let process = automation.zoomProcess() else { return nil }
        return automation.preJoinPreview(for: process)
    }

    // MARK: Steps

    /// Answers "is a meeting already running?" definitively, or not at all.
    ///
    /// When Zoom's windows are on another Space its Accessibility hierarchy is
    /// unreachable and the honest answer is `unknown`. Rather than guess in
    /// either direction — starting a second meeting on top of a live call, or
    /// refusing to ever run because Zoom happens to be on another Desktop — the
    /// workflow spends its one permitted foreground interruption on bringing
    /// Zoom forward, then asks again. If it still cannot tell, it stops.
    private func resolveMeetingState(process: ZoomProcess) -> ZoomAXSupport.MeetingPresenceState {
        let initial = automation.meetingPresence(for: process)
        if initial.state != .unknown {
            observer(
                .checkingAccount,
                "Meeting state: \(initial.state.rawValue) (\(initial.evidenceDescription))"
            )
            return initial.state
        }

        observer(
            .checkingAccount,
            "Meeting state unreadable (\(initial.location.rawValue)); bringing Zoom forward to resolve it"
        )
        automation.activateZoom()
        _ = waitUntil(timeout: timeouts.zoomUIReady) { [automation] in
            automation.meetingPresence(for: process).state != .unknown
        }

        let resolved = automation.meetingPresence(for: process)
        observer(
            .checkingAccount,
            "Meeting state after exposing Zoom: \(resolved.state.rawValue) (\(resolved.evidenceDescription))"
        )
        return resolved.state
    }

    private func ensureZoomRunning() -> ZoomProcess? {
        if let process = automation.zoomProcess() {
            // Zoom is up, but its Accessibility hierarchy may still be building.
            transition(to: .waitingForZoom, detail: "Waiting for Zoom UI…")
            return waitForZoomUI(process: process)
        }

        transition(to: .launchingZoom, detail: "Launching Zoom…")
        guard automation.launchZoom() else { return nil }

        transition(to: .waitingForZoom, detail: "Waiting for Zoom UI…")
        var launched: ZoomProcess?
        let appeared = waitUntil(timeout: timeouts.zoomLaunch) { [automation] in
            launched = automation.zoomProcess()
            return launched != nil
        }
        guard appeared, let launched else { return nil }
        return waitForZoomUI(process: launched)
    }

    /// Re-resolves Zoom after the account step and waits for it to settle.
    ///
    /// Returns the current process once it answers its account menu again. When
    /// the pid changed, Zoom restarted for the account switch and needs a moment
    /// before it will act on a start request at all.
    private func waitForStableZoomProcess(previous: ZoomProcess) -> ZoomProcess? {
        var resolved: ZoomProcess?
        let ready = waitUntil(timeout: timeouts.zoomUIReady) { [automation] in
            guard let current = automation.zoomProcess() else { return false }
            guard let snapshot = automation.readAccountMenu(), !snapshot.entries.isEmpty else {
                return false
            }
            resolved = current
            return true
        }
        guard ready, let resolved else { return nil }

        if resolved.pid != previous.pid {
            observer(
                .verifyingAccount,
                "Zoom restarted for the account switch (pid \(previous.pid) → \(resolved.pid)); reconnecting"
            )
            // A client that has just relaunched will silently drop a start
            // request, so wait until it reports itself ready to start one.
            _ = waitUntil(timeout: timeouts.zoomUIReady) { [automation] in
                automation.isReadyToStartMeeting(for: resolved)
            }
        }
        return resolved
    }

    /// "Ready" means Zoom answers the menu that the workflow actually needs.
    /// Window availability is deliberately not required: during discovery every
    /// Zoom window was on another Space while the menu bar stayed readable.
    private func waitForZoomUI(process: ZoomProcess) -> ZoomProcess? {
        let ready = waitUntil(timeout: timeouts.zoomUIReady) { [automation] in
            guard let snapshot = automation.readAccountMenu() else { return false }
            return !snapshot.entries.isEmpty
        }
        return ready ? process : nil
    }

    private func ensureAccount(profile: ZoomAccountProfile) -> Result<Void, ZoomWorkflowFailure> {
        guard let snapshot = automation.readAccountMenu() else {
            return .failure(.accountMenuUnavailable)
        }

        let currentDescription = snapshot.activeAccount.map(describe) ?? "unknown"
        observer(.checkingAccount, "Current Zoom account: \(currentDescription)")
        observer(.checkingAccount, "Required Zoom account: \(profile.accountIdentifier)")

        switch ZoomAXSupport.matchAccount(identifier: profile.accountIdentifier, in: snapshot.entries) {
        case .notFound:
            return .failure(.accountNotFound(profile.accountIdentifier))

        case .ambiguous(let matches):
            return .failure(.accountAmbiguous(
                profile.accountIdentifier,
                matches: matches.map(\.rawTitle)
            ))

        case .found(let target):
            if target.isActive {
                observer(.checkingAccount, "Required account is already active; no switch needed")
                return .success(())
            }

            transition(to: .switchingAccount, detail: "Switching account…")
            // Opening a menu is the other step that can need Zoom in front.
            automation.activateZoom()
            switch automation.selectAccount(target) {
            case .rejected(let reason):
                return .failure(.accountSwitchRejected(reason))
            case .pressed:
                break
            }

            transition(to: .verifyingAccount, detail: "Verifying active account…")
            let verified = waitUntil(timeout: timeouts.accountSwitch) { [automation] in
                guard let fresh = automation.readAccountMenu() else { return false }
                return Self.isActive(target, in: fresh)
            }

            guard verified else {
                let actual = automation.readAccountMenu()?.activeAccount.map(describe)
                return .failure(.accountSwitchNotVerified(
                    expected: describe(target),
                    actual: actual
                ))
            }
            observer(.verifyingAccount, "Verified active Zoom account: \(describe(target))")
            return .success(())
        }
    }

    /// Verification re-reads the menu and compares identity, never position.
    private static func isActive(_ target: AccountMenuEntry, in snapshot: ZoomAccountSnapshot) -> Bool {
        guard let active = snapshot.activeAccount else { return false }
        if let email = target.email, let activeEmail = active.email {
            return ZoomAXSupport.normalized(email) == ZoomAXSupport.normalized(activeEmail)
        }
        return ZoomAXSupport.normalized(active.rawTitle) == ZoomAXSupport.normalized(target.rawTitle)
    }

    private func describe(_ entry: AccountMenuEntry) -> String {
        entry.email ?? entry.rawTitle
    }

    // MARK: Plumbing

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = automation.now().addingTimeInterval(timeout)
        if condition() { return true }
        while automation.now() < deadline {
            automation.sleep(timeouts.pollInterval)
            if condition() { return true }
        }
        return false
    }

    private func transition(to newState: ZoomWorkflowState, detail: String?) {
        state = newState
        observer(newState, detail)
    }

    private func fail(_ failure: ZoomWorkflowFailure) -> ZoomWorkflowResult {
        transition(to: .failed, detail: failure.message)
        state = .failed
        return .failed(failure)
    }
}
