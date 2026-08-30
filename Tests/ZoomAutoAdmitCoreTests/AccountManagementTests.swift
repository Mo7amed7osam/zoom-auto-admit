import Foundation
import XCTest
import ZoomAXSupport
@testable import ZoomAutoAdmitCore

final class AccountManagementTests: XCTestCase {
    func testAddRetrieveAndRemoveAccount() throws {
        let repository = MemoryAccountRepository()
        let keychain = MemoryKeychain()
        let manager = AccountManager(repository: repository, keychain: keychain)

        let added = try manager.add(.init(
            displayName: "Teacher",
            email: "teacher@example.com",
            password: "secret",
            preferredEngine: .auto
        ))

        XCTAssertEqual(try manager.accounts(), [added])
        try manager.remove(id: added.id)
        XCTAssertEqual(try manager.accounts(), [])
        XCTAssertNil(try keychain.value(accountID: added.id, secret: .password))
    }

    func testPasswordAndEmailAreNeverWrittenToAccountMetadataFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoomAccountTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("accounts.json")
        let manager = AccountManager(
            repository: FileAccountRepository(location: file),
            keychain: MemoryKeychain()
        )

        _ = try manager.add(.init(
            displayName: "Teacher",
            email: "private@example.com",
            password: "never-write-this",
            preferredEngine: .desktop
        ))

        let contents = try String(contentsOf: file)
        XCTAssertFalse(contents.contains("private@example.com"))
        XCTAssertFalse(contents.contains("never-write-this"))
        XCTAssertTrue(contents.contains("Teacher"))
    }

    func testEditAccountUpdatesMetadataAndKeychainEmail() throws {
        let repository = MemoryAccountRepository()
        let keychain = MemoryKeychain()
        let manager = AccountManager(repository: repository, keychain: keychain)
        var account = try manager.add(.init(
            displayName: "Teacher",
            email: "old@example.com",
            password: "secret",
            preferredEngine: .desktop
        ))
        account.displayName = "Coordinator"
        account.email = "new@example.com"
        account.preferredEngine = .web

        try manager.update(account)

        XCTAssertEqual(try manager.accounts(), [account])
        XCTAssertEqual(try keychain.value(accountID: account.id, secret: .email), "new@example.com")
        XCTAssertEqual(try keychain.value(accountID: account.id, secret: .password), "secret")
    }

    func testAllocatorUsesDesktopWhenAvailableAndWebWhenBusy() {
        let account = ZoomAccount(displayName: "Teacher", email: "teacher@example.com")
        let url = URL(string: "https://zoom.us/j/123456789")!
        let allocator = ZoomSessionAllocator()
        let first = SessionRequest(account: account, meetingURL: url, startTime: Date())
        let second = SessionRequest(account: account, meetingURL: url, startTime: Date())

        XCTAssertEqual(allocator.allocate(first, desktopHasActiveMeeting: false), .desktop)
        XCTAssertEqual(allocator.allocate(second, desktopHasActiveMeeting: true), .web)
        allocator.release(first, engine: .desktop)
    }

    func testExplicitWebPreferenceUsesIsolatedWebEngine() {
        let account = ZoomAccount(
            displayName: "Teacher", email: "teacher@example.com", preferredEngine: .web
        )
        let request = SessionRequest(
            account: account,
            meetingURL: URL(string: "https://zoom.us/j/123456789")!,
            startTime: Date()
        )
        XCTAssertEqual(ZoomSessionAllocator().allocate(request, desktopHasActiveMeeting: false), .web)
    }

    func testWebProfilesAreStableAndIsolatedPerAccount() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoomWebProfiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ZoomWebAccountManager(profilesRoot: root, browserCandidates: [])
        let first = ZoomAccount(displayName: "First", email: "first@example.com")
        let second = ZoomAccount(displayName: "Second", email: "second@example.com")

        let firstPath = try manager.profileDirectory(for: first)
        XCTAssertEqual(firstPath, try manager.profileDirectory(for: first))
        XCTAssertNotEqual(firstPath, try manager.profileDirectory(for: second))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPath.path))
    }

    func testDesktopSwitcherSelectsAndVerifiesRequestedAccount() {
        let automation = SwitcherAutomation()
        let account = ZoomAccount(displayName: "Teacher", email: "teacher@example.com")

        let result = ZoomDesktopAccountSwitcher(
            automation: automation, timeout: 2, pollInterval: 0.1
        ).switchAccount(to: account)

        XCTAssertEqual(result, .success(alreadyActive: false))
        XCTAssertEqual(automation.selectedEmail, account.email)
        XCTAssertEqual(automation.readAccountMenu()?.activeAccount?.email, account.email)
    }
}

private final class MemoryAccountRepository: AccountRepository {
    var records: [ZoomAccountMetadata] = []
    func load() throws -> [ZoomAccountMetadata] { records }
    func save(_ accounts: [ZoomAccountMetadata]) throws { records = accounts }
}

private final class MemoryKeychain: KeychainStoring {
    private var values: [String: String] = [:]
    func set(_ value: String, accountID: UUID, secret: AccountSecret) throws {
        values["\(accountID).\(secret.rawValue)"] = value
    }
    func value(accountID: UUID, secret: AccountSecret) throws -> String? {
        values["\(accountID).\(secret.rawValue)"]
    }
    func remove(accountID: UUID, secret: AccountSecret) throws {
        values.removeValue(forKey: "\(accountID).\(secret.rawValue)")
    }
}

private final class SwitcherAutomation: ZoomAutomating {
    private var activeEmail = "other@example.com"
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var selectedEmail: String?

    func isAccessibilityTrusted() -> Bool { true }
    func zoomProcess() -> ZoomProcess? { ZoomProcess(pid: 42, bundleIdentifier: "us.zoom.xos") }
    func launchZoom() -> Bool { true }
    func readAccountMenu() -> ZoomAccountSnapshot? {
        let entries = ["other@example.com", "teacher@example.com"].enumerated().map { index, email in
            AccountMenuEntry(
                rawTitle: "Teacher(\(email))",
                displayName: "Teacher",
                email: email,
                isActive: email == activeEmail,
                enabled: true,
                indexPath: [0, index]
            )
        }
        return ZoomAccountSnapshot(entries: entries, activeAccount: entries.first(where: \.isActive))
    }
    func selectAccount(_ entry: AccountMenuEntry) -> AccountSelectionOutcome {
        selectedEmail = entry.email
        activeEmail = entry.email ?? activeEmail
        return .pressed
    }
    func meetingPresence(for process: ZoomProcess) -> MeetingPresence {
        ZoomAXSupport.classifyMeetingPresence(
            axWindowTitles: ["Zoom Workplace"],
            hasMeetingStructure: false,
            axHierarchyAvailable: true,
            location: .currentSpaceBackground
        )
    }
    func startMeeting(_ meeting: MeetingReference) -> MeetingStartOutcome { .requested(method: "test") }
    func activateZoom() {}
    func now() -> Date { clock }
    func sleep(_ interval: TimeInterval) { clock = clock.addingTimeInterval(interval) }
}
