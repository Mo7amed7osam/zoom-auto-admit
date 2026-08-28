import AppKit
import ApplicationServices
import Foundation
import OSLog
import ZoomAXSupport

/// Production implementation of the workflow seam.
public final class LiveZoomAutomation: ZoomAutomating {
    /// Zoom's public URL scheme. Registered by the installed client under
    /// `CFBundleURLSchemes`, and its `start` action targets a meeting number
    /// using whichever account is currently signed in.
    public static let startMeetingURLTemplate = "zoommtg://zoom.us/start?confno=%@"
    public static let startMeetingMenuTitle = "Start meeting"

    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "automation")

    public init() {}

    public func isAccessibilityTrusted() -> Bool {
        ZoomAXSupport.accessibilityTrustSnapshot(prompt: false).isUsableWithoutRelaunch
    }

    public func zoomProcess() -> ZoomProcess? {
        ZoomAXSupport.zoomApplication().map { ZoomProcess(pid: $0.pid, bundleIdentifier: $0.bundleIdentifier) }
    }

    public func launchZoom() -> Bool {
        let workspace = NSWorkspace.shared
        for bundleIdentifier in ZoomAXSupport.supportedBundleIdentifiers {
            guard let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                continue
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            workspace.openApplication(at: url, configuration: configuration) { [logger] _, error in
                if let error {
                    logger.error("Zoom launch failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return true
        }
        logger.error("No installed Zoom client was found")
        return false
    }

    public func readAccountMenu() -> ZoomAccountSnapshot? {
        guard let process = zoomProcess(),
              let reading = ZoomAXSupport.zoomMenuBarReading(pid: process.pid) else {
            return nil
        }
        return ZoomAccountSnapshot(entries: reading.entries, activeAccount: reading.activeAccount)
    }

    /// Re-reads the menu and re-locates the account by identity before pressing.
    ///
    /// The index path captured earlier is never trusted on its own: Zoom's
    /// sign-out submenu contains identically titled items, so the entry is
    /// re-matched by email against a fresh reading and the live element is
    /// re-verified inside `pressAccountEntry`.
    public func selectAccount(_ entry: AccountMenuEntry) -> AccountSelectionOutcome {
        guard let process = zoomProcess(),
              let reading = ZoomAXSupport.zoomMenuBarReading(pid: process.pid) else {
            return .rejected("Zoom's Switch account menu is unavailable")
        }

        let identifier = entry.email ?? entry.rawTitle
        let lookup = ZoomAXSupport.matchAccount(identifier: identifier, in: reading.entries)
        guard case .found(let fresh) = lookup else {
            switch lookup {
            case .ambiguous(let matches):
                return .rejected("\(matches.count) saved accounts match \(identifier)")
            default:
                return .rejected("\(identifier) is no longer in Zoom's Switch account menu")
            }
        }

        switch ZoomAXSupport.pressAccountEntry(fresh, in: reading) {
        case .pressed:
            return .pressed
        case .verificationFailed(let reason):
            return .rejected(reason)
        case .elementUnavailable:
            return .rejected("the account menu item could not be resolved")
        case .axError(let error):
            return .rejected("AXPress returned \(error.diagnosticDescription)")
        }
    }

    public func meetingPresence(for process: ZoomProcess) -> MeetingPresence {
        ZoomAXSupport.meetingPresence(pid: process.pid, bundleIdentifier: process.bundleIdentifier)
    }

    public func startMeeting(_ meeting: MeetingReference) -> MeetingStartOutcome {
        switch meeting.kind {
        case .meetingID(let raw):
            let digits = MeetingReference.normalizedMeetingID(raw)
            guard !digits.isEmpty else {
                return .rejected("meeting ID has no digits")
            }
            guard let url = URL(string: String(format: Self.startMeetingURLTemplate, digits)) else {
                return .rejected("could not build the Zoom start URL")
            }
            logger.notice("Opening Zoom start URL for meeting ending \(String(digits.suffix(4)), privacy: .public)")
            NSWorkspace.shared.open(url)
            return .requested(method: "zoommtg start URL")

        case .instantMeeting:
            guard let process = zoomProcess(),
                  let reading = ZoomAXSupport.zoomMenuBarReading(pid: process.pid) else {
                return .rejected("Zoom's application menu is unavailable")
            }
            switch ZoomAXSupport.pressApplicationMenuItem(titled: Self.startMeetingMenuTitle, in: reading) {
            case .pressed:
                return .requested(method: "Zoom menu: \(Self.startMeetingMenuTitle)")
            case .verificationFailed(let reason):
                return .rejected(reason)
            case .elementUnavailable:
                return .rejected("Zoom has no \(Self.startMeetingMenuTitle) menu item")
            case .axError(let error):
                return .rejected("AXPress returned \(error.diagnosticDescription)")
            }
        }
    }

    /// Only ever called from the startup workflow. Auto Admit monitoring never
    /// calls it, which is what keeps admissions focus-free.
    public func activateZoom() {
        guard let process = zoomProcess(),
              let application = NSRunningApplication(processIdentifier: process.pid),
              !application.isTerminated else {
            return
        }
        application.activate()
    }

    public func now() -> Date { Date() }

    public func sleep(_ interval: TimeInterval) {
        Thread.sleep(forTimeInterval: interval)
    }
}
