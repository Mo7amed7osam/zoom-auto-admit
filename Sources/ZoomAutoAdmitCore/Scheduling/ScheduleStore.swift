import Foundation
import OSLog

/// Local, file-backed persistence for account profiles and schedules.
///
/// Plain JSON in Application Support: no remote database, no credentials, and a
/// file the user can read, back up or hand-edit.
public final class ScheduleStore {
    public static let defaultFileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Zoom Auto Admit", isDirectory: true)
            .appendingPathComponent("schedules.json", isDirectory: false)
    }()

    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "schedule-store")
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.mohamedhosam.ZoomAutoAdmit.schedule-store")

    public init(fileURL: URL = ScheduleStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public var location: URL { fileURL }

    public func load() -> SchedulerConfiguration {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else {
                return SchedulerConfiguration()
            }
            do {
                return try Self.decoder.decode(SchedulerConfiguration.self, from: data)
            } catch {
                // A corrupt or outdated file must not take the app down, and must
                // not be silently overwritten either.
                logger.error("Could not decode schedules: \(error.localizedDescription, privacy: .public)")
                let backup = fileURL.appendingPathExtension("invalid")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: fileURL, to: backup)
                return SchedulerConfiguration()
            }
        }
    }

    @discardableResult
    public func save(_ configuration: SchedulerConfiguration) -> Bool {
        queue.sync {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try Self.encoder.encode(configuration)
                try data.write(to: fileURL, options: .atomic)
                return true
            } catch {
                logger.error("Could not save schedules: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
