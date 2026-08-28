import ApplicationServices
import Foundation

/// Accessibility notification observer for the Zoom application.
///
/// This is an accelerator, never the source of truth. Zoom draws its participant
/// list with a custom control (`ZMHCTableItemType_*`), so how faithfully it posts
/// Accessibility notifications cannot be relied on. The observer exists to cut
/// admission latency when Zoom does post; the polling loop still runs and remains
/// authoritative.
///
/// The observer only ever *reads* notifications. It never raises, activates or
/// focuses Zoom.
public final class ZoomAXActivityObserver {
    /// Registered on the Zoom application element. Unsupported notifications are
    /// skipped individually, so a Zoom build that posts only some of them still
    /// benefits from the ones it does post.
    public static let observedNotifications: [String] = [
        kAXCreatedNotification as String,
        kAXUIElementDestroyedNotification as String,
        kAXWindowCreatedNotification as String,
        kAXRowCountChangedNotification as String,
        kAXSelectedRowsChangedNotification as String,
        kAXValueChangedNotification as String,
        kAXLayoutChangedNotification as String
    ]

    public let pid: pid_t
    public private(set) var registeredNotifications: [String] = []

    private let onActivity: () -> Void
    private let runLoop: CFRunLoop
    private var observer: AXObserver?
    private var applicationElement: AXUIElement?

    public init(pid: pid_t, runLoop: CFRunLoop = CFRunLoopGetMain(), onActivity: @escaping () -> Void) {
        self.pid = pid
        self.runLoop = runLoop
        self.onActivity = onActivity
    }

    deinit {
        stop()
    }

    /// Returns true when at least one notification was registered.
    @discardableResult
    public func start() -> Bool {
        guard observer == nil else { return !registeredNotifications.isEmpty }

        var created: AXObserver?
        let creationResult = AXObserverCreate(pid, ZoomAXActivityObserver.callback, &created)
        guard creationResult == .success, let created else { return false }

        let application = ZoomAXSupport.freshZoomApplicationElement(pid: pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered: [String] = []
        for notification in Self.observedNotifications {
            let result = AXObserverAddNotification(created, application, notification as CFString, refcon)
            if result == .success || result == .notificationAlreadyRegistered {
                registered.append(notification)
            }
        }

        guard !registered.isEmpty else { return false }

        observer = created
        applicationElement = application
        registeredNotifications = registered
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(created), .defaultMode)
        return true
    }

    public func stop() {
        guard let observer else { return }
        if let applicationElement {
            for notification in registeredNotifications {
                AXObserverRemoveNotification(observer, applicationElement, notification as CFString)
            }
        }
        CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
        self.applicationElement = nil
        registeredNotifications = []
    }

    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let observer = Unmanaged<ZoomAXActivityObserver>.fromOpaque(refcon).takeUnretainedValue()
        observer.onActivity()
    }
}
