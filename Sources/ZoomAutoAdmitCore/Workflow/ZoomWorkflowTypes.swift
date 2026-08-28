import CoreGraphics
import Foundation
import ZoomAXSupport

public typealias AccountMenuEntry = ZoomAXSupport.AccountMenuEntry
public typealias MeetingPresence = ZoomAXSupport.MeetingPresence
public typealias PreJoinPreview = ZoomAXSupport.PreJoinPreview
public typealias PreJoinControl = ZoomAXSupport.PreJoinControl
public typealias PreJoinControlKind = ZoomAXSupport.PreJoinControlKind
public typealias ToggleState = ZoomAXSupport.ToggleState

public struct ZoomProcess: Equatable {
    public let pid: pid_t
    public let bundleIdentifier: String

    public init(pid: pid_t, bundleIdentifier: String) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct ZoomAccountSnapshot: Equatable {
    public let entries: [AccountMenuEntry]
    public let activeAccount: AccountMenuEntry?

    public init(entries: [AccountMenuEntry], activeAccount: AccountMenuEntry?) {
        self.entries = entries
        self.activeAccount = activeAccount
    }
}

public enum AccountSelectionOutcome: Equatable {
    case pressed
    case rejected(String)
}

public enum MeetingStartOutcome: Equatable {
    case requested(method: String)
    case rejected(String)
}

public enum PreJoinActionOutcome: Equatable {
    case pressed
    case rejected(String)
}

/// Explicit workflow states. Every transition is logged, and each one is entered
/// from exactly one place in `ZoomWorkflowRunner`.
public enum ZoomWorkflowState: String, Equatable {
    case idle
    case scheduleTriggered
    case launchingZoom
    case waitingForZoom
    case checkingAccount
    case switchingAccount
    case verifyingAccount
    case findingMeeting
    case startingMeeting
    case preJoinPreviewDetected
    case ensuringMicrophoneOff
    case microphoneOffVerified
    case ensuringCameraOff
    case cameraOffVerified
    case pressingStart
    case verifyingMeeting
    case meetingStarted
    case openingParticipantsPanel
    case participantsPanelReady
    case monitoringWaitingRoom
    case autoAdmitStarted
    case completed
    case failed
}

public enum ZoomWorkflowFailure: Error, Equatable {
    case accessibilityNotTrusted
    case zoomWouldNotLaunch
    case zoomUIUnavailable
    case accountMenuUnavailable
    case accountNotFound(String)
    case accountAmbiguous(String, matches: [String])
    case accountSwitchRejected(String)
    case accountSwitchNotVerified(expected: String, actual: String?)
    case anotherMeetingActive
    case meetingStateUnknown
    case meetingNotConfigured(String)
    case meetingStartRejected(String)
    case meetingNotVerified
    case preJoinPreviewLost
    case preJoinControlNotFound(PreJoinControlKind)
    case preJoinControlAmbiguous(PreJoinControlKind)
    case preJoinStateUnknown(PreJoinControlKind)
    case preJoinPressRejected(PreJoinControlKind, String)
    case preJoinNotVerified(PreJoinControlKind)
    case preJoinStartNotFound
    case preJoinStartRejected(String)

    public var message: String {
        switch self {
        case .accessibilityNotTrusted:
            return "Accessibility permission is required"
        case .zoomWouldNotLaunch:
            return "Zoom could not be launched"
        case .zoomUIUnavailable:
            return "Zoom did not become ready in time"
        case .accountMenuUnavailable:
            return "Zoom's Switch account menu could not be read"
        case .accountNotFound(let identifier):
            return "No saved Zoom account matches \(identifier)"
        case .accountAmbiguous(let identifier, let matches):
            return "\(matches.count) saved Zoom accounts match \(identifier); refusing to guess"
        case .accountSwitchRejected(let reason):
            return "Account switch was refused: \(reason)"
        case .accountSwitchNotVerified(let expected, let actual):
            return "Account switch failed. Expected \(expected), active account is \(actual ?? "unknown")"
        case .anotherMeetingActive:
            return "Another Zoom meeting is already active. Scheduled meeting was not started."
        case .meetingStateUnknown:
            return "Zoom's meeting state could not be determined; nothing was started"
        case .meetingNotConfigured(let reason):
            return "Meeting is not configured correctly: \(reason)"
        case .meetingStartRejected(let reason):
            return "Zoom refused to start the meeting: \(reason)"
        case .meetingNotVerified:
            return "The meeting did not start"
        case .preJoinPreviewLost:
            return "Zoom's join preview disappeared before the meeting could be started"
        case .preJoinControlNotFound(let kind):
            return "Couldn't find the \(kind.displayName.lowercased()) control in Zoom's join preview"
        case .preJoinControlAmbiguous(let kind):
            return "Several \(kind.displayName.lowercased()) controls matched in Zoom's join preview"
        case .preJoinStateUnknown(let kind):
            return "Couldn't tell whether the \(kind.displayName.lowercased()) is on or off"
        case .preJoinPressRejected(let kind, let reason):
            return "Couldn't turn the \(kind.displayName.lowercased()) off: \(reason)"
        case .preJoinNotVerified(let kind):
            return "The \(kind.displayName.lowercased()) did not turn off"
        case .preJoinStartNotFound:
            return "Couldn't find the Start button in Zoom's join preview"
        case .preJoinStartRejected(let reason):
            return "Couldn't press Start: \(reason)"
        }
    }
}

public enum ZoomWorkflowResult: Equatable {
    case completed(autoAdmitStarted: Bool)
    case failed(ZoomWorkflowFailure)

    public var isSuccess: Bool {
        if case .completed = self { return true }
        return false
    }
}

/// Everything the workflow needs from the outside world, behind one seam so the
/// state machine can be tested without Zoom, Accessibility or a real clock.
public protocol ZoomAutomating {
    func isAccessibilityTrusted() -> Bool
    func zoomProcess() -> ZoomProcess?
    /// Asks macOS to launch Zoom. Returns false when the app could not be found.
    func launchZoom() -> Bool
    /// Reads Zoom's Switch account submenu. Nil when the menu is unreadable.
    func readAccountMenu() -> ZoomAccountSnapshot?
    /// Presses one saved account after re-verifying it against the live menu.
    func selectAccount(_ entry: AccountMenuEntry) -> AccountSelectionOutcome
    func meetingPresence(for process: ZoomProcess) -> MeetingPresence
    /// Window-server view of Zoom's meeting-sized windows, compared before and
    /// after a start request to confirm a meeting that Accessibility cannot see
    /// because it opened on another Space.
    func meetingWindowSignature(for process: ZoomProcess) -> Set<CGWindowID>
    /// Whether Zoom is in a state where it will act on a start request. A client
    /// that has just relaunched after an account switch is not.
    func isReadyToStartMeeting(for process: ZoomProcess) -> Bool
    /// Whether the in-meeting Participants panel is open. The Waiting Room rows
    /// only exist in the Accessibility tree while it is.
    func participantsPanelState(for process: ZoomProcess) -> ZoomAXSupport.ParticipantsPanelState
    /// Opens the Participants panel. Only ever called when it is closed, because
    /// the same control closes it again.
    func openParticipantsPanel(for process: ZoomProcess) -> PreJoinActionOutcome
    func startMeeting(_ meeting: MeetingReference) -> MeetingStartOutcome
    /// Zoom's pre-join preview, or nil when no preview is open. A nil result is
    /// normal: Zoom skips the preview when the user has disabled it.
    func preJoinPreview(for process: ZoomProcess) -> PreJoinPreview?
    /// Presses a microphone/camera control, re-verifying the live element and
    /// its state first. Never presses a control that is not currently on.
    func pressPreJoinControl(_ control: PreJoinControl) -> PreJoinActionOutcome
    func pressPreJoinStart() -> PreJoinActionOutcome
    /// Writes the preview hierarchy for diagnostics when it cannot be read.
    func capturePreJoinDiagnostics(reason: String)
    /// Brings Zoom forward. Permitted only during the startup workflow, never
    /// during Auto Admit monitoring.
    func activateZoom()
    func now() -> Date
    func sleep(_ interval: TimeInterval)
}

public struct ZoomWorkflowTimeouts {
    public var zoomLaunch: TimeInterval
    public var zoomUIReady: TimeInterval
    public var accountSwitch: TimeInterval
    public var meetingStart: TimeInterval
    /// How long to wait for Zoom's join preview to appear before assuming this
    /// client is configured to skip it.
    public var preJoinAppearance: TimeInterval
    public var pollInterval: TimeInterval

    public init(
        zoomLaunch: TimeInterval = 60,
        zoomUIReady: TimeInterval = 45,
        accountSwitch: TimeInterval = 45,
        meetingStart: TimeInterval = 90,
        preJoinAppearance: TimeInterval = 20,
        pollInterval: TimeInterval = 0.5
    ) {
        self.zoomLaunch = zoomLaunch
        self.zoomUIReady = zoomUIReady
        self.accountSwitch = accountSwitch
        self.meetingStart = meetingStart
        self.preJoinAppearance = preJoinAppearance
        self.pollInterval = pollInterval
    }

    /// Fast timings for tests.
    public static let immediate = ZoomWorkflowTimeouts(
        zoomLaunch: 1,
        zoomUIReady: 1,
        accountSwitch: 1,
        meetingStart: 1,
        preJoinAppearance: 1,
        pollInterval: 0.01
    )
}
