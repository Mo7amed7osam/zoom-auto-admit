import Foundation
import OSLog

public final class ZoomSessionAllocator {
    private let lock = NSLock()
    private var desktopReservation: UUID?
    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "allocator")

    public init() {}

    public func allocate(_ request: SessionRequest, desktopHasActiveMeeting: Bool) -> ZoomEngine {
        lock.lock()
        defer { lock.unlock() }

        if request.account.preferredEngine == .web {
            logger.info("[ALLOCATOR] Account prefers Web engine")
            return .web
        }
        if desktopHasActiveMeeting || desktopReservation != nil {
            logger.info("[ALLOCATOR] Desktop unavailable, selecting Web engine")
            return .web
        }
        desktopReservation = request.id
        logger.info("[ALLOCATOR] Desktop available, selecting Desktop engine")
        return .desktop
    }

    public func release(_ request: SessionRequest, engine: ZoomEngine) {
        guard engine == .desktop else { return }
        lock.lock()
        if desktopReservation == request.id { desktopReservation = nil }
        lock.unlock()
    }
}
