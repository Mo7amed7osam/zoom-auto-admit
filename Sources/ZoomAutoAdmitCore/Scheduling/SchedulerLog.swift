import Foundation
import OSLog

/// Dedicated workflow log, separate from the Accessibility diagnostic log.
///
/// Records state transitions and decisions only. It never records credentials:
/// the app has none, and account identity is written as the email shown by
/// Zoom's own menu.
public final class SchedulerLog {
    public static let shared = SchedulerLog()

    public let fileURL: URL
    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "scheduler")
    private let queue = DispatchQueue(label: "com.mohamedhosam.ZoomAutoAdmit.scheduler-log")
    private let maximumBytes = 2_000_000

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Zoom Auto Admit", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("scheduler.log", isDirectory: false)
        }
    }

    public func write(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let line = "[\(Self.timestampFormatter.string(from: Date()))] \(message)\n"
        queue.async { [fileURL, maximumBytes] in
            let manager = FileManager.default
            if let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue > maximumBytes {
                try? manager.removeItem(at: fileURL)
            }
            if !manager.fileExists(atPath: fileURL.path) {
                manager.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    public func write(state: ZoomWorkflowState, detail: String?) {
        if let detail, !detail.isEmpty {
            write("state=\(state.rawValue) — \(detail)")
        } else {
            write("state=\(state.rawValue)")
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
