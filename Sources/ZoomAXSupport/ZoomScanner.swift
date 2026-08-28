import AppKit
import ApplicationServices
import Foundation

public extension ZoomAXSupport {
    /// Whether Zoom happens to be the active application. Cosmetic only: it never
    /// decides whether a scan is attempted. A background, fully covered Zoom is
    /// scanned exactly like a frontmost one.
    enum ZoomPresentation: String, Equatable {
        case foreground
        case background
    }

    /// The result of one complete, freshly acquired scan of the Zoom
    /// Accessibility hierarchy.
    struct ZoomScanResult {
        public let candidate: AdmitCandidate?
        public let meetingHierarchyAvailable: Bool
        public let windowCount: Int
        public let axEvidence: [AXMeetingWindowEvidence]
        public let meetingIsMinimized: Bool
        public let failure: ScanFailure?

        public init(
            candidate: AdmitCandidate?,
            meetingHierarchyAvailable: Bool,
            windowCount: Int,
            axEvidence: [AXMeetingWindowEvidence],
            meetingIsMinimized: Bool,
            failure: ScanFailure?
        ) {
            self.candidate = candidate
            self.meetingHierarchyAvailable = meetingHierarchyAvailable
            self.windowCount = windowCount
            self.axEvidence = axEvidence
            self.meetingIsMinimized = meetingIsMinimized
            self.failure = failure
        }
    }

    static func presentation(pid: pid_t) -> ZoomPresentation {
        (NSRunningApplication(processIdentifier: pid)?.isActive ?? false) ? .foreground : .background
    }

    /// One scan, entirely from fresh references.
    ///
    /// The application element, its `AXWindows`, every window subtree and every
    /// Admit button are acquired inside this call and are never retained past it,
    /// so a redrawn Zoom UI can only ever cost one scan, not a stuck monitor.
    ///
    /// Nothing here consults `frontmostApplication`, `isActive`, `AXFocusedWindow`,
    /// `AXMainWindow` or `kCGWindowIsOnscreen`: Accessibility is addressed purely
    /// by PID, which works for a background application on the current Space
    /// regardless of what is drawn over it.
    static func scanZoom(pid: pid_t) -> ZoomScanResult {
        let application = freshZoomApplicationElement(pid: pid)
        let windowsRead = windowsResult(of: application)

        guard windowsRead.error == .success else {
            return ZoomScanResult(
                candidate: nil,
                meetingHierarchyAvailable: false,
                windowCount: 0,
                axEvidence: [],
                meetingIsMinimized: false,
                failure: ScanFailure.classify(windowsRead.error) ?? .transient(windowsRead.error)
            )
        }

        var axEvidence: [AXMeetingWindowEvidence] = []
        var meetingHierarchyAvailable = false
        var meetingIsMinimized = false
        var candidate: AdmitCandidate?

        for window in windowsRead.windows {
            let roleRead = attributeValue(window, kAXRoleAttribute)
            if roleRead.error.indicatesStaleElement {
                // The window list went stale mid-walk. Report it so the caller
                // re-acquires instead of reporting a missing meeting.
                return ZoomScanResult(
                    candidate: nil,
                    meetingHierarchyAvailable: false,
                    windowCount: windowsRead.windows.count,
                    axEvidence: axEvidence,
                    meetingIsMinimized: meetingIsMinimized,
                    failure: .staleElement(roleRead.error)
                )
            }
            guard (roleRead.value as? String) == "AXWindow" else { continue }

            let tree = buildTree(from: window, maxDepth: 14)
            let hasMeetingStructure = hasMeetingStructure(in: tree)
            meetingHierarchyAvailable = meetingHierarchyAvailable || hasMeetingStructure
            axEvidence.append(AXMeetingWindowEvidence(
                title: windowTitle(window),
                bounds: frame(of: window),
                hasMeetingStructure: hasMeetingStructure
            ))
            if hasMeetingStructure || isLikelyMeetingWindowTitle(windowTitle(window)),
               copyBoolAttribute(window, kAXMinimizedAttribute) == true {
                meetingIsMinimized = true
            }

            if candidate == nil {
                candidate = admitCandidates(in: tree).first
            }
        }

        return ZoomScanResult(
            candidate: candidate,
            meetingHierarchyAvailable: meetingHierarchyAvailable,
            windowCount: windowsRead.windows.count,
            axEvidence: axEvidence,
            meetingIsMinimized: meetingIsMinimized,
            failure: nil
        )
    }

    /// Where the meeting is, given a scan that found no meeting hierarchy.
    ///
    /// Only reached after the Accessibility hierarchy was genuinely absent across
    /// retries, which is the sole condition under which `otherSpaceOrFullscreen`
    /// may be reported.
    static func locateMeeting(
        pid: pid_t,
        bundleIdentifier: String,
        scan: ZoomScanResult,
        learnedWindowID: CGWindowID? = nil
    ) -> (location: MeetingWindowLocation, windowID: CGWindowID?, evidence: String?) {
        guard let runningApplication = NSRunningApplication(processIdentifier: pid),
              runningApplication.bundleIdentifier == bundleIdentifier,
              supportedBundleIdentifiers.contains(bundleIdentifier),
              !runningApplication.isTerminated else {
            return (.notFound, nil, nil)
        }

        let windows = cgWindows(ownerPID: pid)
        let discovery = discoverMeetingWindow(
            cgWindows: windows,
            learnedWindowID: learnedWindowID,
            axEvidence: scan.axEvidence
        )
        let location = classifyMeetingWindow(
            zoomHidden: runningApplication.isHidden,
            meetingIsMinimized: scan.meetingIsMinimized,
            axMeetingWindowFound: scan.meetingHierarchyAvailable,
            zoomIsActive: runningApplication.isActive,
            cgMeetingWindows: discovery.map { [$0.window] } ?? []
        )
        return (location, discovery?.window.windowID, discovery?.evidence)
    }
}
