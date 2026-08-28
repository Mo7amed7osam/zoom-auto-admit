import AppKit
import ApplicationServices
import Foundation
import OSLog
import ZoomAXSupport

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

        if openPreview {
            // Zoom needs to be frontmost for its menu to act, and the preview
            // opens on Zoom's own Space.
            NSRunningApplication(processIdentifier: process.pid)?.activate()
            Thread.sleep(forTimeInterval: 1.0)
            guard let reading = ZoomAXSupport.zoomMenuBarReading(pid: process.pid) else {
                write(lines + ["Zoom's menu bar could not be read."])
                return
            }
            let outcome = ZoomAXSupport.pressApplicationMenuItem(titled: "Start meeting", in: reading)
            lines.append("Pressed Zoom menu 'Start meeting': \(outcome)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        var captured = false
        var pollCount = 0

        while Date() < deadline && !captured {
            pollCount += 1
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

            for candidate in candidates {
                let title = ZoomAXSupport.windowTitle(candidate.element)
                let tree = ZoomAXSupport.buildTree(from: candidate.element, maxDepth: 18, maxChildren: 300)
                let snapshot = ZoomAXSupport.snapshot(from: tree)
                let preview = ZoomAXSupport.preJoinPreview(inWindow: snapshot, windowIndexPath: [])

                // A window that is neither the home window nor an in-meeting
                // window is worth dumping even if the matcher did not recognise
                // it; that is precisely the case that needs new vocabulary.
                let isHomeWindow = ZoomAXSupport.normalized(title) == "zoom workplace"
                guard preview != nil || !isHomeWindow else { continue }

                lines.append("")
                lines.append("===== CANDIDATE \(candidate.label) title=\(String(reflecting: title)) poll=\(pollCount) =====")
                lines.append("Matcher result: \(preview.map(describe) ?? "NOT RECOGNISED as a pre-join preview")")
                lines.append("")
                lines.append("----- full hierarchy -----")
                lines.append(contentsOf: describeTree(snapshot, depth: 0, path: ""))
                captured = true
            }

            if !captured { Thread.sleep(forTimeInterval: 1.0) }
        }

        if !captured {
            lines.append("No pre-join preview appeared within \(Int(timeout))s.")
        }
        lines.append("")
        lines.append("Start was deliberately NOT pressed; no meeting was created by this capture.")
        write(lines)
        logger.notice("Pre-join capture finished captured=\(captured)")
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
