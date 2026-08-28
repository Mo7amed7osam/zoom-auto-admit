import ApplicationServices
import AppKit
import Foundation

/// Evidence-based detection of whether Zoom currently has a meeting running.
///
/// Used for two opposite purposes, so it has to be honest in both directions:
/// before starting anything, to refuse to disturb a call already in progress;
/// and after starting, to confirm the scheduled meeting really began rather than
/// trusting that a press "worked". Both uses make guessing worse than admitting
/// ignorance, which is why `unknown` is a first-class answer.
public extension ZoomAXSupport {
    enum MeetingPresenceState: String, Equatable {
        case active
        case notActive
        /// Zoom's Accessibility hierarchy is unreachable — typically its windows
        /// are on another Space — so the question cannot be answered.
        case unknown
    }

    struct MeetingPresence: Equatable {
        public let state: MeetingPresenceState
        /// Which signals fired, recorded so live runs are self-diagnosing.
        public let evidence: [String]
        public let axWindowTitles: [String]
        public let location: MeetingWindowLocation

        public init(
            state: MeetingPresenceState,
            evidence: [String],
            axWindowTitles: [String],
            location: MeetingWindowLocation
        ) {
            self.state = state
            self.evidence = evidence
            self.axWindowTitles = axWindowTitles
            self.location = location
        }

        public var isActive: Bool { state == .active }
        public var isUnknown: Bool { state == .unknown }

        public var evidenceDescription: String {
            evidence.isEmpty ? "none" : evidence.joined(separator: "+")
        }
    }

    /// Pure evidence combination, so the rules are testable without a meeting.
    ///
    /// Only Accessibility evidence can prove a meeting. CoreGraphics is
    /// deliberately excluded: `kCGWindowName` is populated only for processes
    /// holding Screen Recording permission, which this app does not request, so
    /// live capture showed every Zoom CG window name coming back empty. The
    /// off-Space window heuristic then scores Zoom's ordinary main window just as
    /// highly as a meeting window — enough to *locate* a window for the monitor's
    /// diagnostics, nowhere near enough to assert that a call is in progress.
    static func classifyMeetingPresence(
        axWindowTitles: [String],
        hasMeetingStructure: Bool,
        axHierarchyAvailable: Bool,
        location: MeetingWindowLocation
    ) -> MeetingPresence {
        var evidence: [String] = []
        if axWindowTitles.contains(where: isLikelyMeetingWindowTitle) {
            evidence.append("ax-meeting-window-title")
        }
        if hasMeetingStructure {
            evidence.append("ax-meeting-structure")
        }

        let state: MeetingPresenceState
        if !evidence.isEmpty {
            state = .active
        } else if axHierarchyAvailable {
            // Zoom answered with its windows and none of them is a meeting.
            state = .notActive
        } else {
            state = .unknown
        }

        return MeetingPresence(
            state: state,
            evidence: evidence,
            axWindowTitles: axWindowTitles,
            location: location
        )
    }

    static func meetingPresence(pid: pid_t, bundleIdentifier: String) -> MeetingPresence {
        let scan = scanZoom(pid: pid)
        let located = locateMeeting(pid: pid, bundleIdentifier: bundleIdentifier, scan: scan)
        return classifyMeetingPresence(
            axWindowTitles: scan.axEvidence.map(\.title),
            hasMeetingStructure: scan.meetingHierarchyAvailable,
            axHierarchyAvailable: scan.failure == nil && scan.windowCount > 0,
            location: located.location
        )
    }
}
