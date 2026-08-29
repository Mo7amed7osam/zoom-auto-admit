import Foundation
import OSLog

/// Runtime state the scheduler keeps across launches so that a schedule is
/// neither fired twice nor missed because the app was restarted.
public struct SchedulerRuntimeState: Codable, Equatable {
    public var lastCheck: Date?
    /// Schedule id → the occurrence start moment that has already been handled.
    public var firedOccurrences: [String: Date]
    /// Schedule id → when Auto Admit should stop for the occurrence in progress.
    public var monitoringDeadlines: [String: Date]
    /// Schedule id → the occurrence already checked ahead of time.
    public var preflightedOccurrences: [String: Date]

    public init(
        lastCheck: Date? = nil,
        firedOccurrences: [String: Date] = [:],
        monitoringDeadlines: [String: Date] = [:],
        preflightedOccurrences: [String: Date] = [:]
    ) {
        self.lastCheck = lastCheck
        self.firedOccurrences = firedOccurrences
        self.monitoringDeadlines = monitoringDeadlines
        self.preflightedOccurrences = preflightedOccurrences
    }

    private enum CodingKeys: String, CodingKey {
        case lastCheck, firedOccurrences, monitoringDeadlines, preflightedOccurrences
    }

    // State written before pre-flight existed must keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastCheck = try container.decodeIfPresent(Date.self, forKey: .lastCheck)
        firedOccurrences = try container.decodeIfPresent([String: Date].self, forKey: .firedOccurrences) ?? [:]
        monitoringDeadlines = try container.decodeIfPresent([String: Date].self, forKey: .monitoringDeadlines) ?? [:]
        preflightedOccurrences =
            try container.decodeIfPresent([String: Date].self, forKey: .preflightedOccurrences) ?? [:]
    }
}

public protocol SchedulerRuntimeStateStoring: AnyObject {
    func loadRuntimeState() -> SchedulerRuntimeState
    func saveRuntimeState(_ state: SchedulerRuntimeState)
}

/// UserDefaults-backed runtime state. Small, non-user-facing bookkeeping, unlike
/// the schedules themselves which live in a readable JSON file.
public final class UserDefaultsRuntimeStateStore: SchedulerRuntimeStateStoring {
    private let defaults: UserDefaults
    private let key = "schedulerRuntimeState"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadRuntimeState() -> SchedulerRuntimeState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(SchedulerRuntimeState.self, from: data) else {
            return SchedulerRuntimeState()
        }
        return state
    }

    public func saveRuntimeState(_ state: SchedulerRuntimeState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Fires schedules while the app runs, and catches up occurrences that were
/// missed while it was asleep or not running.
///
/// A wall-clock tick is used rather than a single timer armed at the next start
/// time, because that survives system sleep, time-zone and clock changes, and
/// app relaunches without any special casing.
public final class SchedulerService {
    public typealias FireHandler = (ZoomSchedule, ZoomAccountProfile, Date) -> Void
    public typealias EndHandler = (ZoomSchedule) -> Void
    /// Called ahead of an occurrence so problems surface while they are fixable.
    public typealias PreflightHandler = (ZoomSchedule, ZoomAccountProfile?, Date) -> Void

    /// How far back a freshly launched app will look for an occurrence it missed.
    public static let catchUpWindow: TimeInterval = 15 * 60
    public static let tickInterval: TimeInterval = 15
    /// How far ahead of a start time the pre-flight check runs.
    public static let preflightLead: TimeInterval = 5 * 60

    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "scheduler")
    private let queue = DispatchQueue(label: "com.mohamedhosam.ZoomAutoAdmit.scheduler")
    private let runtimeStore: SchedulerRuntimeStateStoring
    private let calendar: Calendar
    private let clock: () -> Date
    private let onFire: FireHandler
    private let onMonitoringEnd: EndHandler
    private let onPreflight: PreflightHandler?

    private var configuration = SchedulerConfiguration()
    private var runtimeState: SchedulerRuntimeState
    private var timer: DispatchSourceTimer?

    public init(
        configuration: SchedulerConfiguration = SchedulerConfiguration(),
        runtimeStore: SchedulerRuntimeStateStoring = UserDefaultsRuntimeStateStore(),
        calendar: Calendar = .current,
        clock: @escaping () -> Date = { Date() },
        onFire: @escaping FireHandler,
        onMonitoringEnd: @escaping EndHandler,
        onPreflight: PreflightHandler? = nil
    ) {
        self.configuration = configuration
        self.runtimeStore = runtimeStore
        self.calendar = calendar
        self.clock = clock
        self.onFire = onFire
        self.onMonitoringEnd = onMonitoringEnd
        self.onPreflight = onPreflight
        self.runtimeState = runtimeStore.loadRuntimeState()
    }

    public func update(configuration: SchedulerConfiguration) {
        queue.sync {
            self.configuration = configuration
            // Forget bookkeeping for schedules that no longer exist.
            let liveIDs = Set(configuration.schedules.map { $0.id.uuidString })
            runtimeState.firedOccurrences = runtimeState.firedOccurrences.filter { liveIDs.contains($0.key) }
            runtimeState.monitoringDeadlines = runtimeState.monitoringDeadlines.filter { liveIDs.contains($0.key) }
            runtimeState.preflightedOccurrences =
                runtimeState.preflightedOccurrences.filter { liveIDs.contains($0.key) }
            runtimeStore.saveRuntimeState(runtimeState)
        }
    }

    public var isRunning: Bool { queue.sync { timer != nil } }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: Self.tickInterval, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.evaluateLocked(at: self.clock())
            }
            self.timer = timer
            timer.resume()
            self.logger.info("Scheduler started")
        }
    }

    public func stop() {
        queue.sync {
            guard let timer else { return }
            timer.setEventHandler {}
            timer.cancel()
            self.timer = nil
            logger.info("Scheduler stopped")
        }
    }

    /// Forces an immediate evaluation, e.g. after the Mac wakes from sleep.
    public func checkNow() {
        queue.async { [weak self] in
            guard let self else { return }
            self.evaluateLocked(at: self.clock())
        }
    }

    /// Synchronous evaluation, used directly by tests.
    public func evaluate(at now: Date) {
        queue.sync { evaluateLocked(at: now) }
    }

    public func nextScheduled(after date: Date? = nil) -> (schedule: ZoomSchedule, date: Date)? {
        queue.sync {
            ScheduleTimeline.nextScheduled(
                in: configuration.schedules.filter(\.isEnabled),
                after: date ?? clock(),
                calendar: calendar
            )
        }
    }

    /// Records that monitoring is running for a schedule, so the end time can
    /// stop it even if the app is relaunched in between.
    public func registerMonitoring(for schedule: ZoomSchedule, startedAt date: Date) {
        queue.sync {
            guard let end = ScheduleTimeline.endDate(for: schedule, startedAt: date, calendar: calendar) else {
                return
            }
            runtimeState.monitoringDeadlines[schedule.id.uuidString] = end
            runtimeStore.saveRuntimeState(runtimeState)
        }
    }

    public func cancelMonitoringDeadline(for schedule: ZoomSchedule) {
        queue.sync {
            runtimeState.monitoringDeadlines.removeValue(forKey: schedule.id.uuidString)
            runtimeStore.saveRuntimeState(runtimeState)
        }
    }

    // MARK: Evaluation

    /// Fires the check for occurrences whose lead time has just passed.
    ///
    /// The window is shifted forward by the lead, so an occurrence at 18:00 is
    /// checked when the clock reaches 17:55.
    private func evaluatePreflightLocked(at now: Date, windowStart: Date) {
        for schedule in configuration.schedules where schedule.isEnabled {
            let occurrences = ScheduleTimeline.occurrences(
                of: schedule,
                after: windowStart.addingTimeInterval(Self.preflightLead),
                through: now.addingTimeInterval(Self.preflightLead),
                calendar: calendar
            )
            guard let occurrence = occurrences.last else { continue }

            let key = schedule.id.uuidString
            if let checked = runtimeState.preflightedOccurrences[key],
               abs(checked.timeIntervalSince(occurrence)) < 1 {
                continue
            }
            // Never check something that has already started.
            guard occurrence > now else { continue }

            runtimeState.preflightedOccurrences[key] = occurrence
            runtimeStore.saveRuntimeState(runtimeState)
            logger.notice("Pre-flight check for \(schedule.name, privacy: .public)")
            onPreflight?(schedule, configuration.profile(for: schedule), occurrence)
        }
    }

    private func evaluateLocked(at now: Date) {
        let windowStart = max(
            runtimeState.lastCheck ?? now.addingTimeInterval(-Self.catchUpWindow),
            now.addingTimeInterval(-Self.catchUpWindow)
        )

        for schedule in configuration.schedules where schedule.isEnabled {
            let occurrences = ScheduleTimeline.occurrences(
                of: schedule,
                after: windowStart,
                through: now,
                calendar: calendar
            )
            guard let occurrence = occurrences.last else { continue }

            let key = schedule.id.uuidString
            if let fired = runtimeState.firedOccurrences[key], abs(fired.timeIntervalSince(occurrence)) < 1 {
                continue
            }
            guard let profile = configuration.profile(for: schedule) else {
                logger.error("Schedule \(schedule.name, privacy: .public) has no matching account profile")
                runtimeState.firedOccurrences[key] = occurrence
                continue
            }

            runtimeState.firedOccurrences[key] = occurrence
            runtimeStore.saveRuntimeState(runtimeState)
            logger.notice("Schedule fired: \(schedule.name, privacy: .public)")
            onFire(schedule, profile, occurrence)
        }

        if onPreflight != nil {
            evaluatePreflightLocked(at: now, windowStart: windowStart)
        }

        for (key, deadline) in runtimeState.monitoringDeadlines where deadline <= now {
            runtimeState.monitoringDeadlines.removeValue(forKey: key)
            if let schedule = configuration.schedules.first(where: { $0.id.uuidString == key }) {
                logger.notice("End time reached for \(schedule.name, privacy: .public)")
                onMonitoringEnd(schedule)
            }
        }

        runtimeState.lastCheck = now
        runtimeStore.saveRuntimeState(runtimeState)
    }
}
