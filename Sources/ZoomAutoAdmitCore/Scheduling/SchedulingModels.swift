import Foundation

/// Wall-clock time of day, stored without a time zone so that "Saturday 6:00 PM"
/// keeps meaning 6:00 PM locally across DST changes.
public struct TimeOfDay: Codable, Equatable, Comparable, Hashable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    public var displayText: String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let calendar = Calendar.current
        guard let date = calendar.date(from: DateComponents(
            year: 2000, month: 1, day: 1, hour: hour, minute: minute
        )) else {
            return String(format: "%02d:%02d", hour, minute)
        }
        _ = components
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

/// Calendar weekday numbers, matching `Calendar.component(.weekday:)`.
public enum Weekday: Int, Codable, CaseIterable, Comparable, Hashable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.rawValue < rhs.rawValue }

    public var shortName: String {
        switch self {
        case .sunday: return "Sun"
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        }
    }

    public var fullName: String {
        switch self {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        }
    }
}

public enum ScheduleRecurrence: Codable, Equatable, Hashable {
    case oneTime(year: Int, month: Int, day: Int)
    case daily
    case selectedWeekdays(Set<Weekday>)

    public var displayText: String {
        switch self {
        case .oneTime(let year, let month, let day):
            return String(format: "%04d-%02d-%02d", year, month, day)
        case .daily:
            return "Every day"
        case .selectedWeekdays(let days):
            if days.isEmpty { return "No days selected" }
            if days.count == 7 { return "Every day" }
            return days.sorted().map(\.shortName).joined(separator: ", ")
        }
    }

    // Explicit coding keys keep the on-disk JSON readable and stable.
    private enum CodingKeys: String, CodingKey {
        case kind, year, month, day, weekdays
    }

    private enum Kind: String, Codable {
        case oneTime, daily, selectedWeekdays
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .oneTime(let year, let month, let day):
            try container.encode(Kind.oneTime, forKey: .kind)
            try container.encode(year, forKey: .year)
            try container.encode(month, forKey: .month)
            try container.encode(day, forKey: .day)
        case .daily:
            try container.encode(Kind.daily, forKey: .kind)
        case .selectedWeekdays(let days):
            try container.encode(Kind.selectedWeekdays, forKey: .kind)
            try container.encode(days.sorted().map(\.rawValue), forKey: .weekdays)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .oneTime:
            self = .oneTime(
                year: try container.decode(Int.self, forKey: .year),
                month: try container.decode(Int.self, forKey: .month),
                day: try container.decode(Int.self, forKey: .day)
            )
        case .daily:
            self = .daily
        case .selectedWeekdays:
            let raw = try container.decode([Int].self, forKey: .weekdays)
            self = .selectedWeekdays(Set(raw.compactMap(Weekday.init(rawValue:))))
        }
    }
}

/// How a scheduled meeting is started.
///
/// Live inspection settled this: Zoom registers the public `zoommtg` URL scheme,
/// and its documented `start` action targets a meeting by number using whichever
/// account is signed in. That is far more robust than navigating the meeting
/// list, which lives inside a window and therefore disappears from Accessibility
/// whenever Zoom sits on another Space — the exact state Zoom was found in
/// during discovery.
public struct MeetingReference: Codable, Equatable, Hashable {
    public enum Kind: Codable, Equatable, Hashable {
        /// Start a specific meeting by its Zoom meeting number.
        case meetingID(String)
        /// Zoom's `Start meeting` application menu entry (personal meeting).
        case instantMeeting

        private enum CodingKeys: String, CodingKey { case kind, meetingID }
        private enum Tag: String, Codable { case meetingID, instantMeeting }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .meetingID(let identifier):
                try container.encode(Tag.meetingID, forKey: .kind)
                try container.encode(identifier, forKey: .meetingID)
            case .instantMeeting:
                try container.encode(Tag.instantMeeting, forKey: .kind)
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Tag.self, forKey: .kind) {
            case .meetingID:
                self = .meetingID(try container.decode(String.self, forKey: .meetingID))
            case .instantMeeting:
                self = .instantMeeting
            }
        }
    }

    public var name: String
    public var kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    /// Digits only. Zoom meeting numbers are commonly written `123 4567 8901`.
    public static func normalizedMeetingID(_ raw: String) -> String {
        raw.filter(\.isNumber)
    }

    public var displayText: String {
        switch kind {
        case .meetingID(let identifier):
            let digits = Self.normalizedMeetingID(identifier)
            return digits.isEmpty ? name : "\(name) (\(digits))"
        case .instantMeeting:
            return "\(name) (personal meeting)"
        }
    }
}

/// A logical Zoom account.
///
/// Holds no password, token or any other credential: only the identifier needed
/// to recognise an account that is *already* signed in inside Zoom's own
/// Switch account menu.
public struct ZoomAccountProfile: Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    /// Friendly label, e.g. "DEPI".
    public var name: String
    /// Matched against Zoom's saved accounts. An email is strongly preferred:
    /// several saved accounts can share a display name.
    public var accountIdentifier: String

    public init(id: UUID = UUID(), name: String, accountIdentifier: String) {
        self.id = id
        self.name = name
        self.accountIdentifier = accountIdentifier
    }
}

public struct ZoomSchedule: Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var recurrence: ScheduleRecurrence
    public var startTime: TimeOfDay
    /// When set, Auto Admit monitoring is stopped at this time. The Zoom meeting
    /// itself is never ended automatically.
    public var endTime: TimeOfDay?
    public var accountProfileID: UUID
    public var meeting: MeetingReference
    public var enablesAutoAdmit: Bool
    /// Zoom is launched this many minutes before the start time so its UI is
    /// ready when the workflow runs.
    public var launchZoomMinutesEarly: Int

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        recurrence: ScheduleRecurrence,
        startTime: TimeOfDay,
        endTime: TimeOfDay? = nil,
        accountProfileID: UUID,
        meeting: MeetingReference,
        enablesAutoAdmit: Bool = true,
        launchZoomMinutesEarly: Int = 2
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.recurrence = recurrence
        self.startTime = startTime
        self.endTime = endTime
        self.accountProfileID = accountProfileID
        self.meeting = meeting
        self.enablesAutoAdmit = enablesAutoAdmit
        self.launchZoomMinutesEarly = min(max(launchZoomMinutesEarly, 0), 60)
    }
}

/// Everything the scheduler persists.
public struct SchedulerConfiguration: Codable, Equatable {
    public var accountProfiles: [ZoomAccountProfile]
    public var schedules: [ZoomSchedule]

    public init(accountProfiles: [ZoomAccountProfile] = [], schedules: [ZoomSchedule] = []) {
        self.accountProfiles = accountProfiles
        self.schedules = schedules
    }

    public func profile(for schedule: ZoomSchedule) -> ZoomAccountProfile? {
        accountProfiles.first { $0.id == schedule.accountProfileID }
    }
}
