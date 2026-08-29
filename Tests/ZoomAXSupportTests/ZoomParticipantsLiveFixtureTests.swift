import XCTest
@testable import ZoomAXSupport

/// Fixtures transcribed from the live capture of a running meeting, so the
/// parser is pinned to Zoom's real structure rather than to an assumed one.
///
/// Ground truth at capture time:
///   AXOutline description="Participants list"   ·  Participants (2)
///   AXCell ZMHCTableItemType_PANELIST → "Mohamed Hosam (Host, me)"
///   AXCell ZMHCTableItemType_PANELIST → "eyouth coordinator"
final class ZoomParticipantsLiveFixtureTests: XCTestCase {
    private typealias Node = ZoomAXSupport.SnapshotNode

    /// One participant row exactly as the live tree presents it: a PANELIST
    /// cell holding the name as static text plus its row controls.
    private func panelistCell(_ name: String) -> Node {
        Node(role: "AXCell", identifier: ZoomAXSupport.panelistIdentifier, children: [
            Node(role: "AXStaticText", value: name),
            Node(
                role: "AXMenuButton",
                description: "More options for \(name), collapsed",
                actions: ["AXPress"]
            ),
            Node(role: "AXButton", description: "unmute \(name)", actions: ["AXPress"]),
            Node(role: "AXButton", description: "ask \(name) to start video", actions: ["AXPress"])
        ])
    }

    private func waitingCell(_ name: String) -> Node {
        Node(role: "AXCell", identifier: ZoomAXSupport.waitingListIdentifier, children: [
            Node(role: "AXStaticText", value: name),
            Node(role: "AXButton", description: "Admit", enabled: true, actions: ["AXPress"])
        ])
    }

    /// The observed window shape: a titled panel above the outline.
    private func meetingWindow(
        rows: [Node],
        countLabel: String? = "Participants (2)"
    ) -> Node {
        var children: [Node] = []
        if let countLabel {
            children.append(Node(role: "AXStaticText", value: countLabel))
        }
        children.append(
            Node(role: "AXOutline", description: "Participants list", children: rows.map { row in
                Node(role: "AXRow", children: [row])
            })
        )
        return Node(role: "AXWindow", title: "Zoom Meeting", children: [
            Node(role: "AXGroup", children: children)
        ])
    }

    private func liveWindow() -> Node {
        meetingWindow(rows: [
            panelistCell("Mohamed Hosam (Host, me)"),
            panelistCell("eyouth coordinator")
        ])
    }

    // MARK: The captured meeting

    func testLiveCaptureIsParsedExactly() {
        let readout = ZoomAXSupport.participantsReadout(inWindow: liveWindow())

        XCTAssertTrue(readout.listAvailable)
        XCTAssertEqual(readout.reportedCount, 2)
        XCTAssertEqual(readout.admitted.count, 2)
        XCTAssertTrue(readout.waiting.isEmpty)

        let host = readout.admitted[0]
        XCTAssertEqual(host.displayName, "Mohamed Hosam")
        XCTAssertEqual(host.roles, [.host, .me])
        XCTAssertTrue(host.isSelfOrHost)

        let student = readout.admitted[1]
        XCTAssertEqual(student.displayName, "eyouth coordinator")
        XCTAssertTrue(student.roles.isEmpty)
        XCTAssertFalse(student.isSelfOrHost)
    }

    func testRowControlsNeverBecomeParticipants() {
        let readout = ZoomAXSupport.participantsReadout(inWindow: liveWindow())
        let names = readout.admitted.map(\.displayName)

        // "More options for …", "unmute …" and "ask … to start video" are
        // actions on a row, never people.
        XCTAssertEqual(names, ["Mohamed Hosam", "eyouth coordinator"])
        for name in names {
            XCTAssertFalse(name.lowercased().contains("more options"))
            XCTAssertFalse(name.lowercased().hasPrefix("unmute"))
            XCTAssertFalse(name.lowercased().hasPrefix("ask "))
        }
    }

    /// Regression for Zoom's habit of republishing subtrees: the same person
    /// appearing twice at different depths is one participant.
    func testNestedDuplicateRowsAreCollapsed() {
        let duplicated = Node(role: "AXWindow", title: "Zoom Meeting", children: [
            Node(role: "AXOutline", description: "Participants list", children: [
                Node(role: "AXRow", children: [panelistCell("eyouth coordinator")]),
                Node(role: "AXGroup", children: [
                    Node(role: "AXGroup", children: [
                        Node(role: "AXRow", children: [panelistCell("eyouth coordinator")])
                    ])
                ])
            ])
        ])

        let readout = ZoomAXSupport.participantsReadout(inWindow: duplicated)
        XCTAssertEqual(readout.admitted.count, 1, "one person republished twice is still one person")
        // The shallowest occurrence is kept.
        XCTAssertEqual(readout.admitted[0].indexPath.count, 3)
    }

    func testTwoDifferentPeopleAreNotCollapsed() {
        let readout = ZoomAXSupport.participantsReadout(inWindow: meetingWindow(rows: [
            panelistCell("Sara Mostafa"),
            panelistCell("Sara Mostafa Ali")
        ]))
        XCTAssertEqual(readout.admitted.count, 2)
    }

    // MARK: PANELIST and WAITINGLIST stay separate

    func testWaitingRoomRowsAreNeverAttendanceCandidates() {
        let mixed = meetingWindow(rows: [
            panelistCell("eyouth coordinator"),
            waitingCell("Ahmed Tarek"),
            waitingCell("Sara M.")
        ], countLabel: nil)

        let readout = ZoomAXSupport.participantsReadout(inWindow: mixed)
        XCTAssertEqual(readout.admitted.map(\.displayName), ["eyouth coordinator"])
        XCTAssertEqual(readout.waiting.map(\.displayName), ["Ahmed Tarek", "Sara M."])

        // The two scopes must never leak into one another.
        let admittedNames = Set(readout.admitted.map(\.displayName))
        for waiting in readout.waiting {
            XCTAssertFalse(admittedNames.contains(waiting.displayName))
        }
    }

    // MARK: Availability

    /// A hidden panel must never read as "everybody left".
    func testMissingOutlineReportsUnavailableRatherThanEmpty() {
        let noPanel = Node(role: "AXWindow", title: "Zoom Meeting", children: [
            Node(role: "AXButton", description: "Open participants panel, closed, 2 participants")
        ])
        let readout = ZoomAXSupport.participantsReadout(inWindow: noPanel)
        XCTAssertFalse(readout.listAvailable)
        XCTAssertTrue(readout.admitted.isEmpty)
    }

    func testEmptyOutlineIsAvailableButEmpty() {
        let readout = ZoomAXSupport.participantsReadout(inWindow: meetingWindow(rows: [], countLabel: nil))
        XCTAssertTrue(readout.listAvailable)
        XCTAssertTrue(readout.admitted.isEmpty)
    }

    // MARK: Role parsing

    func testRoleParenthesesAreParsedButNamesAreNeverRewritten() {
        XCTAssertEqual(ZoomAXSupport.parseParticipantText("Mohamed Hosam (Host, me)").displayName, "Mohamed Hosam")
        XCTAssertEqual(ZoomAXSupport.parseParticipantText("Sara (Guest)").roles, [.guest])
        XCTAssertEqual(ZoomAXSupport.parseParticipantText("Ali (Co-host)").roles, [.coHost])

        // A parenthetical that is not a role list belongs to the name.
        let nickname = ZoomAXSupport.parseParticipantText("Mohamed (Group A)")
        XCTAssertEqual(nickname.displayName, "Mohamed (Group A)")
        XCTAssertTrue(nickname.roles.isEmpty)
    }
}
