import AppKit
import OSLog
import ServiceManagement
import ZoomAutoAdmitCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "app")
    private let defaults = UserDefaults.standard
    private var state: AppState!
    private var monitor: AutoAdmitMonitor!
    private var menuBarController: MenuBarController!
    private var schedulerCoordinator: SchedulerCoordinator!
    private var schedulerWindowController: SchedulerWindowController?
    private var accessibilityCheckGeneration: UInt64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let enabled: Bool
        if defaults.object(forKey: "monitoringEnabled") == nil {
            enabled = true
            defaults.set(true, forKey: "monitoringEnabled")
        } else {
            enabled = defaults.bool(forKey: "monitoringEnabled")
        }

        state = AppState(monitoringEnabled: enabled)
        // Hybrid monitoring: Accessibility notifications from Zoom shorten the
        // wait, the polling loop guarantees correctness on its own.
        monitor = AutoAdmitMonitor(activitySource: ZoomAXObserverActivitySource()) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.state.monitoringEnabled else { return }
                self.state.apply(event)
            }
        }
        menuBarController = MenuBarController(state: state)
        state.onChange = { [weak self] in self?.menuBarController.refresh() }

        // The scheduler drives the same monitor the menu commands drive, so a
        // scheduled start can never create a second Waiting Room loop.
        schedulerCoordinator = SchedulerCoordinator(
            state: state,
            startAutoAdmit: { [weak self] in self?.setMonitoring(true) },
            stopAutoAdmit: { [weak self] in self?.setMonitoring(false) }
        )
        menuBarController.schedulerConfiguration = { [weak self] in
            self?.schedulerCoordinator.currentConfiguration ?? SchedulerConfiguration()
        }
        configureMenuActions()
        schedulerCoordinator.start()

        if enabled {
            checkAccessibilityFromScratch(source: "launch")
        } else {
            state.setMonitoringEnabled(false)
        }
        if CommandLine.arguments.contains(PreJoinCapture.launchArgument) {
            let opensPreview = !CommandLine.arguments.contains("--no-open")
            DispatchQueue.global(qos: .userInitiated).async {
                PreJoinCapture.run(openPreview: opensPreview)
            }
        }
        if CommandLine.arguments.contains("--open-schedules") {
            // Convenience for opening the editor without going through the menu.
            DispatchQueue.main.async { [weak self] in self?.openSchedulerWindow() }
        }
        if CommandLine.arguments.contains(ZoomUISnapshot.launchArgument) {
            // Read-only diagnostic capture requested at launch. Runs off the main
            // thread and does not touch monitoring.
            DispatchQueue.global(qos: .utility).async {
                ZoomUISnapshot.capture(reason: "launch argument")
            }
        }
        logger.info("Menu bar application launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        schedulerCoordinator?.stop()
        monitor?.stop()
        logger.info("Application terminating; monitor stopped")
    }

    private func configureMenuActions() {
        menuBarController.onSetMonitoring = { [weak self] enabled in
            self?.setMonitoring(enabled)
        }
        menuBarController.onOpenAccessibilitySettings = { [weak self] in
            self?.openAccessibilitySettings()
        }
        menuBarController.onCheckAgain = { [weak self] in
            self?.checkAccessibilityFromScratch(source: "Check Again")
        }
        menuBarController.onOpenDiagnosticsLog = {
            NSWorkspace.shared.open(AccessibilityDiagnosticLog.shared.fileURL)
        }
        menuBarController.launchAtLoginEnabled = {
            SMAppService.mainApp.status == .enabled
        }
        menuBarController.onToggleLaunchAtLogin = { [weak self] in
            self?.toggleLaunchAtLogin()
        }
        menuBarController.onOpenSchedules = { [weak self] in
            self?.openSchedulerWindow()
        }
        menuBarController.onOpenSchedulerLog = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.schedulerCoordinator.logFileURL)
        }
        menuBarController.onCaptureZoomUI = { [weak self] in
            self?.captureZoomUISnapshot()
        }
        menuBarController.onRunSchedule = { [weak self] schedule in
            self?.schedulerCoordinator.runNow(schedule)
        }
        menuBarController.onQuit = { [weak self] in
            self?.monitor.stop()
            NSApp.terminate(nil)
        }
    }

    private func setMonitoring(_ enabled: Bool) {
        defaults.set(enabled, forKey: "monitoringEnabled")
        state.setMonitoringEnabled(enabled)
        if enabled {
            checkAccessibilityFromScratch(source: "Start Monitoring")
        } else {
            monitor.stop()
        }
    }

    private func checkAccessibilityFromScratch(source: String) {
        accessibilityCheckGeneration &+= 1
        let generation = accessibilityCheckGeneration
        let previousRuntimeCDHash = defaults.string(forKey: "lastRuntimeCDHash")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = AccessibilityDiagnosticsSnapshot.capture(
                previousRuntimeCDHash: previousRuntimeCDHash,
                userInitiatedRecheck: source == "Check Again"
            )
            AccessibilityDiagnosticLog.shared.write(snapshot.logLines(source: source))

            DispatchQueue.main.async {
                guard let self, generation == self.accessibilityCheckGeneration else { return }
                self.defaults.set(snapshot.runtimeSignature.cdHash, forKey: "lastRuntimeCDHash")
                self.applyAccessibilityDiagnostics(snapshot)
            }
        }
    }

    private func applyAccessibilityDiagnostics(_ snapshot: AccessibilityDiagnosticsSnapshot) {
        switch snapshot.classification {
        case .trusted:
            guard state.monitoringEnabled else {
                state.setMonitoringEnabled(false)
                return
            }
            if monitor.isRunning {
                monitor.checkNow(forceDelivery: true)
            } else {
                monitor.start()
            }
        case .relaunchRequired:
            monitor.stop()
            state.apply(.accessibilityPermissionGrantedRelaunchRequired)
        case .appBundleMismatch:
            monitor.stop()
            state.apply(.accessibilityAppBundleMismatch)
        case .possibleStaleTCCEntry:
            monitor.stop()
            state.apply(.accessibilityPossibleStaleTCCEntry)
        case .notTrusted:
            monitor.stop()
            state.apply(.accessibilityPermissionRequired)
        }
    }

    private func openSchedulerWindow() {
        if schedulerWindowController == nil {
            schedulerWindowController = SchedulerWindowController(coordinator: schedulerCoordinator)
        }
        schedulerWindowController?.present()
    }

    private func captureZoomUISnapshot() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let url = ZoomUISnapshot.capture(reason: "menu command")
            DispatchQueue.main.async {
                guard let url else {
                    self?.state.apply(.error("Could not capture the Zoom UI snapshot"))
                    return
                }
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            state.apply(.error("Could not create Accessibility Settings URL"))
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            menuBarController.refresh()
        } catch {
            logger.error("Launch at Login update failed: \(error.localizedDescription, privacy: .public)")
            state.apply(.error("Launch at Login requires the app to be installed in Applications"))
        }
    }
}
