import AppKit
import Foundation
import ZoomAutoAdmitCore

/// Translates internal workflow vocabulary into something a person wants to read.
///
/// Internal state names stay in the logs; nothing like `state=verifyingMeeting`
/// ever reaches the menu.
enum WorkflowPresentation {
    /// Friendly progress line, or nil for states that should not be announced.
    static func progressText(
        for state: ZoomWorkflowState,
        schedule: ZoomSchedule,
        profile: ZoomAccountProfile
    ) -> String? {
        switch state {
        case .idle, .completed, .failed:
            return nil
        case .scheduleTriggered:
            return "Preparing Zoom…"
        case .launchingZoom:
            return "Opening Zoom…"
        case .waitingForZoom:
            return "Waiting for Zoom…"
        case .checkingAccount:
            return "Checking account…"
        case .switchingAccount:
            return "Switching to \(profile.name)…"
        case .verifyingAccount:
            return "Confirming \(profile.name)…"
        case .findingMeeting:
            return "Opening \(schedule.meeting.name)…"
        case .startingMeeting:
            return "Opening \(schedule.meeting.name)…"
        case .preJoinPreviewDetected:
            return "Preparing microphone and camera…"
        case .ensuringMicrophoneOff:
            return "Muting microphone…"
        case .microphoneOffVerified:
            return "Microphone off"
        case .ensuringCameraOff:
            return "Turning camera off…"
        case .cameraOffVerified:
            return "Camera off"
        case .pressingStart:
            return "Starting meeting…"
        case .verifyingMeeting:
            return "Waiting for meeting…"
        case .meetingStarted:
            return "✓ Meeting started"
        case .openingParticipantsPanel:
            return "Opening participants…"
        case .participantsPanelReady:
            return "Participants panel ready"
        case .monitoringWaitingRoom, .autoAdmitStarted:
            return "Auto Admit active"
        }
    }

    /// Short headline plus an optional explanation and recovery hint.
    struct FailureCopy {
        let title: String
        let detail: String
        let suggestsRetry: Bool
        let suggestsDiagnostics: Bool
    }

    static func copy(for failure: ZoomWorkflowFailure) -> FailureCopy {
        switch failure {
        case .accessibilityNotTrusted:
            return FailureCopy(
                title: "Accessibility permission required",
                detail: "Zoom Auto Admit needs Accessibility access to read and press Zoom controls.",
                suggestsRetry: false,
                suggestsDiagnostics: false
            )
        case .zoomWouldNotLaunch:
            return FailureCopy(
                title: "Couldn't open Zoom",
                detail: "The Zoom app could not be found or launched.",
                suggestsRetry: true,
                suggestsDiagnostics: false
            )
        case .zoomUIUnavailable:
            return FailureCopy(
                title: "Zoom wasn't ready",
                detail: "Zoom didn't finish loading in time.",
                suggestsRetry: true,
                suggestsDiagnostics: false
            )
        case .accountMenuUnavailable:
            return FailureCopy(
                title: "Couldn't read Zoom accounts",
                detail: "Zoom's Switch account menu could not be read. Make sure Zoom is running and signed in.",
                suggestsRetry: true,
                suggestsDiagnostics: true
            )
        case .accountNotFound(let identifier):
            return FailureCopy(
                title: "Zoom account not found",
                detail: "No account signed in to Zoom matches \(identifier).",
                suggestsRetry: false,
                suggestsDiagnostics: false
            )
        case .accountAmbiguous(let identifier, let matches):
            return FailureCopy(
                title: "More than one account matches",
                detail: "\(matches.count) saved accounts match “\(identifier)”. Use the full email address instead.",
                suggestsRetry: false,
                suggestsDiagnostics: false
            )
        case .accountSwitchRejected(let reason):
            return FailureCopy(
                title: "Couldn't switch Zoom account",
                detail: reason,
                suggestsRetry: true,
                suggestsDiagnostics: true
            )
        case .accountSwitchNotVerified(let expected, let actual):
            return FailureCopy(
                title: "Couldn't switch Zoom account",
                detail: "Expected:\n\(expected)\n\nCurrent:\n\(actual ?? "unknown")",
                suggestsRetry: true,
                suggestsDiagnostics: false
            )
        case .anotherMeetingActive:
            return FailureCopy(
                title: "A Zoom meeting is already running",
                detail: "The scheduled meeting was not started, and the meeting in progress was left alone.",
                suggestsRetry: false,
                suggestsDiagnostics: false
            )
        case .meetingStateUnknown:
            return FailureCopy(
                title: "Couldn't check Zoom's meeting state",
                detail: "Zoom's windows couldn't be read, so nothing was started.",
                suggestsRetry: true,
                suggestsDiagnostics: true
            )
        case .meetingNotConfigured(let reason):
            return FailureCopy(
                title: "Meeting isn't set up correctly",
                detail: reason,
                suggestsRetry: false,
                suggestsDiagnostics: false
            )
        case .meetingStartRejected(let reason):
            return FailureCopy(
                title: "Zoom wouldn't start the meeting",
                detail: reason,
                suggestsRetry: true,
                suggestsDiagnostics: true
            )
        case .meetingNotVerified:
            return FailureCopy(
                title: "The meeting didn't start",
                detail: "Zoom was asked to start the meeting, but no meeting appeared.",
                suggestsRetry: true,
                suggestsDiagnostics: true
            )
        case .preJoinPreviewLost:
            return FailureCopy(
                title: "Zoom's join preview closed",
                detail: "The preview disappeared before the meeting could be started.",
                suggestsRetry: true,
                suggestsDiagnostics: true
            )
        case .preJoinControlNotFound(let kind):
            return FailureCopy(
                title: "Couldn't find the \(kind.displayName.lowercased()) control",
                detail: "Zoom opened the join preview, but its \(kind.displayName.lowercased()) control could not be identified. Nothing was pressed.",
                suggestsRetry: true,
                suggestsDiagnostics: true
            )
        case .preJoinControlAmbiguous(let kind):
            return FailureCopy(
                title: "Couldn't identify the \(kind.displayName.lowercased()) control",
                detail: "Several controls looked like the \(kind.displayName.lowercased()). Nothing was pressed.",
                suggestsRetry: true,
                suggestsDiagnostics: true
            )
        case .preJoinStateUnknown(let kind):
            return FailureCopy(
                title: "Couldn't tell if the \(kind.displayName.lowercased()) is on",
                detail: "Zoom's \(kind.displayName.lowercased()) control didn't say whether it is on or off, so it was left untouched and the meeting was not started.",
                suggestsRetry: true,
                suggestsDiagnostics: true
            )
        case .preJoinPressRejected(let kind, let reason):
            return FailureCopy(
                title: "Couldn't turn the \(kind.displayName.lowercased()) off",
                detail: reason,
                suggestsRetry: true,
                suggestsDiagnostics: true
            )
        case .preJoinNotVerified(let kind):
            return FailureCopy(
                title: "The \(kind.displayName.lowercased()) didn't turn off",
                detail: "The control was pressed but Zoom still reports it as on, so the meeting was not started.",
                suggestsRetry: true,
                suggestsDiagnostics: true
            )
        case .preJoinStartNotFound:
            return FailureCopy(
                title: "Couldn't find the Start button",
                detail: "Zoom opened the meeting preview, but the Start button could not be identified.",
                suggestsRetry: true,
                suggestsDiagnostics: true
            )
        case .preJoinStartRejected(let reason):
            return FailureCopy(
                title: "Couldn't press Start",
                detail: reason,
                suggestsRetry: true,
                suggestsDiagnostics: true
            )
        }
    }
}
