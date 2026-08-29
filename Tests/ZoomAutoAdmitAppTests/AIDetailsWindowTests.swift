import AppKit
import Foundation
import XCTest
@testable import ZoomAutoAdmitApp
import ZoomAutoAdmitCore

/// The AI Details window exists to answer "was this name even sent?". A window
/// that comes up blank answers nothing, so both halves are covered here: the
/// transcript text, and the view that has to render it.
final class AIDetailsWindowTests: XCTestCase {
    private func exchange() -> OpenRouterClient.Exchange {
        let request = AIMatchRequest(
            students: [
                .init(id: "s0", officialName: "RAFEEK MAGDY GERGES SALIB"),
                .init(id: "s1", officialName: "عبير محمد أحمد")
            ],
            observedNames: [
                .init(id: "z0", displayName: "رفيق"),
                .init(id: "z1", displayName: "Abeer")
            ]
        )
        return OpenRouterClient.Exchange(
            request: request,
            prompt: OpenRouterClient.prompt(for: request),
            rawResponse: #"{"matches":[{"student_id":"s0","observed_name_id":"z0","confidence":0.88}]}"#,
            response: AIMatchResponse(
                matches: [.init(studentID: "s0", observedNameID: "z0", confidence: 0.88)]
            ),
            httpStatus: 200,
            attempts: 1
        )
    }

    func testReportShowsEverySentNameAndTheRawReply() {
        let report = AttendanceWindowController.aiDetailsReport(
            exchange: exchange(),
            summary: nil,
            model: "openai/gpt-4o-mini"
        )

        XCTAssertTrue(report.contains("openai/gpt-4o-mini"))
        XCTAssertTrue(report.contains("Students sent (2):"))
        XCTAssertTrue(report.contains("[s0] RAFEEK MAGDY GERGES SALIB"))
        XCTAssertTrue(report.contains("[s1] عبير محمد أحمد"))
        XCTAssertTrue(report.contains("Zoom names sent (2):"))
        XCTAssertTrue(report.contains("[z0] رفيق"))
        XCTAssertTrue(report.contains("[z1] Abeer"))
        // The prompt and the verbatim reply, so a silent drop is visible.
        XCTAssertTrue(report.contains("Prompt:"))
        XCTAssertTrue(report.contains("RESPONSE RECEIVED"))
        XCTAssertTrue(report.contains("HTTP 200, attempts: 1"))
        XCTAssertTrue(report.contains(#""observed_name_id":"z0""#))
    }

    func testReportStillSaysSomethingWhenNothingCameBack() {
        let request = AIMatchRequest(
            students: [.init(id: "s0", officialName: "Omar Khaled")],
            observedNames: [.init(id: "z0", displayName: "Galaxy S23")]
        )
        let failed = OpenRouterClient.Exchange(
            request: request,
            prompt: OpenRouterClient.prompt(for: request),
            error: .noAPIKey
        )

        let report = AttendanceWindowController.aiDetailsReport(
            exchange: failed,
            summary: nil,
            model: "openai/gpt-4o-mini"
        )

        XCTAssertTrue(report.contains("[s0] Omar Khaled"))
        XCTAssertTrue(report.contains("[z0] Galaxy S23"))
        XCTAssertTrue(report.contains("Error:"))
        XCTAssertTrue(report.contains("(nothing came back)"))
    }

    /// The window was blank because a zero-frame NSTextView lays out no glyphs.
    func testDetailsViewActuallyLaysOutItsText() throws {
        let frame = NSRect(x: 0, y: 0, width: 700, height: 560)
        let report = AttendanceWindowController.aiDetailsReport(
            exchange: exchange(),
            summary: nil,
            model: "openai/gpt-4o-mini"
        )

        let scroll = AttendanceWindowController.makeTextView(body: report, frame: frame)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)

        XCTAssertEqual(text.string, report)

        // The blank window was a zero-sized document view inside the scroller:
        // the text existed, it just had nowhere to be drawn.
        let container = try XCTUnwrap(text.textContainer)
        XCTAssertEqual(container.size.width, scroll.contentSize.width, accuracy: 0.5)
        XCTAssertEqual(text.frame.width, scroll.contentSize.width, accuracy: 0.5)
        XCTAssertGreaterThan(text.frame.height, 0)

        let layout = try XCTUnwrap(text.layoutManager)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        XCTAssertGreaterThan(used.width, 0)
        XCTAssertGreaterThan(used.height, 0)
    }
}
