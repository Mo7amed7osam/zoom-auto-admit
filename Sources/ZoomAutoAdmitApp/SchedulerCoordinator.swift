import AppKit
import Foundation
import OSLog
import UserNotifications
import ZoomAutoAdmitCore

/// Wires persisted schedules to the startup workflow and to the *existing* Auto
/// Admit monitor.
///
/// It deliberately owns no polling of its own: when a meeting is verified it
/// calls the same `AutoAdmitMonitor` the menu commands use, so there is exactly
/// one Waiting Room loop in the process no matter how many schedules fire.
final class SchedulerCoordinator {
    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "scheduler-coordinator")
    private let store: ScheduleStore
    private let schedulerLog: SchedulerLog
    private let state: AppState
    private let workflowQueue = DispatchQueue(label: "com.mohamedhosam.ZoomAutoAdmit.workflow", qos: .userInitiated)
    private let automation: ZoomAutomating
    private let accountManager: AccountManager
    private let allocator: ZoomSessionAllocator
    private let webAccountManager: ZoomWebAccountManager

    /// Supplied by the app delegate so the coordinator drives the one shared monitor.
    private let startAutoAdmit: () -> Void
    private let stopAutoAdmit: () -> Void

    private var scheduler: SchedulerService!
    private var configuration: SchedulerConfiguration
    private var isWorkflowRunning = false
    /// Schedules whose Auto Admit run was started by the scheduler, so an end
    /// time only ever stops monitoring the scheduler itself turned on.
    private var schedulerStartedMonitoring = Set<UUID>()

    init(
        state: AppState,
        store: ScheduleStore = ScheduleStore(),
        schedulerLog: SchedulerLog = .shared,
        automation: ZoomAutomating = LiveZoomAutomation(),
        accountManager: AccountManager = AccountManager(),
        allocator: ZoomSessionAllocator = ZoomSessionAllocator(),
        webAccountManager: ZoomWebAccountManager = ZoomWebAccountManager(),
        startAutoAdmit: @escaping () -> Void,
        stopAutoAdmit: @escaping () -> Void
    ) {
        self.state = state
        self.store = store
        self.schedulerLog = schedulerLog
        self.automation = automation
        self.accountManager = accountManager
        self.allocator = allocator
        self.webAccountManager = webAccountManager
        self.startAutoAdmit = startAutoAdmit
        self.stopAutoAdmit = stopAutoAdmit
        self.configuration = store.load()
        self.configuration = Self.mergingManagedAccounts(
            (try? accountManager.accounts()) ?? [],
            into: self.configuration
        )

        scheduler = SchedulerService(
            configuration: configuration,
            onFire: { [weak self] schedule, profile, date in
                self?.handleFire(schedule: schedule, profile: profile, occurrence: date)
            },
            onMonitoringEnd: { [weak self] schedule in
                self?.handleMonitoringEnd(schedule: schedule)
            }
        )
    }

    var currentConfiguration: SchedulerConfiguration { configuration }
    var scheduleFileURL: URL { store.location }
    var logFileURL: URL { schedulerLog.fileURL }

    func start() {
        requestNotificationAuthorization()
        scheduler.start()
        refreshNextScheduleSummary()
        // A wake from sleep can skip many ticks; re-evaluate immediately so a
        // start time that passed while the Mac slept is still caught.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduler.checkNow()
            self?.refreshNextScheduleSummary()
        }
        schedulerLog.write("Scheduler started with \(configuration.schedules.count) schedule(s)")
    }

    func stop() {
        scheduler.stop()
    }

    func update(configuration newConfiguration: SchedulerConfiguration) {
        configuration = newConfiguration
        store.save(newConfiguration)
        scheduler.update(configuration: newConfiguration)
        refreshNextScheduleSummary()
        schedulerLog.write("Schedules saved (\(newConfiguration.schedules.count) schedule(s))")
    }

    func reload() {
        configuration = store.load()
        scheduler.update(configuration: configuration)
        refreshNextScheduleSummary()
    }

    func synchronizeManagedAccounts() {
        let accounts = (try? accountManager.accounts()) ?? []
        configuration = Self.mergingManagedAccounts(accounts, into: configuration)
        store.save(configuration)
        scheduler.update(configuration: configuration)
        refreshNextScheduleSummary()
    }

    /// Runs a schedule immediately, for testing a configuration without waiting.
    func runNow(_ schedule: ZoomSchedule) {
        guard let profile = configuration.profile(for: schedule) else {
            notify(title: "Schedule has no account profile", body: schedule.name)
            return
        }
        handleFire(schedule: schedule, profile: profile, occurrence: Date())
    }

    func refreshNextScheduleSummary() {
        guard let next = scheduler.nextScheduled() else {
            DispatchQueue.main.async { [state] in state.setNextScheduleSummary([]) }
            return
        }
        let profileName = configuration.profile(for: next.schedule)?.name ?? "No account"
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        let lines = [
            next.schedule.name,
            formatter.string(from: next.date),
            "\(profileName) · \(next.schedule.meeting.displayText)"
        ]
        DispatchQueue.main.async { [state] in state.setNextScheduleSummary(lines) }
    }

    // MARK: Workflow

    private func handleFire(schedule: ZoomSchedule, profile: ZoomAccountProfile, occurrence: Date) {
        workflowQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isWorkflowRunning else {
                // Two schedules landing together must not race two startups.
                self.schedulerLog.write("Skipped \(schedule.name): another workflow is already running")
                return
            }
            self.isWorkflowRunning = true
            defer { self.isWorkflowRunning = false }

            self.schedulerLog.write("──────── Schedule triggered: \(schedule.name) ────────")
            self.schedulerLog.write("Occurrence: \(occurrence)")
            self.schedulerLog.write("Required account profile: \(profile.name) <\(profile.accountIdentifier)>")
            self.schedulerLog.write("Meeting: \(schedule.meeting.displayText)")

            guard let account = self.managedAccount(for: profile) else {
                self.schedulerLog.write("Account credential reference is missing for \(profile.name)")
                self.notify(title: "Scheduled account is unavailable", body: profile.name)
                return
            }
            let executionProfile = ZoomAccountProfile(
                id: account.id,
                name: account.displayName,
                accountIdentifier: account.email
            )
            guard let meetingURL = self.webMeetingURL(for: schedule.meeting) else {
                self.schedulerLog.write("[ALLOCATOR] Meeting has no Web-compatible URL; selecting Desktop engine")
                self.runDesktopWorkflow(schedule: schedule, profile: executionProfile)
                return
            }
            let request = SessionRequest(
                id: schedule.id,
                account: account,
                meetingURL: meetingURL,
                startTime: occurrence
            )
            let desktopBusy = self.desktopHasActiveMeeting()
            let engine = self.allocator.allocate(request, desktopHasActiveMeeting: desktopBusy)
            switch engine {
            case .desktop:
                defer { self.allocator.release(request, engine: .desktop) }
                self.runDesktopWorkflow(schedule: schedule, profile: executionProfile)
            case .web:
                self.runWebWorkflow(schedule: schedule, account: account, meetingURL: meetingURL)
            }
        }
    }

    private func runDesktopWorkflow(schedule: ZoomSchedule, profile: ZoomAccountProfile) {

            let runner = ZoomWorkflowRunner(
                automation: automation,
                timeouts: ZoomWorkflowTimeouts()
            ) { [weak self] state, detail in
                guard let self else { return }
                self.schedulerLog.write(state: state, detail: detail)
                self.publish(state: state, detail: detail, schedule: schedule, profile: profile)
            }

            let result = runner.run(schedule: schedule, profile: profile)
            finish(result: result, schedule: schedule)
    }

    private func runWebWorkflow(schedule: ZoomSchedule, account: ZoomAccount, meetingURL: URL) {
        do {
            _ = try webAccountManager.openMeeting(meetingURL, for: account)
            schedulerLog.write("[WEB] Using saved browser profile for \(account.displayName)")
            schedulerLog.write("[MEETING] Launching session \(schedule.meeting.displayText)")
            DispatchQueue.main.async { [state] in
                state.setWorkflowStatus("Web meeting launched for \(account.displayName)")
            }
            notify(title: "Scheduled Web Zoom meeting launched", body: schedule.meeting.name)
        } catch {
            schedulerLog.write("Web workflow FAILED for \(schedule.name): \(error.localizedDescription)")
            notify(title: "Web Zoom meeting not started", body: error.localizedDescription)
        }
    }

    private func managedAccount(for profile: ZoomAccountProfile) -> ZoomAccount? {
        if let account = try? accountManager.accounts().first(where: {
            $0.id == profile.id || $0.email.caseInsensitiveCompare(profile.accountIdentifier) == .orderedSame
        }) {
            return account
        }
        if profile.accountIdentifier.hasPrefix("keychain:") { return nil }
        return ZoomAccount(
            id: profile.id,
            displayName: profile.name,
            email: profile.accountIdentifier,
            preferredEngine: .auto
        )
    }

    private func desktopHasActiveMeeting() -> Bool {
        guard let process = automation.zoomProcess() else { return false }
        return automation.meetingPresence(for: process).state == .active
    }

    private func webMeetingURL(for meeting: MeetingReference) -> URL? {
        guard case .meetingID(let raw) = meeting.kind else { return nil }
        let digits = MeetingReference.normalizedMeetingID(raw)
        guard !digits.isEmpty else { return nil }
        return URL(string: "https://zoom.us/j/\(digits)")
    }

    private static func mergingManagedAccounts(
        _ accounts: [ZoomAccount],
        into configuration: SchedulerConfiguration
    ) -> SchedulerConfiguration {
        var result = configuration
        for account in accounts {
            let profile = ZoomAccountProfile(
                id: account.id,
                name: account.displayName,
                accountIdentifier: "keychain:\(account.id.uuidString)"
            )
            if let index = result.accountProfiles.firstIndex(where: {
                $0.id == account.id || $0.accountIdentifier.caseInsensitiveCompare(account.email) == .orderedSame
            }) {
                result.accountProfiles[index] = profile
            } else {
                result.accountProfiles.append(profile)
            }
        }
        return result
    }

    private func publish(
        state workflowState: ZoomWorkflowState,
        detail: String?,
        schedule: ZoomSchedule,
        profile: ZoomAccountProfile
    ) {
        let text: String?
        switch workflowState {
        case .idle, .completed, .failed:
            text = nil
        case .scheduleTriggered:
            text = "Starting \(schedule.name)…"
        case .launchingZoom:
            text = "Launching Zoom…"
        case .waitingForZoom:
            text = "Waiting for Zoom UI…"
        case .checkingAccount:
            text = "Checking Zoom account…"
        case .switchingAccount:
            text = "Switching to \(profile.name) account…"
        case .verifyingAccount:
            text = "Verifying \(profile.name) account…"
        case .findingMeeting:
            text = "Finding \(schedule.meeting.name)…"
        case .startingMeeting:
            text = "Starting \(schedule.meeting.name)…"
        case .verifyingMeeting:
            text = "Verifying meeting started…"
        case .monitoringWaitingRoom:
            text = "Meeting started — Auto Admit active"
        }
        DispatchQueue.main.async { [state] in state.setWorkflowStatus(text) }
    }

    private func finish(result: ZoomWorkflowResult, schedule: ZoomSchedule) {
        switch result {
        case .completed(let autoAdmitStarted):
            schedulerLog.write("Workflow completed for \(schedule.name); autoAdmit=\(autoAdmitStarted)")
            if autoAdmitStarted {
                schedulerStartedMonitoring.insert(schedule.id)
                scheduler.registerMonitoring(for: schedule, startedAt: Date())
                DispatchQueue.main.async { [startAutoAdmit] in startAutoAdmit() }
                schedulerLog.write("Auto Admit started via the existing monitor")
            }
            notify(title: "Scheduled Zoom meeting started", body: schedule.meeting.name)

        case .failed(let failure):
            schedulerLog.write("Workflow FAILED for \(schedule.name): \(failure.message)")
            notify(title: notificationTitle(for: failure), body: failure.message)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [state] in
            state.setWorkflowStatus(nil)
        }
        refreshNextScheduleSummary()
    }

    private func notificationTitle(for failure: ZoomWorkflowFailure) -> String {
        switch failure {
        case .accountNotFound, .accountAmbiguous, .accountSwitchRejected, .accountSwitchNotVerified:
            return "Failed to switch Zoom account"
        case .meetingNotConfigured, .meetingStartRejected, .meetingNotVerified:
            return "Scheduled meeting not started"
        case .anotherMeetingActive:
            return "Another Zoom meeting is already active"
        case .meetingStateUnknown:
            return "Zoom's meeting state could not be determined"
        case .accessibilityNotTrusted:
            return "Accessibility permission required"
        case .zoomWouldNotLaunch, .zoomUIUnavailable, .accountMenuUnavailable:
            return "Zoom was not ready"
        }
    }

    private func handleMonitoringEnd(schedule: ZoomSchedule) {
        guard schedulerStartedMonitoring.remove(schedule.id) != nil else {
            schedulerLog.write("End time for \(schedule.name) ignored: monitoring was not started by the scheduler")
            return
        }
        // Only monitoring stops. The Zoom meeting itself is never ended.
        schedulerLog.write("End time reached for \(schedule.name); stopping Auto Admit only")
        DispatchQueue.main.async { [stopAutoAdmit] in stopAutoAdmit() }
        notify(title: "Auto Admit stopped", body: "End time reached for \(schedule.name)")
    }

    // MARK: Notifications

    private func requestNotificationAuthorization() {
        // Unavailable when the app runs from an unsigned or non-bundled copy;
        // the scheduler must keep working regardless.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [logger] granted, error in
            if let error {
                logger.notice("Notification authorization unavailable: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("Notification authorization granted=\(granted)")
            }
        }
    }

    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
