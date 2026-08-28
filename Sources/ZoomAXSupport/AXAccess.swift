import ApplicationServices
import Foundation

/// Typed Accessibility error handling.
///
/// The monitor must be able to tell three very different situations apart:
///
/// * Accessibility is genuinely switched off for this process (`apiDisabled`).
/// * A specific element reference went stale (`invalidUIElement`).
/// * The target application was momentarily too busy to answer (`cannotComplete`).
///
/// Only the first is a permission problem. Collapsing the other two into a
/// permission failure is what previously produced a false
/// "Permission granted — relaunch app" state.
public extension AXError {
    var isSuccess: Bool { self == .success }

    /// The only AXError that means Accessibility is not available to this process.
    var indicatesAccessibilityDisabled: Bool { self == .apiDisabled }

    /// The reference is dead. The caller must discard it and re-acquire.
    var indicatesStaleElement: Bool { self == .invalidUIElement }

    /// The target was busy, unresponsive, or the attribute momentarily absent.
    /// Retrying with fresh references is the correct response.
    var indicatesTransientFailure: Bool {
        switch self {
        case .cannotComplete, .noValue, .notImplemented, .attributeUnsupported,
             .actionUnsupported, .notificationUnsupported, .failure:
            return true
        default:
            return false
        }
    }

    var diagnosticName: String {
        switch self {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown"
        }
    }

    var diagnosticDescription: String {
        "\(diagnosticName)(\(rawValue))"
    }
}

public extension ZoomAXSupport {
    /// How a scan of the Zoom Accessibility tree ended.
    enum ScanFailure: Equatable {
        /// Accessibility itself is unavailable to this process.
        case accessibilityDisabled(AXError)
        /// Zoom answered, but a reference died mid-scan.
        case staleElement(AXError)
        /// Zoom was momentarily unable to answer.
        case transient(AXError)

        public var axError: AXError {
            switch self {
            case .accessibilityDisabled(let error),
                 .staleElement(let error),
                 .transient(let error):
                return error
            }
        }

        public var diagnosticDescription: String {
            switch self {
            case .accessibilityDisabled: return "accessibility-disabled \(axError.diagnosticDescription)"
            case .staleElement: return "stale-element \(axError.diagnosticDescription)"
            case .transient: return "transient \(axError.diagnosticDescription)"
            }
        }

        public static func classify(_ error: AXError) -> ScanFailure? {
            if error == .success { return nil }
            if error.indicatesAccessibilityDisabled { return .accessibilityDisabled(error) }
            if error.indicatesStaleElement { return .staleElement(error) }
            return .transient(error)
        }
    }

    /// Attribute read that preserves the AXError instead of collapsing it to nil.
    static func attributeValue(
        _ element: AXUIElement,
        _ attribute: String
    ) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (value, error)
    }

    /// AXWindows read that reports why it came back empty.
    static func windowsResult(of application: AXUIElement) -> (windows: [AXUIElement], error: AXError) {
        let result = attributeValue(application, kAXWindowsAttribute)
        guard result.error == .success else { return ([], result.error) }
        return ((result.value as? [AXUIElement]) ?? [], .success)
    }

    /// Bounds every synchronous AX message sent to Zoom. Without this an
    /// unresponsive Zoom can stall the monitor queue for the system default.
    @discardableResult
    static func setMessagingTimeout(_ element: AXUIElement, seconds: Float) -> AXError {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    /// Fresh, PID-addressed Zoom application element with a bounded message
    /// timeout. Deliberately never consults frontmost/active/visible state:
    /// a covered background application on the current Space answers AX
    /// exactly like a foreground one.
    static func freshZoomApplicationElement(pid: pid_t, messagingTimeout: Float = 2.0) -> AXUIElement {
        let application = AXUIElementCreateApplication(pid)
        setMessagingTimeout(application, seconds: messagingTimeout)
        return application
    }
}
