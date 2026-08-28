import ApplicationServices
import XCTest
@testable import ZoomAXSupport

/// Zoom labels these controls with the action they perform, not the state they
/// are in. Reading "Mute" as "already muted" would leave a live microphone in a
/// meeting, so the mapping is pinned down here in both directions.
final class ZoomPreJoinTests: XCTestCase {
    private typealias Node = ZoomAXSupport.SnapshotNode

    private func button(
        title: String? = nil,
        description: String? = nil,
        value: String? = nil,
        help: String? = nil,
        enabled: Bool = true
    ) -> Node {
        Node(
            role: "AXButton",
            title: title,
            description: description,
            value: value,
            enabled: enabled,
            actions: ["AXPress"],
            help: help
        )
    }

    // MARK: State vocabulary

    func testMuteMeansTheMicrophoneIsCurrentlyLive() {
        XCTAssertEqual(ZoomAXSupport.toggleState(for: .microphone, text: "Mute"), .on)
        XCTAssertEqual(ZoomAXSupport.toggleState(for: .microphone, text: "mute my microphone"), .on)
    }

    func testUnmuteMeansTheMicrophoneIsAlreadyOff() {
        XCTAssertEqual(ZoomAXSupport.toggleState(for: .microphone, text: "Unmute"), .off)
        XCTAssertEqual(ZoomAXSupport.toggleState(for: .microphone, text: "Unmute my microphone"), .off)
    }

    /// The single most dangerous confusion: "unmute" contains "mute".
    func testUnmuteIsNeverReadAsMute() {
        for text in ["Unmute", "unmute audio", "UNMUTE MY MICROPHONE"] {
            XCTAssertEqual(
                ZoomAXSupport.toggleState(for: .microphone, text: text),
                .off,
                "\(text) must not be read as a live microphone"
            )
        }
    }

    /// Audio not joined means nothing is being transmitted, and pressing would
    /// turn audio *on*, so it counts as already-off and must not be pressed.
    func testJoinAudioCountsAsOff() {
        XCTAssertEqual(ZoomAXSupport.toggleState(for: .microphone, text: "Join Audio"), .off)
        XCTAssertEqual(ZoomAXSupport.toggleState(for: .microphone, text: "Join with Computer Audio"), .off)
    }

    func testCameraVocabulary() {
        XCTAssertEqual(ZoomAXSupport.toggleState(for: .camera, text: "Stop Video"), .on)
        XCTAssertEqual(ZoomAXSupport.toggleState(for: .camera, text: "Start Video"), .off)
        XCTAssertEqual(ZoomAXSupport.toggleState(for: .camera, text: "start my video"), .off)
    }

    func testUnrelatedTextSaysNothing() {
        XCTAssertNil(ZoomAXSupport.toggleState(for: .microphone, text: "Start Video"))
        XCTAssertNil(ZoomAXSupport.toggleState(for: .camera, text: "Mute"))
        XCTAssertNil(ZoomAXSupport.toggleState(for: .microphone, text: "Settings"))
        XCTAssertNil(ZoomAXSupport.toggleState(for: .microphone, text: ""))
    }

    func testContradictoryTextIsUnknown() {
        XCTAssertEqual(ZoomAXSupport.toggleState(for: .microphone, text: "Mute / Unmute"), .unknown)
    }

    // MARK: Control classification

    func testControlStateIsReadFromAnyAccessibleAttribute() {
        let fromDescription = ZoomAXSupport.preJoinControl(
            for: .microphone,
            node: button(description: "Mute"),
            indexPath: [0]
        )
        XCTAssertEqual(fromDescription?.state, .on)

        let fromHelp = ZoomAXSupport.preJoinControl(
            for: .camera,
            node: button(help: "Start Video"),
            indexPath: [1]
        )
        XCTAssertEqual(fromHelp?.state, .off)
    }

    /// Two attributes disagreeing is exactly where guessing is worst.
    func testDisagreeingAttributesProduceUnknown() {
        let control = ZoomAXSupport.preJoinControl(
            for: .microphone,
            node: button(title: "Mute", help: "Unmute"),
            indexPath: [0]
        )
        XCTAssertEqual(control?.state, .unknown)
    }

    func testControlWithoutPressActionIsNotAControl() {
        let node = Node(role: "AXButton", description: "Mute", actions: [])
        XCTAssertNil(ZoomAXSupport.preJoinControl(for: .microphone, node: node, indexPath: [0]))
    }

    // MARK: Start button

    func testStartButtonMatchesExactlyAndRejectsLookalikes() {
        XCTAssertNotNil(ZoomAXSupport.preJoinStartControl(node: button(title: "Start"), indexPath: [0]))
        XCTAssertNotNil(ZoomAXSupport.preJoinStartControl(node: button(title: "Start Meeting"), indexPath: [0]))
        XCTAssertNotNil(ZoomAXSupport.preJoinStartControl(node: button(title: "Join"), indexPath: [0]))

        // These must never be mistaken for the Start button.
        XCTAssertNil(ZoomAXSupport.preJoinStartControl(node: button(title: "Start Video"), indexPath: [0]))
        XCTAssertNil(ZoomAXSupport.preJoinStartControl(node: button(title: "Join Audio"), indexPath: [0]))
        XCTAssertNil(
            ZoomAXSupport.preJoinStartControl(node: button(title: "Join with Computer Audio"), indexPath: [0])
        )
        XCTAssertNil(ZoomAXSupport.preJoinStartControl(node: button(title: "Start recording"), indexPath: [0]))
    }

    // MARK: Whole preview

    private func previewWindow(
        microphone: String = "Mute",
        camera: String = "Stop Video",
        includeStart: Bool = true
    ) -> Node {
        var children = [
            button(description: microphone),
            button(description: camera)
        ]
        if includeStart { children.append(button(title: "Start")) }
        return Node(role: "AXWindow", title: "Mohamed Hosam's Zoom Meeting", children: children)
    }

    func testPreviewIsRecognisedStructurally() {
        let preview = ZoomAXSupport.preJoinPreview(inWindow: previewWindow(), windowIndexPath: [])
        XCTAssertNotNil(preview)
        XCTAssertEqual(preview?.microphone?.state, .on)
        XCTAssertEqual(preview?.camera?.state, .on)
        XCTAssertEqual(preview?.start?.matchedText, "Start")
        XCTAssertTrue(preview?.ambiguousKinds.isEmpty == true)
    }

    func testPreviewNeedsAStartButton() {
        XCTAssertNil(
            ZoomAXSupport.preJoinPreview(inWindow: previewWindow(includeStart: false), windowIndexPath: [])
        )
    }

    /// An in-meeting window must never be mistaken for the pre-join preview,
    /// or the automation would press things during a live call.
    func testInMeetingWindowIsNotAPreview() {
        let inMeeting = Node(role: "AXWindow", title: "Zoom Meeting", children: [
            button(description: "Mute"),
            button(description: "Stop Video"),
            button(title: "Start"),
            Node(role: "AXRow", identifier: ZoomAXSupport.waitingListIdentifier)
        ])
        XCTAssertNil(ZoomAXSupport.preJoinPreview(inWindow: inMeeting, windowIndexPath: []))
    }

    func testDuplicateControlsAreReportedAsAmbiguous() {
        let window = Node(role: "AXWindow", children: [
            button(description: "Mute"),
            button(description: "Unmute"),
            button(description: "Stop Video"),
            button(title: "Start")
        ])
        let preview = ZoomAXSupport.preJoinPreview(inWindow: window, windowIndexPath: [])
        XCTAssertEqual(preview?.ambiguousKinds, [.microphone])
        XCTAssertNil(preview?.microphone, "An ambiguous control must not be offered for pressing")
    }

    func testSeveralStartButtonsRefuseToPickOne() {
        let window = Node(role: "AXWindow", children: [
            button(description: "Mute"),
            button(description: "Stop Video"),
            button(title: "Start"),
            button(title: "Join")
        ])
        let preview = ZoomAXSupport.preJoinPreview(inWindow: window, windowIndexPath: [])
        XCTAssertNotNil(preview)
        XCTAssertNil(preview?.start)
    }

    func testAlreadyOffPreviewReportsOff() {
        let preview = ZoomAXSupport.preJoinPreview(
            inWindow: previewWindow(microphone: "Unmute", camera: "Start Video"),
            windowIndexPath: []
        )
        XCTAssertEqual(preview?.microphone?.state, .off)
        XCTAssertEqual(preview?.camera?.state, .off)
    }
}
