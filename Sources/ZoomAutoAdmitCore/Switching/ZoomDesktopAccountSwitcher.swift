import Foundation
import OSLog
import ZoomAXSupport

public enum ZoomDesktopSwitchResult: Equatable {
    case success(alreadyActive: Bool)
    case failure(String)
}

public final class ZoomDesktopAccountSwitcher {
    private let automation: ZoomAutomating
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "account-switch")

    public init(
        automation: ZoomAutomating,
        timeout: TimeInterval = 45,
        pollInterval: TimeInterval = 0.5
    ) {
        self.automation = automation
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    public func availableAccounts() -> [AccountMenuEntry] {
        automation.readAccountMenu()?.entries ?? []
    }

    public func currentAccount() -> AccountMenuEntry? {
        automation.readAccountMenu()?.activeAccount
    }

    public func switchAccount(to account: ZoomAccount) -> ZoomDesktopSwitchResult {
        logger.info("[SWITCH] Switching Zoom account to \(account.displayName, privacy: .public)")
        guard let snapshot = automation.readAccountMenu() else {
            return .failure("Zoom's Switch account menu is unavailable")
        }
        switch ZoomAXSupport.matchAccount(identifier: account.email, in: snapshot.entries) {
        case .notFound:
            return .failure("No saved Desktop Zoom account matches \(account.email)")
        case .ambiguous(let entries):
            return .failure("\(entries.count) Desktop Zoom accounts match \(account.email)")
        case .found(let target):
            if target.isActive {
                logger.info("[SWITCH] Requested Zoom account is already active")
                return .success(alreadyActive: true)
            }
            automation.activateZoom()
            switch automation.selectAccount(target) {
            case .pressed:
                break
            case .rejected(let reason):
                return .failure(reason)
            }
            let deadline = automation.now().addingTimeInterval(timeout)
            repeat {
                if let active = automation.readAccountMenu()?.activeAccount,
                   active.email?.caseInsensitiveCompare(account.email) == .orderedSame {
                    logger.info("[SWITCH] Zoom account switch verified")
                    return .success(alreadyActive: false)
                }
                automation.sleep(pollInterval)
            } while automation.now() < deadline
            return .failure("Zoom did not confirm the requested account")
        }
    }
}
