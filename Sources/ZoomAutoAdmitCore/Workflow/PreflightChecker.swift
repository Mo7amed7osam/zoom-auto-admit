import Foundation
import ZoomAXSupport

/// Checks a schedule minutes before it runs, while there is still time to fix
/// anything.
///
/// Every one of these failures is currently discovered at the moment the class
/// starts, when the user is least able to do anything about it. Checking early
/// turns "the meeting didn't start" into "your Zoom is on another Desktop —
/// move it".
///
/// Read-only: nothing is pressed, nothing is started, no account is switched.
public struct PreflightIssue: Equatable {
    public enum Severity: String, Equatable {
        /// The scheduled run will fail.
        case blocking
        /// The run will work, but something about it is degraded.
        case warning
    }

    public enum Kind: String, Equatable {
        case accessibilityMissing
        case zoomNotRunning
        case zoomUnreachable
        case accountNotFound
        case accountAmbiguous
        case meetingNotConfigured
        case noAttendanceGroup
        case rosterEmpty
        case meetingAlreadyRunning
    }

    public let kind: Kind
    public let severity: Severity
    public let message: String
    /// What the user should actually do.
    public let remedy: String?

    public init(kind: Kind, severity: Severity, message: String, remedy: String? = nil) {
        self.kind = kind
        self.severity = severity
        self.message = message
        self.remedy = remedy
    }
}

public struct PreflightReport: Equatable {
    public let scheduleName: String
    public let startsAt: Date
    public let issues: [PreflightIssue]

    public init(scheduleName: String, startsAt: Date, issues: [PreflightIssue]) {
        self.scheduleName = scheduleName
        self.startsAt = startsAt
        self.issues = issues
    }

    public var blocking: [PreflightIssue] { issues.filter { $0.severity == .blocking } }
    public var warnings: [PreflightIssue] { issues.filter { $0.severity == .warning } }
    public var isReady: Bool { blocking.isEmpty }

    /// One line for a notification.
    public var headline: String {
        if isReady {
            return warnings.isEmpty
                ? "\(scheduleName) is ready"
                : "\(scheduleName) is ready, with \(warnings.count) warning(s)"
        }
        return blocking.count == 1
            ? blocking[0].message
            : "\(blocking.count) problems will stop \(scheduleName)"
    }

    public var detail: String {
        issues
            .map { issue in issue.remedy.map { "\(issue.message) — \($0)" } ?? issue.message }
            .joined(separator: "\n")
    }
}

public enum PreflightChecker {
    public static func check(
        schedule: ZoomSchedule,
        profile: ZoomAccountProfile?,
        group: StudentGroup?,
        startsAt: Date,
        automation: ZoomAutomating
    ) -> PreflightReport {
        var issues: [PreflightIssue] = []

        guard automation.isAccessibilityTrusted() else {
            // Nothing else can be checked without it.
            return PreflightReport(
                scheduleName: schedule.name,
                startsAt: startsAt,
                issues: [PreflightIssue(
                    kind: .accessibilityMissing,
                    severity: .blocking,
                    message: "Accessibility permission is missing",
                    remedy: "Grant it in System Settings ▸ Privacy & Security ▸ Accessibility"
                )]
            )
        }

        issues.append(contentsOf: meetingIssues(schedule: schedule))

        guard let process = automation.zoomProcess() else {
            issues.append(PreflightIssue(
                kind: .zoomNotRunning,
                severity: .warning,
                message: "Zoom isn't running",
                remedy: "It will be launched automatically, which takes a little longer"
            ))
            issues.append(contentsOf: attendanceIssues(schedule: schedule, group: group))
            return PreflightReport(scheduleName: schedule.name, startsAt: startsAt, issues: issues)
        }

        // The account menu doubles as a reachability probe: it is the one part
        // of Zoom that stays readable even when its windows are on another
        // Space, so failing here means Zoom is not answering at all.
        guard let accounts = automation.readAccountMenu() else {
            issues.append(PreflightIssue(
                kind: .zoomUnreachable,
                severity: .blocking,
                message: "Zoom isn't responding to Accessibility",
                remedy: "Quit and reopen Zoom"
            ))
            issues.append(contentsOf: attendanceIssues(schedule: schedule, group: group))
            return PreflightReport(scheduleName: schedule.name, startsAt: startsAt, issues: issues)
        }

        if let profile {
            switch ZoomAXSupport.matchAccount(identifier: profile.accountIdentifier, in: accounts.entries) {
            case .found:
                break
            case .notFound:
                issues.append(PreflightIssue(
                    kind: .accountNotFound,
                    severity: .blocking,
                    message: "\(profile.accountIdentifier) isn't signed in to Zoom",
                    remedy: "Sign in to that account in Zoom, or pick a different profile"
                ))
            case .ambiguous(let matches):
                issues.append(PreflightIssue(
                    kind: .accountAmbiguous,
                    severity: .blocking,
                    message: "\(matches.count) Zoom accounts match “\(profile.accountIdentifier)”",
                    remedy: "Use the full email address in the account profile"
                ))
            }
        }

        // A call already in progress will stop the scheduled meeting starting.
        if automation.meetingPresence(for: process).state == .active {
            issues.append(PreflightIssue(
                kind: .meetingAlreadyRunning,
                severity: .warning,
                message: "A Zoom meeting is already running",
                remedy: "The scheduled meeting will not be started while it is"
            ))
        }

        issues.append(contentsOf: attendanceIssues(schedule: schedule, group: group))
        return PreflightReport(scheduleName: schedule.name, startsAt: startsAt, issues: issues)
    }

    private static func meetingIssues(schedule: ZoomSchedule) -> [PreflightIssue] {
        guard case .meetingID(let raw) = schedule.meeting.kind else { return [] }
        guard MeetingReference.normalizedMeetingID(raw).isEmpty else { return [] }
        return [PreflightIssue(
            kind: .meetingNotConfigured,
            severity: .blocking,
            message: "\(schedule.name) has no usable meeting ID",
            remedy: "Paste the meeting link or number into the schedule"
        )]
    }

    private static func attendanceIssues(schedule: ZoomSchedule, group: StudentGroup?) -> [PreflightIssue] {
        guard schedule.attendanceGroupID != nil else { return [] }

        guard let group else {
            return [PreflightIssue(
                kind: .noAttendanceGroup,
                severity: .warning,
                message: "The linked attendance group no longer exists",
                remedy: "Pick a group in the schedule, or attendance won't be recorded"
            )]
        }
        guard group.students.isEmpty else { return [] }
        return [PreflightIssue(
            kind: .rosterEmpty,
            severity: .warning,
            message: "\(group.name) has no students",
            remedy: "Import the class list, or nobody can be matched"
        )]
    }
}
