import ApplicationServices
import AppKit
import Foundation

/// Live side of the menu-bar account layer: snapshotting, re-resolution and the
/// guarded press. The decision logic lives in the pure functions in
/// `ZoomMenuBar.swift`; this file only talks to Accessibility.
public extension ZoomAXSupport {
    struct MenuBarReading {
        public let root: SnapshotNode
        public let menuBarElement: AXUIElement
        public let entries: [AccountMenuEntry]
        public let activeAccount: AccountMenuEntry?
    }

    enum MenuPressOutcome: Equatable {
        case pressed
        /// The live element no longer matches what was matched in the snapshot.
        case verificationFailed(String)
        case axError(AXError)
        case elementUnavailable
    }

    /// Snapshot of Zoom's menu bar, cheap enough to run repeatedly.
    ///
    /// Only the Zoom application menu is walked in depth; the other menu bar
    /// items are recorded as placeholders so that child indices — and therefore
    /// the index paths used to re-resolve live elements — stay exact.
    static func zoomMenuBarReading(pid: pid_t) -> MenuBarReading? {
        let application = freshZoomApplicationElement(pid: pid, messagingTimeout: 5)
        let menuBarRead = attributeValue(application, kAXMenuBarAttribute)
        guard menuBarRead.error == .success,
              let value = menuBarRead.value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let menuBar = unsafeBitCast(value, to: AXUIElement.self)

        var barChildren: [SnapshotNode] = []
        for barItem in children(of: menuBar) {
            let title = copyStringAttribute(barItem, kAXTitleAttribute)
            let normalizedTitle = normalized(title ?? "")
            if zoomApplicationMenuTitles.contains(normalizedTitle)
                || zoomMeetingMenuTitles.contains(normalizedTitle) {
                // The Zoom menu holds Switch account; View holds Show
                // participants. Both need a real walk.
                barChildren.append(snapshot(from: buildTree(from: barItem, maxDepth: 4, maxChildren: 200)))
            } else {
                barChildren.append(SnapshotNode(role: "AXMenuBarItem", title: title))
            }
        }

        let root = SnapshotNode(role: "AXMenuBar", children: barChildren)
        let entries = switchAccountEntries(inMenuBar: root)
        return MenuBarReading(
            root: root,
            menuBarElement: menuBar,
            entries: entries,
            activeAccount: activeAccount(inMenuBar: root)
        )
    }

    /// Walks child indices from a root element to the live element.
    static func resolveElement(at indexPath: [Int], from root: AXUIElement) -> AXUIElement? {
        var current = root
        for index in indexPath {
            let childElements = children(of: current)
            guard childElements.indices.contains(index) else { return nil }
            current = childElements[index]
        }
        return current
    }

    /// Presses a saved-account item after re-verifying it against the live tree.
    ///
    /// The verification is the safety boundary: an index path alone is never
    /// trusted, because the sign-out submenu holds identically titled items. The
    /// live element must still be an enabled `AXMenuItem`, carry Zoom's account
    /// item identifier, expose `AXPress`, and have exactly the title that was
    /// matched.
    static func pressAccountEntry(_ entry: AccountMenuEntry, in reading: MenuBarReading) -> MenuPressOutcome {
        guard let element = resolveElement(at: entry.indexPath, from: reading.menuBarElement) else {
            return .elementUnavailable
        }

        guard copyStringAttribute(element, kAXRoleAttribute) == "AXMenuItem" else {
            return .verificationFailed("element is no longer a menu item")
        }
        guard let liveTitle = copyStringAttribute(element, kAXTitleAttribute),
              normalized(liveTitle) == normalized(entry.rawTitle) else {
            return .verificationFailed("menu item title changed")
        }
        guard copyStringAttribute(element, kAXIdentifierAttribute) == accountMenuItemIdentifier else {
            return .verificationFailed("menu item identifier changed")
        }
        guard isEnabled(element) else {
            return .verificationFailed("menu item is disabled")
        }
        guard actionNames(of: element).contains(pressAction) else {
            return .verificationFailed("menu item does not expose AXPress")
        }

        let result = press(element)
        return result == .success ? .pressed : .axError(result)
    }

    /// Presses a menu item located by its AppKit action identifier.
    ///
    /// Identifiers are used rather than titles because they do not change with
    /// localisation, and because this is how the participants panel is opened:
    /// `View ▸ Show participants` (`onManageParticipants:`) works even when the
    /// meeting window has been moved to another Space, where the in-meeting
    /// toolbar button is unreachable.
    static func pressMenuItem(
        withIdentifier identifier: String,
        in reading: MenuBarReading
    ) -> MenuPressOutcome {
        guard let match = menuItem(withIdentifier: identifier, inMenuBar: reading.root) else {
            return .elementUnavailable
        }
        guard let element = resolveElement(at: match.indexPath, from: reading.menuBarElement) else {
            return .elementUnavailable
        }
        guard copyStringAttribute(element, kAXRoleAttribute) == "AXMenuItem" else {
            return .verificationFailed("element is no longer a menu item")
        }
        guard copyStringAttribute(element, kAXIdentifierAttribute) == identifier else {
            return .verificationFailed("menu item identifier changed")
        }
        guard isEnabled(element) else {
            return .verificationFailed("menu item is disabled")
        }
        guard actionNames(of: element).contains(pressAction) else {
            return .verificationFailed("menu item does not expose AXPress")
        }
        let result = press(element)
        return result == .success ? .pressed : .axError(result)
    }

    /// Presses a Zoom application menu entry such as `Start meeting`, with the
    /// same re-verification discipline.
    static func pressApplicationMenuItem(
        titled title: String,
        in reading: MenuBarReading
    ) -> MenuPressOutcome {
        guard let match = applicationMenuItem(titled: title, inMenuBar: reading.root) else {
            return .elementUnavailable
        }
        guard let element = resolveElement(at: match.indexPath, from: reading.menuBarElement) else {
            return .elementUnavailable
        }
        guard copyStringAttribute(element, kAXRoleAttribute) == "AXMenuItem",
              normalized(copyStringAttribute(element, kAXTitleAttribute) ?? "") == normalized(title) else {
            return .verificationFailed("menu item title changed")
        }
        guard isEnabled(element) else {
            return .verificationFailed("menu item is disabled")
        }
        guard actionNames(of: element).contains(pressAction) else {
            return .verificationFailed("menu item does not expose AXPress")
        }
        let result = press(element)
        return result == .success ? .pressed : .axError(result)
    }
}
