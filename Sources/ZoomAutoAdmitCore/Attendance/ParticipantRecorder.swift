import Foundation
import ZoomAXSupport

/// Accumulates who was actually in the meeting, from repeated reads of Zoom's
/// participant list.
///
/// Two rules shape everything here. A list that could not be read is never
/// treated as an empty list, because that would mark a whole class absent the
/// moment Zoom hides a panel. And the host account is excluded, because the
/// teacher is not on their own register.
public final class ParticipantRecorder {
    public private(set) var observations: [ParticipantObservation] = []
    /// Reads where Zoom's list could not be seen at all.
    public private(set) var unavailableReads = 0
    public private(set) var successfulReads = 0
    public private(set) var lastReadAt: Date?

    private var indexByNormalizedName: [String: Int] = [:]
    private let group: StudentGroup

    public init(group: StudentGroup, existing: [ParticipantObservation] = []) {
        self.group = group
        self.observations = existing
        for (index, observation) in existing.enumerated() {
            indexByNormalizedName[observation.normalizedName] = index
        }
    }

    /// Folds one read of the participant list into the running history.
    public func record(_ readout: ZoomAXSupport.ParticipantsReadout, at now: Date = Date()) {
        guard readout.listAvailable else {
            // Cannot see the list. Say nothing about who is present.
            unavailableReads += 1
            return
        }
        successfulReads += 1
        lastReadAt = now

        var seenThisRead = Set<String>()

        for row in readout.admitted {
            // The host is the account running this app, not a student.
            guard !row.isSelfOrHost else { continue }
            guard !group.isIgnored(row.displayName) else { continue }

            let normalized = NameNormalizer.normalize(row.displayName)
            guard !normalized.isEmpty else { continue }
            seenThisRead.insert(normalized)

            if let index = indexByNormalizedName[normalized] {
                observations[index].lastSeen = now
                if observations[index].currentlyPresent {
                    extendCurrentInterval(at: index, to: now)
                } else {
                    // Same person rejoining is another interval, not another
                    // attendee.
                    observations[index].currentlyPresent = true
                    observations[index].intervals.append(PresenceInterval(start: now, end: now))
                }
                if row.roles.contains(.host) || row.roles.contains(.coHost) {
                    observations[index].sawHostRole = true
                }
                if observations[index].rawName != row.displayName,
                   !observations[index].observedAliases.contains(row.displayName) {
                    observations[index].observedAliases.append(row.displayName)
                }
            } else {
                observations.append(ParticipantObservation(
                    rawName: row.displayName,
                    normalizedName: normalized,
                    firstSeen: now,
                    lastSeen: now,
                    intervals: [PresenceInterval(start: now, end: now)],
                    currentlyPresent: true,
                    sawHostRole: row.roles.contains(.host) || row.roles.contains(.coHost)
                ))
                indexByNormalizedName[normalized] = observations.count - 1
            }
        }

        // Anyone previously present and absent from this read has left.
        for index in observations.indices
        where observations[index].currentlyPresent && !seenThisRead.contains(observations[index].normalizedName) {
            observations[index].currentlyPresent = false
            extendCurrentInterval(at: index, to: observations[index].lastSeen)
        }
    }

    /// Closes every open interval, at the end of the meeting.
    public func finish(at now: Date = Date()) {
        for index in observations.indices where observations[index].currentlyPresent {
            extendCurrentInterval(at: index, to: now)
            observations[index].currentlyPresent = false
            observations[index].lastSeen = now
        }
    }

    public var currentlyPresentCount: Int {
        observations.filter(\.currentlyPresent).count
    }

    private func extendCurrentInterval(at index: Int, to now: Date) {
        if observations[index].intervals.isEmpty {
            observations[index].intervals.append(
                PresenceInterval(start: observations[index].firstSeen, end: now)
            )
        } else {
            observations[index].intervals[observations[index].intervals.count - 1].end = now
        }
    }
}
