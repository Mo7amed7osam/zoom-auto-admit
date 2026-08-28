import AppKit
import ApplicationServices
import Foundation
import OSLog
import ZoomAXSupport
import ZoomAutoAdmitCore

/// Diagnostic capture of Zoom's pre-join preview.
///
/// The preview only exists between asking Zoom to start a meeting and pressing
/// Start, and it is frequently placed on another Space, where `AXWindows` cannot
/// see it. This mode opens the preview through Zoom's own `Start meeting` menu
/// entry, waits for it, dumps it, and deliberately **never presses Start**, so
/// no meeting is actually created.
enum PreJoinCapture {
    static let launchArgument = "--capture-prejoin"

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Zoom Auto Admit/zoom-prejoin-snapshot.log", isDirectory: false)
    }

    static func run(openPreview: Bool, timeout: TimeInterval = 60) {
        let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "prejoin-capture")
        var lines: [String] = ["Pre-join capture \(ISO8601DateFormatter().string(from: Date()))"]

        guard let process = ZoomAXSupport.zoomApplication() else {
            write(["Zoom is not running."])
            return
        }
        lines.append("Zoom pid=\(process.pid)")

        let previousCollect = ZoomAXSupport.collectDiagnosticAttributes
        ZoomAXSupport.collectDiagnosticAttributes = true
        defer { ZoomAXSupport.collectDiagnosticAttributes = previousCollect }

        // Always bring Zoom forward. The preview is routinely placed on another
        // Space, where AXWindows cannot see it at all; activating Zoom brings
        // that Space forward and makes the window readable.
        NSRunningApplication(processIdentifier: process.pid)?.activate()
        Thread.sleep(forTimeInterval: 1.5)

        if openPreview {
            // The home window's own button is used rather than the application
            // menu: AXPress on a menu item blocks for as long as the menu stays
            // open, which stalled an earlier attempt at this capture.
            let application = ZoomAXSupport.freshZoomApplicationElement(pid: process.pid, messagingTimeout: 5)
            let windows = ZoomAXSupport.windowsResult(of: application).windows
            var pressed = false
            for window in windows {
                let tree = ZoomAXSupport.buildTree(from: window, maxDepth: 14, maxChildren: 200)
                guard let button = findButton(describedAs: "start new meeting", in: tree) else { continue }
                guard ZoomAXSupport.isEnabled(button.element),
                      ZoomAXSupport.actionNames(of: button.element).contains(ZoomAXSupport.pressAction) else {
                    continue
                }
                let result = ZoomAXSupport.press(button.element)
                lines.append("Pressed 'Start new meeting' button: \(result.diagnosticDescription)")
                pressed = result == .success
                break
            }
            if !pressed {
                lines.append("Could not find an enabled 'Start new meeting' button.")
            }
            Thread.sleep(forTimeInterval: 2.5)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var captured = false
        var pollCount = 0

        while Date() < deadline && !captured {
            pollCount += 1
            lines.append("")
            lines.append("---- poll \(pollCount) ----")
            let application = ZoomAXSupport.freshZoomApplicationElement(pid: process.pid, messagingTimeout: 5)
            var candidates: [(label: String, element: AXUIElement)] = []

            let windows = ZoomAXSupport.windowsResult(of: application)
            for (index, window) in windows.windows.enumerated() {
                candidates.append(("AXWindows[\(index)]", window))
            }
            // The preview is often the focused/main window even when AXWindows
            // has not caught up with it.
            for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                let read = ZoomAXSupport.attributeValue(application, attribute)
                if read.error == .success, let value = read.value,
                   CFGetTypeID(value) == AXUIElementGetTypeID() {
                    candidates.append((attribute, unsafeBitCast(value, to: AXUIElement.self)))
                }
            }

            var seenTitles: [String] = []
            for candidate in candidates {
                let title = ZoomAXSupport.windowTitle(candidate.element)
                seenTitles.append("\(candidate.label)=\(String(reflecting: title))")

                // Cheap title check first. Building the home window's tree is
                // expensive enough to stall the whole capture if done per poll.
                guard ZoomAXSupport.normalized(title) != "zoom workplace" else { continue }

                let tree = ZoomAXSupport.buildTree(from: candidate.element, maxDepth: 18, maxChildren: 300)
                let snapshot = ZoomAXSupport.snapshot(from: tree)
                let preview = ZoomAXSupport.preJoinPreview(inWindow: snapshot, windowIndexPath: [])

                lines.append("")
                lines.append("===== CANDIDATE \(candidate.label) title=\(String(reflecting: title)) poll=\(pollCount) =====")
                lines.append("Pre-join matcher: \(preview.map(describe) ?? "not a pre-join preview")")
                lines.append("Participants panel: \(ZoomAXSupport.participantsPanelState(inWindow: snapshot).rawValue)")
                if let toggle = ZoomAXSupport.participantsToggle(inWindow: snapshot) {
                    lines.append("Participants toggle: matched=\(String(reflecting: toggle.matchedText)) via \(toggle.evidence) indexPath=\(toggle.indexPath)")
                } else {
                    lines.append("Participants toggle: NOT RECOGNISED")
                }
                lines.append("")
                lines.append("----- full hierarchy -----")
                lines.append(contentsOf: describeTree(snapshot, depth: 0, path: ""))
                captured = true
                // Keep going: the meeting window is usually not the first
                // non-home window Zoom reports.
                continue
            }

            if !captured {
                if pollCount == 1 || pollCount % 5 == 0 {
                    lines.append("poll \(pollCount): windows \(seenTitles.joined(separator: ", "))")
                }
                Thread.sleep(forTimeInterval: 1.0)
            }
        }

        if !captured {
            lines.append("No pre-join preview appeared within \(Int(timeout))s.")
        }
        lines.append("")
        lines.append("Start was deliberately NOT pressed; no meeting was created by this capture.")
        write(lines)
        logger.notice("Pre-join capture finished captured=\(captured)")
    }

    private static func findButton(
        describedAs normalizedDescription: String,
        in node: ZoomAXSupport.Node
    ) -> ZoomAXSupport.Node? {
        let matches = [node.description, node.title, node.help]
            .compactMap { $0 }
            .contains { ZoomAXSupport.normalized($0) == normalizedDescription }
        if node.role == "AXButton", matches { return node }
        for child in node.children {
            if let found = findButton(describedAs: normalizedDescription, in: child) { return found }
        }
        return nil
    }

    private static func describe(_ preview: ZoomAXSupport.PreJoinPreview) -> String {
        var parts = ["window=\(String(reflecting: preview.windowTitle))"]
        if let microphone = preview.microphone {
            parts.append("microphone state=\(microphone.state.rawValue) matched=\(String(reflecting: microphone.matchedText)) evidence=[\(microphone.evidence)] indexPath=\(microphone.indexPath)")
        } else {
            parts.append("microphone=NOT FOUND")
        }
        if let camera = preview.camera {
            parts.append("camera state=\(camera.state.rawValue) matched=\(String(reflecting: camera.matchedText)) evidence=[\(camera.evidence)] indexPath=\(camera.indexPath)")
        } else {
            parts.append("camera=NOT FOUND")
        }
        if let start = preview.start {
            parts.append("start matched=\(String(reflecting: start.matchedText)) enabled=\(start.enabled) indexPath=\(start.indexPath)")
        } else {
            parts.append("start=NOT FOUND")
        }
        if !preview.ambiguousKinds.isEmpty {
            parts.append("ambiguous=\(preview.ambiguousKinds.map(\.rawValue).sorted())")
        }
        return parts.joined(separator: "; ")
    }

    private static func describeTree(_ node: ZoomAXSupport.SnapshotNode, depth: Int, path: String) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        var parts = ["\(indent)\(node.role) path=\(path.isEmpty ? "root" : path)"]
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
            lines.append(contentsOf: describeTree(child, depth: depth + 1, path: path.isEmpty ? "\(index)" : "\(path)/\(index)"))
        }
        return lines
    }

    private static func write(_ lines: [String]) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(lines.joined(separator: "\n").utf8).write(to: fileURL, options: .atomic)
    }
}

/// One-shot check of the Participants panel against a live meeting, used to
/// verify the toolbar matcher without starting another meeting.
enum ParticipantsCheck {
    static let launchArgument = "--open-participants"

    static func run() {
        let log = SchedulerLog.shared
        guard let process = ZoomAXSupport.zoomApplication() else {
            log.write("Participants check: Zoom is not running")
            return
        }

        // Log what the reader actually sees, so a miss is diagnosable instead of
        // guessable.
        let application = ZoomAXSupport.freshZoomApplicationElement(pid: process.pid, messagingTimeout: 5)
        let windows = ZoomAXSupport.windowsResult(of: application)
        log.write("Participants check: AXWindows=\(windows.windows.count) error=\(windows.error.diagnosticDescription)")
        for (index, window) in windows.windows.enumerated() {
            let title = ZoomAXSupport.windowTitle(window)
            let shallow = ZoomAXSupport.snapshot(
                from: ZoomAXSupport.buildTree(from: window, maxDepth: 3, maxChildren: 120)
            )
            let buttons = shallow.children.filter { $0.role == "AXButton" }
            log.write("  window[\(index)] title=\(String(reflecting: title)) children=\(shallow.children.count) buttons=\(buttons.count)")
            for button in buttons where (button.identifier ?? "").contains("partic")
                || (button.description ?? "").lowercased().contains("partic") {
                log.write("    candidate id=\(String(reflecting: button.identifier ?? "")) desc=\(String(reflecting: button.description ?? "")) actions=\(button.actions) enabled=\(button.enabled)")
            }
        }

        let automation = LiveZoomAutomation()
        let zoom = ZoomProcess(pid: process.pid, bundleIdentifier: process.bundleIdentifier)
        let before = automation.participantsPanelState(for: zoom)
        log.write("Participants check: panel is \(before.rawValue)")

        guard before == .closed else {
            log.write("Participants check: nothing to do")
            return
        }

        switch automation.openParticipantsPanel(for: zoom) {
        case .rejected(let reason):
            log.write("Participants check: could not open — \(reason)")
        case .pressed:
            log.write("Participants check: pressed the Participants control")
            Thread.sleep(forTimeInterval: 2.0)
            log.write("Participants check: panel is now \(automation.participantsPanelState(for: zoom).rawValue)")
        }
    }
}
