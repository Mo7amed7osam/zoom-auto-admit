import ApplicationServices
import AppKit
import Foundation

/// Read-only Accessibility capture of the live Zoom UI.
///
/// Discovery tool only: it never presses, activates, raises or focuses anything.
/// It exists so the account and meeting automation can be written against the
/// real Zoom hierarchy instead of guessed identifiers, and so the hierarchy can
/// be re-captured if a future Zoom build changes its UI.
public extension ZoomAXSupport {
    struct UICaptureOptions {
        public var maxDepth: Int
        public var maxChildren: Int
        public var includeMenuBar: Bool

        public init(maxDepth: Int = 22, maxChildren: Int = 400, includeMenuBar: Bool = true) {
            self.maxDepth = maxDepth
            self.maxChildren = maxChildren
            self.includeMenuBar = includeMenuBar
        }
    }

    /// Full textual dump of Zoom's menu bar and every window.
    static func captureZoomUI(options: UICaptureOptions = UICaptureOptions()) -> String {
        var lines: [String] = []
        lines.append("Zoom UI capture \(ISO8601DateFormatter().string(from: Date()))")

        guard let zoom = zoomApplication() else {
            lines.append("Zoom is not running.")
            return lines.joined(separator: "\n")
        }

        let running = NSRunningApplication(processIdentifier: zoom.pid)
        lines.append("Zoom pid=\(zoom.pid) bundle=\(zoom.bundleIdentifier)")
        lines.append("Zoom active=\(running?.isActive ?? false) hidden=\(running?.isHidden ?? false)")

        let previous = collectDiagnosticAttributes
        collectDiagnosticAttributes = true
        defer { collectDiagnosticAttributes = previous }

        let application = freshZoomApplicationElement(pid: zoom.pid, messagingTimeout: 10)

        let trust = accessibilityTrustSnapshot(prompt: false)
        lines.append("AXIsProcessTrusted=\(trust.isProcessTrusted) withOptions=\(trust.isProcessTrustedWithOptions)")
        lines.append("Application attributes: \(attributeNames(of: application).joined(separator: ", "))")

        if options.includeMenuBar {
            lines.append("")
            lines.append("========== MENU BAR ==========")
            let menuBarRead = attributeValue(application, kAXMenuBarAttribute)
            if menuBarRead.error == .success, let value = menuBarRead.value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let menuBar = unsafeBitCast(value, to: AXUIElement.self)
                lines.append(contentsOf: describe(
                    element: menuBar,
                    label: "AXMenuBar",
                    options: options
                ))
            } else {
                lines.append("Menu bar unavailable: \(menuBarRead.error.diagnosticDescription)")
            }
        }

        let windowsRead = windowsResult(of: application)
        lines.append("")
        lines.append("========== WINDOWS (\(windowsRead.windows.count)) ==========")
        if windowsRead.error != .success {
            lines.append("AXWindows unavailable: \(windowsRead.error.diagnosticDescription)")
        }
        if windowsRead.windows.isEmpty {
            // AXWindows is empty for windows the WindowServer has moved to another
            // Space. AXMainWindow / AXFocusedWindow sometimes still resolve, and
            // the CoreGraphics list always does.
            for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
                let read = attributeValue(application, attribute)
                if read.error == .success, let value = read.value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                    let window = unsafeBitCast(value, to: AXUIElement.self)
                    lines.append("")
                    lines.append("---------- \(attribute) title=\(String(reflecting: windowTitle(window))) ----------")
                    lines.append(contentsOf: describe(element: window, label: attribute, options: options))
                } else {
                    lines.append("\(attribute) unavailable: \(read.error.diagnosticDescription)")
                }
            }
            lines.append("")
            lines.append("========== COREGRAPHICS WINDOWS ==========")
            for window in cgWindows(ownerPID: zoom.pid) where window.layer == 0 {
                lines.append("id=\(window.windowID) name=\(String(reflecting: window.name ?? "")) layer=\(window.layer) onscreen=\(window.isOnscreen) bounds=\(window.bounds)")
            }
        }
        for (index, window) in windowsRead.windows.enumerated() {
            lines.append("")
            lines.append("---------- window[\(index)] title=\(String(reflecting: windowTitle(window))) ----------")
            lines.append(contentsOf: describe(element: window, label: "window[\(index)]", options: options))
        }

        return lines.joined(separator: "\n")
    }

    /// Attribute names an element advertises. Useful for spotting Zoom-specific
    /// attributes that the monitor does not read today.
    static func attributeNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let names = names as? [String] else { return [] }
        return names
    }

    private static let standardMenuItemAttributes: Set<String> = [
        "AXRole", "AXRoleDescription", "AXSubrole", "AXTitle", "AXDescription", "AXValue",
        "AXIdentifier", "AXHelp", "AXEnabled", "AXFocused", "AXParent", "AXChildren",
        "AXSelected", "AXSize", "AXPosition", "AXFrame", "AXMenuItemCmdChar",
        "AXMenuItemCmdVirtualKey", "AXMenuItemCmdGlyph", "AXMenuItemCmdModifiers",
        "AXMenuItemMarkChar", "AXMenuItemPrimaryUIElement", "AXServesAsTitleForUIElements",
        "AXTopLevelUIElement", "AXWindow", "AXElementBusy"
    ]

    private static func describe(
        element: AXUIElement,
        label: String,
        options: UICaptureOptions
    ) -> [String] {
        var lines: [String] = []

        func walk(_ element: AXUIElement, depth: Int, path: String) {
            let node = Node(element: element)
            let indent = String(repeating: "  ", count: depth)
            var parts = ["\(indent)\(node.role)"]
            if let subrole = node.subrole { parts.append("/\(subrole)") }
            parts.append(" path=\(path)")
            if let title = node.title, !title.isEmpty { parts.append(" title=\(String(reflecting: title))") }
            if let description = node.description, !description.isEmpty {
                parts.append(" description=\(String(reflecting: description))")
            }
            if let value = node.value, !value.isEmpty { parts.append(" value=\(String(reflecting: value))") }
            if let identifier = node.identifier, !identifier.isEmpty {
                parts.append(" identifier=\(String(reflecting: identifier))")
            }
            if let help = copyStringAttribute(element, kAXHelpAttribute), !help.isEmpty {
                parts.append(" help=\(String(reflecting: help))")
            }
            if !node.actions.isEmpty { parts.append(" actions=[\(node.actions.joined(separator: ","))]") }
            if node.role == "AXButton" || node.role == "AXMenuItem" || node.role == "AXCheckBox" {
                parts.append(" enabled=\(node.enabled)")
            }
            if node.role == "AXMenuItem" {
                // The mark character is how AppKit exposes a checked menu item,
                // which is the most likely place Zoom marks the active account.
                if let mark = copyStringAttribute(element, kAXMenuItemMarkCharAttribute), !mark.isEmpty {
                    parts.append(" markChar=\(String(reflecting: mark))")
                }
                if let selected = copyBoolAttribute(element, kAXSelectedAttribute) {
                    parts.append(" selected=\(selected)")
                }
                let names = attributeNames(of: element)
                let interesting = names.filter { !standardMenuItemAttributes.contains($0) }
                if !interesting.isEmpty {
                    parts.append(" extraAttributes=[\(interesting.joined(separator: ","))]")
                }
            }
            lines.append(parts.joined())

            guard depth < options.maxDepth else {
                lines.append("\(indent)  … depth limit")
                return
            }
            let children = ZoomAXSupport.children(of: element)
            for (index, child) in children.prefix(options.maxChildren).enumerated() {
                walk(child, depth: depth + 1, path: "\(path)/\(index)")
            }
            if children.count > options.maxChildren {
                lines.append("\(indent)  … \(children.count - options.maxChildren) more children omitted")
            }
        }

        walk(element, depth: 0, path: label)
        return lines
    }
}
