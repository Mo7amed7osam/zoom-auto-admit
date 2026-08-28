import ApplicationServices
import Foundation
import OSLog
import ZoomAXSupport

public typealias ZoomPresentation = ZoomAXSupport.ZoomPresentation

public enum AutoAdmitMonitorEvent: Equatable {
    case accessibilityPermissionRequired
    case accessibilityPermissionGrantedRelaunchRequired
    case accessibilityAppBundleMismatch
    case accessibilityPossibleStaleTCCEntry
    case zoomNotRunning
    case meetingNotDetected
    case meetingOnOtherDesktop
    case meetingInaccessible(String)
    /// Zoom is running and Accessibility permission is intact, but a Zoom-specific
    /// Accessibility query failed. Always recoverable; never a permission state.
    case zoomTemporarilyUnavailable(String)
    case monitoring(presentation: ZoomPresentation)
    case admitted(participantName: String?, admitAll: Bool, at: Date)
    case error(String)
}

public protocol AutoAdmitProbing {
    func poll() -> AutoAdmitMonitorEvent
}

/// Something that can tell the monitor "Zoom's UI just changed, scan now".
/// Purely an accelerator: the monitor is correct without it.
public protocol AutoAdmitActivitySource: AnyObject {
    func start(onActivity: @escaping () -> Void)
    /// Called after every poll so the source can follow Zoom launches, quits and
    /// PID changes without keeping its own timer.
    func synchronize()
    func stop()
}

public final class ZoomAutoAdmitProbe: AutoAdmitProbing {
    public struct Configuration {
        /// Scan attempts per poll. Attempt 1 is the normal path; the extra
        /// attempts exist so a single transient Accessibility failure never
        /// surfaces as a user-visible state change.
        public var maximumScanAttempts: Int
        /// Pause before re-acquiring fresh Accessibility references.
        public var retryDelay: TimeInterval

        public init(maximumScanAttempts: Int = 3, retryDelay: TimeInterval = 0.3) {
            self.maximumScanAttempts = max(1, maximumScanAttempts)
            self.retryDelay = min(max(retryDelay, 0.25), 0.5)
        }
    }

    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "monitor")
    private let configuration: Configuration
    private let access: ZoomAccessProviding
    private let sleeper: (TimeInterval) -> Void
    /// Remembered only to improve off-Space CoreGraphics discovery. No
    /// Accessibility element is ever cached between scans.
    private var learnedMeetingWindowID: CGWindowID?

    public init(
        configuration: Configuration = Configuration(),
        access: ZoomAccessProviding = LiveZoomAccess(),
        sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.configuration = configuration
        self.access = access
        self.sleeper = sleeper
    }

    public func poll() -> AutoAdmitMonitorEvent {
        let trust = access.trustSnapshot()
        guard trust.isTrusted else {
            return .accessibilityPermissionRequired
        }
        // Only kAXErrorAPIDisabled means Accessibility is unavailable to this
        // process. A busy or unresponsive frontmost application returning
        // cannotComplete/noValue is unrelated to permission.
        if trust.accessibilityAPIDisabled {
            return .accessibilityPermissionGrantedRelaunchRequired
        }
        if trust.systemWideProbeFailedBenignly {
            logger.debug("System-wide AX probe failed benignly: \(trust.systemWideProbeResult.diagnosticDescription, privacy: .public)")
        }

        guard let zoom = access.zoomApplication() else {
            learnedMeetingWindowID = nil
            return .zoomNotRunning
        }

        var lastFailureDescription: String?
        let lastAttemptIndex = configuration.maximumScanAttempts - 1

        for attempt in 0...lastAttemptIndex {
            if attempt > 0 {
                sleeper(configuration.retryDelay)
                guard let current = access.zoomApplication(),
                      current.pid == zoom.pid,
                      current.bundleIdentifier == zoom.bundleIdentifier else {
                    return .zoomNotRunning
                }
            }

            // Fresh application element, fresh AXWindows, fresh subtree, fresh
            // buttons. Nothing survives from the previous scan.
            let scan = access.scan(pid: zoom.pid)

            if let failure = scan.failure {
                if case .accessibilityDisabled = failure {
                    logger.error("Accessibility reported apiDisabled for Zoom")
                    return .accessibilityPermissionGrantedRelaunchRequired
                }
                lastFailureDescription = failure.diagnosticDescription
                logger.notice("Zoom AX scan failed (\(failure.diagnosticDescription, privacy: .public)); retrying with fresh references")
                continue
            }

            if let candidate = scan.candidate {
                switch admit(candidate, zoom: zoom) {
                case .admitted(let event):
                    return event
                case .retry(let description):
                    lastFailureDescription = description
                    continue
                case .failed(let event):
                    return event
                }
            }

            if scan.meetingHierarchyAvailable {
                return .monitoring(presentation: access.presentation(pid: zoom.pid))
            }

            // The hierarchy is genuinely absent for this scan. Only now do the
            // window APIs get consulted to explain why.
            let located = access.locateMeeting(
                pid: zoom.pid,
                bundleIdentifier: zoom.bundleIdentifier,
                scan: scan,
                learnedWindowID: learnedMeetingWindowID
            )
            switch located.location {
            case .otherSpaceOrFullscreen:
                // Requires the hierarchy to stay absent across every attempt
                // before it is reported as another Desktop.
                if attempt < lastAttemptIndex {
                    lastFailureDescription = "meeting hierarchy absent"
                    continue
                }
                learnedMeetingWindowID = located.windowID ?? learnedMeetingWindowID
                logger.notice("Zoom meeting appears to be on another Desktop or full-screen Space")
                return .meetingOnOtherDesktop
            case .hidden:
                return .meetingInaccessible("Zoom is hidden")
            case .minimized:
                return .meetingInaccessible("Zoom meeting is minimized")
            case .currentSpace, .currentSpaceBackground:
                return .monitoring(presentation: access.presentation(pid: zoom.pid))
            case .notFound:
                return .meetingNotDetected
            }
        }

        return .zoomTemporarilyUnavailable(lastFailureDescription ?? "Zoom did not answer Accessibility")
    }

    private enum AdmitOutcome {
        case admitted(AutoAdmitMonitorEvent)
        case retry(String)
        case failed(AutoAdmitMonitorEvent)
    }

    private func admit(
        _ candidate: ZoomAXSupport.AdmitCandidate,
        zoom: (pid: pid_t, bundleIdentifier: String)
    ) -> AdmitOutcome {
        let label = candidate.isAdmitAll ? "Admit All" : "Admit"
        logger.info("Guarded Waiting Room candidate detected: \(candidate.type.rawValue, privacy: .public)")

        guard let currentZoom = access.zoomApplication(),
              currentZoom.pid == zoom.pid,
              currentZoom.bundleIdentifier == zoom.bundleIdentifier else {
            return .failed(.error("Zoom process changed before Admit"))
        }

        // pressAdmit re-verifies role, enabled and AXPress against the live
        // element before pressing, and reports invalidUIElement if it no longer
        // qualifies. A stale button is re-acquired, never force-pressed.
        let result = access.pressAdmit(candidate)
        if result == .success {
            logger.info("Admitted participant; admitAll=\(candidate.isAdmitAll)")
            return .admitted(.admitted(
                participantName: candidate.isAdmitAll ? nil : candidate.participantName,
                admitAll: candidate.isAdmitAll,
                at: Date()
            ))
        }

        if result.indicatesStaleElement || result.indicatesTransientFailure {
            logger.notice("AXPress on \(label, privacy: .public) returned \(result.diagnosticDescription, privacy: .public); re-acquiring")
            return .retry("AXPress \(result.diagnosticDescription)")
        }

        logger.error("AXPress failed with \(result.diagnosticDescription, privacy: .public)")
        return .failed(.error("Could not press \(label) (\(result.diagnosticDescription))"))
    }
}

public final class AutoAdmitMonitor {
    public typealias EventHandler = (AutoAdmitMonitorEvent) -> Void

    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "polling")
    private let queue: DispatchQueue
    private let interval: TimeInterval
    /// Shortest gap between two Accessibility-notification-triggered scans.
    /// Bounds CPU if Zoom posts notifications continuously.
    private let activityCoalescingInterval: TimeInterval = 0.35
    private let probe: AutoAdmitProbing
    private let activitySource: AutoAdmitActivitySource?
    private let eventHandler: EventHandler
    private var timer: DispatchSourceTimer?
    private var generation: UInt64 = 0
    private var lastDeliveredEvent: AutoAdmitMonitorEvent?
    private var lastScanStarted = Date.distantPast
    private var activityScanScheduled = false

    public init(
        interval: TimeInterval = 0.75,
        probe: AutoAdmitProbing = ZoomAutoAdmitProbe(),
        activitySource: AutoAdmitActivitySource? = nil,
        eventHandler: @escaping EventHandler
    ) {
        self.interval = min(max(interval, 0.5), 1.0)
        self.probe = probe
        self.activitySource = activitySource
        self.eventHandler = eventHandler
        self.queue = DispatchQueue(label: "com.mohamedhosam.ZoomAutoAdmit.monitor", qos: .utility)
    }

    public var isRunning: Bool {
        queue.sync { timer != nil }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.generation &+= 1
            self.lastDeliveredEvent = nil
            let activeGeneration = self.generation
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now(),
                repeating: self.interval,
                leeway: .milliseconds(100)
            )
            timer.setEventHandler { [weak self] in
                self?.runProbe(generation: activeGeneration)
            }
            self.timer = timer
            timer.resume()
            self.activitySource?.start { [weak self] in
                self?.handleZoomActivity()
            }
            self.logger.info("Monitoring started")
        }
    }

    public func stop() {
        queue.sync {
            guard let timer else { return }
            generation &+= 1
            lastDeliveredEvent = nil
            activityScanScheduled = false
            timer.setEventHandler {}
            timer.cancel()
            self.timer = nil
            activitySource?.stop()
            logger.info("Monitoring stopped")
        }
    }

    public func checkNow(forceDelivery: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastScanStarted = Date()
            let event = self.probe.poll()
            self.deliver(event, force: forceDelivery)
        }
    }

    /// An Accessibility notification arrived from Zoom. Scan sooner than the next
    /// poll, coalescing bursts so a chatty Zoom cannot spin the CPU.
    private func handleZoomActivity() {
        queue.async { [weak self] in
            guard let self, self.timer != nil, !self.activityScanScheduled else { return }
            let elapsed = Date().timeIntervalSince(self.lastScanStarted)
            let delay = max(0, self.activityCoalescingInterval - elapsed)
            let activeGeneration = self.generation
            self.activityScanScheduled = true
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.activityScanScheduled = false
                self.runProbe(generation: activeGeneration)
            }
        }
    }

    private func runProbe(generation activeGeneration: UInt64) {
        guard timer != nil, generation == activeGeneration else { return }
        lastScanStarted = Date()
        let event = probe.poll()
        guard timer != nil, generation == activeGeneration else { return }
        deliver(event)
        activitySource?.synchronize()
    }

    private func deliver(_ event: AutoAdmitMonitorEvent, force: Bool = false) {
        if !force, lastDeliveredEvent == event {
            return
        }
        lastDeliveredEvent = event
        eventHandler(event)
    }

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
        activitySource?.stop()
    }
}
