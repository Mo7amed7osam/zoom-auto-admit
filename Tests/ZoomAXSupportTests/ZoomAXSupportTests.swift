import ApplicationServices
import XCTest
@testable import ZoomAXSupport

final class ZoomAXSupportTests: XCTestCase {
    func testTrustIsDecidedByTheTrustAPIsAlone() {
        let usable = ZoomAXSupport.AccessibilityTrustSnapshot(
            isProcessTrusted: true,
            isProcessTrustedWithOptions: true,
            systemWideProbeResult: .success
        )
        XCTAssertTrue(usable.APIsAgree)
        XCTAssertTrue(usable.isTrusted)
        XCTAssertTrue(usable.isUsableWithoutRelaunch)
        XCTAssertFalse(usable.relaunchAppearsRequired)
        XCTAssertFalse(usable.systemWideProbeFailedBenignly)
    }

    /// Regression test for the false "Permission granted — relaunch app" state.
    ///
    /// The system-wide probe reads the *frontmost* application. When another app
    /// (Chrome and other Electron-style apps do this routinely) is slow to build
    /// its Accessibility tree the probe returns cannotComplete, and when nothing
    /// holds Accessibility focus it returns noValue. Neither says anything about
    /// this app's permission, so neither may downgrade the trust state.
    func testForeignApplicationProbeFailuresNeverDowngradeTrust() {
        for benignResult in [AXError.cannotComplete, .noValue, .attributeUnsupported, .failure] {
            let snapshot = ZoomAXSupport.AccessibilityTrustSnapshot(
                isProcessTrusted: true,
                isProcessTrustedWithOptions: true,
                systemWideProbeResult: benignResult
            )
            XCTAssertTrue(snapshot.isTrusted, "\(benignResult.diagnosticName) must stay trusted")
            XCTAssertTrue(
                snapshot.isUsableWithoutRelaunch,
                "\(benignResult.diagnosticName) must not require a relaunch"
            )
            XCTAssertFalse(
                snapshot.relaunchAppearsRequired,
                "\(benignResult.diagnosticName) must not request a relaunch"
            )
            XCTAssertTrue(snapshot.systemWideProbeFailedBenignly)
            XCTAssertFalse(snapshot.accessibilityAPIDisabled)
        }
    }

    func testOnlyAPIDisabledIndicatesAccessibilityIsUnavailable() {
        let disabled = ZoomAXSupport.AccessibilityTrustSnapshot(
            isProcessTrusted: true,
            isProcessTrustedWithOptions: true,
            systemWideProbeResult: .apiDisabled
        )
        XCTAssertTrue(disabled.isTrusted)
        XCTAssertTrue(disabled.accessibilityAPIDisabled)
        XCTAssertFalse(disabled.isUsableWithoutRelaunch)
        XCTAssertTrue(disabled.relaunchAppearsRequired)
    }

    func testTrustSnapshotDetectsDisagreeingTrustAPIs() {
        let disagreement = ZoomAXSupport.AccessibilityTrustSnapshot(
            isProcessTrusted: true,
            isProcessTrustedWithOptions: false,
            systemWideProbeResult: .success
        )
        XCTAssertFalse(disagreement.APIsAgree)
        XCTAssertFalse(disagreement.isTrusted)
        XCTAssertTrue(disagreement.relaunchAppearsRequired)
    }

    func testAXErrorClassificationSeparatesPermissionFromTransientAndStale() {
        XCTAssertTrue(AXError.apiDisabled.indicatesAccessibilityDisabled)
        XCTAssertFalse(AXError.cannotComplete.indicatesAccessibilityDisabled)
        XCTAssertFalse(AXError.invalidUIElement.indicatesAccessibilityDisabled)

        XCTAssertTrue(AXError.invalidUIElement.indicatesStaleElement)
        XCTAssertFalse(AXError.cannotComplete.indicatesStaleElement)

        XCTAssertTrue(AXError.cannotComplete.indicatesTransientFailure)
        XCTAssertTrue(AXError.noValue.indicatesTransientFailure)
        XCTAssertFalse(AXError.apiDisabled.indicatesTransientFailure)

        XCTAssertEqual(ZoomAXSupport.ScanFailure.classify(.success), nil)
        XCTAssertEqual(ZoomAXSupport.ScanFailure.classify(.apiDisabled), .accessibilityDisabled(.apiDisabled))
        XCTAssertEqual(ZoomAXSupport.ScanFailure.classify(.invalidUIElement), .staleElement(.invalidUIElement))
        XCTAssertEqual(ZoomAXSupport.ScanFailure.classify(.cannotComplete), .transient(.cannotComplete))
    }

    typealias Node = ZoomAXSupport.SnapshotNode

    func testExactObservedWaitingListHierarchyMatchesDescriptionAndParticipant() {
        let tree = Node(role: "AXWindow", children: [
            Node(role: "AXRow", children: [
                Node(
                    role: "AXCell",
                    description: "eyouth Coordinator selected, press space to admit",
                    identifier: ZoomAXSupport.waitingListIdentifier,
                    actions: [ZoomAXSupport.pressAction],
                    children: [
                        Node(role: "AXStaticText", value: "eyouth Coordinator (Guest)"),
                        Node(role: "AXMenuButton", description: "More options for eyouth Coordinator, collapsed"),
                        Node(
                            role: "AXButton",
                            description: "Admit",
                            enabled: true,
                            actions: [ZoomAXSupport.pressAction]
                        )
                    ]
                )
            ])
        ])

        let candidates = ZoomAXSupport.matchAdmitCandidates(in: tree)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].type, .individual)
        XCTAssertEqual(candidates[0].waitingRoomEvidence.kind, .participantIdentifier)
        XCTAssertEqual(candidates[0].waitingRoomEvidence.value, ZoomAXSupport.waitingListIdentifier)
        XCTAssertEqual(candidates[0].participantName, "eyouth Coordinator (Guest)")
        XCTAssertEqual(candidates[0].buttonDescription, "Admit")
        XCTAssertNil(candidates[0].buttonTitle)
        XCTAssertEqual(candidates[0].buttonIndexPath, [0, 0, 2])
        XCTAssertEqual(candidates[0].contextIndexPath, [0, 0])
    }

    func testMeetingWindowRecognitionIsExactEnoughForDiagnostics() {
        XCTAssertTrue(ZoomAXSupport.isLikelyMeetingWindowTitle("Zoom Meeting"))
        XCTAssertTrue(ZoomAXSupport.isLikelyMeetingWindowTitle("Zoom Meeting 123"))
        XCTAssertFalse(ZoomAXSupport.isLikelyMeetingWindowTitle("Zoom Workplace"))
        XCTAssertFalse(ZoomAXSupport.isLikelyMeetingWindowTitle("Invite people to join meeting"))
    }

    func testMeetingWindowStateClassification() {
        let visible = ZoomAXSupport.CGWindowRecord(
            windowID: 1,
            ownerPID: 42,
            name: "Zoom Meeting",
            layer: 0,
            isOnscreen: true
        )
        let offscreen = ZoomAXSupport.CGWindowRecord(
            windowID: 2,
            ownerPID: 42,
            name: "Zoom Meeting",
            layer: 0,
            isOnscreen: false
        )

        // Zoom frontmost.
        XCTAssertEqual(
            ZoomAXSupport.classifyMeetingWindow(
                zoomHidden: false,
                meetingIsMinimized: false,
                axMeetingWindowFound: true,
                zoomIsActive: true,
                cgMeetingWindows: [visible]
            ),
            .currentSpace
        )

        // Zoom on the current Space with another application frontmost, possibly
        // completely covering it. The hierarchy still answers, so it stays fully
        // monitorable.
        let background = ZoomAXSupport.classifyMeetingWindow(
            zoomHidden: false,
            meetingIsMinimized: false,
            axMeetingWindowFound: true,
            zoomIsActive: false,
            cgMeetingWindows: [visible]
        )
        XCTAssertEqual(background, .currentSpaceBackground)
        XCTAssertTrue(background.isAccessible)

        // Off-Space: no Accessibility hierarchy, CoreGraphics still sees it.
        let offSpace = ZoomAXSupport.classifyMeetingWindow(
            zoomHidden: false,
            meetingIsMinimized: false,
            axMeetingWindowFound: false,
            zoomIsActive: false,
            cgMeetingWindows: [offscreen]
        )
        XCTAssertEqual(offSpace, .otherSpaceOrFullscreen)
        XCTAssertFalse(offSpace.isAccessible)

        XCTAssertEqual(
            ZoomAXSupport.classifyMeetingWindow(
                zoomHidden: false,
                meetingIsMinimized: true,
                axMeetingWindowFound: true,
                zoomIsActive: false,
                cgMeetingWindows: [offscreen]
            ),
            .minimized
        )
        XCTAssertEqual(
            ZoomAXSupport.classifyMeetingWindow(
                zoomHidden: true,
                meetingIsMinimized: false,
                axMeetingWindowFound: false,
                zoomIsActive: false,
                cgMeetingWindows: [offscreen]
            ),
            .hidden
        )
        XCTAssertEqual(
            ZoomAXSupport.classifyMeetingWindow(
                zoomHidden: false,
                meetingIsMinimized: false,
                axMeetingWindowFound: false,
                zoomIsActive: false,
                cgMeetingWindows: []
            ),
            .notFound
        )
    }

    /// Occlusion is not a Space. A covered window on the current Space keeps
    /// reporting kCGWindowIsOnscreen == true, so the on-screen flag can never be
    /// the reason a window is called off-Space.
    func testOcclusionIsNeverTreatedAsAnotherSpace() {
        let coveredButOnscreen = ZoomAXSupport.CGWindowRecord(
            windowID: 3,
            ownerPID: 42,
            name: "Zoom Meeting",
            layer: 0,
            isOnscreen: true
        )
        XCTAssertEqual(
            ZoomAXSupport.classifyMeetingWindow(
                zoomHidden: false,
                meetingIsMinimized: false,
                axMeetingWindowFound: false,
                zoomIsActive: false,
                cgMeetingWindows: [coveredButOnscreen]
            ),
            .currentSpaceBackground
        )
    }

    func testMeetingDiscoveryCorrelatesAXStructureAndBoundsWithoutTitle() {
        let cgWindow = ZoomAXSupport.CGWindowRecord(
            windowID: 77,
            ownerPID: 42,
            name: nil,
            layer: 0,
            isOnscreen: true,
            bounds: CGRect(x: 100, y: 80, width: 1200, height: 760),
            alpha: 1,
            sharingState: 1
        )
        let axEvidence = ZoomAXSupport.AXMeetingWindowEvidence(
            title: "",
            bounds: CGRect(x: 100, y: 80, width: 1200, height: 760),
            hasMeetingStructure: true
        )

        let result = ZoomAXSupport.discoverMeetingWindow(
            cgWindows: [cgWindow],
            learnedWindowID: nil,
            axEvidence: [axEvidence]
        )

        XCTAssertEqual(result?.window.windowID, 77)
        XCTAssertTrue(result?.evidence.contains("ax-structure+bounds") == true)
    }

    func testLearnedMeetingWindowIDSurvivesOffSpaceTitleLoss() {
        let workplace = ZoomAXSupport.CGWindowRecord(
            windowID: 10,
            ownerPID: 42,
            name: "Zoom Workplace",
            layer: 0,
            isOnscreen: true,
            bounds: CGRect(x: 0, y: 0, width: 900, height: 700)
        )
        let offSpaceMeeting = ZoomAXSupport.CGWindowRecord(
            windowID: 77,
            ownerPID: 42,
            name: nil,
            layer: 0,
            isOnscreen: false,
            bounds: CGRect(x: 0, y: 0, width: 1200, height: 760)
        )

        let result = ZoomAXSupport.discoverMeetingWindow(
            cgWindows: [workplace, offSpaceMeeting],
            learnedWindowID: 77,
            axEvidence: []
        )

        XCTAssertEqual(result?.window.windowID, 77)
        XCTAssertEqual(result?.evidence, "learned-window-id")
    }

    func testOffSpaceNormalWindowHeuristicDoesNotAuthorizeKnownNonMeetingWindow() {
        let healthcheck = ZoomAXSupport.CGWindowRecord(
            windowID: 11,
            ownerPID: 42,
            name: "Zoom Client Healthcheck",
            layer: 0,
            isOnscreen: false,
            bounds: CGRect(x: 0, y: 0, width: 1200, height: 760)
        )

        XCTAssertNil(ZoomAXSupport.discoverMeetingWindow(
            cgWindows: [healthcheck],
            learnedWindowID: nil,
            axEvidence: []
        ))
    }

    func testWaitingListIdentifierTakesPriorityOverTextAndGroupEvidence() {
        let tree = Node(role: "AXWindow", children: [
            Node(role: "AXGroup", children: [
                Node(
                    role: "AXCell",
                    identifier: ZoomAXSupport.waitingListGroupIdentifier,
                    children: [Node(role: "AXStaticText", value: "Waiting room (1)")]
                ),
                waitingParticipantCell(buttonDescription: "Admit")
            ])
        ])

        let candidate = try! XCTUnwrap(ZoomAXSupport.matchAdmitCandidates(in: tree).first)

        XCTAssertEqual(candidate.waitingRoomEvidence.kind, .participantIdentifier)
        XCTAssertEqual(candidate.waitingRoomEvidence.value, ZoomAXSupport.waitingListIdentifier)
    }

    func testWaitingListGroupIdentifierSupportsExactDescriptionAdmitAll() {
        let tree = Node(role: "AXWindow", children: [
            Node(role: "AXGroup", children: [
                Node(
                    role: "AXCell",
                    identifier: ZoomAXSupport.waitingListGroupIdentifier,
                    children: [Node(role: "AXStaticText", value: "Waiting room (1)")]
                ),
                Node(
                    role: "AXButton",
                    description: "Admit All",
                    actions: [ZoomAXSupport.pressAction]
                )
            ])
        ])

        let candidate = try! XCTUnwrap(ZoomAXSupport.matchAdmitCandidates(in: tree).first)

        XCTAssertEqual(candidate.type, .admitAll)
        XCTAssertEqual(candidate.waitingRoomEvidence.kind, .groupIdentifier)
        XCTAssertEqual(candidate.waitingRoomEvidence.value, ZoomAXSupport.waitingListGroupIdentifier)
        XCTAssertEqual(candidate.buttonDescription, "Admit All")
    }

    func testTitleMatchingRemainsCompatible() {
        let tree = Node(role: "AXWindow", children: [
            Node(
                role: "AXCell",
                identifier: ZoomAXSupport.waitingListIdentifier,
                children: [
                    Node(role: "AXButton", title: "  ADMIT  ", actions: [ZoomAXSupport.pressAction])
                ]
            )
        ])

        let candidate = try! XCTUnwrap(ZoomAXSupport.matchAdmitCandidates(in: tree).first)

        XCTAssertEqual(candidate.type, .individual)
        XCTAssertEqual(candidate.buttonTitle, "  ADMIT  ")
    }

    func testAccessibleTextFallbackRemainsCompatible() {
        let tree = Node(role: "AXWindow", children: [
            Node(role: "AXGroup", children: [
                Node(role: "AXStaticText", value: "Waiting Room (1)"),
                Node(role: "AXButton", description: "Admit", actions: [ZoomAXSupport.pressAction])
            ])
        ])

        let candidate = try! XCTUnwrap(ZoomAXSupport.matchAdmitCandidates(in: tree).first)

        XCTAssertEqual(candidate.waitingRoomEvidence.kind, .accessibleText)
        XCTAssertEqual(candidate.waitingRoomEvidence.value, "Waiting Room (1)")
    }

    func testLooseDescriptionDoesNotMatch() {
        assertNoCandidate(button: Node(
            role: "AXButton",
            description: "Admit participant now",
            actions: [ZoomAXSupport.pressAction]
        ))
    }

    func testDisabledButtonDoesNotMatch() {
        assertNoCandidate(button: Node(
            role: "AXButton",
            description: "Admit",
            enabled: false,
            actions: [ZoomAXSupport.pressAction]
        ))
    }

    func testButtonWithoutPressActionDoesNotMatch() {
        assertNoCandidate(button: Node(role: "AXButton", description: "Admit", actions: []))
    }

    func testNonButtonDoesNotMatch() {
        assertNoCandidate(button: Node(
            role: "AXMenuButton",
            description: "Admit",
            actions: [ZoomAXSupport.pressAction]
        ))
    }

    func testBreakoutAncestorRejectsStructurallyValidButton() {
        let tree = Node(role: "AXWindow", children: [
            Node(role: "AXGroup", description: "Breakout Rooms", children: [
                waitingParticipantCell(buttonDescription: "Admit")
            ])
        ])

        XCTAssertTrue(ZoomAXSupport.matchAdmitCandidates(in: tree).isEmpty)
    }

    func testNoWaitingRoomEvidenceDoesNotMatch() {
        let tree = Node(role: "AXWindow", children: [
            Node(role: "AXGroup", children: [
                Node(role: "AXButton", description: "Admit", actions: [ZoomAXSupport.pressAction])
            ])
        ])

        XCTAssertTrue(ZoomAXSupport.matchAdmitCandidates(in: tree).isEmpty)
    }

    private func waitingParticipantCell(buttonDescription: String) -> Node {
        Node(
            role: "AXCell",
            identifier: ZoomAXSupport.waitingListIdentifier,
            children: [
                Node(role: "AXStaticText", value: "Test Participant (Guest)"),
                Node(
                    role: "AXButton",
                    description: buttonDescription,
                    actions: [ZoomAXSupport.pressAction]
                )
            ]
        )
    }

    private func assertNoCandidate(button: Node, file: StaticString = #filePath, line: UInt = #line) {
        let tree = Node(role: "AXWindow", children: [
            Node(role: "AXCell", identifier: ZoomAXSupport.waitingListIdentifier, children: [button])
        ])
        XCTAssertTrue(ZoomAXSupport.matchAdmitCandidates(in: tree).isEmpty, file: file, line: line)
    }
}
