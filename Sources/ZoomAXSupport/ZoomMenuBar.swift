import ApplicationServices
import Foundation

/// Zoom account discovery and switching through the application menu bar.
///
/// The menu bar was chosen over the profile popover for three reasons found by
/// live inspection:
///
/// * It is an application-level Accessibility element, so it stays readable even
///   when every Zoom window has been moved to another Space and `AXWindows` is
///   empty — which is exactly the state the capture was taken in.
/// * Zoom builds the whole `Switch account` submenu eagerly, so the saved
///   accounts can be enumerated without opening any menu.
/// * Each account item carries `AXMenuItemMarkChar` = "✓" when it is the
///   signed-in account, which gives a direct read of the active account.
///
/// Safety note that drives the whole design: the `Sign out` submenu contains the
/// *same account titles* as `Switch account`. Selection is therefore scoped
/// structurally to the `Switch account` submenu, and anything reachable under a
/// sign-out item is rejected outright.
public extension ZoomAXSupport {
    static let switchAccountMenuTitle = "switch account"
    static let signOutMenuTitle = "sign out"
    static let accountMenuItemIdentifier = "menuItemDidClicked:"
    static let addAccountIdentifier = "addAccount:"
    static let signOutAllAccountsIdentifier = "signOutAllAccounts:"
    static let zoomApplicationMenuTitles = ["zoom workplace", "zoom.us", "zoom"]
    /// Menus that only exist during a meeting, or that hold in-meeting commands.
    static let zoomMeetingMenuTitles = ["view", "meeting"]
    /// Zoom adds this menu bar item for the duration of a meeting, which makes
    /// it an application-level "a meeting is running" signal that keeps working
    /// when every Zoom window is on another Space.
    static let meetingMenuBarTitle = "meeting"
    /// Observed on every account row of the signed-in account.
    static let activeAccountMarkCharacters: Set<String> = ["✓", "√", "•"]

    /// One saved Zoom account as advertised by the Switch account submenu.
    struct AccountMenuEntry: Equatable {
        /// Exactly as Zoom renders it, e.g. `eyouth coordinator(depi+11@eyouthlearning.com)`.
        public let rawTitle: String
        public let displayName: String
        public let email: String?
        public let isActive: Bool
        public let enabled: Bool
        /// Child indices from the menu bar root, used to re-resolve the live
        /// element immediately before pressing it.
        public let indexPath: [Int]

        public init(
            rawTitle: String,
            displayName: String,
            email: String?,
            isActive: Bool,
            enabled: Bool,
            indexPath: [Int]
        ) {
            self.rawTitle = rawTitle
            self.displayName = displayName
            self.email = email
            self.isActive = isActive
            self.enabled = enabled
            self.indexPath = indexPath
        }
    }

    enum AccountLookup: Equatable {
        case found(AccountMenuEntry)
        case notFound
        /// Several saved accounts matched. The workflow must stop rather than guess.
        case ambiguous([AccountMenuEntry])
    }

    /// Splits `Display Name(email@example.com)` into its parts.
    /// Returns a nil email when Zoom renders a title without one.
    static func parseAccountTitle(_ title: String) -> (displayName: String, email: String?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.lastIndex(of: "("),
              let close = trimmed.lastIndex(of: ")"),
              open < close else {
            return (trimmed, nil)
        }
        let candidate = String(trimmed[trimmed.index(after: open)..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.contains("@"), !candidate.contains(" ") else {
            return (trimmed, nil)
        }
        let name = String(trimmed[trimmed.startIndex..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? trimmed : name, candidate)
    }

    /// Every saved account under the `Switch account` submenu.
    ///
    /// Deliberately structural: it locates the Zoom application menu, then the
    /// item titled exactly `Switch account`, then that item's own submenu. It
    /// never searches the whole tree for account-looking titles, because the
    /// `Sign out` submenu would match just as well.
    static func switchAccountEntries(inMenuBar menuBar: SnapshotNode) -> [AccountMenuEntry] {
        guard let submenu = switchAccountSubmenu(inMenuBar: menuBar) else { return [] }

        var entries: [AccountMenuEntry] = []
        for (index, item) in submenu.node.children.enumerated() {
            guard item.role == "AXMenuItem",
                  item.identifier == accountMenuItemIdentifier,
                  let title = item.title,
                  !title.isEmpty else {
                continue
            }
            // Belt and braces: these two are the destructive neighbours.
            guard item.identifier != addAccountIdentifier,
                  item.identifier != signOutAllAccountsIdentifier else {
                continue
            }
            let parsed = parseAccountTitle(title)
            entries.append(AccountMenuEntry(
                rawTitle: title,
                displayName: parsed.displayName,
                email: parsed.email,
                isActive: isActiveAccountMark(item.markCharacter),
                enabled: item.enabled,
                indexPath: submenu.indexPath + [index]
            ))
        }
        return entries
    }

    static func isActiveAccountMark(_ markCharacter: String?) -> Bool {
        guard let markCharacter else { return false }
        let trimmed = markCharacter.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && activeAccountMarkCharacters.contains(trimmed)
    }

    /// The signed-in account, read from the checkmark Zoom puts on it.
    static func activeAccount(inMenuBar menuBar: SnapshotNode) -> AccountMenuEntry? {
        let active = switchAccountEntries(inMenuBar: menuBar).filter(\.isActive)
        // More than one checkmark means the assumption behind this read no longer
        // holds; report nothing rather than a guess.
        return active.count == 1 ? active[0] : nil
    }

    /// Matches a configured profile identifier against the saved accounts.
    ///
    /// An identifier containing `@` is matched against the account email only,
    /// which is the one unique key: the observed Zoom accounts include three
    /// different accounts all displaying the name "eyouth coordinator". An
    /// identifier without `@` falls back to the display name, where such a
    /// collision correctly resolves to `.ambiguous` instead of a coin flip.
    static func matchAccount(identifier: String, in entries: [AccountMenuEntry]) -> AccountLookup {
        let wanted = normalized(identifier)
        guard !wanted.isEmpty else { return .notFound }

        let matches: [AccountMenuEntry]
        if wanted.contains("@") {
            matches = entries.filter { normalized($0.email ?? "") == wanted }
        } else {
            matches = entries.filter { normalized($0.displayName) == wanted }
        }

        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0])
        default: return .ambiguous(matches)
        }
    }

    /// The `Start meeting` / `Join meeting...` style entries of the Zoom
    /// application menu, located structurally rather than by index.
    static func applicationMenuItem(
        titled title: String,
        inMenuBar menuBar: SnapshotNode
    ) -> (node: SnapshotNode, indexPath: [Int])? {
        guard let applicationMenu = zoomApplicationMenu(inMenuBar: menuBar) else { return nil }
        let wanted = normalized(title)
        for (index, item) in applicationMenu.node.children.enumerated()
        where item.role == "AXMenuItem" && normalized(item.title ?? "") == wanted {
            return (item, applicationMenu.indexPath + [index])
        }
        return nil
    }

    // MARK: Structural location

    private static func zoomApplicationMenu(
        inMenuBar menuBar: SnapshotNode
    ) -> (node: SnapshotNode, indexPath: [Int])? {
        for (barIndex, barItem) in menuBar.children.enumerated() {
            guard barItem.role == "AXMenuBarItem",
                  zoomApplicationMenuTitles.contains(normalized(barItem.title ?? "")) else {
                continue
            }
            for (menuIndex, menu) in barItem.children.enumerated() where menu.role == "AXMenu" {
                return (menu, [barIndex, menuIndex])
            }
        }
        return nil
    }

    private static func switchAccountSubmenu(
        inMenuBar menuBar: SnapshotNode
    ) -> (node: SnapshotNode, indexPath: [Int])? {
        guard let applicationMenu = zoomApplicationMenu(inMenuBar: menuBar) else { return nil }

        for (itemIndex, item) in applicationMenu.node.children.enumerated() {
            guard item.role == "AXMenuItem" else { continue }
            let title = normalized(item.title ?? "")
            // Hard stop: never descend into the sign-out submenu, which lists the
            // very same accounts.
            guard title == switchAccountMenuTitle, !title.contains(signOutMenuTitle) else { continue }

            for (menuIndex, menu) in item.children.enumerated() where menu.role == "AXMenu" {
                return (menu, applicationMenu.indexPath + [itemIndex, menuIndex])
            }
        }
        return nil
    }
}
