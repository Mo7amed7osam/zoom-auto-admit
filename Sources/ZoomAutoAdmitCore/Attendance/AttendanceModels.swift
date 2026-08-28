import Foundation

/// One official student on a group's roster.
///
/// Identity is the `id`, never the array position or the name: names get
/// corrected, and a roster edit tomorrow must not silently rewrite who was
/// present yesterday.
public struct Student: Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var officialName: String
    /// Optional external identifier from the institution's own records.
    public var externalID: String?
    public var email: String?
    /// Names this student has been seen using in Zoom, learned from manual
    /// corrections. Group-scoped by virtue of living on the group's roster.
    public var aliases: [String]

    public init(
        id: UUID = UUID(),
        officialName: String,
        externalID: String? = nil,
        email: String? = nil,
        aliases: [String] = []
    ) {
        self.id = id
        self.officialName = officialName
        self.externalID = externalID
        self.email = email
        self.aliases = aliases
    }

    public var normalizedOfficialName: String {
        NameNormalizer.normalize(officialName)
    }

    private enum CodingKeys: String, CodingKey {
        case id, officialName, externalID, email, aliases
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        officialName = try container.decode(String.self, forKey: .officialName)
        externalID = try container.decodeIfPresent(String.self, forKey: .externalID)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }
}

/// A class group: its roster, its learned aliases, and who to ignore.
public struct StudentGroup: Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var students: [Student]
    /// Names that are never students — the host account, a co-teacher, and so on.
    public var ignoredParticipantNames: [String]
    /// Confidence at or above which an AI match is accepted without review.
    public var autoAcceptConfidence: Double

    public init(
        id: UUID = UUID(),
        name: String,
        students: [Student] = [],
        ignoredParticipantNames: [String] = [],
        autoAcceptConfidence: Double = 0.90
    ) {
        self.id = id
        self.name = name
        self.students = students
        self.ignoredParticipantNames = ignoredParticipantNames
        self.autoAcceptConfidence = autoAcceptConfidence
    }

    public func isIgnored(_ displayName: String) -> Bool {
        let candidate = NameNormalizer.normalize(displayName)
        return ignoredParticipantNames.contains { NameNormalizer.normalize($0) == candidate }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, students, ignoredParticipantNames, autoAcceptConfidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        students = try container.decodeIfPresent([Student].self, forKey: .students) ?? []
        ignoredParticipantNames =
            try container.decodeIfPresent([String].self, forKey: .ignoredParticipantNames) ?? []
        autoAcceptConfidence =
            try container.decodeIfPresent(Double.self, forKey: .autoAcceptConfidence) ?? 0.90
    }
}

/// One continuous stretch during which a name was visible in the list.
public struct PresenceInterval: Codable, Equatable, Hashable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// Everything observed about one Zoom display name during a session.
///
/// Keyed by normalized name because Zoom exposes no per-participant identifier;
/// leaving and rejoining under the same name is therefore one observation with
/// several intervals, not two attendees.
public struct ParticipantObservation: Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var rawName: String
    public var normalizedName: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var intervals: [PresenceInterval]
    public var currentlyPresent: Bool
    /// Other spellings seen for what is judged the same row within this meeting.
    public var observedAliases: [String]
    public var sawHostRole: Bool

    public init(
        id: UUID = UUID(),
        rawName: String,
        normalizedName: String,
        firstSeen: Date,
        lastSeen: Date,
        intervals: [PresenceInterval] = [],
        currentlyPresent: Bool = true,
        observedAliases: [String] = [],
        sawHostRole: Bool = false
    ) {
        self.id = id
        self.rawName = rawName
        self.normalizedName = normalizedName
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.intervals = intervals
        self.currentlyPresent = currentlyPresent
        self.observedAliases = observedAliases
        self.sawHostRole = sawHostRole
    }

    /// Separate join sessions, which is what a register usually means by "joins".
    public var joinCount: Int { max(1, intervals.count) }

    public var totalDuration: TimeInterval {
        intervals.reduce(0) { $0 + $1.duration }
    }
}

public enum AttendanceStatus: String, Codable, Equatable {
    case present
    case absent
    case needsReview
    /// Before finalization, a student who has not been seen is not yet absent.
    case notSeenYet
}

/// Why the app believes someone was present. Kept for auditing: an attendance
/// register that cannot explain itself is not worth much.
public enum MatchSource: String, Codable, Equatable {
    case exact
    case alias
    case token
    case fuzzy
    case ai
    case manual
    case none
}

public struct AttendanceRecord: Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var studentID: UUID
    public var studentName: String
    public var status: AttendanceStatus
    public var matchedObservationID: UUID?
    public var matchedZoomName: String?
    public var matchSource: MatchSource
    public var confidence: Double?
    public var reason: String?
    /// Manual decisions are never overwritten by a later automatic pass.
    public var isManual: Bool

    public init(
        id: UUID = UUID(),
        studentID: UUID,
        studentName: String,
        status: AttendanceStatus,
        matchedObservationID: UUID? = nil,
        matchedZoomName: String? = nil,
        matchSource: MatchSource = .none,
        confidence: Double? = nil,
        reason: String? = nil,
        isManual: Bool = false
    ) {
        self.id = id
        self.studentID = studentID
        self.studentName = studentName
        self.status = status
        self.matchedObservationID = matchedObservationID
        self.matchedZoomName = matchedZoomName
        self.matchSource = matchSource
        self.confidence = confidence
        self.reason = reason
        self.isManual = isManual
    }
}

/// One meeting occurrence's attendance.
///
/// The roster is snapshotted into the session at creation so that editing the
/// group tomorrow cannot change what yesterday's register says.
public struct AttendanceSession: Codable, Equatable, Identifiable {
    public var id: UUID
    public var groupID: UUID
    public var groupName: String
    public var scheduleID: UUID?
    public var meetingName: String
    public var startedAt: Date
    public var endedAt: Date?
    public var finalizedAt: Date?
    /// Immutable copy of the roster as it stood when the meeting began.
    public var rosterSnapshot: [Student]
    public var observations: [ParticipantObservation]
    public var records: [AttendanceRecord]
    /// Zoom names that matched nobody.
    public var unmatchedZoomNames: [String]

    public init(
        id: UUID = UUID(),
        groupID: UUID,
        groupName: String,
        scheduleID: UUID? = nil,
        meetingName: String,
        startedAt: Date,
        endedAt: Date? = nil,
        finalizedAt: Date? = nil,
        rosterSnapshot: [Student],
        observations: [ParticipantObservation] = [],
        records: [AttendanceRecord] = [],
        unmatchedZoomNames: [String] = []
    ) {
        self.id = id
        self.groupID = groupID
        self.groupName = groupName
        self.scheduleID = scheduleID
        self.meetingName = meetingName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.finalizedAt = finalizedAt
        self.rosterSnapshot = rosterSnapshot
        self.observations = observations
        self.records = records
        self.unmatchedZoomNames = unmatchedZoomNames
    }

    public var isFinalized: Bool { finalizedAt != nil }

    public var presentCount: Int { records.filter { $0.status == .present }.count }
    public var absentCount: Int { records.filter { $0.status == .absent }.count }
    public var needsReviewCount: Int { records.filter { $0.status == .needsReview }.count }

    public func observation(withID id: UUID) -> ParticipantObservation? {
        observations.first { $0.id == id }
    }
}
