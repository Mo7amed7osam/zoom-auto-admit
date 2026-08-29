import Foundation

/// When attendance snapshots are due.
///
/// Pure decision logic, kept out of the timer so the timing rules can be tested
/// against fixed dates rather than by waiting fifteen minutes.
public struct SnapshotSchedule: Equatable {
    /// Bounds chosen so the interval stays useful without becoming a poll.
    public static let minimumInterval: TimeInterval = 5 * 60
    public static let defaultInterval: TimeInterval = 15 * 60
    public static let minimumPostAdmitDelay: TimeInterval = 3
    public static let defaultPostAdmitDelay: TimeInterval = 8
    public static let maximumPostAdmitDelay: TimeInterval = 60

    public var periodicEnabled: Bool
    public var interval: TimeInterval
    public var postAdmitEnabled: Bool
    public var postAdmitDelay: TimeInterval

    public init(
        periodicEnabled: Bool = true,
        interval: TimeInterval = SnapshotSchedule.defaultInterval,
        postAdmitEnabled: Bool = true,
        postAdmitDelay: TimeInterval = SnapshotSchedule.defaultPostAdmitDelay
    ) {
        self.periodicEnabled = periodicEnabled
        self.interval = max(interval, Self.minimumInterval)
        self.postAdmitEnabled = postAdmitEnabled
        self.postAdmitDelay = min(max(postAdmitDelay, Self.minimumPostAdmitDelay), Self.maximumPostAdmitDelay)
    }

    /// When the next periodic snapshot is due after one taken at `last`.
    public func nextPeriodicDate(after last: Date) -> Date? {
        guard periodicEnabled else { return nil }
        return last.addingTimeInterval(interval)
    }

    public func isPeriodicDue(now: Date, lastSnapshotAt: Date?) -> Bool {
        guard periodicEnabled else { return false }
        guard let lastSnapshotAt else { return true }
        return now.timeIntervalSince(lastSnapshotAt) >= interval
    }
}

/// Coalesces admit bursts into a single snapshot.
///
/// Admitting five students in four seconds is one event as far as attendance is
/// concerned. Each admit merely extends the same pending snapshot rather than
/// queueing another expensive scan of the participant tree.
public struct PostAdmitCoalescer: Equatable {
    public private(set) var pendingSince: Date?
    public private(set) var dueAt: Date?
    public private(set) var admitsInBurst = 0

    public init() {}

    /// Records an admit. Returns the moment the snapshot is now due.
    @discardableResult
    public mutating func noteAdmit(at now: Date, delay: TimeInterval) -> Date {
        admitsInBurst += 1
        if pendingSince == nil {
            pendingSince = now
            dueAt = now.addingTimeInterval(delay)
        }
        // A later admit joins the pending snapshot; it does not push it back
        // indefinitely, so a steady trickle still gets captured.
        return dueAt ?? now.addingTimeInterval(delay)
    }

    public func isDue(at now: Date) -> Bool {
        guard let dueAt else { return false }
        return now >= dueAt
    }

    public var isPending: Bool { dueAt != nil }

    public mutating func reset() {
        pendingSince = nil
        dueAt = nil
        admitsInBurst = 0
    }
}
