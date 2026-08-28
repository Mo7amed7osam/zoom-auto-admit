import ApplicationServices
import AppKit
import Foundation

public enum ZoomAXSupport {
    public static let waitingListIdentifier = "ZMHCTableItemType_WAITINGLIST"
    public static let waitingListGroupIdentifier = "ZMHCTableItemType_WAITINGLIST_Group"

    public static let supportedBundleIdentifiers = [
        "us.zoom.xos",              // Zoom Workplace on current macOS releases
        "us.zoom.videomeetings"    // Older Zoom client identifier
    ]

    public static let pressAction = kAXPressAction as String

    public struct AccessibilityTrustSnapshot: Equatable {
        public let isProcessTrusted: Bool
        public let isProcessTrustedWithOptions: Bool
        public let systemWideProbeResult: AXError

        public init(
            isProcessTrusted: Bool,
            isProcessTrustedWithOptions: Bool,
            systemWideProbeResult: AXError
        ) {
            self.isProcessTrusted = isProcessTrusted
            self.isProcessTrustedWithOptions = isProcessTrustedWithOptions
            self.systemWideProbeResult = systemWideProbeResult
        }

        public var APIsAgree: Bool {
            isProcessTrusted == isProcessTrustedWithOptions
        }

        public var isTrusted: Bool {
            isProcessTrusted && isProcessTrustedWithOptions
        }

        /// `kAXErrorAPIDisabled` is the only AXError that means Accessibility is
        /// unavailable to this process. The system-wide probe reads the *frontmost*
        /// application, so it also returns `cannotComplete` when that unrelated app
        /// is slow to build its Accessibility tree (Chrome and other Electron-style
        /// apps do this routinely) and `noValue` when nothing has AX focus. Those
        /// results say nothing about this app's permission and must never downgrade
        /// the trust state.
        public var accessibilityAPIDisabled: Bool {
            systemWideProbeResult == .apiDisabled
        }

        /// True when a foreign-application AX probe failed for a benign reason.
        /// Recorded for diagnostics only; never gates monitoring.
        public var systemWideProbeFailedBenignly: Bool {
            systemWideProbeResult != .success && !accessibilityAPIDisabled
        }

        public var isUsableWithoutRelaunch: Bool {
            isTrusted && !accessibilityAPIDisabled
        }

        public var relaunchAppearsRequired: Bool {
            (isProcessTrusted || isProcessTrustedWithOptions) && !isUsableWithoutRelaunch
        }
    }

    public static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    public static func hasWaitingRoomText(_ value: String?) -> Bool {
        guard let value else { return false }
        let text = normalized(value)
        return text == "waiting room" || text.hasPrefix("waiting room ") || text.contains("waiting room (")
    }

    public static func hasBreakoutText(_ value: String?) -> Bool {
        guard let value else { return false }
        let text = normalized(value)
        return text.contains("breakout") || text.contains("break out")
    }

    public static func isAdmitAllTitle(_ value: String?) -> Bool {
        guard let value else { return false }
        switch normalized(value) {
        case "admit all", "admit all participants", "admit all participants in waiting room":
            return true
        default:
            return false
        }
    }

    public static func isAdmitTitle(_ value: String?) -> Bool {
        normalized(value ?? "") == "admit"
    }

    public static func isAdmitAllDescription(_ value: String?) -> Bool {
        normalized(value ?? "") == "admit all"
    }

    public static func isAdmitDescription(_ value: String?) -> Bool {
        normalized(value ?? "") == "admit"
    }

    public static func zoomApplication() -> (pid: pid_t, bundleIdentifier: String)? {
        let workspace = NSWorkspace.shared
        for bundleIdentifier in supportedBundleIdentifiers {
            if let app = workspace.runningApplications.first(where: {
                $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
            }) {
                return (app.processIdentifier, bundleIdentifier)
            }
        }
        return nil
    }

    public struct CGWindowRecord: Equatable {
        public let windowID: CGWindowID
        public let ownerPID: pid_t
        public let ownerName: String?
        public let name: String?
        public let layer: Int
        public let isOnscreen: Bool
        public let bounds: CGRect
        public let alpha: Double
        public let sharingState: Int?

        public init(
            windowID: CGWindowID,
            ownerPID: pid_t,
            ownerName: String? = nil,
            name: String?,
            layer: Int,
            isOnscreen: Bool,
            bounds: CGRect = .zero,
            alpha: Double = 1,
            sharingState: Int? = nil
        ) {
            self.windowID = windowID
            self.ownerPID = ownerPID
            self.ownerName = ownerName
            self.name = name
            self.layer = layer
            self.isOnscreen = isOnscreen
            self.bounds = bounds
            self.alpha = alpha
            self.sharingState = sharingState
        }

        public var hasSensibleDimensions: Bool {
            bounds.width >= 320 && bounds.height >= 200 && bounds.width.isFinite && bounds.height.isFinite
        }

        public var isLikelyMeetingWindow: Bool {
            guard let name else { return false }
            let normalizedName = ZoomAXSupport.normalized(name)
            return normalizedName == "zoom meeting" || normalizedName.hasPrefix("zoom meeting ")
        }
    }

    public enum MeetingWindowLocation: String, Equatable {
        /// Meeting hierarchy is reachable and Zoom is the active application.
        case currentSpace
        /// Meeting hierarchy is reachable while another application is frontmost,
        /// possibly completely covering Zoom. Fully monitorable.
        case currentSpaceBackground
        case otherSpaceOrFullscreen
        case minimized
        case hidden
        case notFound

        /// The Accessibility hierarchy can be scanned in this state.
        public var isAccessible: Bool {
            self == .currentSpace || self == .currentSpaceBackground
        }
    }

    public struct ZoomWindowDiagnostics: Equatable {
        public let zoomRunning: Bool
        public let zoomHidden: Bool
        public let zoomActive: Bool
        public let meetingWindowFound: Bool
        public let meetingWindowLocation: MeetingWindowLocation
        public let meetingWindowID: CGWindowID?
        public let meetingWindowEvidence: String?
        public let axWindowTitles: [String]
        public let cgWindows: [CGWindowRecord]
    }

    public struct AXMeetingWindowEvidence: Equatable {
        public let title: String
        public let bounds: CGRect?
        public let hasMeetingStructure: Bool

        public init(title: String, bounds: CGRect?, hasMeetingStructure: Bool) {
            self.title = title
            self.bounds = bounds
            self.hasMeetingStructure = hasMeetingStructure
        }
    }

    public struct MeetingWindowCandidate: Equatable {
        public let window: CGWindowRecord
        public let evidence: String
        public let score: Int
    }

    public static let cgWindowListOptionsDescription = "kCGWindowListOptionAll (rawValue=0); kCGWindowListOptionOnScreenOnly is NOT set"

    public static func cgWindows(ownerPID: pid_t) -> [CGWindowRecord] {
        // optionAll is raw value 0. Do not combine optionOnScreenOnly: the
        // diagnostic and discovery paths intentionally include off-screen and
        // off-Space WindowServer records.
        let options: CGWindowListOption = .optionAll
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return rawWindows.compactMap { dictionary in
            guard let pidNumber = dictionary[kCGWindowOwnerPID as String] as? NSNumber,
                  pidNumber.int32Value == ownerPID,
                  let idNumber = dictionary[kCGWindowNumber as String] as? NSNumber else {
                return nil
            }
            let layer = (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let onscreen = (dictionary[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let bounds: CGRect
            if let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
               let parsed = CGRect(dictionaryRepresentation: boundsDictionary) {
                bounds = parsed
            } else {
                bounds = .zero
            }
            return CGWindowRecord(
                windowID: CGWindowID(idNumber.uint32Value),
                ownerPID: pidNumber.int32Value,
                ownerName: dictionary[kCGWindowOwnerName as String] as? String,
                name: dictionary[kCGWindowName as String] as? String,
                layer: layer,
                isOnscreen: onscreen,
                bounds: bounds,
                alpha: (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                sharingState: (dictionary[kCGWindowSharingState as String] as? NSNumber)?.intValue
            )
        }
    }

    public static func windowDiagnostics(
        pid: pid_t,
        bundleIdentifier: String,
        learnedWindowID: CGWindowID? = nil
    ) -> ZoomWindowDiagnostics {
        let runningApplication = NSRunningApplication(processIdentifier: pid)
        let isZoom = runningApplication?.bundleIdentifier == bundleIdentifier
            && supportedBundleIdentifiers.contains(bundleIdentifier)
            && runningApplication?.isTerminated == false

        guard isZoom, let runningApplication else {
            return ZoomWindowDiagnostics(
                zoomRunning: false,
                zoomHidden: false,
                zoomActive: false,
                meetingWindowFound: false,
                meetingWindowLocation: .notFound,
                meetingWindowID: nil,
                meetingWindowEvidence: nil,
                axWindowTitles: [],
                cgWindows: []
            )
        }

        let application = applicationElement(pid: pid)
        let axWindows = windows(of: application)
        let axTitles = axWindows.map(windowTitle)
        let axEvidence = axWindows.map { window -> AXMeetingWindowEvidence in
            let tree = buildTree(from: window, maxDepth: 14)
            return AXMeetingWindowEvidence(
                title: windowTitle(window),
                bounds: frame(of: window),
                hasMeetingStructure: hasMeetingStructure(in: tree)
            )
        }
        let meetingAXWindows = zip(axWindows, axEvidence).filter {
            $0.1.hasMeetingStructure || isLikelyMeetingWindowTitle($0.1.title)
        }.map(\.0)
        let meetingIsMinimized = meetingAXWindows.contains { copyBoolAttribute($0, kAXMinimizedAttribute) == true }
        let windows = cgWindows(ownerPID: pid)
        let discovery = discoverMeetingWindow(cgWindows: windows, learnedWindowID: learnedWindowID, axEvidence: axEvidence)
        let meetingWindows = discovery.map { [$0.window] } ?? []

        let location = classifyMeetingWindow(
            zoomHidden: runningApplication.isHidden,
            meetingIsMinimized: meetingIsMinimized,
            axMeetingWindowFound: !meetingAXWindows.isEmpty,
            zoomIsActive: runningApplication.isActive,
            cgMeetingWindows: meetingWindows
        )

        return ZoomWindowDiagnostics(
            zoomRunning: true,
            zoomHidden: runningApplication.isHidden,
            zoomActive: runningApplication.isActive,
            meetingWindowFound: discovery != nil || !meetingAXWindows.isEmpty,
            meetingWindowLocation: location,
            meetingWindowID: discovery?.window.windowID,
            meetingWindowEvidence: discovery?.evidence,
            axWindowTitles: axTitles,
            cgWindows: windows
        )
    }

    public static func discoverMeetingWindow(
        cgWindows: [CGWindowRecord],
        learnedWindowID: CGWindowID?,
        axEvidence: [AXMeetingWindowEvidence]
    ) -> MeetingWindowCandidate? {
        let candidates = cgWindows.filter {
            $0.layer == 0 && $0.hasSensibleDimensions && $0.alpha > 0.01
        }

        if let learnedWindowID,
           let learned = candidates.first(where: { $0.windowID == learnedWindowID }) {
            return MeetingWindowCandidate(window: learned, evidence: "learned-window-id", score: 10_000)
        }

        let scored: [MeetingWindowCandidate] = candidates.compactMap { window in
            var score = 0
            var evidence: [String] = []
            let normalizedName = normalized(window.name ?? "")

            if window.isLikelyMeetingWindow {
                score += 500
                evidence.append("known-meeting-title")
            } else if normalizedName.contains("meeting") && !isKnownNonMeetingWindowName(normalizedName) {
                score += 240
                evidence.append("meeting-related-title")
            }

            for axWindow in axEvidence where axWindow.hasMeetingStructure || isLikelyMeetingWindowTitle(axWindow.title) {
                if let axBounds = axWindow.bounds, boundsApproximatelyEqual(window.bounds, axBounds) {
                    score += axWindow.hasMeetingStructure ? 800 : 400
                    evidence.append(axWindow.hasMeetingStructure ? "ax-structure+bounds" : "ax-title+bounds")
                }
                if let name = window.name,
                   !name.isEmpty,
                   normalized(name) == normalized(axWindow.title) {
                    score += axWindow.hasMeetingStructure ? 300 : 180
                    evidence.append("ax-title-match")
                }
            }

            // Off-Space Zoom windows may have a blank or changed title. A large,
            // normal-layer, nontransparent, off-screen window is retained as a
            // lower-confidence discovery candidate. It never authorizes a click;
            // the strict AX Waiting Room matcher still does that after exposure.
            if score == 0,
               !window.isOnscreen,
               !isKnownNonMeetingWindowName(normalizedName) {
                let area = window.bounds.width * window.bounds.height
                if area >= 640 * 360 {
                    score = 100 + min(Int(area / 100_000), 50)
                    evidence.append(normalizedName.isEmpty ? "offscreen-normal-window+blank-title" : "offscreen-normal-window+dimensions")
                }
            }

            guard score > 0 else { return nil }
            return MeetingWindowCandidate(window: window, evidence: evidence.joined(separator: "+"), score: score)
        }

        return scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let leftArea = $0.window.bounds.width * $0.window.bounds.height
            let rightArea = $1.window.bounds.width * $1.window.bounds.height
            return leftArea > rightArea
        }.first
    }

    private static func isKnownNonMeetingWindowName(_ normalizedName: String) -> Bool {
        if normalizedName == "zoom workplace" || normalizedName == "zoom client healthcheck" { return true }
        return normalizedName.contains("breakout")
            || normalizedName.contains("advanced sharing")
            || normalizedName.contains("select a window")
            || normalizedName.contains("invite people")
            || normalizedName == "menu window"
    }

    private static func boundsApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 8) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    public static func isLikelyMeetingWindowTitle(_ title: String) -> Bool {
        let normalizedTitle = normalized(title)
        return normalizedTitle == "zoom meeting" || normalizedTitle.hasPrefix("zoom meeting ")
    }

    /// Accessibility reachability is the authoritative signal, not occlusion.
    ///
    /// `kCGWindowIsOnscreen` is false for an off-Space window but stays true for a
    /// window that is merely covered by another application, so it can never be
    /// used on its own to decide which Space a window is on. A window on the
    /// current Space keeps answering Accessibility no matter what is drawn on top
    /// of it; only a window the WindowServer has moved to another Space or into a
    /// full-screen tile drops out of `AXWindows`.
    public static func classifyMeetingWindow(
        zoomHidden: Bool,
        meetingIsMinimized: Bool,
        axMeetingWindowFound: Bool,
        zoomIsActive: Bool = false,
        cgMeetingWindows: [CGWindowRecord]
    ) -> MeetingWindowLocation {
        if zoomHidden { return .hidden }
        if meetingIsMinimized { return .minimized }
        if axMeetingWindowFound {
            return zoomIsActive ? .currentSpace : .currentSpaceBackground
        }
        // No AX hierarchy. Only now does the CoreGraphics window list get a vote.
        if cgMeetingWindows.contains(where: \.isOnscreen) { return .currentSpaceBackground }
        if !cgMeetingWindows.isEmpty { return .otherSpaceOrFullscreen }
        return .notFound
    }

    public static func accessibilityTrustSnapshot(prompt: Bool = false) -> AccessibilityTrustSnapshot {
        // These calls intentionally run every time. TCC state is never cached by
        // Zoom Auto Admit, so Check Again and every monitor scan see fresh state.
        let direct = AXIsProcessTrusted()
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        let withOptions = AXIsProcessTrustedWithOptions(options)

        let systemWide = AXUIElementCreateSystemWide()
        var focusedApplication: CFTypeRef?
        let probeResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApplication
        )

        return AccessibilityTrustSnapshot(
            isProcessTrusted: direct,
            isProcessTrustedWithOptions: withOptions,
            systemWideProbeResult: probeResult
        )
    }

    public static func isTrusted(prompt: Bool) -> Bool {
        accessibilityTrustSnapshot(prompt: prompt).isUsableWithoutRelaunch
    }

    public static func applicationElement(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    public static func windows(of application: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttribute(application, kAXWindowsAttribute) else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    public static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    public static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    public static func isEnabled(_ element: AXUIElement) -> Bool {
        guard let value = copyAttribute(element, kAXEnabledAttribute) else { return true }
        return (value as? Bool) ?? true
    }

    public static func copyBoolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        if let bool = value as? Bool { return bool }
        return (value as? NSNumber)?.boolValue
    }

    public static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copyAttribute(element, kAXPositionAttribute),
              let sizeValue = copyAttribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let axPosition = unsafeBitCast(positionValue, to: AXValue.self)
        let axSize = unsafeBitCast(sizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(axPosition, .cgPoint, &position),
              AXValueGetValue(axSize, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    @discardableResult
    public static func setBoolAttribute(_ element: AXUIElement, _ attribute: String, value: Bool) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    public static func focusedWindow(of application: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(application, kAXFocusedWindowAttribute) else { return nil }
        return (value as! AXUIElement)
    }

    @discardableResult
    public static func setFrontmost(_ application: AXUIElement, value: Bool) -> AXError {
        setBoolAttribute(application, kAXFrontmostAttribute, value: value)
    }

    @discardableResult
    public static func raise(_ window: AXUIElement) -> AXError {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    public static func actionNames(of element: AXUIElement) -> [String] {
        var actions: CFArray?
        let result = AXUIElementCopyActionNames(element, &actions)
        guard result == .success, let actions else { return [] }
        return (actions as? [String]) ?? []
    }

    public static func press(_ element: AXUIElement) -> AXError {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    public static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttribute(element, kAXChildrenAttribute) else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    public final class Node {
        public let element: AXUIElement
        public let role: String
        public let subrole: String?
        public let title: String?
        public let description: String?
        public let value: String?
        public let identifier: String?
        public let enabled: Bool
        public let actions: [String]
        /// AXHelp. Zoom puts real state text here on its pressable controls.
        public let help: String?
        /// AXMenuItemMarkChar. Read only for AXMenuItem, where Zoom uses the
        /// checkmark to mark the signed-in account.
        public let markCharacter: String?
        public weak var parent: Node?
        public var children: [Node] = []
        public let index: Int

        public init(element: AXUIElement, index: Int = 0, parent: Node? = nil) {
            self.element = element
            self.index = index
            self.parent = parent
            let role = ZoomAXSupport.copyStringAttribute(element, kAXRoleAttribute) ?? "?"
            self.role = role
            self.title = ZoomAXSupport.copyStringAttribute(element, kAXTitleAttribute)
            self.description = ZoomAXSupport.copyStringAttribute(element, kAXDescriptionAttribute)
            self.value = ZoomAXSupport.copyStringAttribute(element, kAXValueAttribute)
            self.identifier = ZoomAXSupport.copyStringAttribute(element, kAXIdentifierAttribute)
            // Every attribute read is a synchronous IPC round trip to Zoom, so
            // AXEnabled/AXActions/AXHelp are only read for roles that can
            // actually be pressed. Menu items belong in this set: the
            // participants command lives in Zoom's View menu, and omitting them
            // left every menu item looking like it had no AXPress at all.
            let interactiveRoles: Set<String> = [
                "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton"
            ]
            let wantsInteractiveAttributes = interactiveRoles.contains(role)
                || ZoomAXSupport.collectDiagnosticAttributes
            self.subrole = ZoomAXSupport.collectDiagnosticAttributes
                ? ZoomAXSupport.copyStringAttribute(element, kAXSubroleAttribute)
                : nil
            self.enabled = wantsInteractiveAttributes ? ZoomAXSupport.isEnabled(element) : true
            self.actions = wantsInteractiveAttributes ? ZoomAXSupport.actionNames(of: element) : []
            self.help = wantsInteractiveAttributes
                ? ZoomAXSupport.copyStringAttribute(element, kAXHelpAttribute)
                : nil
            self.markCharacter = role == "AXMenuItem"
                ? ZoomAXSupport.copyStringAttribute(element, kAXMenuItemMarkCharAttribute)
                : nil
        }

        public var ownText: String {
            [title, description, value, identifier].compactMap { $0 }.joined(separator: " | ")
        }

        public var isWaitingRoomMarker: Bool {
            identifier == ZoomAXSupport.waitingListIdentifier
                || identifier == ZoomAXSupport.waitingListGroupIdentifier
                || ZoomAXSupport.hasWaitingRoomText(title)
                || ZoomAXSupport.hasWaitingRoomText(description)
                || ZoomAXSupport.hasWaitingRoomText(value)
        }

        public var hasBreakoutMarker: Bool {
            ZoomAXSupport.hasBreakoutText(title)
                || ZoomAXSupport.hasBreakoutText(description)
                || ZoomAXSupport.hasBreakoutText(value)
                || ZoomAXSupport.hasBreakoutText(identifier)
        }

        public var path: String {
            var components: [String] = []
            var current: Node? = self
            while let node = current {
                components.append("\(node.role.lowercased())[\(node.index)]")
                current = node.parent
            }
            return components.reversed().joined(separator: "/")
        }

        public func containsWaitingRoomMarker() -> Bool {
            if isWaitingRoomMarker { return true }
            return children.contains { $0.containsWaitingRoomMarker() }
        }

        public func containsBreakoutMarker() -> Bool {
            if hasBreakoutMarker { return true }
            return children.contains { $0.containsBreakoutMarker() }
        }

        public func nearestWaitingContext() -> Node? {
            var current = parent
            while let node = current {
                // A window-wide match is intentionally rejected. It is too broad to
                // establish that an Admit button belongs to Waiting Room.
                if node.role != "AXWindow", node.containsWaitingRoomMarker(), !node.containsBreakoutMarker() {
                    return node
                }
                current = node.parent
            }
            return nil
        }
    }

    /// Set by diagnostic tools that want every attribute of every node.
    /// The monitor leaves this false to keep each scan cheap.
    public nonisolated(unsafe) static var collectDiagnosticAttributes = false

    /// Builds the tree breadth-first.
    ///
    /// Order matters because of the node budget. Zoom's in-meeting toolbar
    /// republishes each button as its own descendant, over and over, so a
    /// depth-first walk spends the entire budget inside the first button's
    /// self-nested chain and never reaches its siblings — which is where the
    /// real controls live. Breadth-first guarantees every shallow control is
    /// visited before any deep duplicate.
    public static func buildTree(
        from element: AXUIElement,
        maxDepth: Int = 14,
        maxChildren: Int = 250,
        maxNodes: Int = 6_000
    ) -> Node {
        let root = Node(element: element, index: 0, parent: nil)
        var visited = 1
        var queue: [(node: Node, depth: Int)] = [(root, 0)]
        var head = 0

        while head < queue.count, visited < maxNodes {
            let (node, depth) = queue[head]
            head += 1
            guard depth < maxDepth else { continue }

            for (childIndex, child) in children(of: node.element).prefix(maxChildren).enumerated() {
                if visited >= maxNodes { break }
                let childNode = Node(element: child, index: childIndex, parent: node)
                visited += 1
                node.children.append(childNode)
                queue.append((childNode, depth + 1))
            }
        }
        return root
    }

    public static func windowTitle(_ window: AXUIElement) -> String {
        copyStringAttribute(window, kAXTitleAttribute) ?? "(untitled window)"
    }

    public static func allNodes(in root: Node) -> [Node] {
        [root] + root.children.flatMap { allNodes(in: $0) }
    }

    public static func hasMeetingStructure(in root: Node) -> Bool {
        allNodes(in: root).contains { node in
            node.identifier == waitingListIdentifier
                || node.identifier == waitingListGroupIdentifier
                || node.identifier == "ZMHCTableItemType_PANELIST"
                || (node.role == "AXOutline" && normalized(node.description ?? "") == "participants list")
        }
    }

    public struct AdmitCandidate {
        public let node: Node
        public let type: AdmitType
        public let waitingRoomEvidence: WaitingRoomEvidence
        public let participantName: String?
        public let contextPath: String

        public init(
            node: Node,
            type: AdmitType,
            waitingRoomEvidence: WaitingRoomEvidence,
            participantName: String?,
            contextPath: String
        ) {
            self.node = node
            self.type = type
            self.waitingRoomEvidence = waitingRoomEvidence
            self.participantName = participantName
            self.contextPath = contextPath
        }

        public var isAdmitAll: Bool { type == .admitAll }
    }

    public static func admitCandidates(in root: Node) -> [AdmitCandidate] {
        let matches = matchAdmitCandidates(in: snapshot(from: root))
        return matches.compactMap { match -> AdmitCandidate? in
            guard let buttonNode = node(at: match.buttonIndexPath, in: root) else { return nil }
            let context = node(at: match.contextIndexPath, in: root)
            return AdmitCandidate(
                node: buttonNode,
                type: match.type,
                waitingRoomEvidence: match.waitingRoomEvidence,
                participantName: match.participantName,
                contextPath: context?.path ?? root.path
            )
        }
    }

    public enum AdmitType: String, Equatable {
        case individual = "individual-admit"
        case admitAll = "admit-all"
    }

    public enum WaitingRoomEvidenceKind: String, Equatable {
        case participantIdentifier
        case groupIdentifier
        case accessibleText
    }

    public struct WaitingRoomEvidence: Equatable {
        public let kind: WaitingRoomEvidenceKind
        public let value: String

        public init(kind: WaitingRoomEvidenceKind, value: String) {
            self.kind = kind
            self.value = value
        }
    }

    /// A platform-independent copy of the AX fields used by the safety matcher.
    /// Tests construct this type directly; production snapshots it from AXUIElement.
    public struct SnapshotNode: Equatable {
        public let role: String
        public let title: String?
        public let description: String?
        public let value: String?
        public let identifier: String?
        public let enabled: Bool
        public let actions: [String]
        public let help: String?
        public let markCharacter: String?
        public let children: [SnapshotNode]

        public init(
            role: String,
            title: String? = nil,
            description: String? = nil,
            value: String? = nil,
            identifier: String? = nil,
            enabled: Bool = true,
            actions: [String] = [],
            help: String? = nil,
            markCharacter: String? = nil,
            children: [SnapshotNode] = []
        ) {
            self.role = role
            self.title = title
            self.description = description
            self.value = value
            self.identifier = identifier
            self.enabled = enabled
            self.actions = actions
            self.help = help
            self.markCharacter = markCharacter
            self.children = children
        }

        fileprivate var isDirectWaitingRoomTextMarker: Bool {
            ZoomAXSupport.hasWaitingRoomText(title)
                || ZoomAXSupport.hasWaitingRoomText(description)
                || ZoomAXSupport.hasWaitingRoomText(value)
        }

        fileprivate var hasDirectBreakoutMarker: Bool {
            ZoomAXSupport.hasBreakoutText(title)
                || ZoomAXSupport.hasBreakoutText(description)
                || ZoomAXSupport.hasBreakoutText(value)
                || ZoomAXSupport.hasBreakoutText(identifier)
        }

        fileprivate func containsIdentifier(_ target: String) -> Bool {
            identifier == target || children.contains { $0.containsIdentifier(target) }
        }

        fileprivate func containsWaitingRoomTextMarker() -> Bool {
            isDirectWaitingRoomTextMarker || children.contains { $0.containsWaitingRoomTextMarker() }
        }

        fileprivate func containsBreakoutMarker() -> Bool {
            hasDirectBreakoutMarker || children.contains { $0.containsBreakoutMarker() }
        }
    }

    public struct CandidateMatch: Equatable {
        public let buttonIndexPath: [Int]
        public let contextIndexPath: [Int]
        public let type: AdmitType
        public let waitingRoomEvidence: WaitingRoomEvidence
        public let participantName: String?
        public let buttonTitle: String?
        public let buttonDescription: String?
    }

    private struct AncestorSnapshot {
        let node: SnapshotNode
        let indexPath: [Int]
    }

    public static func snapshot(from node: Node) -> SnapshotNode {
        SnapshotNode(
            role: node.role,
            title: node.title,
            description: node.description,
            value: node.value,
            identifier: node.identifier,
            enabled: node.enabled,
            actions: node.actions,
            help: node.help,
            markCharacter: node.markCharacter,
            children: node.children.map(snapshot(from:))
        )
    }

    /// Pure candidate selection. Structural Zoom identifiers take priority;
    /// accessible Waiting Room text is retained only as a compatibility fallback.
    public static func matchAdmitCandidates(in root: SnapshotNode) -> [CandidateMatch] {
        var matches: [CandidateMatch] = []

        func walk(_ node: SnapshotNode, indexPath: [Int], ancestors: [AncestorSnapshot]) {
            if node.role == "AXButton",
               node.enabled,
               node.actions.contains(pressAction),
               let type = admitType(title: node.title, description: node.description),
               !ancestors.contains(where: { $0.node.hasDirectBreakoutMarker }),
               let context = waitingRoomContext(ancestors: ancestors) {
                matches.append(CandidateMatch(
                    buttonIndexPath: indexPath,
                    contextIndexPath: context.ancestor.indexPath,
                    type: type,
                    waitingRoomEvidence: context.evidence,
                    participantName: type == .individual ? participantName(in: context.ancestor.node) : nil,
                    buttonTitle: node.title,
                    buttonDescription: node.description
                ))
            }

            let nextAncestors = ancestors + [AncestorSnapshot(node: node, indexPath: indexPath)]
            for (childIndex, child) in node.children.enumerated() {
                walk(child, indexPath: indexPath + [childIndex], ancestors: nextAncestors)
            }
        }

        walk(root, indexPath: [], ancestors: [])
        return matches.sorted {
            if $0.type != $1.type { return $0.type == .admitAll }
            return $0.buttonIndexPath.lexicographicallyPrecedes($1.buttonIndexPath)
        }
    }

    private static func admitType(title: String?, description: String?) -> AdmitType? {
        if isAdmitAllDescription(description) || isAdmitAllTitle(title) { return .admitAll }
        if isAdmitDescription(description) || isAdmitTitle(title) { return .individual }
        return nil
    }

    private static func waitingRoomContext(
        ancestors: [AncestorSnapshot]
    ) -> (ancestor: AncestorSnapshot, evidence: WaitingRoomEvidence)? {
        // An individual WAITINGLIST cell is the strongest evidence available.
        if let context = ancestors.reversed().first(where: {
            $0.node.identifier == waitingListIdentifier && !$0.node.containsBreakoutMarker()
        }) {
            return (context, WaitingRoomEvidence(kind: .participantIdentifier, value: waitingListIdentifier))
        }

        // Zoom may place Admit All directly in its WAITINGLIST_Group cell.
        if let context = ancestors.reversed().first(where: {
            $0.node.identifier == waitingListGroupIdentifier && !$0.node.containsBreakoutMarker()
        }) {
            return (context, WaitingRoomEvidence(kind: .groupIdentifier, value: waitingListGroupIdentifier))
        }

        // Some trees put the group marker and button in sibling descendants of a
        // tighter non-window container. Keep this structural signal above text.
        if let context = ancestors.reversed().first(where: {
            $0.node.role != "AXWindow"
                && $0.node.containsIdentifier(waitingListGroupIdentifier)
                && !$0.node.containsBreakoutMarker()
        }) {
            return (context, WaitingRoomEvidence(kind: .groupIdentifier, value: waitingListGroupIdentifier))
        }

        // Compatibility path for older Zoom trees without stable identifiers.
        if let context = ancestors.reversed().first(where: {
            $0.node.role != "AXWindow"
                && $0.node.containsWaitingRoomTextMarker()
                && !$0.node.containsBreakoutMarker()
        }) {
            let marker = firstWaitingRoomText(in: context.node) ?? "Waiting Room"
            return (context, WaitingRoomEvidence(kind: .accessibleText, value: marker))
        }

        return nil
    }

    private static func firstWaitingRoomText(in node: SnapshotNode) -> String? {
        for value in [node.title, node.description, node.value] {
            if hasWaitingRoomText(value) { return value }
        }
        for child in node.children {
            if let value = firstWaitingRoomText(in: child) { return value }
        }
        return nil
    }

    private static func participantName(in context: SnapshotNode) -> String? {
        if context.role == "AXStaticText" {
            for text in [context.value, context.title, context.description].compactMap({ $0 }) {
                if isParticipantNameText(text) { return text }
            }
        }
        for child in context.children {
            if let name = participantName(in: child) { return name }
        }
        return nil
    }

    private static func isParticipantNameText(_ text: String) -> Bool {
        let normalizedText = normalized(text)
        return !normalizedText.isEmpty
            && !hasWaitingRoomText(text)
            && !hasBreakoutText(text)
            && normalizedText != "admit"
            && normalizedText != "admit all"
    }

    private static func node(at indexPath: [Int], in root: Node) -> Node? {
        var current = root
        for index in indexPath {
            guard current.children.indices.contains(index) else { return nil }
            current = current.children[index]
        }
        return current
    }

    public static func printTree(_ root: Node, includeNonInteractive: Bool = true) {
        func printNode(_ node: Node, prefix: String) {
            let marker = node.isWaitingRoomMarker ? " WAITING-ROOM-MARKER" : ""
            let title = node.title.map { " title=\(quote($0))" } ?? ""
            let description = node.description.map { " description=\(quote($0))" } ?? ""
            let value = node.value.map { " value=\(quote($0))" } ?? ""
            let identifier = node.identifier.map { " identifier=\(quote($0))" } ?? ""
            let actions = node.actions.isEmpty ? "" : " actions=[\(node.actions.joined(separator: ","))]"
            let enabled = node.role == "AXButton" ? " enabled=\(node.enabled)" : ""
            if includeNonInteractive || node.role == "AXButton" || node.isWaitingRoomMarker {
                print("\(prefix)\(node.role)\(node.subrole.map { "/\($0)" } ?? "") path=\(node.path)\(title)\(description)\(value)\(identifier)\(enabled)\(actions)\(marker)")
            }
            for child in node.children {
                printNode(child, prefix: prefix + "  ")
            }
        }
        printNode(root, prefix: "")
    }

    private static func quote(_ string: String) -> String {
        let escaped = string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
