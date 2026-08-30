import AppKit
import SwiftUI
import ZoomAutoAdmitCore

@MainActor
final class AccountWindowController: NSWindowController {
    let model: AccountManagementViewModel

    init(manager: AccountManager) {
        model = AccountManagementViewModel(manager: manager)
        let hosting = NSHostingController(rootView: AccountListView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Zoom Accounts"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 600, height: 390)); window.center()
        super.init(window: window); window.isReleasedWhenClosed = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present(addAccount: Bool = false, editing account: ZoomAccount? = nil) {
        model.reload()
        if let account { model.edit(account) } else if addAccount { model.addAccount() }
        showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
}
