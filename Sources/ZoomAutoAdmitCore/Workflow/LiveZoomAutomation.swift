import AppKit
import ApplicationServices
import Foundation
import OSLog
import ZoomAXSupport

/// Production implementation of the workflow seam.
public final class LiveZoomAutomation: ZoomAutomating {
    /// Zoom's public URL scheme, registered by the installed client under
    /// `CFBundleURLSchemes`.
    ///
    /// `join` is used rather than `start`. Both are public, but `start` means
    /// "begin a meeting as host" and Zoom resolves it against the signed-in
    /// account rather than the number given — in live use it opened the
    /// account's personal meeting room instead of the scheduled meeting.
    /// `join` names the meeting explicitly, and because the workflow has
    /// already verified that the host account is signed in, joining a meeting
    /// that account owns starts it as host.
    public static let joinMeetingURLTemplate = "zoommtg://zoom.us/join?confno=%@"
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

    /// Zoom disables its own `Start meeting` entry while it is not ready, which
    /// is an application-level signal and therefore works even when every Zoom
    /// window is on another Space.
    public func isReadyToStartMeeting(for process: ZoomProcess) -> Bool {
        guard let reading = ZoomAXSupport.zoomMenuBarReading(pid: process.pid),
              let item = ZoomAXSupport.applicationMenuItem(
                  titled: Self.startMeetingMenuTitle,
                  inMenuBar: reading.root
              ) else {
            return false
        }
        return item.node.enabled
    }

    public func meetingWindowSignature(for process: ZoomProcess) -> Set<CGWindowID> {
        ZoomAXSupport.meetingWindowSignature(pid: process.pid)
    }

    public func startMeeting(_ meeting: MeetingReference) -> MeetingStartOutcome {
        switch meeting.kind {
        case .meetingID(let raw):
            let digits = MeetingReference.normalizedMeetingID(raw)
            guard !digits.isEmpty else {
                return .rejected("meeting ID has no digits")
            }
            var urlText = String(format: Self.joinMeetingURLTemplate, digits)
            if let passcode = meeting.passcode ?? MeetingReference.passcode(from: raw),
               !passcode.isEmpty {
                urlText += "&pwd=\(passcode)"
            }
            guard let url = URL(string: urlText) else {
                return .rejected("could not build the Zoom meeting URL")
            }
            // The number is logged in truncated form only.
            logger.notice("Opening Zoom meeting URL for meeting ending \(String(digits.suffix(4)), privacy: .public)")
            NSWorkspace.shared.open(url)
            return .requested(method: "zoommtg join URL (confno \(digits))")

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

    public func preJoinPreview(for process: ZoomProcess) -> PreJoinPreview? {
        ZoomAXSupport.preJoinReading(pid: process.pid)?.preview
    }

    /// Re-reads the preview and re-locates the control by kind before pressing.
    /// The index path captured earlier is never trusted on its own, and the
    /// control is only pressed while it is genuinely on.
    public func pressPreJoinControl(_ control: PreJoinControl) -> PreJoinActionOutcome {
        guard let process = zoomProcess(),
              let reading = ZoomAXSupport.preJoinReading(pid: process.pid) else {
            return .rejected("Zoom's join preview is no longer open")
        }
        guard !reading.preview.ambiguousKinds.contains(control.kind) else {
            return .rejected("several \(control.kind.displayName.lowercased()) controls matched")
        }
        guard let fresh = reading.preview.control(for: control.kind) else {
            return .rejected("the \(control.kind.displayName.lowercased()) control disappeared")
        }
        guard fresh.state == .on else {
            return .rejected("the \(control.kind.displayName.lowercased()) is \(fresh.state.rawValue); refusing to press")
        }

        switch ZoomAXSupport.pressPreJoinControl(fresh, in: reading) {
        case .pressed:
            return .pressed
        case .verificationFailed(let reason):
            return .rejected(reason)
        case .elementUnavailable:
            return .rejected("the control could not be resolved")
        case .axError(let error):
            return .rejected("AXPress returned \(error.diagnosticDescription)")
        }
    }

    public func pressPreJoinStart() -> PreJoinActionOutcome {
        guard let process = zoomProcess(),
              let reading = ZoomAXSupport.preJoinReading(pid: process.pid) else {
            return .rejected("Zoom's join preview is no longer open")
        }
        guard let start = reading.preview.start else {
            return .rejected("no Start button was identified")
        }
        switch ZoomAXSupport.pressPreJoinStart(start, in: reading) {
        case .pressed:
            return .pressed
        case .verificationFailed(let reason):
            return .rejected(reason)
        case .elementUnavailable:
            return .rejected("the Start button could not be resolved")
        case .axError(let error):
            return .rejected("AXPress returned \(error.diagnosticDescription)")
        }
    }

    /// Dumps the live preview hierarchy so unknown controls can be identified
    /// from real data rather than guessed at.
    public func capturePreJoinDiagnostics(reason: String) {
        guard let process = zoomProcess(),
              let reading = ZoomAXSupport.preJoinReading(pid: process.pid) else {
            SchedulerLog.shared.write("Pre-join diagnostics unavailable (no preview open): \(reason)")
            return
        }
        let text = "Pre-join diagnostics — \(reason)" + "\n"
            + ZoomAXSupport.describePreJoinForDiagnostics(reading)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Zoom Auto Admit/zoom-prejoin-snapshot.log", isDirectory: false)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(text.utf8).write(to: url, options: .atomic)
        SchedulerLog.shared.write("Pre-join hierarchy written to \(url.path)")
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
