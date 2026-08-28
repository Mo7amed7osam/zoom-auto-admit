import ApplicationServices
import Foundation
import ZoomAXSupport

let arguments = CommandLine.arguments.dropFirst()
let dumpCGWindows = arguments.contains("--cg-windows")
let accountUI = arguments.contains("--account-ui")
let meetingsUI = arguments.contains("--meetings-ui")
let maxDepth = arguments.firstIndex(of: "--max-depth").flatMap { index in
    arguments.dropFirst(index + 1).first.flatMap(Int.init)
} ?? 14

// The inspector wants every attribute of every node, unlike the monitor.
ZoomAXSupport.collectDiagnosticAttributes = true

print("Zoom Auto Admit — Accessibility inspector")
print("Requested max depth: \(maxDepth)")
print("Accessibility trusted: \(ZoomAXSupport.isTrusted(prompt: true))")

guard let zoom = ZoomAXSupport.zoomApplication() else {
    print("Zoom was not found. Start Zoom and open the meeting Participants panel, then run this again.")
    exit(2)
}

print("Zoom process: pid=\(zoom.pid), bundle=\(zoom.bundleIdentifier)")

if accountUI {
    // Account layer discovery: the Switch account submenu of Zoom's own
    // application menu, including which entry Zoom marks as signed in.
    print("")
    print("========== ZOOM ACCOUNT UI ==========")
    if let reading = ZoomAXSupport.zoomMenuBarReading(pid: zoom.pid) {
        print("Saved accounts: \(reading.entries.count)")
        for entry in reading.entries {
            print("\(entry.isActive ? "● ACTIVE " : "  ")rawTitle=\(String(reflecting: entry.rawTitle))")
            print("    displayName=\(String(reflecting: entry.displayName)) email=\(entry.email ?? "(none)") enabled=\(entry.enabled) indexPath=\(entry.indexPath)")
        }
        print("Active account: \(reading.activeAccount.map { $0.email ?? $0.rawTitle } ?? "(not determined)")")
        let startItem = ZoomAXSupport.applicationMenuItem(titled: "Start meeting", inMenuBar: reading.root)
        print("Start meeting menu item present: \(startItem != nil)")
    } else {
        print("Zoom's menu bar could not be read. Is this process Accessibility-trusted?")
    }
    exit(0)
}

if meetingsUI {
    print("")
    print("========== ZOOM MEETING STATE ==========")
    let presence = ZoomAXSupport.meetingPresence(pid: zoom.pid, bundleIdentifier: zoom.bundleIdentifier)
    print("Meeting active: \(presence.isActive)")
    print("Evidence: \(presence.evidenceDescription)")
    print("Meeting window location: \(presence.location.rawValue)")
    print("AX window titles: \(presence.axWindowTitles)")
    exit(0)
}
let diagnostics = ZoomAXSupport.windowDiagnostics(pid: zoom.pid, bundleIdentifier: zoom.bundleIdentifier)
print("Zoom active: \(diagnostics.zoomActive)")
print("Zoom hidden: \(diagnostics.zoomHidden)")
print("Meeting window found via public window APIs: \(diagnostics.meetingWindowFound)")
print("Meeting window state: \(diagnostics.meetingWindowLocation.rawValue)")
print("Meeting window discovery ID: \(diagnostics.meetingWindowID.map(String.init) ?? "(none)")")
print("Meeting window discovery evidence: \(diagnostics.meetingWindowEvidence ?? "(none)")")
print("CGWindowList options: \(ZoomAXSupport.cgWindowListOptionsDescription)")
print("Zoom PID: \(zoom.pid)")
print("CG windows: \(diagnostics.cgWindows.count)")
for window in diagnostics.cgWindows {
    let bounds = String(
        format: "{x=%.1f,y=%.1f,width=%.1f,height=%.1f}",
        window.bounds.origin.x,
        window.bounds.origin.y,
        window.bounds.width,
        window.bounds.height
    )
    print("id=\(window.windowID) pid=\(window.ownerPID) owner=\(String(reflecting: window.ownerName ?? "")) name=\(String(reflecting: window.name ?? "")) layer=\(window.layer) onscreen=\(window.isOnscreen) bounds=\(bounds) alpha=\(String(format: "%.3f", window.alpha)) sharing=\(window.sharingState.map(String.init) ?? "unavailable")")
}
print("AX window titles: \(diagnostics.axWindowTitles.map { String(reflecting: $0) }.joined(separator: ", "))")
if dumpCGWindows {
    print("CoreGraphics diagnostic complete. No window was filtered by title.")
    exit(0)
}
let application = ZoomAXSupport.applicationElement(pid: zoom.pid)
let windows = ZoomAXSupport.windows(of: application)

guard !windows.isEmpty else {
    print("Zoom is running, but macOS exposed no AXWindow elements.")
    print("Make sure a meeting window is open and that this executable has Accessibility permission.")
    exit(3)
}

for (index, window) in windows.enumerated() {
    print("\n=== WINDOW \(index): \(ZoomAXSupport.windowTitle(window)) ===")
    let tree = ZoomAXSupport.buildTree(from: window, maxDepth: maxDepth)
    ZoomAXSupport.printTree(tree)
    let candidates = ZoomAXSupport.admitCandidates(in: tree)
    if candidates.isEmpty {
        print("  [No guarded Waiting Room Admit candidate found in this window]")
    } else {
        for candidate in candidates {
            print("  [GUARDED CANDIDATE]")
            print("  type=\(candidate.type.rawValue)")
            print("  waitingRoomEvidence=\(candidate.waitingRoomEvidence.value)")
            print("  waitingRoomEvidenceKind=\(candidate.waitingRoomEvidence.kind.rawValue)")
            if let participantName = candidate.participantName {
                print("  participantName=\(String(reflecting: participantName))")
            }
            print("  buttonTitle=\(candidate.node.title.map(String.init(reflecting:)) ?? "(none)")")
            print("  buttonDescription=\(candidate.node.description.map(String.init(reflecting:)) ?? "(none)")")
            print("  buttonPath=\(candidate.node.path)")
            print("  contextPath=\(candidate.contextPath)")
        }
    }
}

print("\nInspection complete. Save this output if the monitor cannot find the controls.")
