import ApplicationServices
import AppKit
import Darwin
import Foundation
import ZoomAXSupport

final class StopController {
    private let lock = NSLock()
    private var stopped = false

    func requestStop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

func usage() {
    print("Usage: auto-admit [--interval SECONDS] [--dry-run] [--once] [--cross-space]")
    print("  --interval SECONDS  Poll interval; default 0.75, clamped to 0.5–1.0")
    print("  --dry-run           Log matching buttons without pressing them")
    print("  --once              Inspect once, perform at most one action, then exit")
    print("  --cross-space       Enable bounded off-Space Zoom exposure and restoration")
    print("  --cross-space-interval SECONDS")
    print("                       Initial off-Space probe interval; default 15, minimum 5")
    print("  Stop with Ctrl-C (SIGINT).")
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    usage()
    exit(0)
}

var interval = 0.75
var dryRun = false
var once = false
var crossSpace = false
var crossSpaceInterval = 15.0
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--interval":
        guard index + 1 < arguments.count,
              let parsed = Double(arguments[index + 1]),
              parsed.isFinite,
              parsed > 0 else {
            print("Invalid --interval value")
            exit(64)
        }
        interval = min(max(parsed, 0.5), 1.0)
        index += 1
    case "--dry-run": dryRun = true
    case "--once": once = true
    case "--cross-space": crossSpace = true
    case "--cross-space-interval":
        guard index + 1 < arguments.count,
              let parsed = Double(arguments[index + 1]),
              parsed.isFinite,
              parsed >= 5 else {
            print("Invalid --cross-space-interval value; use 5 seconds or more")
            exit(64)
        }
        crossSpaceInterval = parsed
        index += 1
    default:
        print("Unknown argument: \(arguments[index])")
        usage()
        exit(64)
    }
    index += 1
}

guard ZoomAXSupport.isTrusted(prompt: true) else {
    print("Accessibility permission is required. Enable this executable (or its terminal app) in System Settings → Privacy & Security → Accessibility, then run again.")
    exit(2)
}

let stopController = StopController()
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signalQueue = DispatchQueue.global(qos: .utility)
let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
signalSource.setEventHandler { stopController.requestStop() }
signalSource.resume()
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
termSource.setEventHandler { stopController.requestStop() }
termSource.resume()

func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func log(_ message: String) {
    print("[\(timestamp())] \(message)")
    fflush(stdout)
}

struct ScanHit {
    let candidate: ZoomAXSupport.AdmitCandidate
    let windowIndex: Int
}

struct ZoomScanResult {
    let hit: ScanHit?
    let meetingWindowCandidate: ZoomAXSupport.MeetingWindowCandidate?
}

struct FocusSnapshot {
    let previousApplication: NSRunningApplication?
    let previousFocusedWindow: AXUIElement?
    let previousOnscreenWindowIDs: Set<CGWindowID>
    let zoomWasHidden: Bool
}

struct ExposureSession {
    let focus: FocusSnapshot
    let temporarilyUnminimizedWindows: [AXUIElement]
}

func scanZoom(pid: pid_t, learnedMeetingWindowID: CGWindowID?) -> ZoomScanResult {
    let application = ZoomAXSupport.applicationElement(pid: pid)
    let cgWindows = ZoomAXSupport.cgWindows(ownerPID: pid)
    var hit: ScanHit?
    var axEvidence: [ZoomAXSupport.AXMeetingWindowEvidence] = []
    for (windowIndex, window) in ZoomAXSupport.windows(of: application).enumerated() {
        guard ZoomAXSupport.copyStringAttribute(window, kAXRoleAttribute) == "AXWindow" else { continue }
        let tree = ZoomAXSupport.buildTree(from: window, maxDepth: 14)
        axEvidence.append(ZoomAXSupport.AXMeetingWindowEvidence(
            title: ZoomAXSupport.windowTitle(window),
            bounds: ZoomAXSupport.frame(of: window),
            hasMeetingStructure: ZoomAXSupport.hasMeetingStructure(in: tree)
        ))
        if hit == nil, let candidate = ZoomAXSupport.admitCandidates(in: tree).first {
            hit = ScanHit(candidate: candidate, windowIndex: windowIndex)
        }
    }
    let discovery = ZoomAXSupport.discoverMeetingWindow(
        cgWindows: cgWindows,
        learnedWindowID: learnedMeetingWindowID,
        axEvidence: axEvidence
    )
    return ZoomScanResult(hit: hit, meetingWindowCandidate: discovery)
}

func handleCandidate(_ hit: ScanHit, zoomPID: pid_t) -> Bool {
    let candidate = hit.candidate
    let label = candidate.isAdmitAll ? "Admit All" : "Admit"
    if candidate.type == .individual {
        log("Found Waiting Room participant: \(candidate.participantName ?? "(name unavailable)")")
    } else {
        log("Found Waiting Room control: Admit All")
    }
    log("Guard evidence: \(candidate.waitingRoomEvidence.value); button=\(candidate.node.path); window=\(hit.windowIndex); context=\(candidate.contextPath)")

    guard let currentZoom = ZoomAXSupport.zoomApplication(), currentZoom.pid == zoomPID else {
        log("Zoom process changed before action; skipping this poll.")
        return false
    }

    if dryRun {
        log("Would press \(label)")
        return true
    }

    let result = ZoomAXSupport.press(candidate.node.element)
    if result == .success {
        log("Pressed \(label); Zoom should admit \(candidate.isAdmitAll ? "all waiting participants" : "one waiting participant").")
        return true
    }

    log("Could not press \(label): AXError \(result.rawValue). The UI may have changed; rescanning.")
    return false
}

func isStrongLearningEvidence(_ evidence: String) -> Bool {
    evidence.contains("ax-structure")
        || evidence.contains("ax-title")
        || evidence.contains("known-meeting-title")
        || evidence == "learned-window-id"
}

func captureFocus(zoomPID: pid_t) -> FocusSnapshot {
    let previousApplication = NSWorkspace.shared.frontmostApplication
    let previousFocusedWindow = previousApplication.flatMap {
        ZoomAXSupport.focusedWindow(of: ZoomAXSupport.applicationElement(pid: $0.processIdentifier))
    }
    let previousOnscreenWindowIDs = Set(
        previousApplication.map {
            ZoomAXSupport.cgWindows(ownerPID: $0.processIdentifier)
                .filter { $0.layer == 0 && $0.isOnscreen }
                .map(\.windowID)
        } ?? []
    )
    let zoomWasHidden = NSRunningApplication(processIdentifier: zoomPID)?.isHidden ?? false
    return FocusSnapshot(
        previousApplication: previousApplication,
        previousFocusedWindow: previousFocusedWindow,
        previousOnscreenWindowIDs: previousOnscreenWindowIDs,
        zoomWasHidden: zoomWasHidden
    )
}

func temporarilyExposeZoom(
    pid: pid_t,
    bundleIdentifier: String,
    learnedMeetingWindowID: CGWindowID?
) -> ExposureSession? {
    guard let zoom = NSRunningApplication(processIdentifier: pid),
          zoom.bundleIdentifier == bundleIdentifier,
          ZoomAXSupport.supportedBundleIdentifiers.contains(bundleIdentifier),
          !zoom.isTerminated else {
        return nil
    }

    let focus = captureFocus(zoomPID: pid)
    let before = ZoomAXSupport.windowDiagnostics(
        pid: pid,
        bundleIdentifier: bundleIdentifier,
        learnedWindowID: learnedMeetingWindowID
    )
    let meetingWasOnscreen = before.meetingWindowLocation == .currentSpace
    log("Temporarily exposing Zoom meeting")

    if zoom.isHidden {
        let requested = zoom.unhide()
        log("Zoom was hidden; unhide requested: \(requested ? "yes" : "no")")
        Thread.sleep(forTimeInterval: 0.2)
    }

    let zoomAX = ZoomAXSupport.applicationElement(pid: pid)
    let frontmostResult = ZoomAXSupport.setFrontmost(zoomAX, value: true)
    log("AX frontmost request result: \(frontmostResult.rawValue)")

    var meetingVisibleToAX = false
    for _ in 0..<8 {
        if stopController.isStopped { break }
        let titles = ZoomAXSupport.windows(of: zoomAX).map(ZoomAXSupport.windowTitle)
        if titles.contains(where: ZoomAXSupport.isLikelyMeetingWindowTitle) {
            meetingVisibleToAX = true
            break
        }
        Thread.sleep(forTimeInterval: 0.15)
    }

    if !meetingVisibleToAX {
        let requested = zoom.activate(options: [.activateAllWindows])
        log("AppKit activation fallback requested: \(requested ? "yes" : "no")")
        Thread.sleep(forTimeInterval: 0.4)
    }

    var temporarilyUnminimizedWindows: [AXUIElement] = []
    for window in ZoomAXSupport.windows(of: zoomAX) {
        let title = ZoomAXSupport.windowTitle(window)
        if ZoomAXSupport.isLikelyMeetingWindowTitle(title),
           ZoomAXSupport.copyBoolAttribute(window, kAXMinimizedAttribute) == true,
           ZoomAXSupport.setBoolAttribute(window, kAXMinimizedAttribute, value: false) == .success {
            temporarilyUnminimizedWindows.append(window)
            log("Temporarily unminimized Zoom Meeting window")
        }
    }
    if !temporarilyUnminimizedWindows.isEmpty {
        Thread.sleep(forTimeInterval: 0.25)
    }

    let after = ZoomAXSupport.windowDiagnostics(
        pid: pid,
        bundleIdentifier: bundleIdentifier,
        learnedWindowID: learnedMeetingWindowID
    )
    if !meetingWasOnscreen, after.meetingWindowLocation == .currentSpace {
        log("Zoom Meeting became on-screen; a temporary Space change may have occurred")
    }

    return ExposureSession(
        focus: focus,
        temporarilyUnminimizedWindows: temporarilyUnminimizedWindows
    )
}

func restoreAfterExposure(_ session: ExposureSession, zoomPID: pid_t) {
    for window in session.temporarilyUnminimizedWindows {
        _ = ZoomAXSupport.setBoolAttribute(window, kAXMinimizedAttribute, value: true)
    }

    if let previous = session.focus.previousApplication, !previous.isTerminated {
        let previousAX = ZoomAXSupport.applicationElement(pid: previous.processIdentifier)
        _ = ZoomAXSupport.setFrontmost(previousAX, value: true)
        if let focusedWindow = session.focus.previousFocusedWindow {
            _ = ZoomAXSupport.raise(focusedWindow)
        } else {
            _ = previous.activate(options: [])
        }
        _ = ZoomAXSupport.setFrontmost(previousAX, value: true)
        Thread.sleep(forTimeInterval: 0.25)
    }

    if session.focus.zoomWasHidden,
       let zoom = NSRunningApplication(processIdentifier: zoomPID),
       !zoom.isTerminated {
        _ = zoom.hide()
    }

    let restoredIDs = session.focus.previousApplication.map {
        Set(ZoomAXSupport.cgWindows(ownerPID: $0.processIdentifier).filter(\.isOnscreen).map(\.windowID))
    } ?? []
    let restoredPriorWindow = !session.focus.previousOnscreenWindowIDs.isEmpty
        && !restoredIDs.isDisjoint(with: session.focus.previousOnscreenWindowIDs)
    let restoredApp = session.focus.previousApplication?.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier

    if restoredPriorWindow || (session.focus.previousOnscreenWindowIDs.isEmpty && restoredApp) {
        log("Restored previous application / Space")
    } else if restoredApp {
        log("Restored previous application; public APIs could not verify the exact prior Space")
    } else {
        log("Restoration requested, but the previous application / Space could not be verified")
    }
}

log("Monitoring Zoom Waiting Room every \(String(format: "%.2f", interval)) seconds. Ctrl-C stops the utility.")
if dryRun { log("Dry-run enabled: no UI actions will be performed.") }
if crossSpace {
    log("Cross-Space mode enabled; initial probe interval \(String(format: "%.0f", crossSpaceInterval)) seconds with backoff.")
}

var nextCrossSpaceProbe = Date.distantPast
var crossSpaceBackoff = crossSpaceInterval
let maximumCrossSpaceBackoff = max(60, crossSpaceInterval)
var lastZoomRunning: Bool?
var lastMeetingLocation: ZoomAXSupport.MeetingWindowLocation?
var lastMeetingWindowID: CGWindowID?
var learnedMeetingWindowID: CGWindowID?
repeat {
    var performedAction = false

    if let zoom = ZoomAXSupport.zoomApplication() {
        if lastZoomRunning != true {
            log("Zoom running: yes")
            lastZoomRunning = true
        }

        let scanResult = scanZoom(pid: zoom.pid, learnedMeetingWindowID: learnedMeetingWindowID)
        if let discovered = scanResult.meetingWindowCandidate,
           isStrongLearningEvidence(discovered.evidence),
           learnedMeetingWindowID != discovered.window.windowID {
            learnedMeetingWindowID = discovered.window.windowID
            log("Learned Zoom meeting CG window: id=\(discovered.window.windowID) evidence=\(discovered.evidence)")
        }

        if let hit = scanResult.hit {
            performedAction = handleCandidate(hit, zoomPID: zoom.pid)
            crossSpaceBackoff = crossSpaceInterval
            nextCrossSpaceProbe = Date().addingTimeInterval(crossSpaceInterval)
        } else if crossSpace, Date() >= nextCrossSpaceProbe {
            let diagnostics = ZoomAXSupport.windowDiagnostics(
                pid: zoom.pid,
                bundleIdentifier: zoom.bundleIdentifier,
                learnedWindowID: learnedMeetingWindowID
            )
            if lastMeetingLocation != diagnostics.meetingWindowLocation
                || lastMeetingWindowID != diagnostics.meetingWindowID {
                log("Zoom active: \(diagnostics.zoomActive ? "yes" : "no")")
                log("Zoom hidden: \(diagnostics.zoomHidden ? "yes" : "no")")
                log("Meeting window found: \(diagnostics.meetingWindowFound ? "yes" : "no")")
                log("Meeting window on current Space: \(diagnostics.meetingWindowLocation == .currentSpace ? "yes" : "no")")
                log("Meeting window state: \(diagnostics.meetingWindowLocation.rawValue)")
                log("Meeting window CG id: \(diagnostics.meetingWindowID.map(String.init) ?? "(none)")")
                log("Meeting window discovery evidence: \(diagnostics.meetingWindowEvidence ?? "(none)")")
                log("CGWindowList options: \(ZoomAXSupport.cgWindowListOptionsDescription)")
                lastMeetingLocation = diagnostics.meetingWindowLocation
                lastMeetingWindowID = diagnostics.meetingWindowID
            }

            let requiresExposure = diagnostics.meetingWindowFound
                && diagnostics.meetingWindowLocation != .currentSpace
                && diagnostics.meetingWindowLocation != .notFound

            if requiresExposure {
                log("AX Waiting Room unavailable off-Space")
                log("Attempting background access...")
                log("Background access failed")
                if let session = temporarilyExposeZoom(
                    pid: zoom.pid,
                    bundleIdentifier: zoom.bundleIdentifier,
                    learnedMeetingWindowID: learnedMeetingWindowID
                ) {
                    let exposedScan = scanZoom(pid: zoom.pid, learnedMeetingWindowID: learnedMeetingWindowID)
                    if let exposedDiscovery = exposedScan.meetingWindowCandidate,
                       isStrongLearningEvidence(exposedDiscovery.evidence) {
                        learnedMeetingWindowID = exposedDiscovery.window.windowID
                    }
                    if let exposedHit = exposedScan.hit {
                        performedAction = handleCandidate(exposedHit, zoomPID: zoom.pid)
                    } else {
                        log("Zoom Meeting exposed, but no guarded Waiting Room candidate was found")
                    }
                    restoreAfterExposure(session, zoomPID: zoom.pid)
                } else {
                    log("Could not temporarily expose the verified Zoom process")
                }

                if performedAction && !dryRun {
                    crossSpaceBackoff = max(5, min(crossSpaceInterval, 10))
                } else if performedAction {
                    crossSpaceBackoff = max(60, crossSpaceInterval)
                } else {
                    crossSpaceBackoff = min(max(crossSpaceBackoff * 2, crossSpaceInterval), maximumCrossSpaceBackoff)
                }
                nextCrossSpaceProbe = Date().addingTimeInterval(crossSpaceBackoff)
                log("Next off-Space probe in \(String(format: "%.0f", crossSpaceBackoff)) seconds")
            } else {
                nextCrossSpaceProbe = Date().addingTimeInterval(crossSpaceInterval)
            }
        }
    } else if lastZoomRunning != false {
        log("Zoom running: no")
        lastZoomRunning = false
        lastMeetingLocation = nil
        lastMeetingWindowID = nil
        learnedMeetingWindowID = nil
    }

    if once { break }
    if !performedAction {
        // The normal no-waiting case is deliberately silent to avoid terminal spam.
    }
    Thread.sleep(forTimeInterval: interval)
} while !stopController.isStopped

signalSource.cancel()
termSource.cancel()
log("Stopped.")
