import Foundation

/// Which control an issue belongs to, so the UI can put the message next to the
/// field rather than showing a generic "invalid form".
public enum ScheduleField: String, Equatable {
    case name
    case weekdays
    case account
    case meetingName
    case meetingID
}

public enum ProfileField: String, Equatable {
    case name
    case accountIdentifier
}

public struct ValidationIssue<Field: Equatable>: Equatable {
    public let field: Field
    public let message: String

    public init(field: Field, message: String) {
        self.field = field
        self.message = message
    }
}

/// Pure validation rules, shared by the editor and the tests.
///
/// Invalid configurations are rejected before they can be written, because a
/// schedule with, say, an empty account silently fails hours later at 6:00 PM
/// with "No saved Zoom account matches".
public enum ScheduleValidation {
    public static func validate(
        _ schedule: ZoomSchedule,
        in configuration: SchedulerConfiguration
    ) -> [ValidationIssue<ScheduleField>] {
        var issues: [ValidationIssue<ScheduleField>] = []

        if schedule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(field: .name, message: "Enter a name"))
        }

        if case .selectedWeekdays(let days) = schedule.recurrence, days.isEmpty {
            issues.append(.init(field: .weekdays, message: "Select at least one day"))
        }

        let profile = configuration.accountProfiles.first { $0.id == schedule.accountProfileID }
        if profile == nil {
            issues.append(.init(field: .account, message: "Select a Zoom account"))
        }

        if schedule.meeting.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(field: .meetingName, message: "Enter a meeting name"))
        }

        if case .meetingID(let raw) = schedule.meeting.kind,
           MeetingReference.normalizedMeetingID(raw).isEmpty {
            issues.append(.init(field: .meetingID, message: "Enter the meeting ID"))
        }

        return issues
    }

    public static func validate(_ profile: ZoomAccountProfile) -> [ValidationIssue<ProfileField>] {
        var issues: [ValidationIssue<ProfileField>] = []

        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(field: .name, message: "Enter a name"))
        }

        let identifier = profile.accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if identifier.isEmpty {
            issues.append(.init(field: .accountIdentifier, message: "Select a Zoom account"))
        } else if !isPlausibleAccountIdentifier(identifier) {
            issues.append(.init(
                field: .accountIdentifier,
                message: "Enter the account's email address"
            ))
        }

        return issues
    }

    /// An email is required rather than merely preferred: display names collide
    /// between Zoom accounts, and a colliding name aborts the workflow.
    public static func isPlausibleAccountIdentifier(_ identifier: String) -> Bool {
        let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = value.firstIndex(of: "@"), at != value.startIndex else { return false }
        let domain = value[value.index(after: at)...]
        return domain.contains(".")
            && !domain.hasPrefix(".")
            && !domain.hasSuffix(".")
            && !value.contains(" ")
            && value.filter { $0 == "@" }.count == 1
    }

    public static func isValid(
        _ schedule: ZoomSchedule,
        in configuration: SchedulerConfiguration
    ) -> Bool {
        validate(schedule, in: configuration).isEmpty
    }

    public static func isValid(_ profile: ZoomAccountProfile) -> Bool {
        validate(profile).isEmpty
    }

    /// Nothing invalid may reach disk.
    public static func isValid(_ configuration: SchedulerConfiguration) -> Bool {
        configuration.accountProfiles.allSatisfy(isValid)
            && configuration.schedules.allSatisfy { isValid($0, in: configuration) }
    }
}
