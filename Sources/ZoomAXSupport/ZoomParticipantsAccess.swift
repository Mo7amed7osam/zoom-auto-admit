import ApplicationServices
import Foundation

/// Live side of the Participants panel: finding the meeting window, reading the
/// panel state, and pressing the toggle with re-verification.
public extension ZoomAXSupport {
    struct ParticipantsReading {
        public let state: ParticipantsPanelState
        public let toggle: ParticipantsToggle?
        public let menuCommand: ParticipantsMenuCommand?
        public let menuBarElement: AXUIElement?
        public let windowElement: AXUIElement?
        public let windowSnapshot: SnapshotNode?

        public init(
            state: ParticipantsPanelState,
            toggle: ParticipantsToggle?,
            menuCommand: ParticipantsMenuCommand? = nil,
            menuBarElement: AXUIElement? = nil,
            windowElement: AXUIElement?,
            windowSnapshot: SnapshotNode?
        ) {
            self.state = state
            self.toggle = toggle
            self.menuCommand = menuCommand
            self.menuBarElement = menuBarElement
            self.windowElement = windowElement
            self.windowSnapshot = windowSnapshot
        }
    }

    /// Reads the Participants panel state from Zoom's meeting window.
    ///
    /// Deliberately scoped to a meeting window: the home window has its own
    /// unrelated controls, and pressing something there would do the wrong thing.
    static func participantsReading(pid: pid_t) -> ParticipantsReading {
        // The menu is tried first and is the path that actually works: Zoom
        // hides the in-meeting toolbar when the pointer is elsewhere, and a
        // hidden toolbar drops out of the Accessibility tree completely.
        if let menuReading = zoomMenuBarReading(pid: pid),
           let command = participantsMenuCommand(inMenuBar: menuReading.root),
           command.state != .unknown {
            return ParticipantsReading(
                state: command.state,
                toggle: nil,
                menuCommand: command,
                menuBarElement: menuReading.menuBarElement,
                windowElement: nil,
                windowSnapshot: nil
            )
        }

        let application = freshZoomApplicationElement(pid: pid, messagingTimeout: 5)
        let windows = windowsResult(of: application)

        guard windows.error == .success, !windows.windows.isEmpty else {
            return ParticipantsReading(state: .unknown, toggle: nil, windowElement: nil, windowSnapshot: nil)
        }

        var bestSnapshot: SnapshotNode?
        var bestElement: AXUIElement?

        for window in windows.windows {
            let title = windowTitle(window)
            guard normalized(title) != "zoom workplace" else { continue }

            // The toolbar controls are direct children of the meeting window, so
            // a shallow read finds them immediately and cheaply; the deeper read
            // is only needed to spot the participant list itself.
            let shallow = snapshot(from: buildTree(from: window, maxDepth: 3, maxChildren: 120))
            if let toggle = participantsToggle(inWindow: shallow), toggle.state != .unknown {
                return ParticipantsReading(
                    state: toggle.state,
                    toggle: toggle,
                    windowElement: window,
                    windowSnapshot: shallow
                )
            }

            let tree = buildTree(from: window, maxDepth: 14)
            let snapshot = snapshot(from: tree)

            // A window already showing the participant list is the answer.
            if participantsPanelState(inWindow: snapshot) == .open {
                return ParticipantsReading(
                    state: .open,
                    toggle: participantsToggle(inWindow: snapshot),
                    windowElement: window,
                    windowSnapshot: snapshot
                )
            }
            // Otherwise keep the window that actually offers the control.
            if participantsToggle(inWindow: snapshot) != nil {
                bestSnapshot = snapshot
                bestElement = window
            } else if isLikelyMeetingWindowTitle(title), bestSnapshot == nil {
                bestSnapshot = snapshot
                bestElement = window
            }
        }

        guard let bestSnapshot, let bestElement else {
            return ParticipantsReading(state: .unknown, toggle: nil, windowElement: nil, windowSnapshot: nil)
        }
        return ParticipantsReading(
            state: participantsPanelState(inWindow: bestSnapshot),
            toggle: participantsToggle(inWindow: bestSnapshot),
            windowElement: bestElement,
            windowSnapshot: bestSnapshot
        )
    }

    /// Presses the participants command in Zoom's View menu, re-verifying it.
    static func pressParticipantsMenuCommand(
        _ command: ParticipantsMenuCommand,
        in reading: ParticipantsReading
    ) -> PreJoinPressOutcome {
        guard let menuBar = reading.menuBarElement,
              let element = resolveElement(at: command.indexPath, from: menuBar) else {
            return .elementUnavailable
        }
        guard copyStringAttribute(element, kAXRoleAttribute) == "AXMenuItem" else {
            return .verificationFailed("the participants command is no longer a menu item")
        }
        guard isEnabled(element) else {
            return .verificationFailed("the participants command is disabled")
        }
        guard actionNames(of: element).contains(pressAction) else {
            return .verificationFailed("the participants command does not expose AXPress")
        }

        let liveTitle = normalized(copyStringAttribute(element, kAXTitleAttribute) ?? "")
        guard liveTitle == normalized(command.title) else {
            return .verificationFailed("the participants command changed to \(liveTitle)")
        }
        // "Hide participants" means it is already open; pressing would close it.
        guard !liveTitle.hasPrefix("hide") else {
            return .verificationFailed("the Participants panel is already open; refusing to close it")
        }

        let result = press(element)
        return result == .success ? .pressed : .axError(result)
    }

    /// Presses the Participants toggle after re-verifying the live element.
    static func pressParticipantsToggle(
        _ toggle: ParticipantsToggle,
        in reading: ParticipantsReading
    ) -> PreJoinPressOutcome {
        guard let windowElement = reading.windowElement,
              let element = resolveElement(at: toggle.indexPath, from: windowElement) else {
            return .elementUnavailable
        }
        guard isEnabled(element) else {
            return .verificationFailed("the Participants control is disabled")
        }
        guard actionNames(of: element).contains(pressAction) else {
            return .verificationFailed("the Participants control does not expose AXPress")
        }

        // Re-verify by identity and state rather than by exact text: the
        // description embeds a live participant count ("1 participants") that
        // legitimately changes between reading and pressing.
        let liveSnapshot = snapshot(from: Node(element: element))
        let identifierStillMatches = liveSnapshot.identifier
            .map { normalized($0) == participantsButtonIdentifier } ?? false
        let labelStillMatches = accessibleTexts(of: liveSnapshot)
            .filter { $0.attribute != "AXIdentifier" }
            .contains { participantsToggleTitles.contains(normalized($0.text)) }
        guard identifierStillMatches || labelStillMatches else {
            return .verificationFailed("the Participants control changed identity")
        }

        let liveState = participantsState(fromDescription: liveSnapshot.description ?? liveSnapshot.title)
        guard liveState != .open else {
            return .verificationFailed("the Participants panel is already open; refusing to close it")
        }

        let result = press(element)
        return result == .success ? .pressed : .axError(result)
    }
}
