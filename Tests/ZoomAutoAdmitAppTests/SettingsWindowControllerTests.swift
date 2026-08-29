import AppKit
import XCTest
@testable import ZoomAutoAdmitApp

final class SettingsWindowControllerTests: XCTestCase {
    func testAPIKeyControlsLiveInsideScrollableSettingsContent() throws {
        let controller = SettingsWindowController()
        let scrollView = try XCTUnwrap(controller.window?.contentView as? NSScrollView)
        let documentView = try XCTUnwrap(scrollView.documentView)

        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertNotNil(findView(identifier: "openRouterAPIKey", in: documentView) as? NSSecureTextField)
        XCTAssertNotNil(findView(identifier: "openRouterModel", in: documentView) as? NSTextField)
        XCTAssertTrue(allLabels(in: documentView).contains("AI attendance matching"))
        XCTAssertTrue(allLabels(in: documentView).contains("OpenRouter API key"))
    }

    private func findView(identifier: String, in root: NSView) -> NSView? {
        if root.identifier?.rawValue == identifier { return root }
        return root.subviews.lazy.compactMap { self.findView(identifier: identifier, in: $0) }.first
    }

    private func allLabels(in root: NSView) -> [String] {
        let own = (root as? NSTextField).map { [$0.stringValue] } ?? []
        return own + root.subviews.flatMap(allLabels(in:))
    }
}
