import ApplicationServices
import Foundation

/// Reading the in-meeting participant list.
///
/// Grounded in the live hierarchy:
///
/// ```
/// AXOutline description="Participants list"
///   AXRow
///     AXCell identifier="ZMHCTableItemType_PANELIST"
///       AXStaticText value="eyouth coordinator (Host, me)"
///       AXMenuButton description="More options for eyouth coordinator, collapsed"
/// ```
///
/// Two properties drive the design. Admitted participants and Waiting Room
/// entries are distinguished by the cell identifier, so attendance never counts
/// someone still waiting. And Zoom exposes no per-participant identifier, so
/// identity has to come from the displayed name — which is exactly why the
/// attendance layer above this treats names as evidence rather than as identity.
public extension ZoomAXSupport {
    enum ParticipantRole: String, Equatable, CaseIterable {
        case host
        case coHost
        case me
        case guest
    }

    struct ParticipantRow: Equatable {
        /// The full text Zoom displayed, e.g. `"eyouth coordinator (Host, me)"`.
        public let rawText: String
        /// The name with a trailing role parenthetical removed.
        public let displayName: String
        public let roles: Set<ParticipantRole>
        public let indexPath: [Int]

        public init(rawText: String, displayName: String, roles: Set<ParticipantRole>, indexPath: [Int]) {
            self.rawText = rawText
            self.displayName = displayName
            self.roles = roles
            self.indexPath = indexPath
        }

        /// The host account running the app is not a student.
        public var isSelfOrHost: Bool {
            roles.contains(.me) || roles.contains(.host) || roles.contains(.coHost)
        }
    }

    /// What a single read of the participants list produced.
    ///
    /// `listAvailable` is deliberately separate from an empty list. Zoom drops
    /// whole subtrees out of Accessibility when panels are hidden, and reading
    /// "no rows" as "everybody left" would silently mark a class absent.
    struct ParticipantsReadout: Equatable {
        public let listAvailable: Bool
        public let admitted: [ParticipantRow]
        public let waiting: [ParticipantRow]
        /// Count Zoom itself reports, when it exposes one.
        public let reportedCount: Int?

        public init(
            listAvailable: Bool,
            admitted: [ParticipantRow],
            waiting: [ParticipantRow],
            reportedCount: Int?
        ) {
            self.listAvailable = listAvailable
            self.admitted = admitted
            self.waiting = waiting
            self.reportedCount = reportedCount
        }

        public static let unavailable = ParticipantsReadout(
            listAvailable: false,
            admitted: [],
            waiting: [],
            reportedCount: nil
        )
    }

    static let participantsListDescription = "participants list"
    static let panelistIdentifier = "ZMHCTableItemType_PANELIST"

    /// Role words Zoom appends in parentheses after a name.
    static let participantRoleTokens: [String: ParticipantRole] = [
        "host": .host,
        "co-host": .coHost,
        "cohost": .coHost,
        "me": .me,
        "you": .me,
        "guest": .guest
    ]

    /// Splits `"Mohamed Ahmed (Host, me)"` into a name and its role markers.
    ///
    /// Only a trailing parenthetical made up *entirely* of known role words is
    /// removed. Names legitimately contain parentheses, and stripping any
    /// trailing bracket would quietly rewrite somebody's name.
    static func parseParticipantText(_ raw: String) -> (displayName: String, roles: Set<ParticipantRole>) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else {
            return (trimmed, [])
        }

        let inside = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        let tokens = inside
            .split(separator: ",")
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return (trimmed, []) }

        var roles: Set<ParticipantRole> = []
        for token in tokens {
            guard let role = participantRoleTokens[token] else {
                // An unrecognised word means this is part of the name.
                return (trimmed, [])
            }
            roles.insert(role)
        }

        let name = String(trimmed[trimmed.startIndex..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? trimmed : name, roles)
    }

    /// Reads every participant row out of a meeting window snapshot.
    static func participantsReadout(inWindow window: SnapshotNode) -> ParticipantsReadout {
        guard let outline = participantsOutline(in: window) else {
            return .unavailable
        }

        var admitted: [ParticipantRow] = []
        var waiting: [ParticipantRow] = []
        // Dedupe on what the row *is*, not where it sits.
        //
        // Zoom republishes whole subtrees at different depths — the in-meeting
        // toolbar does it heavily — so two occurrences of one person carry two
        // different index paths. Keying on the path would happily record the
        // same student twice; keying on the row's identity collapses them, and
        // the shallowest occurrence is kept as the canonical one.
        var admittedKeys: [String: Int] = [:]
        var waitingKeys: [String: Int] = [:]

        func add(_ row: ParticipantRow, to rows: inout [ParticipantRow], keys: inout [String: Int]) {
            let key = normalized(row.rawText)
            guard !key.isEmpty else { return }
            guard let existing = keys[key] else {
                keys[key] = rows.count
                rows.append(row)
                return
            }
            if row.indexPath.count < rows[existing].indexPath.count {
                rows[existing] = row
            }
        }

        func walk(_ node: SnapshotNode, indexPath: [Int]) {
            if node.role == "AXCell", let identifier = node.identifier {
                if identifier == panelistIdentifier {
                    if let row = row(from: node, indexPath: indexPath) {
                        add(row, to: &admitted, keys: &admittedKeys)
                    }
                } else if identifier == waitingListIdentifier {
                    if let row = row(from: node, indexPath: indexPath) {
                        add(row, to: &waiting, keys: &waitingKeys)
                    }
                }
                // A cell's own subtree holds its controls, not further rows.
                return
            }
            for (index, child) in node.children.enumerated() {
                walk(child, indexPath: indexPath + [index])
            }
        }
        walk(outline.node, indexPath: outline.indexPath)

        return ParticipantsReadout(
            listAvailable: true,
            admitted: admitted,
            waiting: waiting,
            reportedCount: reportedParticipantCount(in: window)
        )
    }

    /// The participant name lives in the row's first static text.
    private static func row(from cell: SnapshotNode, indexPath: [Int]) -> ParticipantRow? {
        guard let text = firstStaticText(in: cell), !text.isEmpty else { return nil }
        let parsed = parseParticipantText(text)
        guard !parsed.displayName.isEmpty else { return nil }
        return ParticipantRow(
            rawText: text,
            displayName: parsed.displayName,
            roles: parsed.roles,
            indexPath: indexPath
        )
    }

    private static func firstStaticText(in node: SnapshotNode) -> String? {
        if node.role == "AXStaticText" {
            for candidate in [node.value, node.title, node.description] {
                if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                    return candidate
                }
            }
        }
        for child in node.children {
            if let found = firstStaticText(in: child) { return found }
        }
        return nil
    }

    private static func participantsOutline(
        in node: SnapshotNode,
        indexPath: [Int] = []
    ) -> (node: SnapshotNode, indexPath: [Int])? {
        if node.role == "AXOutline",
           normalized(node.description ?? "") == participantsListDescription {
            return (node, indexPath)
        }
        for (index, child) in node.children.enumerated() {
            if let found = participantsOutline(in: child, indexPath: indexPath + [index]) {
                return found
            }
        }
        return nil
    }

    /// Zoom labels the panel `Participants (N)`; used only as corroboration.
    static func reportedParticipantCount(in node: SnapshotNode) -> Int? {
        for text in [node.description, node.value, node.title].compactMap({ $0 }) {
            let value = normalized(text)
            guard value.hasPrefix("participants (") , value.hasSuffix(")") else { continue }
            let digits = value.filter(\.isNumber)
            if let count = Int(digits) { return count }
        }
        for child in node.children {
            if let count = reportedParticipantCount(in: child) { return count }
        }
        return nil
    }
}

public extension ZoomAXSupport {
    /// Live read of the participants list from the running meeting.
    ///
    /// Fresh references every call, like every other scan in this app: the
    /// participants outline is rebuilt by Zoom as people join and leave, so a
    /// retained element goes stale quickly.
    ///
    /// Returns `.unavailable` — never an empty list — when the meeting window or
    /// the panel cannot be read, so the recorder can tell "cannot see" from
    /// "nobody there".
    static func participantsReadout(pid: pid_t) -> ParticipantsReadout {
        let application = freshZoomApplicationElement(pid: pid, messagingTimeout: 5)
        let windows = windowsResult(of: application)
        guard windows.error == .success else { return .unavailable }

        for window in windows.windows {
            let title = windowTitle(window)
            guard normalized(title) != "zoom workplace" else { continue }

            // The participants outline sits a few levels below the window, well
            // inside a depth that stays cheap to walk.
            let snapshot = snapshot(from: buildTree(from: window, maxDepth: 12, maxChildren: 400, maxNodes: 20_000))
            let readout = participantsReadout(inWindow: snapshot)
            if readout.listAvailable { return readout }
        }
        return .unavailable
    }
}
