import Foundation
import XCTest
@testable import ZoomAutoAdmitCore

final class ScheduleTimelineTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Africa/Cairo") ?? .current
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func schedule(
        recurrence: ScheduleRecurrence,
        start: TimeOfDay = TimeOfDay(hour: 18, minute: 0),
        end: TimeOfDay? = nil,
        enabled: Bool = true
    ) -> ZoomSchedule {
        ZoomSchedule(
            name: "Saturday DEPI",
            isEnabled: enabled,
            recurrence: recurrence,
            startTime: start,
            endTime: end,
            accountProfileID: UUID(),
            meeting: MeetingReference(name: "Week 2 Saturday", kind: .meetingID("123 4567 890"))
        )
    }

    /// 2026-08-28 is a Friday; 2026-08-29 is the Saturday after it.
    func testSelectedWeekdaysFindsTheNextMatchingDay() {
        let saturday = schedule(recurrence: .selectedWeekdays([.saturday]))
        let next = ScheduleTimeline.nextOccurrence(
            of: saturday,
            after: date(2026, 8, 28, 12, 0),
            calendar: calendar
        )
        XCTAssertEqual(next, date(2026, 8, 29, 18, 0))
        XCTAssertEqual(calendar.component(.weekday, from: next!), Weekday.saturday.rawValue)
    }

    func testSelectedWeekdaysSupportsSeveralDays() {
        let twiceWeekly = schedule(recurrence: .selectedWeekdays([.saturday, .tuesday]))
        let afterSaturday = ScheduleTimeline.nextOccurrence(
            of: twiceWeekly,
            after: date(2026, 8, 29, 19, 0),
            calendar: calendar
        )
        XCTAssertEqual(afterSaturday, date(2026, 9, 1, 18, 0), "Tuesday follows Saturday")
    }

    func testSameDayBeforeStartTimeFiresToday() {
        let saturday = schedule(recurrence: .selectedWeekdays([.saturday]))
        let next = ScheduleTimeline.nextOccurrence(
            of: saturday,
            after: date(2026, 8, 29, 9, 0),
            calendar: calendar
        )
        XCTAssertEqual(next, date(2026, 8, 29, 18, 0))
    }

    func testDailyRollsOverAfterTheStartTime() {
        let daily = schedule(recurrence: .daily)
        XCTAssertEqual(
            ScheduleTimeline.nextOccurrence(of: daily, after: date(2026, 8, 28, 18, 1), calendar: calendar),
            date(2026, 8, 29, 18, 0)
        )
    }

    func testOneTimeScheduleNeverRepeats() {
        let once = schedule(recurrence: .oneTime(year: 2026, month: 9, day: 5))
        XCTAssertEqual(
            ScheduleTimeline.nextOccurrence(of: once, after: date(2026, 9, 1, 0, 0), calendar: calendar),
            date(2026, 9, 5, 18, 0)
        )
        XCTAssertNil(
            ScheduleTimeline.nextOccurrence(of: once, after: date(2026, 9, 5, 18, 1), calendar: calendar)
        )
    }

    /// 2. A disabled schedule never produces an occurrence.
    func testDisabledScheduleNeverFires() {
        let disabled = schedule(recurrence: .daily, enabled: false)
        XCTAssertNil(
            ScheduleTimeline.nextOccurrence(of: disabled, after: date(2026, 8, 28, 0, 0), calendar: calendar)
        )
        XCTAssertTrue(ScheduleTimeline.occurrences(
            of: disabled,
            after: date(2026, 8, 28, 0, 0),
            through: date(2026, 9, 30, 0, 0),
            calendar: calendar
        ).isEmpty)
    }

    func testEmptyWeekdaySelectionNeverFires() {
        let none = schedule(recurrence: .selectedWeekdays([]))
        XCTAssertNil(
            ScheduleTimeline.nextOccurrence(of: none, after: date(2026, 8, 28, 0, 0), calendar: calendar)
        )
    }

    func testEndTimeAfterStartStaysOnTheSameDay() {
        let withEnd = schedule(
            recurrence: .daily,
            start: TimeOfDay(hour: 18, minute: 0),
            end: TimeOfDay(hour: 20, minute: 30)
        )
        XCTAssertEqual(
            ScheduleTimeline.endDate(for: withEnd, startedAt: date(2026, 8, 29, 18, 0), calendar: calendar),
            date(2026, 8, 29, 20, 30)
        )
    }

    func testEndTimeBeforeStartRollsToTheNextDay() {
        let overnight = schedule(
            recurrence: .daily,
            start: TimeOfDay(hour: 22, minute: 0),
            end: TimeOfDay(hour: 0, minute: 30)
        )
        XCTAssertEqual(
            ScheduleTimeline.endDate(for: overnight, startedAt: date(2026, 8, 29, 22, 0), calendar: calendar),
            date(2026, 8, 30, 0, 30)
        )
    }

    func testNextScheduledPicksTheSoonest() {
        let saturday = schedule(recurrence: .selectedWeekdays([.saturday]))
        var tuesday = schedule(recurrence: .selectedWeekdays([.tuesday]), start: TimeOfDay(hour: 20, minute: 0))
        tuesday.name = "Tuesday Training"

        let next = ScheduleTimeline.nextScheduled(
            in: [tuesday, saturday],
            after: date(2026, 8, 28, 12, 0),
            calendar: calendar
        )
        XCTAssertEqual(next?.schedule.name, "Saturday DEPI")
        XCTAssertEqual(next?.date, date(2026, 8, 29, 18, 0))
    }
}

final class SchedulerServiceTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Africa/Cairo") ?? .current
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func makeConfiguration(
        enabled: Bool = true,
        end: TimeOfDay? = nil
    ) -> (SchedulerConfiguration, ZoomSchedule, ZoomAccountProfile) {
        let profile = ZoomAccountProfile(name: "DEPI", accountIdentifier: "depi+11@eyouthlearning.com")
        let schedule = ZoomSchedule(
            name: "Saturday DEPI",
            isEnabled: enabled,
            recurrence: .selectedWeekdays([.saturday]),
            startTime: TimeOfDay(hour: 18, minute: 0),
            endTime: end,
            accountProfileID: profile.id,
            meeting: MeetingReference(name: "Week 2 Saturday", kind: .meetingID("12345678901"))
        )
        return (SchedulerConfiguration(accountProfiles: [profile], schedules: [schedule]), schedule, profile)
    }

    /// 1. The schedule fires once its start time is inside the evaluated window.
    func testScheduleFiresAtTheCorrectTime() {
        let (configuration, _, _) = makeConfiguration()
        var fired: [String] = []
        let service = SchedulerService(
            configuration: configuration,
            runtimeStore: MemoryRuntimeStore(),
            calendar: calendar,
            clock: { self.date(2026, 8, 29, 18, 0) },
            onFire: { schedule, _, _ in fired.append(schedule.name) },
            onMonitoringEnd: { _ in }
        )

        service.evaluate(at: date(2026, 8, 29, 17, 59))
        XCTAssertTrue(fired.isEmpty, "Nothing should fire before the start time")

        service.evaluate(at: date(2026, 8, 29, 18, 0, ))
        XCTAssertEqual(fired, ["Saturday DEPI"])
    }

    /// 2. A disabled schedule is never fired.
    func testDisabledScheduleDoesNotFire() {
        let (configuration, _, _) = makeConfiguration(enabled: false)
        var fired = 0
        let service = SchedulerService(
            configuration: configuration,
            runtimeStore: MemoryRuntimeStore(),
            calendar: calendar,
            clock: { self.date(2026, 8, 29, 18, 0) },
            onFire: { _, _, _ in fired += 1 },
            onMonitoringEnd: { _ in }
        )

        service.evaluate(at: date(2026, 8, 29, 18, 0))
        XCTAssertEqual(fired, 0)
    }

    /// 14. Repeated evaluations of the same occurrence fire exactly once, so no
    /// second workflow — and therefore no second monitor — is ever launched.
    func testAnOccurrenceFiresOnlyOnce() {
        let (configuration, _, _) = makeConfiguration()
        var fired = 0
        let service = SchedulerService(
            configuration: configuration,
            runtimeStore: MemoryRuntimeStore(),
            calendar: calendar,
            clock: { self.date(2026, 8, 29, 18, 0) },
            onFire: { _, _, _ in fired += 1 },
            onMonitoringEnd: { _ in }
        )

        service.evaluate(at: date(2026, 8, 29, 18, 0))
        service.evaluate(at: date(2026, 8, 29, 18, 0, 30))
        service.evaluate(at: date(2026, 8, 29, 18, 1))
        XCTAssertEqual(fired, 1)
    }

    /// 15. A relaunch keeps the fired bookkeeping, and still catches an
    /// occurrence that was missed while the app was not running.
    func testRelaunchCatchesAMissedOccurrenceButNeverRepeatsOne() {
        let (configuration, _, _) = makeConfiguration()
        let store = MemoryRuntimeStore()
        var firstRunFires = 0
        let first = SchedulerService(
            configuration: configuration,
            runtimeStore: store,
            calendar: calendar,
            clock: { self.date(2026, 8, 29, 18, 2) },
            onFire: { _, _, _ in firstRunFires += 1 },
            onMonitoringEnd: { _ in }
        )
        // App launched two minutes late; the catch-up window still sees 18:00.
        first.evaluate(at: date(2026, 8, 29, 18, 2))
        XCTAssertEqual(firstRunFires, 1)

        var secondRunFires = 0
        let second = SchedulerService(
            configuration: configuration,
            runtimeStore: store,
            calendar: calendar,
            clock: { self.date(2026, 8, 29, 18, 5) },
            onFire: { _, _, _ in secondRunFires += 1 },
            onMonitoringEnd: { _ in }
        )
        second.evaluate(at: date(2026, 8, 29, 18, 5))
        XCTAssertEqual(secondRunFires, 0, "A relaunch must not re-run an occurrence already handled")
    }

    func testOccurrenceOlderThanTheCatchUpWindowIsNotFired() {
        let (configuration, _, _) = makeConfiguration()
        var fired = 0
        let service = SchedulerService(
            configuration: configuration,
            runtimeStore: MemoryRuntimeStore(),
            calendar: calendar,
            clock: { self.date(2026, 8, 29, 21, 0) },
            onFire: { _, _, _ in fired += 1 },
            onMonitoringEnd: { _ in }
        )

        // Three hours late: far outside the catch-up window, so the meeting is
        // not started retroactively.
        service.evaluate(at: date(2026, 8, 29, 21, 0))
        XCTAssertEqual(fired, 0)
    }

    /// 13. The end time stops monitoring.
    func testEndTimeTriggersMonitoringStop() {
        let (configuration, schedule, _) = makeConfiguration(end: TimeOfDay(hour: 20, minute: 0))
        var ended: [String] = []
        let service = SchedulerService(
            configuration: configuration,
            runtimeStore: MemoryRuntimeStore(),
            calendar: calendar,
            clock: { self.date(2026, 8, 29, 18, 0) },
            onFire: { _, _, _ in },
            onMonitoringEnd: { ended.append($0.name) }
        )

        service.registerMonitoring(for: schedule, startedAt: date(2026, 8, 29, 18, 0))
        service.evaluate(at: date(2026, 8, 29, 19, 59))
        XCTAssertTrue(ended.isEmpty)

        service.evaluate(at: date(2026, 8, 29, 20, 0))
        XCTAssertEqual(ended, ["Saturday DEPI"])

        service.evaluate(at: date(2026, 8, 29, 20, 1))
        XCTAssertEqual(ended, ["Saturday DEPI"], "The end must fire exactly once")
    }

    func testCancellingTheDeadlineStopsTheEndFromFiring() {
        let (configuration, schedule, _) = makeConfiguration(end: TimeOfDay(hour: 20, minute: 0))
        var ended = 0
        let service = SchedulerService(
            configuration: configuration,
            runtimeStore: MemoryRuntimeStore(),
            calendar: calendar,
            clock: { self.date(2026, 8, 29, 18, 0) },
            onFire: { _, _, _ in },
            onMonitoringEnd: { _ in ended += 1 }
        )

        service.registerMonitoring(for: schedule, startedAt: date(2026, 8, 29, 18, 0))
        service.cancelMonitoringDeadline(for: schedule)
        service.evaluate(at: date(2026, 8, 29, 20, 1))
        XCTAssertEqual(ended, 0)
    }

    func testScheduleWithoutAProfileIsSkippedRatherThanRunBlind() {
        let profile = ZoomAccountProfile(name: "DEPI", accountIdentifier: "depi@example.com")
        let orphan = ZoomSchedule(
            name: "Orphan",
            recurrence: .daily,
            startTime: TimeOfDay(hour: 18, minute: 0),
            accountProfileID: UUID(),
            meeting: MeetingReference(name: "M", kind: .meetingID("123"))
        )
        var fired = 0
        let service = SchedulerService(
            configuration: SchedulerConfiguration(accountProfiles: [profile], schedules: [orphan]),
            runtimeStore: MemoryRuntimeStore(),
            calendar: calendar,
            clock: { self.date(2026, 8, 29, 18, 0) },
            onFire: { _, _, _ in fired += 1 },
            onMonitoringEnd: { _ in }
        )

        service.evaluate(at: date(2026, 8, 29, 18, 0))
        XCTAssertEqual(fired, 0)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ s: Int) -> Date {
        calendar.date(from: DateComponents(
            year: y, month: m, day: d, hour: h, minute: min, second: s
        ))!
    }
}

/// 15. Schedules survive an app restart.
final class ScheduleStoreTests: XCTestCase {
    func testConfigurationRoundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-tests-\(UUID().uuidString)")
            .appendingPathComponent("schedules.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let profile = ZoomAccountProfile(name: "DEPI", accountIdentifier: "depi+11@eyouthlearning.com")
        let configuration = SchedulerConfiguration(
            accountProfiles: [profile],
            schedules: [
                ZoomSchedule(
                    name: "Saturday DEPI",
                    recurrence: .selectedWeekdays([.saturday, .tuesday]),
                    startTime: TimeOfDay(hour: 18, minute: 0),
                    endTime: TimeOfDay(hour: 20, minute: 30),
                    accountProfileID: profile.id,
                    meeting: MeetingReference(name: "Week 2 Saturday", kind: .meetingID("123 4567 8901")),
                    launchZoomMinutesEarly: 5
                ),
                ZoomSchedule(
                    name: "One off",
                    recurrence: .oneTime(year: 2026, month: 9, day: 5),
                    startTime: TimeOfDay(hour: 9, minute: 15),
                    accountProfileID: profile.id,
                    meeting: MeetingReference(name: "Personal", kind: .instantMeeting),
                    enablesAutoAdmit: false
                )
            ]
        )

        let store = ScheduleStore(fileURL: url)
        XCTAssertTrue(store.save(configuration))

        // A separate store instance stands in for the next app launch.
        let reloaded = ScheduleStore(fileURL: url).load()
        XCTAssertEqual(reloaded, configuration)
        XCTAssertEqual(reloaded.schedules[0].recurrence, .selectedWeekdays([.saturday, .tuesday]))
        XCTAssertEqual(reloaded.schedules[1].meeting.kind, .instantMeeting)
        XCTAssertEqual(reloaded.profile(for: reloaded.schedules[0])?.name, "DEPI")
    }

    func testMissingFileLoadsAnEmptyConfiguration() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-missing-\(UUID().uuidString).json")
        XCTAssertEqual(ScheduleStore(fileURL: url).load(), SchedulerConfiguration())
    }

    func testStoredJSONContainsNoCredentialFields() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-tests-\(UUID().uuidString)")
            .appendingPathComponent("schedules.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let profile = ZoomAccountProfile(name: "DEPI", accountIdentifier: "depi+11@eyouthlearning.com")
        let store = ScheduleStore(fileURL: url)
        XCTAssertTrue(store.save(SchedulerConfiguration(accountProfiles: [profile], schedules: [])))

        let json = try String(contentsOf: url, encoding: .utf8).lowercased()
        for forbidden in ["password", "passcode", "token", "secret", "credential"] {
            XCTAssertFalse(json.contains(forbidden), "schedules.json must never contain \(forbidden)")
        }
    }

    func testMeetingIDNormalizationKeepsDigitsOnly() {
        XCTAssertEqual(MeetingReference.normalizedMeetingID("123 4567 8901"), "12345678901")
        XCTAssertEqual(MeetingReference.normalizedMeetingID("123-456-7890"), "1234567890")
        XCTAssertEqual(MeetingReference.normalizedMeetingID("no digits here"), "")
    }
}

private final class MemoryRuntimeStore: SchedulerRuntimeStateStoring {
    private var state = SchedulerRuntimeState()
    func loadRuntimeState() -> SchedulerRuntimeState { state }
    func saveRuntimeState(_ state: SchedulerRuntimeState) { self.state = state }
}
