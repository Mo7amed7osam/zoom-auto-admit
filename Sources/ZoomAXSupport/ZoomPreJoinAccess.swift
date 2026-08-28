import ApplicationServices
import AppKit
import Foundation

/// Live side of the pre-join preview: locating it among Zoom's windows,
/// re-resolving controls, and pressing them with the same re-verification
/// discipline used for Admit and for account switching.
public extension ZoomAXSupport {
    struct PreJoinReading {
        public let preview: PreJoinPreview
        /// The live window element the preview was read from.
        public let windowElement: AXUIElement
        /// Full snapshot, kept so a failure can be dumped for diagnostics.
        public let windowSnapshot: SnapshotNode
    }

    enum PreJoinPressOutcome: Equatable {
        case pressed
        case verificationFailed(String)
        case axError(AXError)
        case elementUnavailable
    }

    /// Finds Zoom's pre-join preview, if it is currently open.
    ///
    /// Returns nil when no preview exists — which is a normal, non-error state:
    /// Zoom only shows the preview when "show preview dialog when joining" is
    /// enabled, and otherwise goes straight into the meeting.
    static func preJoinReading(pid: pid_t) -> PreJoinReading? {
        let application = freshZoomApplicationElement(pid: pid, messagingTimeout: 5)
        var candidates: [AXUIElement] = windowsResult(of: application).windows

        // The preview is frequently the focused window before it lands in
        // AXWindows, so both are considered.
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            let read = attributeValue(application, attribute)
            if read.error == .success, let value = read.value,
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                candidates.append(unsafeBitCast(value, to: AXUIElement.self))
            }
        }

        for window in candidates {
            let title = windowTitle(window)
            // The home window is large and never a preview; skipping it by title
            // avoids building its very deep tree on every poll.
            guard normalized(title) != "zoom workplace" else { continue }

            let tree = buildTree(from: window, maxDepth: 14, maxChildren: 200)
            let snapshot = snapshot(from: tree)
            guard let preview = preJoinPreview(inWindow: snapshot, windowIndexPath: []) else { continue }
            return PreJoinReading(preview: preview, windowElement: window, windowSnapshot: snapshot)
        }
        return nil
    }

    /// Presses a microphone or camera control after re-verifying that the live
    /// element is still the same control, in the same state, that was matched.
    ///
    /// The state is re-checked deliberately: between reading and pressing, the
    /// user or Zoom itself could have changed it, and a blind press would then
    /// turn a device *on*.
    static func pressPreJoinControl(
        _ control: PreJoinControl,
        in reading: PreJoinReading
    ) -> PreJoinPressOutcome {
        guard let element = resolveElement(at: control.indexPath, from: reading.windowElement) else {
            return .elementUnavailable
        }
        guard isEnabled(element) else {
            return .verificationFailed("\(control.kind.displayName) control is disabled")
        }
        guard actionNames(of: element).contains(pressAction) else {
            return .verificationFailed("\(control.kind.displayName) control does not expose AXPress")
        }

        let liveNode = Node(element: element)
        let liveSnapshot = snapshot(from: liveNode)
        guard let live = preJoinControl(for: control.kind, node: liveSnapshot, indexPath: control.indexPath) else {
            return .verificationFailed("\(control.kind.displayName) control no longer identifies itself")
        }
        guard live.state == control.state else {
            return .verificationFailed(
                "\(control.kind.displayName) state changed from \(control.state.rawValue) to \(live.state.rawValue) before pressing"
            )
        }
        guard live.state == .on else {
            return .verificationFailed("\(control.kind.displayName) is not on; refusing to press")
        }

        let result = press(element)
        return result == .success ? .pressed : .axError(result)
    }

    /// Presses the preview's Start button after re-verifying it.
    static func pressPreJoinStart(
        _ start: PreJoinStartControl,
        in reading: PreJoinReading
    ) -> PreJoinPressOutcome {
        guard let element = resolveElement(at: start.indexPath, from: reading.windowElement) else {
            return .elementUnavailable
        }
        guard copyStringAttribute(element, kAXRoleAttribute) == "AXButton" else {
            return .verificationFailed("Start control is no longer a button")
        }
        guard isEnabled(element) else {
            return .verificationFailed("Start button is disabled")
        }
        guard actionNames(of: element).contains(pressAction) else {
            return .verificationFailed("Start button does not expose AXPress")
        }

        let liveNode = Node(element: element)
        guard let live = preJoinStartControl(node: snapshot(from: liveNode), indexPath: start.indexPath),
              normalized(live.matchedText) == normalized(start.matchedText) else {
            return .verificationFailed("Start button text changed")
        }

        let result = press(element)
        return result == .success ? .pressed : .axError(result)
    }

    /// Human-readable dump of a preview window, written when the pre-join step
    /// cannot identify what it needs so the vocabulary can be extended from real
    /// data instead of guesses.
    static func describePreJoinForDiagnostics(_ reading: PreJoinReading) -> String {
        var lines = ["Pre-join preview window title=\(String(reflecting: reading.preview.windowTitle))"]
        lines.append("microphone=\(reading.preview.microphone.map(describeControl) ?? "NOT FOUND")")
        lines.append("camera=\(reading.preview.camera.map(describeControl) ?? "NOT FOUND")")
        lines.append("start=\(reading.preview.start.map { "\(String(reflecting: $0.matchedText)) enabled=\($0.enabled) indexPath=\($0.indexPath)" } ?? "NOT FOUND")")
        if !reading.preview.ambiguousKinds.isEmpty {
            lines.append("ambiguous=\(reading.preview.ambiguousKinds.map(\.rawValue).sorted())")
        }
        lines.append("---- full hierarchy ----")
        lines.append(contentsOf: dump(reading.windowSnapshot, depth: 0, path: "root"))
        return lines.joined(separator: "\n")
    }

    private static func describeControl(_ control: PreJoinControl) -> String {
        "state=\(control.state.rawValue) matched=\(String(reflecting: control.matchedText)) evidence=[\(control.evidence)] enabled=\(control.enabled) indexPath=\(control.indexPath)"
    }

    private static func dump(_ node: SnapshotNode, depth: Int, path: String) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        var parts = ["\(indent)\(node.role) path=\(path)"]
        if let title = node.title, !title.isEmpty { parts.append(" title=\(String(reflecting: title))") }
        if let description = node.description, !description.isEmpty {
            parts.append(" description=\(String(reflecting: description))")
        }
        if let value = node.value, !value.isEmpty { parts.append(" value=\(String(reflecting: value))") }
        if let help = node.help, !help.isEmpty { parts.append(" help=\(String(reflecting: help))") }
        if let identifier = node.identifier, !identifier.isEmpty {
            parts.append(" identifier=\(String(reflecting: identifier))")
        }
        if !node.actions.isEmpty { parts.append(" actions=[\(node.actions.joined(separator: ","))]") }
        parts.append(" enabled=\(node.enabled)")

        var lines = [parts.joined()]
        for (index, child) in node.children.enumerated() {
            lines.append(contentsOf: dump(child, depth: depth + 1, path: "\(path)/\(index)"))
        }
        return lines
    }
}
