import XCTest
@testable import ZoomAXSupport

/// Built from the real in-meeting toolbar captured from the live Zoom client,
/// including the two properties that broke the first attempt: the button is
/// described by its action and state rather than by a name, and the toolbar
/// tree repeats each button inside itself many times over.
final class ZoomParticipantsPanelTests: XCTestCase {
    private typealias Node = ZoomAXSupport.SnapshotNode

    /// Exactly as the live client reports it.
    private func participantsButton(
        description: String = "Open participants panel, closed, 1 participants",
        enabled: Bool = true
    ) -> Node {
        Node(
            role: "AXButton",
            description: description,
            identifier: "participant",
            enabled: enabled,
            actions: ["AXPress"],
            help: "Show the participants list (⌘U), press Shift+F10 key to open the context menu"
        )
    }

    private func toolbarButton(_ description: String, identifier: String? = nil) -> Node {
        Node(
            role: "AXButton",
            description: description,
            identifier: identifier,
            actions: ["AXPress"]
        )
    }

    /// The observed toolbar, with the participants button at index 7 and its
    /// options caret immediately after it at index 8.
    private func meetingWindow(
        participants: Node? = nil,
        extra: [Node] = []
    ) -> Node {
        Node(role: "AXWindow", title: "Zoom Meeting", children: [
            Node(role: "AXTabGroup", description: "eyouth coordinator, Computer audio muted"),
            toolbarButton("Unmute my audio", identifier: "audio"),
            toolbarButton("Audio options"),
            toolbarButton("Start video", identifier: "video"),
            toolbarButton("Video options"),
            toolbarButton("End", identifier: "leave"),
            toolbarButton("Host tools, open panel", identifier: "hosttools"),
            participants ?? participantsButton(),
            toolbarButton("Participants options"),
            toolbarButton("Open chat panel ", identifier: "chat")
        ] + extra)
    }

    // MARK: State from the control's own description

    func testStateIsReadFromTheLiveDescription() {
        XCTAssertEqual(
            ZoomAXSupport.participantsState(
                fromDescription: "Open participants panel, closed, 1 participants"
            ),
            .closed
        )
        XCTAssertEqual(
            ZoomAXSupport.participantsState(
                fromDescription: "Close participants panel, open, 3 participants"
            ),
            .open
        )
        XCTAssertEqual(ZoomAXSupport.participantsState(fromDescription: nil), .unknown)
        XCTAssertEqual(ZoomAXSupport.participantsState(fromDescription: "Participants"), .unknown)
    }

    /// Verb and state token disagreeing means the reading is not trustworthy,
    /// and pressing on a bad reading closes a panel that was already open.
    func testContradictoryDescriptionIsUnknown() {
        XCTAssertEqual(
            ZoomAXSupport.participantsState(fromDescription: "Open participants panel, open, 1 participants"),
            .unknown
        )
    }

    // MARK: Finding the control

    func testParticipantsButtonIsFoundByZoomsStableIdentifier() {
        let toggle = ZoomAXSupport.participantsToggle(inWindow: meetingWindow())
        XCTAssertEqual(toggle?.indexPath, [7])
        XCTAssertEqual(toggle?.evidence, "AXIdentifier=participant")
        XCTAssertEqual(toggle?.state, .closed)
        XCTAssertTrue(toggle?.enabled == true)
    }

    /// The caret next to it opens a menu; pressing it would not open the panel.
    func testParticipantsOptionsCaretIsNeverChosen() {
        let toggle = ZoomAXSupport.participantsToggle(inWindow: meetingWindow())
        XCTAssertNotEqual(toggle?.indexPath, [8])
        XCTAssertFalse(toggle?.matchedText.lowercased().contains("options") == true)
    }

    func testNeighbouringToolbarButtonsAreNotConfused() {
        for label in ["Unmute my audio", "Start video", "End", "Host tools, open panel", "Open chat panel "] {
            let window = Node(role: "AXWindow", children: [toolbarButton(label)])
            XCTAssertNil(
                ZoomAXSupport.participantsToggle(inWindow: window),
                "\(label) must not match"
            )
        }
    }

    func testInviteControlsAreNeverMistakenForTheToggle() {
        for label in ["Invite", "Invite participants", "Invite people", "Copy invite link"] {
            let window = Node(role: "AXWindow", children: [toolbarButton(label)])
            XCTAssertNil(ZoomAXSupport.participantsToggle(inWindow: window), "\(label) must not match")
        }
    }

    /// Regression test for the live failure: Zoom nests each toolbar button
    /// inside itself repeatedly, so requiring exactly one match rejected a
    /// perfectly unambiguous control and nothing was ever pressed.
    func testSelfNestedToolbarStillResolvesToOneControl() {
        // Rebuild the observed shape: the button as its own descendant, deep.
        var nested = participantsButton()
        for _ in 0..<12 {
            nested = Node(
                role: "AXButton",
                description: "Open participants panel, closed, 1 participants",
                identifier: "participant",
                actions: ["AXPress"],
                children: [nested]
            )
        }
        let toggle = ZoomAXSupport.participantsToggle(inWindow: meetingWindow(participants: nested))

        XCTAssertNotNil(toggle, "duplicates of one control are not ambiguity")
        XCTAssertEqual(toggle?.indexPath, [7], "the shallowest occurrence is the real control")
    }

    /// Two genuinely different controls remain ambiguous and are refused.
    func testTwoDifferentCandidatesAreStillRefused() {
        let window = meetingWindow(extra: [toolbarButton("Manage participants")])
        XCTAssertNil(ZoomAXSupport.participantsToggle(inWindow: window))
    }

    func testControlWithoutPressActionIsIgnored() {
        let window = Node(role: "AXWindow", children: [
            Node(role: "AXButton", description: "Open participants panel, closed", identifier: "participant")
        ])
        XCTAssertNil(ZoomAXSupport.participantsToggle(inWindow: window))
    }

    func testOlderClientsStillMatchByLabel() {
        let window = Node(role: "AXWindow", children: [toolbarButton("Participants")])
        let toggle = ZoomAXSupport.participantsToggle(inWindow: window)
        XCTAssertEqual(toggle?.evidence, "label")
    }

    // MARK: The menu path, which is the one that actually works

    /// Zoom's View menu during a meeting, exactly as captured live.
    private func meetingMenuBar(participantsTitle: String = "Show participants") -> Node {
        Node(role: "AXMenuBar", children: [
            Node(role: "AXMenuBarItem", title: "Apple"),
            Node(role: "AXMenuBarItem", title: "Zoom Workplace"),
            Node(role: "AXMenuBarItem", title: "Meeting"),
            Node(role: "AXMenuBarItem", title: "View", children: [
                Node(role: "AXMenu", children: [
                    Node(
                        role: "AXMenuItem",
                        title: participantsTitle,
                        identifier: "onManageParticipants:",
                        enabled: true,
                        actions: ["AXCancel", "AXPress", "AXPick"]
                    )
                ])
            ]),
            Node(role: "AXMenuBarItem", title: "Edit")
        ])
    }

    func testParticipantsCommandIsFoundInTheViewMenu() {
        let command = ZoomAXSupport.participantsMenuCommand(inMenuBar: meetingMenuBar())
        XCTAssertEqual(command?.title, "Show participants")
        XCTAssertEqual(command?.state, .closed)
        XCTAssertEqual(command?.indexPath, [3, 0, 0])
        XCTAssertTrue(command?.enabled == true)
    }

    /// "Hide participants" means the panel is already open, and pressing the
    /// command again would close it and blind Auto Admit.
    func testHideParticipantsMeansThePanelIsOpen() {
        let command = ZoomAXSupport.participantsMenuCommand(
            inMenuBar: meetingMenuBar(participantsTitle: "Hide participants")
        )
        XCTAssertEqual(command?.state, .open)
    }

    func testNoParticipantsCommandWhenTheMenuIsAbsent() {
        let menuBar = Node(role: "AXMenuBar", children: [
            Node(role: "AXMenuBarItem", title: "Zoom Workplace")
        ])
        XCTAssertNil(ZoomAXSupport.participantsMenuCommand(inMenuBar: menuBar))
    }

    /// Zoom only publishes a Meeting menu while a call is running, which works
    /// even when the meeting window is on another Space.
    func testMeetingMenuIndicatesAMeetingIsRunning() {
        XCTAssertTrue(ZoomAXSupport.meetingMenuPresent(inMenuBar: meetingMenuBar()))

        let idle = Node(role: "AXMenuBar", children: [
            Node(role: "AXMenuBarItem", title: "Zoom Workplace"),
            Node(role: "AXMenuBarItem", title: "Edit")
        ])
        XCTAssertFalse(ZoomAXSupport.meetingMenuPresent(inMenuBar: idle))
    }

    // MARK: Panel state

    func testPanelStateUsesTheControlWhenTheListIsAbsent() {
        XCTAssertEqual(ZoomAXSupport.participantsPanelState(inWindow: meetingWindow()), .closed)

        let openWindow = meetingWindow(
            participants: participantsButton(description: "Close participants panel, open, 2 participants")
        )
        XCTAssertEqual(ZoomAXSupport.participantsPanelState(inWindow: openWindow), .open)
    }

    /// The Waiting Room rows are the definitive signal: if they are in the tree
    /// the panel is open, whatever any label says.
    func testWaitingRoomRowsAlwaysMeanOpen() {
        let window = meetingWindow(extra: [
            Node(role: "AXRow", identifier: ZoomAXSupport.waitingListIdentifier)
        ])
        XCTAssertEqual(ZoomAXSupport.participantsPanelState(inWindow: window), .open)
    }
}
