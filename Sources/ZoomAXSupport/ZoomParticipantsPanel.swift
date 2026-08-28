import ApplicationServices
import Foundation

/// Zoom's in-meeting Participants panel.
///
/// This matters functionally, not cosmetically: the Waiting Room rows and their
/// Admit buttons only exist in the Accessibility tree while the panel is open,
/// so with it closed the strict matcher has nothing to find and nobody is ever
/// admitted.
///
/// Everything here is grounded in the live in-meeting hierarchy, which has two
/// awkward properties:
///
/// * The toolbar button is described by its *action and state* rather than a
///   plain name — `"Open participants panel, closed, 1 participants"` — so an
///   exact match on "Participants" finds nothing.
/// * The toolbar tree is self-nesting: the same logical button reappears as its
///   own descendant many times over, so counting matches to detect ambiguity
///   rejects a perfectly unambiguous control.
///
/// Both are handled by keying on Zoom's stable `AXIdentifier` and collapsing
/// duplicates to the shallowest occurrence.
public extension ZoomAXSupport {
    /// Zoom's identifier for the participants toolbar button, alongside its
    /// siblings `audio`, `video`, `chat`, `share` and `hosttools`.
    static let participantsButtonIdentifier = "participant"

    /// Fallback labels for clients that do not publish the identifier.
    static let participantsToggleTitles = [
        "participants",
        "manage participants",
        "open participants",
        "show participants",
        "participants panel"
    ]

    /// The neighbouring caret opens a menu and must never be pressed.
    static let participantsToggleRejectTitles = [
        "participants options",
        "invite",
        "invite participants",
        "invite people",
        "copy invite link",
        "participants list"
    ]

    enum ParticipantsPanelState: String, Equatable {
        case open
        case closed
        case unknown
    }

    struct ParticipantsToggle: Equatable {
        public let matchedText: String
        public let evidence: String
        /// State read from the control's own description.
        public let state: ParticipantsPanelState
        public let enabled: Bool
        public let indexPath: [Int]

        public init(
            matchedText: String,
            evidence: String,
            state: ParticipantsPanelState,
            enabled: Bool,
            indexPath: [Int]
        ) {
            self.matchedText = matchedText
            self.evidence = evidence
            self.state = state
            self.enabled = enabled
            self.indexPath = indexPath
        }
    }

    /// Zoom's action selector for the participants command in the View menu.
    static let participantsMenuIdentifier = "onmanageparticipants:"
    static let participantsMenuTitles = [
        "show participants", "hide participants", "manage participants", "participants"
    ]

    struct ParticipantsMenuCommand: Equatable {
        public let title: String
        public let state: ParticipantsPanelState
        public let enabled: Bool
        public let indexPath: [Int]

        public init(title: String, state: ParticipantsPanelState, enabled: Bool, indexPath: [Int]) {
            self.title = title
            self.state = state
            self.enabled = enabled
            self.indexPath = indexPath
        }
    }

    /// Whether Zoom is currently in a meeting, read from its menu bar.
    ///
    /// Zoom adds a `Meeting` menu for the duration of a call. Being an
    /// application-level element, it is readable even when the meeting window
    /// itself sits on another Space and never appears in `AXWindows`.
    static func meetingMenuPresent(inMenuBar menuBar: SnapshotNode) -> Bool {
        menuBar.children.contains { child in
            child.role == "AXMenuBarItem" && normalized(child.title ?? "") == meetingMenuBarTitle
        }
    }

    /// Finds the participants command in Zoom's menus.
    ///
    /// This is the primary way the panel is opened. The in-meeting toolbar is
    /// unusable for automation because Zoom hides it when the pointer is not
    /// over the window, and a hidden toolbar is not merely invisible — its
    /// buttons leave the Accessibility tree entirely. The menu is always there.
    static func participantsMenuCommand(inMenuBar menuBar: SnapshotNode) -> ParticipantsMenuCommand? {
        var found: ParticipantsMenuCommand?

        func walk(_ node: SnapshotNode, indexPath: [Int]) {
            if node.role == "AXMenuItem", node.actions.contains(pressAction) {
                let title = normalized(node.title ?? "")
                let identifierMatches = node.identifier
                    .map { normalized($0) == participantsMenuIdentifier } ?? false
                if identifierMatches || participantsMenuTitles.contains(title) {
                    let state: ParticipantsPanelState
                    if title.hasPrefix("show") {
                        state = .closed
                    } else if title.hasPrefix("hide") {
                        state = .open
                    } else {
                        state = .unknown
                    }
                    if found == nil {
                        found = ParticipantsMenuCommand(
                            title: node.title ?? "",
                            state: state,
                            enabled: node.enabled,
                            indexPath: indexPath
                        )
                    }
                }
            }
            for (index, child) in node.children.enumerated() {
                walk(child, indexPath: indexPath + [index])
            }
        }
        walk(menuBar, indexPath: [])
        return found
    }

    /// Reads panel state out of the toolbar button's description.
    ///
    /// Live text: `"Open participants panel, closed, 1 participants"`. The verb
    /// states the action and the middle token states the current state, so both
    /// are read and must agree; disagreement yields `unknown` rather than a
    /// guess, because pressing the toggle when it is already open closes it and
    /// blinds Auto Admit.
    static func participantsState(fromDescription description: String?) -> ParticipantsPanelState {
        guard let description else { return .unknown }
        let value = normalized(description)
        guard !value.isEmpty else { return .unknown }

        var fromVerb: ParticipantsPanelState = .unknown
        if value.hasPrefix("open participants panel") || value.hasPrefix("open the participants") {
            fromVerb = .closed
        } else if value.hasPrefix("close participants panel") || value.hasPrefix("close the participants") {
            fromVerb = .open
        }

        var fromToken: ParticipantsPanelState = .unknown
        let hasClosed = value.contains(", closed") || value.contains(" closed,")
        let hasOpen = value.contains(", open") || value.contains(" open,") || value.contains(", opened")
        if hasClosed && !hasOpen {
            fromToken = .closed
        } else if hasOpen && !hasClosed {
            fromToken = .open
        }

        switch (fromVerb, fromToken) {
        case (.unknown, let token): return token
        case (let verb, .unknown): return verb
        case (let verb, let token): return verb == token ? verb : .unknown
        }
    }

    /// Locates the control that opens the panel, without pressing anything.
    static func participantsToggle(inWindow window: SnapshotNode) -> ParticipantsToggle? {
        var matches: [ParticipantsToggle] = []

        func consider(_ node: SnapshotNode, indexPath: [Int]) {
            guard node.role == "AXButton", node.actions.contains(pressAction) else { return }

            let texts = accessibleTexts(of: node)
            let labels = texts.filter { $0.attribute != "AXIdentifier" }.map { normalized($0.text) }
            // "Participants options" is the caret beside the real button.
            guard !labels.contains(where: { label in
                participantsToggleRejectTitles.contains { label == $0 || label.hasPrefix($0) }
            }) else { return }

            let identifierMatches = node.identifier.map { normalized($0) == participantsButtonIdentifier } ?? false
            let labelMatches = labels.contains { participantsToggleTitles.contains($0) }
            guard identifierMatches || labelMatches else { return }

            matches.append(ParticipantsToggle(
                matchedText: node.description ?? node.title ?? participantsButtonIdentifier,
                evidence: identifierMatches ? "AXIdentifier=participant" : "label",
                state: participantsState(fromDescription: node.description ?? node.title),
                enabled: node.enabled,
                indexPath: indexPath
            ))
        }

        func walk(_ node: SnapshotNode, indexPath: [Int]) {
            consider(node, indexPath: indexPath)
            for (index, child) in node.children.enumerated() {
                walk(child, indexPath: indexPath + [index])
            }
        }
        walk(window, indexPath: [])

        guard !matches.isEmpty else { return nil }

        // The self-nesting toolbar reports the same button repeatedly. Genuine
        // ambiguity is two *different* controls, so duplicates of one control
        // are collapsed to the shallowest occurrence and only distinct labels
        // count as ambiguous.
        let distinctLabels = Set(matches.map { normalized($0.matchedText) })
        guard distinctLabels.count == 1 else { return nil }
        return matches.min { $0.indexPath.count < $1.indexPath.count }
    }

    /// Panel state, preferring the control's own description and falling back to
    /// the structural markers the Admit matcher itself relies on.
    static func participantsPanelState(inWindow window: SnapshotNode) -> ParticipantsPanelState {
        if hasMeetingStructure(inSnapshot: window) { return .open }
        if let toggle = participantsToggle(inWindow: window), toggle.state != .unknown {
            return toggle.state
        }
        return .closed
    }
}
