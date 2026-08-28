import ApplicationServices
import Foundation
import XCTest
import ZoomAXSupport
@testable import ZoomAutoAdmitCore

final class AutoAdmitMonitorTests: XCTestCase {
    func testStartingTwiceCreatesOnlyOnePollingLoop() {
        let probe = CountingProbe(event: .monitoring(presentation: .background))
        let monitor = AutoAdmitMonitor(interval: 0.5, probe: probe) { _ in }

        monitor.start()
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        Thread.sleep(forTimeInterval: 1.1)
        monitor.stop()

        XCTAssertGreaterThanOrEqual(probe.count, 2)
        XCTAssertLessThanOrEqual(probe.count, 3, "Duplicate starts must not create duplicate timers")
        XCTAssertFalse(monitor.isRunning)
    }

    func testStopCancelsPollingCleanly() {
        let probe = CountingProbe(event: .monitoring(presentation: .background))
        let monitor = AutoAdmitMonitor(interval: 0.5, probe: probe) { _ in }

        monitor.start()
        Thread.sleep(forTimeInterval: 0.65)
        monitor.stop()
        let countAfterStop = probe.count
        Thread.sleep(forTimeInterval: 0.65)

        XCTAssertEqual(probe.count, countAfterStop)
    }

    /// Requirement: repeated Start/Stop must never leave a second polling loop
    /// behind.
    func testRepeatedStartStopNeverAccumulatesPollingLoops() {
        let probe = CountingProbe(event: .zoomNotRunning)
        let monitor = AutoAdmitMonitor(interval: 0.5, probe: probe) { _ in }

        for _ in 0..<5 {
            monitor.start()
            XCTAssertTrue(monitor.isRunning)
            monitor.stop()
            XCTAssertFalse(monitor.isRunning)
        }

        monitor.start()
        Thread.sleep(forTimeInterval: 1.1)
        let countWhileRunning = probe.count
        monitor.stop()
        Thread.sleep(forTimeInterval: 0.7)

        XCTAssertEqual(probe.count, countWhileRunning, "A cancelled loop must not keep polling")
        XCTAssertLessThanOrEqual(
            countWhileRunning,
            9,
            "One 0.5s loop over ~1.1s plus the earlier immediate ticks; more means duplicated timers"
        )
    }

    func testRestartDeliversTheCurrentStateAgain() {
        let deliveredTwice = expectation(description: "state delivered after each start")
        deliveredTwice.expectedFulfillmentCount = 2
        let probe = CountingProbe(event: .zoomNotRunning)
        let monitor = AutoAdmitMonitor(interval: 0.5, probe: probe) { _ in
            deliveredTwice.fulfill()
        }

        monitor.start()
        Thread.sleep(forTimeInterval: 0.15)
        monitor.stop()
        monitor.start()

        wait(for: [deliveredTwice], timeout: 1)
        monitor.stop()
    }

    func testPermissionRequiredEventIsDeliveredWithoutCrashing() {
        let expectation = expectation(description: "permission state delivered")
        let probe = CountingProbe(event: .accessibilityPermissionRequired)
        let monitor = AutoAdmitMonitor(interval: 0.5, probe: probe) { event in
            XCTAssertEqual(event, .accessibilityPermissionRequired)
            expectation.fulfill()
        }

        monitor.checkNow()

        wait(for: [expectation], timeout: 1)
    }

    func testForcedCheckDeliversUnchangedPermissionStateAgain() {
        let deliveredTwice = expectation(description: "forced checks are never suppressed")
        deliveredTwice.expectedFulfillmentCount = 2
        let probe = CountingProbe(event: .accessibilityPermissionRequired)
        let monitor = AutoAdmitMonitor(interval: 0.5, probe: probe) { event in
            XCTAssertEqual(event, .accessibilityPermissionRequired)
            deliveredTwice.fulfill()
        }

        monitor.checkNow(forceDelivery: true)
        monitor.checkNow(forceDelivery: true)

        wait(for: [deliveredTwice], timeout: 1)
    }

    /// An Accessibility notification from Zoom must trigger a scan before the
    /// next poll would have run.
    func testAccessibilityNotificationTriggersAnEarlyScan() {
        let probe = CountingProbe(event: .monitoring(presentation: .background))
        let activity = FakeActivitySource()
        let monitor = AutoAdmitMonitor(interval: 1.0, probe: probe, activitySource: activity) { _ in }

        monitor.start()
        Thread.sleep(forTimeInterval: 0.1)
        let countBefore = probe.count
        activity.fire()
        Thread.sleep(forTimeInterval: 0.6)
        monitor.stop()

        XCTAssertGreaterThan(probe.count, countBefore, "The notification must produce an extra scan")
        XCTAssertTrue(activity.started)
        XCTAssertTrue(activity.stopped)
    }

    /// A notification storm must not turn into a scan storm.
    func testAccessibilityNotificationBurstIsCoalesced() {
        let probe = CountingProbe(event: .monitoring(presentation: .background))
        let activity = FakeActivitySource()
        let monitor = AutoAdmitMonitor(interval: 1.0, probe: probe, activitySource: activity) { _ in }

        monitor.start()
        Thread.sleep(forTimeInterval: 0.05)
        for _ in 0..<50 { activity.fire() }
        Thread.sleep(forTimeInterval: 0.6)
        monitor.stop()

        XCTAssertLessThanOrEqual(probe.count, 4, "50 notifications must coalesce into at most a couple of scans")
    }
}

final class ZoomAutoAdmitProbeTests: XCTestCase {
    // MARK: Zoom in the foreground, the background, and fully covered

    /// 1. Zoom frontmost: a WAITINGLIST candidate is admitted.
    func testAdmitsWaitingParticipantWhileZoomIsFrontmost() {
        let access = FakeZoomAccess()
        access.presentationValue = .foreground
        access.scans = [.candidate(named: "eyouth Coordinator (Guest)")]

        let event = makeProbe(access).poll()

        XCTAssertEqual(event.admittedParticipantName, "eyouth Coordinator (Guest)")
        XCTAssertEqual(access.pressCount, 1)
    }

    /// 2. Zoom on the same Space with another application frontmost.
    /// The probe addresses Zoom by PID, so the outcome is identical.
    func testAdmitsWaitingParticipantWhileAnotherApplicationIsFrontmost() {
        let access = FakeZoomAccess()
        access.presentationValue = .background
        access.scans = [.candidate(named: "eyouth Coordinator (Guest)")]

        let event = makeProbe(access).poll()

        XCTAssertEqual(event.admittedParticipantName, "eyouth Coordinator (Guest)")
        XCTAssertEqual(access.pressCount, 1)
    }

    /// 3. Zoom on the same Space and completely covered by another window.
    /// Occlusion is invisible to Accessibility, so the hierarchy still answers
    /// and the candidate is still admitted.
    func testAdmitsWaitingParticipantWhileZoomIsCompletelyCovered() {
        let access = FakeZoomAccess()
        access.presentationValue = .background
        access.location = .currentSpaceBackground
        access.scans = [.candidate(named: "eyouth Coordinator")]

        let event = makeProbe(access).poll()

        XCTAssertEqual(event.admittedParticipantName, "eyouth Coordinator")
    }

    /// 4. A second participant arriving after a successful admission, with
    /// another application frontmost the whole time, is admitted too.
    func testSecondParticipantIsAdmittedWhileAnotherApplicationStaysFrontmost() {
        let access = FakeZoomAccess()
        access.presentationValue = .background
        access.scans = [
            .candidate(named: "First Guest"),
            .monitoringOnly,
            .candidate(named: "Second Guest")
        ]
        let probe = makeProbe(access)

        XCTAssertEqual(probe.poll().admittedParticipantName, "First Guest")
        XCTAssertEqual(probe.poll(), .monitoring(presentation: .background))
        XCTAssertEqual(probe.poll().admittedParticipantName, "Second Guest")
        XCTAssertEqual(access.pressCount, 2)
    }

    /// The probe must report a covered, background Zoom as monitoring, never as
    /// an error or a permission problem.
    func testBackgroundZoomReportsMonitoringWithBackgroundPresentation() {
        let access = FakeZoomAccess()
        access.presentationValue = .background
        access.scans = [.monitoringOnly]

        XCTAssertEqual(makeProbe(access).poll(), .monitoring(presentation: .background))
        XCTAssertEqual(access.locateCount, 0, "An available hierarchy must not consult the window APIs")
    }

    // MARK: Transient and stale Accessibility failures

    /// 5. A transient cannotComplete must never produce a relaunch state.
    func testTransientCannotCompleteNeverRequestsRelaunch() {
        let access = FakeZoomAccess()
        access.scans = [.failed(.transient(.cannotComplete))]

        let event = makeProbe(access).poll()

        guard case .zoomTemporarilyUnavailable(let reason) = event else {
            return XCTFail("Expected a temporary Zoom failure, got \(event)")
        }
        XCTAssertTrue(reason.contains("cannotComplete"), "The AXError must be reported verbatim, got \(reason)")
        XCTAssertNotEqual(event, .accessibilityPermissionGrantedRelaunchRequired)
        XCTAssertNotEqual(event, .accessibilityPermissionRequired)
        XCTAssertEqual(access.scanCount, 3, "Every attempt must re-acquire fresh references")
    }

    func testTransientFailureRecoversWithinTheSamePoll() {
        let access = FakeZoomAccess()
        access.scans = [
            .failed(.transient(.cannotComplete)),
            .candidate(named: "Recovered Guest")
        ]

        XCTAssertEqual(makeProbe(access).poll().admittedParticipantName, "Recovered Guest")
        XCTAssertEqual(access.scanCount, 2)
    }

    func testRetryWaitsBetween250And500Milliseconds() {
        let access = FakeZoomAccess()
        access.scans = [.failed(.transient(.cannotComplete)), .monitoringOnly]
        var sleeps: [TimeInterval] = []
        let probe = ZoomAutoAdmitProbe(access: access) { sleeps.append($0) }

        _ = probe.poll()

        XCTAssertEqual(sleeps.count, 1)
        XCTAssertGreaterThanOrEqual(sleeps[0], 0.25)
        XCTAssertLessThanOrEqual(sleeps[0], 0.5)
    }

    /// 6. invalidUIElement: the stale reference is discarded and re-acquired.
    func testStaleElementIsDiscardedAndReacquired() {
        let access = FakeZoomAccess()
        access.scans = [
            .failed(.staleElement(.invalidUIElement)),
            .candidate(named: "Guest After Redraw")
        ]

        XCTAssertEqual(makeProbe(access).poll().admittedParticipantName, "Guest After Redraw")
        XCTAssertEqual(access.scanCount, 2, "The stale scan must be followed by a fresh one")
    }

    func testStaleAdmitButtonIsReacquiredRatherThanForcePressed() {
        let access = FakeZoomAccess()
        access.scans = [.candidate(named: "Guest"), .candidate(named: "Guest")]
        access.pressResults = [.invalidUIElement, .success]

        XCTAssertEqual(makeProbe(access).poll().admittedParticipantName, "Guest")
        XCTAssertEqual(access.pressCount, 2)
        XCTAssertEqual(access.scanCount, 2)
    }

    // MARK: Permission truth

    /// 7. Permission stays trusted through a Zoom-specific failure.
    func testTrustedPermissionSurvivesRepeatedZoomFailures() {
        let access = FakeZoomAccess()
        access.trust = .init(
            isProcessTrusted: true,
            isProcessTrustedWithOptions: true,
            // The system-wide probe reads the frontmost application, which is
            // exactly what happens when Chrome is covering Zoom.
            systemWideProbeResult: .cannotComplete
        )
        access.scans = [.failed(.transient(.cannotComplete))]

        let event = makeProbe(access).poll()

        guard case .zoomTemporarilyUnavailable = event else {
            return XCTFail("Expected a temporary Zoom failure, got \(event)")
        }
    }

    /// 8. Genuinely missing permission produces the permission-required state.
    func testUntrustedProcessRequiresPermission() {
        let access = FakeZoomAccess()
        access.trust = .init(
            isProcessTrusted: false,
            isProcessTrustedWithOptions: false,
            systemWideProbeResult: .apiDisabled
        )

        XCTAssertEqual(makeProbe(access).poll(), .accessibilityPermissionRequired)
        XCTAssertEqual(access.scanCount, 0)
    }

    func testAPIDisabledIsTheOnlyRelaunchTrigger() {
        let access = FakeZoomAccess()
        access.trust = .init(
            isProcessTrusted: true,
            isProcessTrustedWithOptions: true,
            systemWideProbeResult: .apiDisabled
        )

        XCTAssertEqual(makeProbe(access).poll(), .accessibilityPermissionGrantedRelaunchRequired)
    }

    func testZoomAXAPIDisabledIsReportedAsRelaunch() {
        let access = FakeZoomAccess()
        access.scans = [.failed(.accessibilityDisabled(.apiDisabled))]

        XCTAssertEqual(makeProbe(access).poll(), .accessibilityPermissionGrantedRelaunchRequired)
    }

    func testZoomNotRunningIsReportedPlainly() {
        let access = FakeZoomAccess()
        access.zoom = nil

        XCTAssertEqual(makeProbe(access).poll(), .zoomNotRunning)
    }

    // MARK: Space distinction

    /// 9a. Off-Space Zoom is reported only after the hierarchy stays absent
    /// across every retry.
    func testOffSpaceIsReportedOnlyAfterTheHierarchyStaysAbsent() {
        let access = FakeZoomAccess()
        access.scans = [.hierarchyAbsent]
        access.location = .otherSpaceOrFullscreen

        XCTAssertEqual(makeProbe(access).poll(), .meetingOnOtherDesktop)
        XCTAssertEqual(access.scanCount, 3, "Another Desktop must survive every retry before it is reported")
    }

    func testOffSpaceIsNotReportedWhenTheHierarchyComesBack() {
        let access = FakeZoomAccess()
        access.scans = [.hierarchyAbsent, .monitoringOnly]
        access.location = .otherSpaceOrFullscreen

        XCTAssertEqual(makeProbe(access).poll(), .monitoring(presentation: .background))
    }

    /// 9b. A covered same-Space Zoom is never confused with an off-Space one.
    func testCoveredSameSpaceZoomIsNotReportedAsAnotherDesktop() {
        let access = FakeZoomAccess()
        access.scans = [.hierarchyAbsent]
        access.location = .currentSpaceBackground

        let event = makeProbe(access).poll()

        XCTAssertEqual(event, .monitoring(presentation: .background))
        XCTAssertNotEqual(event, .meetingOnOtherDesktop)
    }

    func testHiddenAndMinimizedZoomAreDistinguished() {
        let hidden = FakeZoomAccess()
        hidden.scans = [.hierarchyAbsent]
        hidden.location = .hidden
        XCTAssertEqual(makeProbe(hidden).poll(), .meetingInaccessible("Zoom is hidden"))

        let minimized = FakeZoomAccess()
        minimized.scans = [.hierarchyAbsent]
        minimized.location = .minimized
        XCTAssertEqual(makeProbe(minimized).poll(), .meetingInaccessible("Zoom meeting is minimized"))

        let absent = FakeZoomAccess()
        absent.scans = [.hierarchyAbsent]
        absent.location = .notFound
        XCTAssertEqual(makeProbe(absent).poll(), .meetingNotDetected)
    }

    private func makeProbe(_ access: FakeZoomAccess) -> ZoomAutoAdmitProbe {
        ZoomAutoAdmitProbe(access: access, sleeper: { _ in })
    }
}

// MARK: - Test doubles

private extension AutoAdmitMonitorEvent {
    var admittedParticipantName: String?? {
        guard case .admitted(let name, _, _) = self else { return nil }
        return .some(name)
    }
}

private extension ZoomAXSupport.ZoomScanResult {
    static var monitoringOnly: ZoomAXSupport.ZoomScanResult {
        .init(
            candidate: nil,
            meetingHierarchyAvailable: true,
            windowCount: 2,
            axEvidence: [],
            meetingIsMinimized: false,
            failure: nil
        )
    }

    static var hierarchyAbsent: ZoomAXSupport.ZoomScanResult {
        .init(
            candidate: nil,
            meetingHierarchyAvailable: false,
            windowCount: 1,
            axEvidence: [],
            meetingIsMinimized: false,
            failure: nil
        )
    }

    static func candidate(named name: String) -> ZoomAXSupport.ZoomScanResult {
        .init(
            candidate: ZoomAXSupport.AdmitCandidate(
                node: ZoomAXSupport.Node(element: AXUIElementCreateApplication(getpid())),
                type: .individual,
                waitingRoomEvidence: .init(
                    kind: .participantIdentifier,
                    value: ZoomAXSupport.waitingListIdentifier
                ),
                participantName: name,
                contextPath: "axwindow[0]/axrow[0]"
            ),
            meetingHierarchyAvailable: true,
            windowCount: 2,
            axEvidence: [],
            meetingIsMinimized: false,
            failure: nil
        )
    }

    static func failed(_ failure: ZoomAXSupport.ScanFailure) -> ZoomAXSupport.ZoomScanResult {
        .init(
            candidate: nil,
            meetingHierarchyAvailable: false,
            windowCount: 0,
            axEvidence: [],
            meetingIsMinimized: false,
            failure: failure
        )
    }
}

/// Records every Zoom-facing call. Deliberately offers no way to activate,
/// raise, unhide or focus Zoom, so the probe cannot steal focus even by mistake.
private final class FakeZoomAccess: ZoomAccessProviding {
    var trust = ZoomAXSupport.AccessibilityTrustSnapshot(
        isProcessTrusted: true,
        isProcessTrustedWithOptions: true,
        systemWideProbeResult: .success
    )
    var zoom: (pid: pid_t, bundleIdentifier: String)? = (4242, "us.zoom.xos")
    /// Consumed in order; the last entry repeats.
    var scans: [ZoomAXSupport.ZoomScanResult] = [.monitoringOnly]
    var pressResults: [AXError] = [.success]
    var presentationValue: ZoomPresentation = .background
    var location: ZoomAXSupport.MeetingWindowLocation = .notFound

    private(set) var scanCount = 0
    private(set) var pressCount = 0
    private(set) var locateCount = 0

    func trustSnapshot() -> ZoomAXSupport.AccessibilityTrustSnapshot { trust }

    func zoomApplication() -> (pid: pid_t, bundleIdentifier: String)? { zoom }

    func scan(pid: pid_t) -> ZoomAXSupport.ZoomScanResult {
        defer { scanCount += 1 }
        return scans[min(scanCount, scans.count - 1)]
    }

    func pressAdmit(_ candidate: ZoomAXSupport.AdmitCandidate) -> AXError {
        defer { pressCount += 1 }
        return pressResults[min(pressCount, pressResults.count - 1)]
    }

    func presentation(pid: pid_t) -> ZoomPresentation { presentationValue }

    func locateMeeting(
        pid: pid_t,
        bundleIdentifier: String,
        scan: ZoomAXSupport.ZoomScanResult,
        learnedWindowID: CGWindowID?
    ) -> (location: ZoomAXSupport.MeetingWindowLocation, windowID: CGWindowID?, evidence: String?) {
        locateCount += 1
        return (location, 29_333, "test-evidence")
    }
}

private final class FakeActivitySource: AutoAdmitActivitySource {
    private let lock = NSLock()
    private var handler: (() -> Void)?
    private(set) var started = false
    private(set) var stopped = false

    func start(onActivity: @escaping () -> Void) {
        lock.lock()
        handler = onActivity
        started = true
        lock.unlock()
    }

    func synchronize() {}

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?()
    }
}

private final class CountingProbe: AutoAdmitProbing {
    private let lock = NSLock()
    private var storedCount = 0
    private let event: AutoAdmitMonitorEvent

    init(event: AutoAdmitMonitorEvent) {
        self.event = event
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    func poll() -> AutoAdmitMonitorEvent {
        lock.lock()
        storedCount += 1
        lock.unlock()
        return event
    }
}
