import Foundation
import OSLog

public enum ZoomWebAccountError: Error, LocalizedError, Equatable {
    case invalidMeetingURL
    case browserNotInstalled
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMeetingURL: return "A valid HTTPS Zoom meeting URL is required"
        case .browserNotInstalled: return "Google Chrome or Chromium is not installed"
        case .launchFailed(let reason): return "Web Zoom could not be launched: \(reason)"
        }
    }
}

public final class ZoomWebAccountManager {
    public let profilesRoot: URL
    private let fileManager: FileManager
    private let browserCandidates: [URL]
    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "web-account")

    public init(
        profilesRoot: URL? = nil,
        fileManager: FileManager = .default,
        browserCandidates: [URL] = [
            URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            URL(fileURLWithPath: "/Applications/Chromium.app/Contents/MacOS/Chromium")
        ]
    ) {
        self.fileManager = fileManager
        self.browserCandidates = browserCandidates
        if let profilesRoot {
            self.profilesRoot = profilesRoot
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.profilesRoot = support
                .appendingPathComponent("Zoom Auto Admit", isDirectory: true)
                .appendingPathComponent("ZoomProfiles", isDirectory: true)
        }
    }

    public func profileDirectory(for account: ZoomAccount) throws -> URL {
        let directory = profilesRoot.appendingPathComponent(account.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    public func openMeeting(_ meetingURL: URL, for account: ZoomAccount) throws -> Process {
        guard meetingURL.scheme?.lowercased() == "https",
              let host = meetingURL.host?.lowercased(),
              host == "zoom.us" || host.hasSuffix(".zoom.us") ||
              host == "zoom.com" || host.hasSuffix(".zoom.com") else {
            throw ZoomWebAccountError.invalidMeetingURL
        }
        guard let browser = browserCandidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            throw ZoomWebAccountError.browserNotInstalled
        }
        let profile = try profileDirectory(for: account)
        let process = Process()
        process.executableURL = browser
        process.arguments = [
            "--user-data-dir=\(profile.path)",
            "--no-first-run",
            "--no-default-browser-check",
            meetingURL.absoluteString
        ]
        do {
            try process.run()
        } catch {
            throw ZoomWebAccountError.launchFailed(error.localizedDescription)
        }
        logger.info("[WEB] Using saved browser profile for \(account.displayName, privacy: .public)")
        logger.info("[MEETING] Launching Web Zoom session")
        return process
    }
}
