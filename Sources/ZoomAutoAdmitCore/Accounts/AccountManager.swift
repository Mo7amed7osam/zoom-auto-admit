import Foundation
import OSLog

public protocol ZoomCredentialValidating {
    func validate(email: String, password: String) -> Bool
}

public struct LocalZoomCredentialValidator: ZoomCredentialValidating {
    public init() {}
    public func validate(email: String, password: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !password.isEmpty
    }
}

public enum AccountManagerError: Error, LocalizedError, Equatable {
    case invalidDisplayName
    case loginFailed
    case duplicateEmail
    case accountNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidDisplayName: return "Display name is required"
        case .loginFailed: return "Login failed"
        case .duplicateEmail: return "That Zoom email is already saved"
        case .accountNotFound: return "Zoom account was not found"
        }
    }
}

public final class AccountManager {
    private let repository: AccountRepository
    private let keychain: KeychainStoring
    private let validator: ZoomCredentialValidating
    private let lock = NSRecursiveLock()
    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "accounts")

    public init(
        repository: AccountRepository = FileAccountRepository(),
        keychain: KeychainStoring = KeychainStorage(),
        validator: ZoomCredentialValidating = LocalZoomCredentialValidator()
    ) {
        self.repository = repository
        self.keychain = keychain
        self.validator = validator
    }

    public func accounts() throws -> [ZoomAccount] {
        lock.lock(); defer { lock.unlock() }
        let accounts = try repository.load().map { metadata in
            ZoomAccount(
                id: metadata.id,
                displayName: metadata.displayName,
                email: try keychain.value(accountID: metadata.id, secret: .email) ?? "",
                preferredEngine: metadata.preferredEngine
            )
        }
        for account in accounts {
            logger.info("[ACCOUNT] Loaded account \(account.displayName, privacy: .public)")
        }
        return accounts
    }

    @discardableResult
    public func add(_ draft: ZoomAccountDraft) throws -> ZoomAccount {
        lock.lock(); defer { lock.unlock() }
        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = draft.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { throw AccountManagerError.invalidDisplayName }
        guard validator.validate(email: email, password: draft.password) else {
            throw AccountManagerError.loginFailed
        }
        guard try !accounts().contains(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) else {
            throw AccountManagerError.duplicateEmail
        }

        let account = ZoomAccount(
            displayName: name,
            email: email,
            preferredEngine: draft.preferredEngine
        )
        try keychain.set(email, accountID: account.id, secret: .email)
        do {
            try keychain.set(draft.password, accountID: account.id, secret: .password)
            var metadata = try repository.load()
            metadata.append(.init(
                id: account.id,
                displayName: account.displayName,
                preferredEngine: account.preferredEngine
            ))
            try repository.save(metadata)
        } catch {
            try? keychain.remove(accountID: account.id, secret: .email)
            try? keychain.remove(accountID: account.id, secret: .password)
            throw error
        }
        logger.info("[ACCOUNT] Added account \(account.displayName, privacy: .public)")
        return account
    }

    public func update(_ account: ZoomAccount, password: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        var metadata = try repository.load()
        guard let index = metadata.firstIndex(where: { $0.id == account.id }) else {
            throw AccountManagerError.accountNotFound
        }
        let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { throw AccountManagerError.invalidDisplayName }
        guard try !accounts().contains(where: {
            $0.id != account.id && $0.email.caseInsensitiveCompare(email) == .orderedSame
        }) else { throw AccountManagerError.duplicateEmail }
        let credential = (password?.isEmpty == false ? password : nil) ??
            (try keychain.value(accountID: account.id, secret: .password)) ?? ""
        guard validator.validate(email: email, password: credential) else {
            throw AccountManagerError.loginFailed
        }
        metadata[index] = .init(
            id: account.id,
            displayName: name,
            preferredEngine: account.preferredEngine
        )
        try keychain.set(email, accountID: account.id, secret: .email)
        if let password, !password.isEmpty {
            try keychain.set(password, accountID: account.id, secret: .password)
        }
        try repository.save(metadata)
        logger.info("[ACCOUNT] Updated account \(account.displayName, privacy: .public)")
    }

    public func remove(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var metadata = try repository.load()
        guard metadata.contains(where: { $0.id == id }) else { throw AccountManagerError.accountNotFound }
        metadata.removeAll { $0.id == id }
        try repository.save(metadata)
        try keychain.remove(accountID: id, secret: .email)
        try keychain.remove(accountID: id, secret: .password)
        logger.info("[ACCOUNT] Removed account \(id.uuidString, privacy: .public)")
    }
}
