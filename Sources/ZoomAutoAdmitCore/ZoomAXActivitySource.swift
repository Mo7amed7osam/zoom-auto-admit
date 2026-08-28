import ApplicationServices
import Foundation
import OSLog
import ZoomAXSupport

/// Hybrid half of the monitor: an `AXObserver` on the Zoom process that asks for
/// an immediate scan when Zoom's participant UI changes.
///
/// It is deliberately best-effort. Zoom's participant list is a custom control
/// and may post few or no notifications; if registration fails, or Zoom stays
/// silent, the polling loop still admits participants on its own schedule. This
/// only ever shortens the wait.
///
/// The observer never activates, raises or focuses Zoom.
public final class ZoomAXObserverActivitySource: AutoAdmitActivitySource {
    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "observer")
    /// Registration and the run-loop source live on the main run loop; the
    /// callback body only forwards to the monitor's queue.
    private let stateQueue = DispatchQueue(label: "com.mohamedhosam.ZoomAutoAdmit.observer-state")
    private var observer: ZoomAXActivityObserver?
    private var observedPID: pid_t?
    private var onActivity: (() -> Void)?
    private var started = false

    public init() {}

    public func start(onActivity: @escaping () -> Void) {
        stateQueue.sync {
            self.onActivity = onActivity
            self.started = true
        }
        synchronize()
    }

    /// Follows Zoom launches, quits and PID changes. Called after every poll.
    public func synchronize() {
        let currentPID = ZoomAXSupport.zoomApplication()?.pid
        stateQueue.sync {
            guard started else { return }
            guard currentPID != observedPID || (currentPID != nil && observer == nil) else { return }
            observedPID = currentPID
            let handler = onActivity
            let existing = observer
            observer = nil

            DispatchQueue.main.async { [weak self] in
                existing?.stop()
                guard let self, let currentPID, let handler else { return }
                let created = ZoomAXActivityObserver(pid: currentPID, onActivity: handler)
                let registered = created.start()
                if registered {
                    self.logger.info("Zoom AX observer registered for \(created.registeredNotifications.count) notifications")
                } else {
                    self.logger.notice("Zoom AX observer unavailable; polling remains authoritative")
                }
                self.stateQueue.sync {
                    guard self.started, self.observedPID == currentPID else {
                        created.stop()
                        return
                    }
                    self.observer = registered ? created : nil
                }
            }
        }
    }

    public func stop() {
        let existing: ZoomAXActivityObserver? = stateQueue.sync {
            started = false
            onActivity = nil
            observedPID = nil
            let current = observer
            observer = nil
            return current
        }
        guard let existing else { return }
        DispatchQueue.main.async { existing.stop() }
    }
}
