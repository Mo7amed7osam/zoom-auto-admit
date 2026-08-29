import AppKit
import ApplicationServices
import Foundation
import ZoomAXSupport
import ZoomAutoAdmitCore

/// Phase 1 discovery: dumps the live participants panel and, next to it, what
/// the production parser makes of the very same tree.
///
/// Printing both together is the point — it turns "does the parser understand
/// Zoom?" into something readable rather than something assumed.
enum ParticipantsCapture {
    static let launchArgument = "--capture-participants"

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Zoom Auto Admit/zoom-participants-snapshot.log", isDirectory: false)
    }

    static func run() {
        var lines = ["Participants capture \(ISO8601DateFormatter().string(from: Date()))"]

        guard let process = ZoomAXSupport.zoomApplication() else {
            write(lines + ["Zoom is not running."])
            return
        }
        lines.append("Zoom pid=\(process.pid)")

        let previous = ZoomAXSupport.collectDiagnosticAttributes
        ZoomAXSupport.collectDiagnosticAttributes = true
        defer { ZoomAXSupport.collectDiagnosticAttributes = previous }

        // Open the panel through the menu, which works regardless of the
        // toolbar's auto-hiding.
        if let reading = ZoomAXSupport.zoomMenuBarReading(pid: process.pid) {
            let item = ZoomAXSupport.menuItem(
                withIdentifier: ZoomAXSupport.showParticipantsMenuIdentifier,
                inMenuBar: reading.root
            )
            lines.append("View ▸ Show participants menu item: \(item.map { "found at \($0.indexPath)" } ?? "NOT FOUND")")
            if item != nil {
                let outcome = ZoomAXSupport.pressMenuItem(
                    withIdentifier: ZoomAXSupport.showParticipantsMenuIdentifier,
                    in: reading
                )
                lines.append("Press result: \(outcome)")
                Thread.sleep(forTimeInterval: 2.0)
            }
        } else {
            lines.append("Zoom's menu bar could not be read.")
        }

        let application = ZoomAXSupport.freshZoomApplicationElement(pid: process.pid, messagingTimeout: 8)
        let windows = ZoomAXSupport.windowsResult(of: application)
        lines.append("AXWindows=\(windows.windows.count) error=\(windows.error.diagnosticDescription)")

        guard !windows.windows.isEmpty else {
            lines.append("")
            lines.append("No Accessibility windows. The meeting window is almost certainly on")
            lines.append("another Desktop/Space, where macOS removes it from AXWindows entirely.")
            lines.append("Move the Zoom meeting to the current Desktop and run this again.")
            write(lines)
            return
        }

        for (index, window) in windows.windows.enumerated() {
            let title = ZoomAXSupport.windowTitle(window)
            let snapshot = ZoomAXSupport.snapshot(
                from: ZoomAXSupport.buildTree(from: window, maxDepth: 16, maxChildren: 300)
            )

            lines.append("")
            lines.append("===== window[\(index)] title=\(String(reflecting: title)) =====")

            // What production code sees.
            let readout = ZoomAXSupport.participantsReadout(inWindow: snapshot)
            lines.append("PARSER RESULT")
            lines.append("  listAvailable = \(readout.listAvailable)")
            lines.append("  reportedCount = \(readout.reportedCount.map(String.init) ?? "nil")")
            lines.append("  admitted (\(readout.admitted.count)):")
            for row in readout.admitted {
                lines.append("    displayName=\(String(reflecting: row.displayName)) roles=\(row.roles.map(\.rawValue).sorted()) indexPath=\(row.indexPath)")
                lines.append("      rawText=\(String(reflecting: row.rawText))")
            }
            lines.append("  waiting (\(readout.waiting.count)):")
            for row in readout.waiting {
                lines.append("    displayName=\(String(reflecting: row.displayName)) roles=\(row.roles.map(\.rawValue).sorted()) indexPath=\(row.indexPath)")
            }

            // Only dump the raw tree for windows that look relevant; the home
            // window's tree is enormous and adds nothing here.
            let relevant = readout.listAvailable
                || ZoomAXSupport.isLikelyMeetingWindowTitle(title)
                || ZoomAXSupport.normalized(title) != "zoom workplace"
            guard relevant else {
                lines.append("  (raw hierarchy omitted for the home window)")
                continue
            }

            lines.append("")
            lines.append("RAW HIERARCHY")
            lines.append(contentsOf: dump(snapshot, depth: 0, path: "root"))
        }

        write(lines)
    }

    private static func dump(_ node: ZoomAXSupport.SnapshotNode, depth: Int, path: String) -> [String] {
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

        var lines = [parts.joined()]
        for (index, child) in node.children.enumerated() {
            lines.append(contentsOf: dump(child, depth: depth + 1, path: "\(path)/\(index)"))
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
