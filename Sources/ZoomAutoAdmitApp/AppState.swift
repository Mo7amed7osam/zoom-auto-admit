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
        switch displayStatus {
        case .monitoring, .participantAdmitted: return "person.badge.plus"
        case .permissionRequired, .permissionGrantedRelaunchRequired, .error: return "exclamationmark.triangle"
        case .meetingOnOtherDesktop: return "rectangle.on.rectangle"
        case .zoomNotRunning, .meetingNotDetected: return "video.slash"
        case .idle: return "pause.circle"
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
