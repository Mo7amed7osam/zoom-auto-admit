import AppKit
import Foundation
import ZoomAutoAdmitCore

enum AppDisplayStatus: Equatable {
    case idle
    case monitoring
    case zoomNotRunning
    case meetingNotDetected
    case meetingOnOtherDesktop
    case permissionRequired
    case permissionGrantedRelaunchRequired
    case participantAdmitted
    case error
}

struct AdmitActionRecord: Equatable {
    let date: Date
    let description: String
}

/// One small vocabulary for status colour across the whole app, mapped to
/// system colours so light and dark mode both work without hard-coded values.
enum StatusLevel {
    case normal
    case neutral
    case warning
    case error

    var color: NSColor {
        switch self {
        case .normal: return .systemGreen
        case .neutral: return .secondaryLabelColor
        case .warning: return .systemOrange
        case .error: return .systemRed
        }
    }

    var dot: String {
        switch self {
        case .normal: return "●"
        case .neutral: return "○"
        case .warning: return "▲"
        case .error: return "■"
        }
    }
}

/// What the most recent scheduled run is doing, for Run Now feedback.
enum RunOutcome: Equatable {
    case running(scheduleName: String)
    case succeeded(meetingName: String, autoAdmitActive: Bool)
    case failed(title: String, detail: String)
}

final class AppState {
    private(set) var displayStatus: AppDisplayStatus = .idle
    private(set) var zoomStatus = "Not checked"
    private(set) var waitingRoomStatus = "Stopped"
    private(set) var lastAction: AdmitActionRecord?
    private(set) var recentActions: [AdmitActionRecord] = []
    private(set) var errorMessage: String?
    /// Set while a scheduled startup workflow is running. It takes over the
    /// status line, because during those seconds the workflow is what the user
    /// cares about, not the Waiting Room poll.
    private(set) var workflowStatus: String?
    private(set) var nextScheduleSummary: [String] = []
    private(set) var runOutcome: RunOutcome?
    var monitoringEnabled: Bool
    var onChange: (() -> Void)?

    init(monitoringEnabled: Bool) {
        self.monitoringEnabled = monitoringEnabled
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        monitoringEnabled = enabled
        if !enabled {
            displayStatus = .idle
            waitingRoomStatus = "Stopped"
            errorMessage = nil
        }
        notifyChange()
    }

    /// `nil` clears the workflow line and lets monitoring status show again.
    func setWorkflowStatus(_ status: String?) {
        workflowStatus = status
        notifyChange()
    }

    func setNextScheduleSummary(_ lines: [String]) {
        nextScheduleSummary = lines
        notifyChange()
    }

    func setRunOutcome(_ outcome: RunOutcome?) {
        runOutcome = outcome
        notifyChange()
    }

    /// Drops the short-lived success/failure banner but keeps a running workflow.
    func clearTransientRunState() {
        if case .running = runOutcome { return }
        runOutcome = nil
        workflowStatus = nil
        notifyChange()
    }

    var isWorkflowRunning: Bool {
        if case .running = runOutcome { return true }
        return false
    }

    /// The single line shown at the top of the menu.
    var statusLevel: StatusLevel {
        if let runOutcome {
            switch runOutcome {
            case .running: return .normal
            case .succeeded: return .normal
            case .failed: return .error
            }
        }
        switch displayStatus {
        case .monitoring, .participantAdmitted:
            return zoomStatus == "Temporarily unavailable" ? .warning : .normal
        case .idle:
            return .neutral
        case .zoomNotRunning, .meetingNotDetected:
            return .neutral
        case .meetingOnOtherDesktop:
            return .warning
        case .permissionRequired, .permissionGrantedRelaunchRequired:
            return .error
        case .error:
            return .error
        }
    }

    func apply(_ event: AutoAdmitMonitorEvent) {
        errorMessage = nil
        switch event {
        case .accessibilityPermissionRequired:
            displayStatus = .permissionRequired
            zoomStatus = "Permission required"
            waitingRoomStatus = "Paused"
        case .accessibilityPermissionGrantedRelaunchRequired:
            displayStatus = .permissionGrantedRelaunchRequired
            zoomStatus = "Permission granted — relaunch app"
            waitingRoomStatus = "Quit and reopen Zoom Auto Admit"
        case .accessibilityAppBundleMismatch:
            displayStatus = .permissionRequired
            zoomStatus = "App bundle mismatch"
            waitingRoomStatus = "Run /Applications/Zoom Auto Admit.app"
        case .accessibilityPossibleStaleTCCEntry:
            displayStatus = .permissionRequired
            zoomStatus = "Possible stale TCC entry"
            waitingRoomStatus = "Remove and re-add the installed app"
        case .zoomNotRunning:
            displayStatus = .zoomNotRunning
            zoomStatus = "Not running"
            waitingRoomStatus = "Waiting for Zoom"
        case .meetingNotDetected:
            displayStatus = .meetingNotDetected
            zoomStatus = "Connected"
            waitingRoomStatus = "Meeting not detected"
        case .meetingOnOtherDesktop:
            displayStatus = .meetingOnOtherDesktop
            zoomStatus = "Connected"
            waitingRoomStatus = "Move Zoom here or assign it to All Desktops"
        case .meetingInaccessible(let reason):
            displayStatus = .meetingNotDetected
            zoomStatus = "Connected"
            waitingRoomStatus = reason
        case .zoomTemporarilyUnavailable:
            // Accessibility permission is intact; only a Zoom query failed.
            // Monitoring continues and recovers on its own.
            displayStatus = .monitoring
            zoomStatus = "Temporarily unavailable"
            waitingRoomStatus = "Retrying…"
        case .monitoring(let presentation):
            displayStatus = .monitoring
            zoomStatus = presentation == .background ? "Connected — background" : "Connected"
            waitingRoomStatus = "Monitoring"
        case .admitted(let participantName, let admitAll, let date):
            displayStatus = .participantAdmitted
            zoomStatus = zoomStatus.hasPrefix("Connected") ? zoomStatus : "Connected"
            waitingRoomStatus = "Monitoring"
            let description: String
            if admitAll {
                description = "Admitted all waiting participants"
            } else {
                description = "Admitted \(participantName ?? "waiting participant")"
            }
            let record = AdmitActionRecord(date: date, description: description)
            lastAction = record
            recentActions.insert(record, at: 0)
            recentActions = Array(recentActions.prefix(10))
        case .error(let message):
            displayStatus = .error
            errorMessage = message
            waitingRoomStatus = message
        }
        notifyChange()
    }

    var statusText: String {
        if case .succeeded(let meetingName, let autoAdmitActive) = runOutcome {
            return autoAdmitActive ? "Meeting started — Auto Admit active" : "\(meetingName) started"
        }
        if case .failed(let title, _) = runOutcome { return title }
        if let workflowStatus { return workflowStatus }
        switch displayStatus {
        case .idle: return "Idle"
        case .monitoring: return "Monitoring"
        case .zoomNotRunning: return "Zoom not running"
        case .meetingNotDetected: return "Meeting not detected"
        case .meetingOnOtherDesktop: return "Another Desktop"
        case .permissionRequired: return "Accessibility required"
        case .permissionGrantedRelaunchRequired: return "Permission granted — relaunch app"
        case .participantAdmitted: return "Participant admitted"
        case .error: return "Error"
        }
    }

    var menuBarSymbolName: String {
        // A scheduled startup in progress outranks the monitoring state: it is
        // the thing the user is waiting on.
        if isWorkflowRunning { return "clock.badge" }
        if case .failed = runOutcome { return "exclamationmark.triangle" }
        switch displayStatus {
        case .monitoring, .participantAdmitted:
            return monitoringEnabled ? "person.badge.plus.fill" : "person.badge.plus"
        case .permissionRequired, .permissionGrantedRelaunchRequired, .error:
            return "exclamationmark.triangle"
        case .meetingOnOtherDesktop:
            return "rectangle.on.rectangle"
        case .zoomNotRunning, .meetingNotDetected:
            return "person.badge.plus"
        case .idle:
            return "pause.circle"
        }
    }

    var formattedLastAction: String {
        guard let lastAction else { return "None yet" }
        return "\(lastAction.description) at \(Self.timeFormatter.string(from: lastAction.date))"
    }

    private func notifyChange() {
        precondition(Thread.isMainThread)
        onChange?()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
