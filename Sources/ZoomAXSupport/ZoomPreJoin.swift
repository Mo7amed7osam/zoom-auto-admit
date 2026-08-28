import ApplicationServices
import Foundation

/// Zoom's pre-join preview: the window that offers Audio, Video and Start
/// before the meeting actually begins.
///
/// Zoom labels these controls with the *action* they perform, not the state they
/// are in — "Mute" means the microphone is currently live, "Unmute" means it is
/// already muted, "Start Video" means the camera is currently off. Reading them
/// the other way round would turn a microphone *on* right before a meeting, so
/// every mapping here is explicit and anything outside the known vocabulary is
/// reported as `unknown`, never assumed.
public extension ZoomAXSupport {
    enum PreJoinControlKind: String, Equatable {
        case microphone
        case camera

        public var displayName: String {
            switch self {
            case .microphone: return "Microphone"
            case .camera: return "Camera"
            }
        }
    }

    /// `on` means the device is live (transmitting). `off` means muted or stopped.
    enum ToggleState: String, Equatable {
        case on
        case off
        case unknown
    }

    struct PreJoinControl: Equatable {
        public let kind: PreJoinControlKind
        public let state: ToggleState
        /// The exact accessible text the state was read from.
        public let matchedText: String
        /// Which attribute supplied it, for the log.
        public let evidence: String
        public let enabled: Bool
        public let indexPath: [Int]

        public init(
            kind: PreJoinControlKind,
            state: ToggleState,
            matchedText: String,
            evidence: String,
            enabled: Bool,
            indexPath: [Int]
        ) {
            self.kind = kind
            self.state = state
            self.matchedText = matchedText
            self.evidence = evidence
            self.enabled = enabled
            self.indexPath = indexPath
        }
    }

    struct PreJoinStartControl: Equatable {
        public let matchedText: String
        public let enabled: Bool
        public let indexPath: [Int]

        public init(matchedText: String, enabled: Bool, indexPath: [Int]) {
            self.matchedText = matchedText
            self.enabled = enabled
            self.indexPath = indexPath
        }
    }

    /// What a single pre-join window resolved to.
    struct PreJoinPreview: Equatable {
        public let windowTitle: String
        public let windowIndexPath: [Int]
        public let microphone: PreJoinControl?
        public let camera: PreJoinControl?
        public let start: PreJoinStartControl?
        /// Set when several controls of one kind matched, which must abort.
        public let ambiguousKinds: Set<PreJoinControlKind>

        public init(
            windowTitle: String,
            windowIndexPath: [Int],
            microphone: PreJoinControl?,
            camera: PreJoinControl?,
            start: PreJoinStartControl?,
            ambiguousKinds: Set<PreJoinControlKind> = []
        ) {
            self.windowTitle = windowTitle
            self.windowIndexPath = windowIndexPath
            self.microphone = microphone
            self.camera = camera
            self.start = start
            self.ambiguousKinds = ambiguousKinds
        }

        public func control(for kind: PreJoinControlKind) -> PreJoinControl? {
            kind == .microphone ? microphone : camera
        }
    }

    // MARK: Vocabulary

    /// Phrases that mean "pressing this will mute", i.e. the microphone is live.
    static let microphoneOnPhrases = ["mute", "mute my microphone", "mute audio", "mute microphone"]
    /// Phrases that mean the microphone is already muted or not transmitting.
    ///
    /// `join audio` / `connect audio` belong here deliberately: audio is not
    /// connected, so nothing is being transmitted, and pressing would *enable*
    /// audio. Treating it as already-off is both accurate and the safe direction.
    static let microphoneOffPhrases = [
        "unmute", "unmute my microphone", "unmute audio", "unmute microphone",
        "join audio", "connect audio", "join computer audio", "join with computer audio"
    ]
    /// Pressing this stops the camera, so the camera is live.
    static let cameraOnPhrases = ["stop video", "stop my video", "stop camera", "turn off video"]
    /// Pressing this starts the camera, so the camera is off.
    static let cameraOffPhrases = ["start video", "start my video", "start camera", "turn on video"]

    /// Buttons that begin the meeting from the preview.
    static let preJoinStartPhrases = ["start meeting", "start", "join meeting", "join", "join with video", "join without video"]
    /// Never treated as the Start button even though they contain "join".
    static let preJoinStartRejectPhrases = ["join audio", "connect audio", "join computer audio", "join with computer audio"]

    // MARK: Pure classification

    /// Reads one control's state from a single piece of accessible text.
    /// Returns nil when the text says nothing about this kind of control.
    static func toggleState(for kind: PreJoinControlKind, text: String?) -> ToggleState? {
        guard let text else { return nil }
        let value = normalized(text)
        guard !value.isEmpty else { return nil }

        let onPhrases = kind == .microphone ? microphoneOnPhrases : cameraOnPhrases
        let offPhrases = kind == .microphone ? microphoneOffPhrases : cameraOffPhrases

        // Longest phrases first so "unmute" is never read as "mute", and
        // "stop video" is never read by a shorter, weaker phrase.
        let matchesOff = offPhrases.contains { matchesPhrase(value, $0) }
        let matchesOn = onPhrases.contains { matchesPhrase(value, $0) }

        switch (matchesOn, matchesOff) {
        case (true, false): return .on
        case (false, true): return .off
        case (true, true): return .unknown   // contradictory text: refuse to read it
        case (false, false): return nil
        }
    }

    /// Whole-word-ish containment, so "unmute" never satisfies "mute".
    private static func matchesPhrase(_ haystack: String, _ phrase: String) -> Bool {
        guard let range = haystack.range(of: phrase) else { return false }
        let before = range.lowerBound == haystack.startIndex
            ? nil
            : haystack[haystack.index(before: range.lowerBound)]
        let after = range.upperBound == haystack.endIndex ? nil : haystack[range.upperBound]
        let isBoundary: (Character?) -> Bool = { character in
            guard let character else { return true }
            return !character.isLetter && !character.isNumber
        }
        return isBoundary(before) && isBoundary(after)
    }

    /// All accessible text of a node, paired with the attribute it came from.
    static func accessibleTexts(of node: SnapshotNode) -> [(attribute: String, text: String)] {
        var texts: [(String, String)] = []
        if let title = node.title, !title.isEmpty { texts.append(("AXTitle", title)) }
        if let description = node.description, !description.isEmpty {
            texts.append(("AXDescription", description))
        }
        if let value = node.value, !value.isEmpty { texts.append(("AXValue", value)) }
        if let help = node.help, !help.isEmpty { texts.append(("AXHelp", help)) }
        if let identifier = node.identifier, !identifier.isEmpty {
            texts.append(("AXIdentifier", identifier))
        }
        return texts
    }

    /// Classifies one node as a microphone/camera control, if it is one.
    static func preJoinControl(
        for kind: PreJoinControlKind,
        node: SnapshotNode,
        indexPath: [Int]
    ) -> PreJoinControl? {
        guard node.actions.contains(pressAction) else { return nil }

        var readings: [(state: ToggleState, text: String, attribute: String)] = []
        for entry in accessibleTexts(of: node) {
            if let state = toggleState(for: kind, text: entry.text) {
                readings.append((state, entry.text, entry.attribute))
            }
        }
        guard !readings.isEmpty else { return nil }

        let distinctStates = Set(readings.map(\.state))
        // Two attributes disagreeing, or a single contradictory one, is exactly
        // the situation where guessing would be worst.
        let resolved: ToggleState = distinctStates.count == 1 ? (distinctStates.first ?? .unknown) : .unknown
        let primary = readings[0]

        return PreJoinControl(
            kind: kind,
            state: resolved,
            matchedText: primary.text,
            evidence: readings.map { "\($0.attribute)=\(quoteForLog($0.text))" }.joined(separator: " "),
            enabled: node.enabled,
            indexPath: indexPath
        )
    }

    static func preJoinStartControl(node: SnapshotNode, indexPath: [Int]) -> PreJoinStartControl? {
        guard node.role == "AXButton", node.actions.contains(pressAction) else { return nil }

        for entry in accessibleTexts(of: node) where entry.attribute != "AXIdentifier" {
            let value = normalized(entry.text)
            guard !preJoinStartRejectPhrases.contains(where: { matchesPhrase(value, $0) }) else { continue }
            // Exact match only. A substring rule would happily press
            // "Start Video" or "Join Audio" to begin the meeting.
            guard preJoinStartPhrases.contains(value) else { continue }
            return PreJoinStartControl(
                matchedText: entry.text,
                enabled: node.enabled,
                indexPath: indexPath
            )
        }
        return nil
    }

    /// Resolves a candidate pre-join window.
    ///
    /// Recognition is structural rather than title-based: the live client titles
    /// this window "Zoom" at the window-server level and
    /// "<Name>'s Zoom Meeting" in its own UI, so a title rule would be fragile.
    /// A window qualifies when it offers a Start-style button together with at
    /// least one identifiable audio or video control, and shows none of the
    /// in-meeting participant structure.
    static func preJoinPreview(inWindow window: SnapshotNode, windowIndexPath: [Int]) -> PreJoinPreview? {
        guard !hasMeetingStructure(inSnapshot: window) else { return nil }

        var microphones: [PreJoinControl] = []
        var cameras: [PreJoinControl] = []
        var starts: [PreJoinStartControl] = []

        func walk(_ node: SnapshotNode, indexPath: [Int]) {
            if let control = preJoinControl(for: .microphone, node: node, indexPath: indexPath) {
                microphones.append(control)
            }
            if let control = preJoinControl(for: .camera, node: node, indexPath: indexPath) {
                cameras.append(control)
            }
            if let start = preJoinStartControl(node: node, indexPath: indexPath) {
                starts.append(start)
            }
            for (index, child) in node.children.enumerated() {
                walk(child, indexPath: indexPath + [index])
            }
        }
        walk(window, indexPath: [])

        guard let start = starts.first, !microphones.isEmpty || !cameras.isEmpty else {
            return nil
        }

        var ambiguous: Set<PreJoinControlKind> = []
        if microphones.count > 1 { ambiguous.insert(.microphone) }
        if cameras.count > 1 { ambiguous.insert(.camera) }
        if starts.count > 1 {
            // Several plausible Start buttons: refuse rather than pick one.
            return PreJoinPreview(
                windowTitle: window.title ?? "",
                windowIndexPath: windowIndexPath,
                microphone: microphones.count == 1 ? microphones[0] : nil,
                camera: cameras.count == 1 ? cameras[0] : nil,
                start: nil,
                ambiguousKinds: ambiguous
            )
        }

        return PreJoinPreview(
            windowTitle: window.title ?? "",
            windowIndexPath: windowIndexPath,
            microphone: microphones.count == 1 ? microphones[0] : nil,
            camera: cameras.count == 1 ? cameras[0] : nil,
            start: start,
            ambiguousKinds: ambiguous
        )
    }

    /// Snapshot-based variant of the in-meeting structure check.
    static func hasMeetingStructure(inSnapshot root: SnapshotNode) -> Bool {
        if root.identifier == waitingListIdentifier
            || root.identifier == waitingListGroupIdentifier
            || root.identifier == "ZMHCTableItemType_PANELIST" {
            return true
        }
        if root.role == "AXOutline", normalized(root.description ?? "") == "participants list" {
            return true
        }
        return root.children.contains { hasMeetingStructure(inSnapshot: $0) }
    }

    private static func quoteForLog(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
