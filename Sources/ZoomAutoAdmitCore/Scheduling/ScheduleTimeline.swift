import Foundation

/// Pure recurrence arithmetic. Kept free of timers and side effects so the
/// firing rules can be tested against fixed dates.
public enum ScheduleTimeline {
    /// How far ahead `nextOccurrence` is willing to search.
    public static let searchHorizonDays = 400

    /// The next start moment strictly after `date`.
    public static func nextOccurrence(
        of schedule: ZoomSchedule,
        after date: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard schedule.isEnabled else { return nil }

        switch schedule.recurrence {
        case .oneTime(let year, let month, let day):
            guard let occurrence = calendar.date(from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: schedule.startTime.hour,
                minute: schedule.startTime.minute
            )) else { return nil }
            return occurrence > date ? occurrence : nil

        case .daily:
            return firstOccurrence(after: date, calendar: calendar, schedule: schedule) { _ in true }

        case .selectedWeekdays(let weekdays):
            guard !weekdays.isEmpty else { return nil }
            let rawDays = Set(weekdays.map(\.rawValue))
            return firstOccurrence(after: date, calendar: calendar, schedule: schedule) { day in
                rawDays.contains(calendar.component(.weekday, from: day))
            }
        }
    }

    /// Every start moment in `(start, end]`.
    ///
    /// The scheduler asks in terms of an interval rather than "is it time yet?"
    /// so that a tick delayed by system sleep, a clock change, or the app being
    /// relaunched still sees the occurrence it slept through.
    public static func occurrences(
        of schedule: ZoomSchedule,
        after start: Date,
        through end: Date,
        calendar: Calendar = .current
    ) -> [Date] {
        guard schedule.isEnabled, end > start else { return [] }

        var results: [Date] = []
        var cursor = start
        while let next = nextOccurrence(of: schedule, after: cursor, calendar: calendar), next <= end {
            results.append(next)
            cursor = next
            if results.count >= 64 { break }
        }
        return results
    }

    /// The moment monitoring should stop for an occurrence that started at
    /// `startDate`. An end time at or before the start time is read as the next
    /// day, so "20:00 to 00:30" works.
    public static func endDate(
        for schedule: ZoomSchedule,
        startedAt startDate: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard let endTime = schedule.endTime else { return nil }
        let day = calendar.startOfDay(for: startDate)
        guard let sameDayEnd = calendar.date(
            byAdding: DateComponents(hour: endTime.hour, minute: endTime.minute),
            to: day
        ) else { return nil }

        if sameDayEnd > startDate { return sameDayEnd }
        return calendar.date(byAdding: .day, value: 1, to: sameDayEnd)
    }

    /// The soonest upcoming occurrence across a set of schedules.
    public static func nextScheduled(
        in schedules: [ZoomSchedule],
        after date: Date,
        calendar: Calendar = .current
    ) -> (schedule: ZoomSchedule, date: Date)? {
        schedules
            .compactMap { schedule -> (schedule: ZoomSchedule, date: Date)? in
                guard let next = nextOccurrence(of: schedule, after: date, calendar: calendar) else {
                    return nil
                }
                return (schedule, next)
            }
            .min { $0.date < $1.date }
    }

    private static func firstOccurrence(
        after date: Date,
        calendar: Calendar,
        schedule: ZoomSchedule,
        dayMatches: (Date) -> Bool
    ) -> Date? {
        var day = calendar.startOfDay(for: date)
        for _ in 0...searchHorizonDays {
            if dayMatches(day),
               let candidate = calendar.date(
                   bySettingHour: schedule.startTime.hour,
                   minute: schedule.startTime.minute,
                   second: 0,
                   of: day
               ),
               candidate > date {
                return candidate
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = nextDay
        }
        return nil
    }
}
