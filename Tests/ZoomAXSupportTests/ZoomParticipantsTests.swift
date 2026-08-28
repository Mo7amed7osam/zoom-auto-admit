import XCTest
@testable import ZoomAXSupport

/// Built from the participants list captured from a live meeting.
final class ZoomParticipantsTests: XCTestCase {
    private typealias Node = ZoomAXSupport.SnapshotNode

    /// One row, exactly as the live client publishes it.
    private func participantCell(_ text: String, identifier: String) -> Node {
        Node(role: "AXRow", children: [
            Node(role: "AXCell", identifier: identifier, actions: ["AXPress"], children: [
                Node(role: "AXStaticText", value: text, help: text),
                Node(
                    role: "AXMenuButton",
                    description: "More options for \(text), collapsed",
                    actions: ["AXPress"]
                ),
                Node(role: "AXButton", description: "Start video", actions: ["AXPress"]),
                Node(role: "AXButton", description: "Unmute", actions: ["AXPress"])
            ])
        ])
    }

    private func meetingWindow(
        admitted: [String] = ["eyouth coordinator (Host, me)"],
        waiting: [String] = [],
        count: Int? = nil
    ) -> Node {
        var rows = admitted.map { participantCell($0, identifier: ZoomAXSupport.panelistIdentifier) }
        rows += waiting.map { participantCell($0, identifier: ZoomAXSupport.waitingListIdentifier) }

        var children: [Node] = [
            Node(role: "AXButton", description: "Mute all", actions: ["AXPress"]),
            Node(role: "AXScrollArea", children: [
                Node(role: "AXOutline", description: "Participants list", children: rows)
            ])
        ]
        if let count {
            children.append(Node(role: "AXUnknown", description: "Participants (\(count))", children: [
                Node(role: "AXStaticText", value: "Participants (\(count))")
            ]))
        }
        return Node(role: "AXWindow", title: "Zoom Meeting", children: children)
    }

    // MARK: Name and role parsing

    func testHostRowIsParsedFromTheLiveText() {
        let parsed = ZoomAXSupport.parseParticipantText("eyouth coordinator (Host, me)")
        XCTAssertEqual(parsed.displayName, "eyouth coordinator")
        XCTAssertEqual(parsed.roles, [.host, .me])
    }

    func testGuestAndCoHostMarkers() {
        XCTAssertEqual(ZoomAXSupport.parseParticipantText("Mohamed Ahmed (Guest)").roles, [.guest])
        XCTAssertEqual(ZoomAXSupport.parseParticipantText("Sara Ali (Co-host)").roles, [.coHost])
        XCTAssertEqual(ZoomAXSupport.parseParticipantText("Omar (me)").roles, [.me])
    }

    func testPlainNameHasNoRoles() {
        let parsed = ZoomAXSupport.parseParticipantText("Mohamed Ahmed Hassan")
        XCTAssertEqual(parsed.displayName, "Mohamed Ahmed Hassan")
        XCTAssertTrue(parsed.roles.isEmpty)
    }

    /// A trailing bracket that is part of somebody's name must survive intact.
    func testNamesContainingParenthesesAreNotRewritten() {
        for name in ["Mohamed (Group A)", "Ahmed (CS)", "Sara (2024)"] {
            let parsed = ZoomAXSupport.parseParticipantText(name)
            XCTAssertEqual(parsed.displayName, name, "\(name) must not be truncated")
            XCTAssertTrue(parsed.roles.isEmpty)
        }
    }

    func testArabicNamesAreLeftAlone() {
        let parsed = ZoomAXSupport.parseParticipantText("عبدالرحمن محمد علي (Guest)")
        XCTAssertEqual(parsed.displayName, "عبدالرحمن محمد علي")
        XCTAssertEqual(parsed.roles, [.guest])
    }

    // MARK: Reading the list

    func testAdmittedParticipantsAreRead() {
        let readout = ZoomAXSupport.participantsReadout(
            inWindow: meetingWindow(admitted: [
                "eyouth coordinator (Host, me)",
                "Mohamed Ahmed (Guest)",
                "Sara Mostafa"
            ], count: 3)
        )

        XCTAssertTrue(readout.listAvailable)
        XCTAssertEqual(readout.admitted.map(\.displayName), [
            "eyouth coordinator", "Mohamed Ahmed", "Sara Mostafa"
        ])
        XCTAssertEqual(readout.reportedCount, 3)
    }

    /// Waiting Room entries are not attendance: they have not been admitted yet.
    func testWaitingRoomRowsAreSeparatedFromAttendance() {
        let readout = ZoomAXSupport.participantsReadout(
            inWindow: meetingWindow(
                admitted: ["eyouth coordinator (Host, me)"],
                waiting: ["Ahmed Tarek (Guest)"]
            )
        )

        XCTAssertEqual(readout.admitted.map(\.displayName), ["eyouth coordinator"])
        XCTAssertEqual(readout.waiting.map(\.displayName), ["Ahmed Tarek"])
    }

    func testHostRowIsIdentifiableSoItCanBeExcluded() {
        let readout = ZoomAXSupport.participantsReadout(inWindow: meetingWindow())
        let host = readout.admitted.first
        XCTAssertTrue(host?.isSelfOrHost == true)

        let student = ZoomAXSupport.parseParticipantText("Mohamed Ahmed (Guest)")
        XCTAssertFalse(student.roles.contains(.host))
        XCTAssertFalse(student.roles.contains(.me))
    }

    /// The distinction that prevents a whole class being marked absent: a list
    /// that cannot be read is not a list with nobody in it.
    func testMissingListIsUnavailableRatherThanEmpty() {
        let noPanel = Node(role: "AXWindow", title: "Zoom Meeting", children: [
            Node(role: "AXButton", description: "Mute all", actions: ["AXPress"])
        ])
        let readout = ZoomAXSupport.participantsReadout(inWindow: noPanel)

        XCTAssertFalse(readout.listAvailable)
        XCTAssertTrue(readout.admitted.isEmpty)
        XCTAssertNotEqual(readout, ZoomAXSupport.participantsReadout(inWindow: meetingWindow(admitted: [])))
    }

    func testEmptyListIsAvailableButEmpty() {
        let readout = ZoomAXSupport.participantsReadout(inWindow: meetingWindow(admitted: []))
        XCTAssertTrue(readout.listAvailable)
        XCTAssertTrue(readout.admitted.isEmpty)
    }

    func testReportedCountIsParsed() {
        XCTAssertEqual(
            ZoomAXSupport.reportedParticipantCount(
                in: Node(role: "AXUnknown", description: "Participants (12)")
            ),
            12
        )
        XCTAssertNil(
            ZoomAXSupport.reportedParticipantCount(in: Node(role: "AXUnknown", description: "Chat"))
        )
    }

    /// Duplicate subtrees must not inflate the roll call.
    func testSameRowSeenTwiceIsCountedOnce() {
        let row = participantCell("Mohamed Ahmed (Guest)", identifier: ZoomAXSupport.panelistIdentifier)
        let window = Node(role: "AXWindow", children: [
            Node(role: "AXScrollArea", children: [
                Node(role: "AXOutline", description: "Participants list", children: [row])
            ])
        ])
        let readout = ZoomAXSupport.participantsReadout(inWindow: window)
        XCTAssertEqual(readout.admitted.count, 1)
    }
}
