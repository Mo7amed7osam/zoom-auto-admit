import AppKit
import ZoomAutoAdmitCore

final class MenuBarController: NSObject, NSMenuDelegate {
    var onSetMonitoring: ((Bool) -> Void)?
    var onOpenSchedules: (() -> Void)?
    var onOpenSchedulerLog: (() -> Void)?
    var onCaptureZoomUI: (() -> Void)?
    var onRunSchedule: ((ZoomSchedule) -> Void)?
    /// Supplies the live scheduler configuration for the menu sections.
    var schedulerConfiguration: (() -> SchedulerConfiguration)?
    var onOpenAccessibilitySettings: (() -> Void)?
    var onCheckAgain: (() -> Void)?
    var onOpenDiagnosticsLog: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var launchAtLoginEnabled: (() -> Bool)?
    var onQuit: (() -> Void)?

    private let state: AppState
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem()
    private let zoomMenuItem = NSMenuItem()
    private let waitingRoomMenuItem = NSMenuItem()
    private let autoAdmitMenuItem = NSMenuItem()
    private let lastActionMenuItem = NSMenuItem()
    private let startMenuItem = NSMenuItem()
    private let stopMenuItem = NSMenuItem()
    private let accessibilityMenuItem = NSMenuItem()
    private let checkAgainMenuItem = NSMenuItem()
    private let diagnosticsLogMenuItem = NSMenuItem()
    private let launchAtLoginMenuItem = NSMenuItem()
    private let nextScheduleHeaderItem = NSMenuItem()
    private var nextScheduleDetailItems: [NSMenuItem] = []
    private let schedulesMenuItem = NSMenuItem()
    private let accountProfilesMenuItem = NSMenuItem()
    private let schedulerLogMenuItem = NSMenuItem()
    private let captureZoomUIMenuItem = NSMenuItem()

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureMenu()
        refresh()
    }

    func refresh() {
        precondition(Thread.isMainThread)
        let image = NSImage(
            systemSymbolName: state.menuBarSymbolName,
            accessibilityDescription: "Zoom Auto Admit — \(state.statusText)"
        )
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Zoom Auto Admit — \(state.statusText)"

        statusMenuItem.title = "Status: ● \(state.statusText)"
        zoomMenuItem.title = "Zoom: \(state.zoomStatus)"
        waitingRoomMenuItem.title = "Waiting Room: \(state.waitingRoomStatus)"
        autoAdmitMenuItem.state = state.monitoringEnabled ? .on : .off
        autoAdmitMenuItem.title = "Auto Admit"
        lastActionMenuItem.title = "Last action: \(state.formattedLastAction)"
        refreshScheduleSections()
        startMenuItem.isEnabled = !state.monitoringEnabled
        stopMenuItem.isEnabled = state.monitoringEnabled
        accessibilityMenuItem.isHidden = false
        checkAgainMenuItem.isHidden = false
        launchAtLoginMenuItem.state = launchAtLoginEnabled?() == true ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func configureMenu() {
        menu.delegate = self
        let header = NSMenuItem(title: "Zoom Auto Admit", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        [statusMenuItem, zoomMenuItem, waitingRoomMenuItem].forEach {
            $0.isEnabled = false
            menu.addItem($0)
        }

        autoAdmitMenuItem.target = self
        autoAdmitMenuItem.action = #selector(toggleAutoAdmit)
        menu.addItem(autoAdmitMenuItem)

        lastActionMenuItem.isEnabled = false
        menu.addItem(lastActionMenuItem)

        nextScheduleHeaderItem.title = "Next Schedule: none"
        nextScheduleHeaderItem.isEnabled = false
        menu.addItem(nextScheduleHeaderItem)
        // Reserved detail rows, shown or hidden as the next schedule changes.
        for _ in 0..<3 {
            let item = NSMenuItem()
            item.isEnabled = false
            item.isHidden = true
            nextScheduleDetailItems.append(item)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        schedulesMenuItem.title = "Schedules"
        schedulesMenuItem.submenu = NSMenu()
        menu.addItem(schedulesMenuItem)

        accountProfilesMenuItem.title = "Account Profiles"
        accountProfilesMenuItem.submenu = NSMenu()
        menu.addItem(accountProfilesMenuItem)

        menu.addItem(.separator())

        startMenuItem.title = "Start Monitoring"
        startMenuItem.target = self
        startMenuItem.action = #selector(startMonitoring)
        menu.addItem(startMenuItem)

        stopMenuItem.title = "Stop Monitoring"
        stopMenuItem.target = self
        stopMenuItem.action = #selector(stopMonitoring)
        menu.addItem(stopMenuItem)

        accessibilityMenuItem.title = "Open Accessibility Settings"
        accessibilityMenuItem.target = self
        accessibilityMenuItem.action = #selector(openAccessibilitySettings)
        menu.addItem(accessibilityMenuItem)

        checkAgainMenuItem.title = "Check Again"
        checkAgainMenuItem.target = self
        checkAgainMenuItem.action = #selector(checkAgain)
        menu.addItem(checkAgainMenuItem)

        diagnosticsLogMenuItem.title = "Open Accessibility Diagnostic Log"
        diagnosticsLogMenuItem.target = self
        diagnosticsLogMenuItem.action = #selector(openDiagnosticsLog)
        menu.addItem(diagnosticsLogMenuItem)

        schedulerLogMenuItem.title = "Open Scheduler Log"
        schedulerLogMenuItem.target = self
        schedulerLogMenuItem.action = #selector(openSchedulerLog)
        menu.addItem(schedulerLogMenuItem)

        captureZoomUIMenuItem.title = "Capture Zoom UI Snapshot"
        captureZoomUIMenuItem.toolTip = "Writes Zoom's live Accessibility hierarchy to a log for diagnostics."
        captureZoomUIMenuItem.target = self
        captureZoomUIMenuItem.action = #selector(captureZoomUI)
        menu.addItem(captureZoomUIMenuItem)

        launchAtLoginMenuItem.title = "Launch at Login"
        launchAtLoginMenuItem.target = self
        launchAtLoginMenuItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(launchAtLoginMenuItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func refreshScheduleSections() {
        let summary = state.nextScheduleSummary
        if summary.isEmpty {
            nextScheduleHeaderItem.title = "Next Schedule: none"
            nextScheduleDetailItems.forEach { $0.isHidden = true }
        } else {
            nextScheduleHeaderItem.title = "Next Schedule:"
            for (index, item) in nextScheduleDetailItems.enumerated() {
                if index < summary.count {
                    item.title = "    \(summary[index])"
                    item.isHidden = false
                } else {
                    item.isHidden = true
                }
            }
        }

        let configuration = schedulerConfiguration?() ?? SchedulerConfiguration()
        rebuildSchedulesSubmenu(configuration)
        rebuildAccountProfilesSubmenu(configuration)
    }

    private func rebuildSchedulesSubmenu(_ configuration: SchedulerConfiguration) {
        let submenu = NSMenu()
        if configuration.schedules.isEmpty {
            let empty = NSMenuItem(title: "No schedules yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for schedule in configuration.schedules {
            let marker = schedule.isEnabled ? "●" : "○"
            let header = NSMenuItem(
                title: "\(marker) \(schedule.recurrence.displayText) \(schedule.startTime.displayText)",
                action: nil,
                keyEquivalent: ""
            )
            header.isEnabled = false
            submenu.addItem(header)

            let name = NSMenuItem(title: "    \(schedule.name)", action: nil, keyEquivalent: "")
            name.isEnabled = false
            submenu.addItem(name)

            let accountName = configuration.profile(for: schedule)?.name ?? "No account profile"
            let account = NSMenuItem(title: "    Account: \(accountName)", action: nil, keyEquivalent: "")
            account.isEnabled = false
            submenu.addItem(account)

            let meeting = NSMenuItem(
                title: "    Meeting: \(schedule.meeting.displayText)",
                action: nil,
                keyEquivalent: ""
            )
            meeting.isEnabled = false
            submenu.addItem(meeting)

            let autoAdmit = NSMenuItem(
                title: "    Auto Admit: \(schedule.enablesAutoAdmit ? "ON" : "OFF")",
                action: nil,
                keyEquivalent: ""
            )
            autoAdmit.isEnabled = false
            submenu.addItem(autoAdmit)

            let runNow = NSMenuItem(title: "    Run Now", action: #selector(runSchedule(_:)), keyEquivalent: "")
            runNow.target = self
            runNow.representedObject = schedule
            submenu.addItem(runNow)

            submenu.addItem(.separator())
        }

        let add = NSMenuItem(title: "Add Schedule…", action: #selector(openSchedules), keyEquivalent: "")
        add.target = self
        submenu.addItem(add)

        let manage = NSMenuItem(title: "Manage Schedules…", action: #selector(openSchedules), keyEquivalent: "")
        manage.target = self
        submenu.addItem(manage)

        schedulesMenuItem.submenu = submenu
    }

    private func rebuildAccountProfilesSubmenu(_ configuration: SchedulerConfiguration) {
        let submenu = NSMenu()
        if configuration.accountProfiles.isEmpty {
            let empty = NSMenuItem(title: "No account profiles yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for profile in configuration.accountProfiles {
            let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)

            let identifier = NSMenuItem(
                title: "    Expected Zoom account: \(profile.accountIdentifier)",
                action: nil,
                keyEquivalent: ""
            )
            identifier.isEnabled = false
            submenu.addItem(identifier)
        }
        submenu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Account Profiles…", action: #selector(openSchedules), keyEquivalent: "")
        manage.target = self
        submenu.addItem(manage)
        accountProfilesMenuItem.submenu = submenu
    }

    @objc private func openSchedules() { onOpenSchedules?() }
    @objc private func openSchedulerLog() { onOpenSchedulerLog?() }
    @objc private func captureZoomUI() { onCaptureZoomUI?() }

    @objc private func runSchedule(_ sender: NSMenuItem) {
        guard let schedule = sender.representedObject as? ZoomSchedule else { return }
        onRunSchedule?(schedule)
    }

    @objc private func toggleAutoAdmit() { onSetMonitoring?(!state.monitoringEnabled) }
    @objc private func startMonitoring() { onSetMonitoring?(true) }
    @objc private func stopMonitoring() { onSetMonitoring?(false) }
    @objc private func openAccessibilitySettings() { onOpenAccessibilitySettings?() }
    @objc private func checkAgain() { onCheckAgain?() }
    @objc private func openDiagnosticsLog() { onOpenDiagnosticsLog?() }
    @objc private func toggleLaunchAtLogin() { onToggleLaunchAtLogin?() }
    @objc private func quit() { onQuit?() }
}
