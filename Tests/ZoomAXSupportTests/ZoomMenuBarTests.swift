import ApplicationServices
import XCTest
@testable import ZoomAXSupport

/// Built from the real Accessibility capture of Zoom Workplace taken on this
/// machine, including the detail that makes account switching dangerous: the
/// `Sign out` submenu lists exactly the same account titles as `Switch account`.
final class ZoomMenuBarTests: XCTestCase {
    private typealias Node = ZoomAXSupport.SnapshotNode

    private func accountItem(_ title: String, active: Bool = false) -> Node {
        Node(
            role: "AXMenuItem",
            title: title,
            identifier: "menuItemDidClicked:",
            enabled: true,
            actions: ["AXCancel", "AXPress", "AXPick"],
            markCharacter: active ? "✓" : nil
        )
    }

    /// The observed hierarchy: Apple menu, then the Zoom application menu.
    private func liveMenuBar() -> Node {
        Node(role: "AXMenuBar", children: [
            Node(role: "AXMenuBarItem", title: "Apple"),
            Node(role: "AXMenuBarItem", title: "Zoom Workplace", children: [
                Node(role: "AXMenu", children: [
                    Node(role: "AXMenuItem", title: "About Zoom Workplace", identifier: "onSystemMenuClicked:"),
                    Node(role: "AXMenuItem", title: "Settings...", identifier: "onSystemMenuClicked:"),
                    Node(role: "AXMenuItem", title: "Join meeting...", identifier: "onSystemMenuClicked:"),
                    Node(
                        role: "AXMenuItem",
                        title: "Start meeting",
                        identifier: "onSystemMenuClicked:",
                        enabled: true,
                        actions: ["AXCancel", "AXPress", "AXPick"]
                    ),
                    Node(role: "AXMenuItem", title: "Switch account", enabled: true, children: [
                        Node(role: "AXMenu", children: [
                            accountItem("eyouth coordinator(depi+11@eyouthlearning.com)", active: true),
                            accountItem("Mohamed Hosam(mohamed.hosam2310@gmail.com)"),
                            accountItem("eyouth Coordinator(depi4.2025_45@teml.net)"),
                            accountItem("deci+50 deci+50(deci+50@eyouthlearning.com)"),
                            accountItem("eyouth coordinator(depi+10@eyouthlearning.com)"),
                            Node(role: "AXMenuItem", enabled: false),
                            Node(role: "AXMenuItem", title: "Add account", identifier: "addAccount:")
                        ])
                    ]),
                    Node(role: "AXMenuItem", title: "Sign out", enabled: true, children: [
                        Node(role: "AXMenu", children: [
                            accountItem("eyouth coordinator(depi+11@eyouthlearning.com)", active: true),
                            accountItem("Mohamed Hosam(mohamed.hosam2310@gmail.com)"),
                            accountItem("eyouth Coordinator(depi4.2025_45@teml.net)"),
                            accountItem("deci+50 deci+50(deci+50@eyouthlearning.com)"),
                            accountItem("eyouth coordinator(depi+10@eyouthlearning.com)"),
                            Node(role: "AXMenuItem", enabled: false),
                            Node(
                                role: "AXMenuItem",
                                title: "Sign out of all accounts",
                                identifier: "signOutAllAccounts:"
                            )
                        ])
                    ]),
                    Node(role: "AXMenuItem", title: "Quit Zoom Workplace", identifier: "onSystemMenuClicked:")
                ])
            ]),
            Node(role: "AXMenuBarItem", title: "Edit"),
            Node(role: "AXMenuBarItem", title: "Window"),
            Node(role: "AXMenuBarItem", title: "Help")
        ])
    }

    func testEnumeratesEverySavedAccountFromTheSwitchAccountSubmenu() {
        let entries = ZoomAXSupport.switchAccountEntries(inMenuBar: liveMenuBar())

        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries.map(\.email), [
            "depi+11@eyouthlearning.com",
            "mohamed.hosam2310@gmail.com",
            "depi4.2025_45@teml.net",
            "deci+50@eyouthlearning.com",
            "depi+10@eyouthlearning.com"
        ])
        XCTAssertFalse(entries.contains { $0.rawTitle.contains("Add account") })
    }

    /// The safety property this whole design exists for.
    func testAccountEntriesNeverComeFromTheSignOutSubmenu() {
        let entries = ZoomAXSupport.switchAccountEntries(inMenuBar: liveMenuBar())

        // Switch account is the 5th item (index 4) of the Zoom application menu;
        // Sign out is the 6th (index 5). Every entry must sit under the former.
        for entry in entries {
            XCTAssertEqual(
                Array(entry.indexPath.prefix(3)),
                [1, 0, 4],
                "entry \(entry.rawTitle) must be scoped to the Switch account submenu"
            )
        }
        XCTAssertFalse(entries.contains { $0.indexPath.prefix(3) == [1, 0, 5] })
    }

    func testSignOutSubmenuAloneYieldsNoAccounts() {
        // A Zoom build that dropped Switch account must produce nothing at all,
        // never a fallback onto the identically titled sign-out list.
        let menuBar = Node(role: "AXMenuBar", children: [
            Node(role: "AXMenuBarItem", title: "Zoom Workplace", children: [
                Node(role: "AXMenu", children: [
                    Node(role: "AXMenuItem", title: "Sign out", enabled: true, children: [
                        Node(role: "AXMenu", children: [
                            accountItem("eyouth coordinator(depi+11@eyouthlearning.com)", active: true)
                        ])
                    ])
                ])
            ])
        ])

        XCTAssertTrue(ZoomAXSupport.switchAccountEntries(inMenuBar: menuBar).isEmpty)
        XCTAssertNil(ZoomAXSupport.activeAccount(inMenuBar: menuBar))
    }

    func testActiveAccountComesFromTheCheckmark() {
        let active = ZoomAXSupport.activeAccount(inMenuBar: liveMenuBar())
        XCTAssertEqual(active?.email, "depi+11@eyouthlearning.com")
        XCTAssertTrue(active?.isActive == true)
    }

    func testTwoCheckmarksReportNoActiveAccountRatherThanGuessing() {
        let menuBar = Node(role: "AXMenuBar", children: [
            Node(role: "AXMenuBarItem", title: "Zoom Workplace", children: [
                Node(role: "AXMenu", children: [
                    Node(role: "AXMenuItem", title: "Switch account", enabled: true, children: [
                        Node(role: "AXMenu", children: [
                            accountItem("A(a@example.com)", active: true),
                            accountItem("B(b@example.com)", active: true)
                        ])
                    ])
                ])
            ])
        ])

        XCTAssertNil(ZoomAXSupport.activeAccount(inMenuBar: menuBar))
    }

    func testAccountTitleParsingSplitsDisplayNameAndEmail() {
        let parsed = ZoomAXSupport.parseAccountTitle("eyouth coordinator(depi+11@eyouthlearning.com)")
        XCTAssertEqual(parsed.displayName, "eyouth coordinator")
        XCTAssertEqual(parsed.email, "depi+11@eyouthlearning.com")

        let noEmail = ZoomAXSupport.parseAccountTitle("Some Account")
        XCTAssertEqual(noEmail.displayName, "Some Account")
        XCTAssertNil(noEmail.email)
    }

    func testEmailMatchIsExactAndCaseInsensitive() {
        let entries = ZoomAXSupport.switchAccountEntries(inMenuBar: liveMenuBar())

        guard case .found(let entry) = ZoomAXSupport.matchAccount(
            identifier: "DEPI4.2025_45@TEML.NET",
            in: entries
        ) else {
            return XCTFail("Expected an exact email match")
        }
        XCTAssertEqual(entry.email, "depi4.2025_45@teml.net")
    }

    func testUnknownAccountIsNotFound() {
        let entries = ZoomAXSupport.switchAccountEntries(inMenuBar: liveMenuBar())
        XCTAssertEqual(ZoomAXSupport.matchAccount(identifier: "nobody@example.com", in: entries), .notFound)
    }

    /// Three of the captured accounts render the same display name, which is
    /// exactly why the email is the key and why a name match must abort.
    func testCollidingDisplayNamesAreReportedAsAmbiguous() {
        let entries = ZoomAXSupport.switchAccountEntries(inMenuBar: liveMenuBar())

        guard case .ambiguous(let matches) = ZoomAXSupport.matchAccount(
            identifier: "eyouth coordinator",
            in: entries
        ) else {
            return XCTFail("Three saved accounts share this display name; expected ambiguity")
        }
        XCTAssertEqual(matches.count, 3)
    }

    func testApplicationMenuItemIsLocatedStructurally() {
        let match = ZoomAXSupport.applicationMenuItem(titled: "Start meeting", inMenuBar: liveMenuBar())
        XCTAssertEqual(match?.indexPath, [1, 0, 3])
        XCTAssertEqual(match?.node.title, "Start meeting")

        XCTAssertNil(ZoomAXSupport.applicationMenuItem(titled: "Nonexistent", inMenuBar: liveMenuBar()))
    }

    func testMarkCharacterRecognition() {
        XCTAssertTrue(ZoomAXSupport.isActiveAccountMark("✓"))
        XCTAssertTrue(ZoomAXSupport.isActiveAccountMark(" ✓ "))
        XCTAssertFalse(ZoomAXSupport.isActiveAccountMark(nil))
        XCTAssertFalse(ZoomAXSupport.isActiveAccountMark(""))
        XCTAssertFalse(ZoomAXSupport.isActiveAccountMark("x"))
    }

    func testOnlyAccessibilityEvidenceProvesAMeeting() {
        let byTitle = ZoomAXSupport.classifyMeetingPresence(
            axWindowTitles: ["Zoom Workplace", "Zoom Meeting"],
            hasMeetingStructure: false,
            axHierarchyAvailable: true,
            location: .currentSpaceBackground
        )
        XCTAssertEqual(byTitle.state, .active)
        XCTAssertEqual(byTitle.evidence, ["ax-meeting-window-title"])

        let byStructure = ZoomAXSupport.classifyMeetingPresence(
            axWindowTitles: ["Zoom Workplace"],
            hasMeetingStructure: true,
            axHierarchyAvailable: true,
            location: .currentSpaceBackground
        )
        XCTAssertEqual(byStructure.state, .active)
    }

    func testZoomWithOnlyItsMainWindowIsNotInAMeeting() {
        let idle = ZoomAXSupport.classifyMeetingPresence(
            axWindowTitles: ["Zoom Workplace"],
            hasMeetingStructure: false,
            axHierarchyAvailable: true,
            location: .currentSpaceBackground
        )
        XCTAssertEqual(idle.state, .notActive)
        XCTAssertEqual(idle.evidenceDescription, "none")
    }

    /// Regression test for a false "Another Zoom meeting is already active".
    ///
    /// With Zoom's windows on another Space the Accessibility hierarchy is gone,
    /// and CoreGraphics cannot fill the gap: this app holds no Screen Recording
    /// permission, so every Zoom window name is empty and the off-Space heuristic
    /// scores the ordinary main window exactly like a meeting window. The honest
    /// answer is "unknown", never "active".
    func testOffSpaceZoomIsUnknownRatherThanAssumedToBeInAMeeting() {
        let offSpace = ZoomAXSupport.classifyMeetingPresence(
            axWindowTitles: [],
            hasMeetingStructure: false,
            axHierarchyAvailable: false,
            location: .otherSpaceOrFullscreen
        )
        XCTAssertEqual(offSpace.state, .unknown)
        XCTAssertFalse(offSpace.isActive)
        XCTAssertTrue(offSpace.isUnknown)
        XCTAssertEqual(offSpace.evidenceDescription, "none")
    }
}
