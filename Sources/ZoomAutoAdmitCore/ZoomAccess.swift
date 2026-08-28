import ApplicationServices
import Foundation
import ZoomAXSupport

/// Every Zoom-facing Accessibility operation the probe performs, behind one
/// seam so the state machine can be tested against real failure modes
/// (transient `cannotComplete`, stale `invalidUIElement`, off-Space, trust
/// changes) without a live Zoom meeting.
public protocol ZoomAccessProviding {
    func trustSnapshot() -> ZoomAXSupport.AccessibilityTrustSnapshot
    func zoomApplication() -> (pid: pid_t, bundleIdentifier: String)?
    /// Must acquire fresh Accessibility references on every call.
    func scan(pid: pid_t) -> ZoomAXSupport.ZoomScanResult
    /// Re-verifies the button and presses it. Returns `invalidUIElement` when the
    /// button no longer verifies as an enabled, pressable Admit button.
    func pressAdmit(_ candidate: ZoomAXSupport.AdmitCandidate) -> AXError
    func presentation(pid: pid_t) -> ZoomPresentation
    func locateMeeting(
        pid: pid_t,
        bundleIdentifier: String,
        scan: ZoomAXSupport.ZoomScanResult,
        learnedWindowID: CGWindowID?
    ) -> (location: ZoomAXSupport.MeetingWindowLocation, windowID: CGWindowID?, evidence: String?)
}

/// The production implementation. Addresses Zoom purely by PID and never
/// activates, raises, unhides or focuses it.
public struct LiveZoomAccess: ZoomAccessProviding {
    public init() {}

    public func trustSnapshot() -> ZoomAXSupport.AccessibilityTrustSnapshot {
        ZoomAXSupport.accessibilityTrustSnapshot(prompt: false)
    }

    public func zoomApplication() -> (pid: pid_t, bundleIdentifier: String)? {
        ZoomAXSupport.zoomApplication()
    }

    public func scan(pid: pid_t) -> ZoomAXSupport.ZoomScanResult {
        ZoomAXSupport.scanZoom(pid: pid)
    }

    public func pressAdmit(_ candidate: ZoomAXSupport.AdmitCandidate) -> AXError {
        // The element is at most one scan old, but Zoom redraws its participant
        // list freely, so the safety properties are re-checked against the live
        // element immediately before the press.
        let element = candidate.node.element
        guard ZoomAXSupport.copyStringAttribute(element, kAXRoleAttribute) == "AXButton",
              ZoomAXSupport.isEnabled(element),
              ZoomAXSupport.actionNames(of: element).contains(ZoomAXSupport.pressAction) else {
            return .invalidUIElement
        }
        return ZoomAXSupport.press(element)
    }

    public func presentation(pid: pid_t) -> ZoomPresentation {
        ZoomAXSupport.presentation(pid: pid)
    }

    public func locateMeeting(
        pid: pid_t,
        bundleIdentifier: String,
        scan: ZoomAXSupport.ZoomScanResult,
        learnedWindowID: CGWindowID?
    ) -> (location: ZoomAXSupport.MeetingWindowLocation, windowID: CGWindowID?, evidence: String?) {
        ZoomAXSupport.locateMeeting(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            scan: scan,
            learnedWindowID: learnedWindowID
        )
    }
}
