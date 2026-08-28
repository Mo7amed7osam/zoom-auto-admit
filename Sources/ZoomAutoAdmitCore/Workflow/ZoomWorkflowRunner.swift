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
        guard let process = ensureZoomRunning() else {
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

        // 4. Meeting.
        transition(to: .findingMeeting, detail: schedule.meeting.displayText)
        if case .meetingID(let raw) = schedule.meeting.kind,
           MeetingReference.normalizedMeetingID(raw).isEmpty {
            return fail(.meetingNotConfigured("meeting ID has no digits"))
        }

        transition(to: .startingMeeting, detail: "Starting \(schedule.meeting.name)")
        // Starting a meeting is the one step that genuinely needs Zoom in front.
        automation.activateZoom()
        switch automation.startMeeting(schedule.meeting) {
        case .rejected(let reason):
            return fail(.meetingStartRejected(reason))
        case .requested(let method):
            transition(to: .verifyingMeeting, detail: "Start requested via \(method)")
        }

        // 5. A successful press proves nothing; wait for real meeting evidence.
        let started = waitUntil(timeout: timeouts.meetingStart) { [automation] in
            automation.meetingPresence(for: process).state == .active
        }
        guard started else {
            return fail(.meetingNotVerified)
        }
        let presence = automation.meetingPresence(for: process)
        transition(to: .verifyingMeeting, detail: "Meeting verified (\(presence.evidenceDescription))")

        guard schedule.enablesAutoAdmit else {
            transition(to: .completed, detail: "Meeting started; Auto Admit off for this schedule")
            state = .completed
            return .completed(autoAdmitStarted: false)
        }

        transition(to: .monitoringWaitingRoom, detail: "Handing over to Auto Admit")
        transition(to: .completed, detail: "Workflow completed")
        state = .completed
        return .completed(autoAdmitStarted: true)
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
