import AppKit
import Foundation
import OSLog
import ZoomAXSupport

/// Writes a read-only capture of the live Zoom Accessibility hierarchy.
///
/// The command-line inspector cannot do this because a terminal is normally not
/// an Accessibility-trusted process; this app is. Nothing here presses, raises or
/// activates anything.
enum ZoomUISnapshot {
    static let launchArgument = "--capture-zoom-ui"

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Zoom Auto Admit/zoom-ui-snapshot.log", isDirectory: false)
    }

    @discardableResult
    static func capture(reason: String) -> URL? {
        let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "ui-snapshot")
        var text = "Capture reason: \(reason)\n" + ZoomAXSupport.captureZoomUI()
        text += "\n\n========== PARSED ACCOUNT READING ==========\n"
        if let process = ZoomAXSupport.zoomApplication(),
           let reading = ZoomAXSupport.zoomMenuBarReading(pid: process.pid) {
            text += "Saved accounts: \(reading.entries.count)\n"
            for entry in reading.entries {
                text += "\(entry.isActive ? "● ACTIVE " : "  ")"
                text += "email=\(entry.email ?? "(none)") displayName=\(String(reflecting: entry.displayName)) indexPath=\(entry.indexPath)\n"
            }
            text += "Active account: \(reading.activeAccount.map { $0.email ?? $0.rawTitle } ?? "(not determined)")\n"
            let startItem = ZoomAXSupport.applicationMenuItem(titled: "Start meeting", inMenuBar: reading.root)
            text += "Start meeting menu item: \(startItem.map { "indexPath=\($0.indexPath)" } ?? "(absent)")\n"
            let presence = ZoomAXSupport.meetingPresence(
                pid: process.pid,
                bundleIdentifier: process.bundleIdentifier
            )
            text += "Meeting state: \(presence.state.rawValue) evidence=\(presence.evidenceDescription) location=\(presence.location.rawValue)\n"
        } else {
            text += "Zoom menu bar could not be read.\n"
        }
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url, options: .atomic)
            logger.notice("Zoom UI snapshot written to \(url.path, privacy: .public)")
            return url
        } catch {
            logger.error("Zoom UI snapshot failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
