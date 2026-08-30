import Foundation
import Security

public enum AccountSecret: String {
    case email
    case password
}

public protocol KeychainStoring {
    func set(_ value: String, accountID: UUID, secret: AccountSecret) throws
    func value(accountID: UUID, secret: AccountSecret) throws -> String?
    func remove(accountID: UUID, secret: AccountSecret) throws
}

public enum KeychainStorageError: Error, LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): return "Keychain operation failed (\(status))"
        case .invalidData: return "Keychain returned invalid credential data"
        }
    }
}

public final class KeychainStorage: KeychainStoring {
    private let service: String

    public init(service: String = "com.mohamedhosam.ZoomAutoAdmit.accounts") {
        self.service = service
    }

    public func set(_ value: String, accountID: UUID, secret: AccountSecret) throws {
        let key = key(accountID: accountID, secret: secret)
        let data = Data(value.utf8)
        let query = baseQuery(key: key)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData] = data
            addition[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainStorageError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainStorageError.unexpectedStatus(status)
        }
    }

    public func value(accountID: UUID, secret: AccountSecret) throws -> String? {
        var query = baseQuery(key: key(accountID: accountID, secret: secret))
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStorageError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainStorageError.invalidData
        }
        return value
    }

    public func remove(accountID: UUID, secret: AccountSecret) throws {
        let status = SecItemDelete(baseQuery(key: key(accountID: accountID, secret: secret)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStorageError.unexpectedStatus(status)
        }
    }

    private func key(accountID: UUID, secret: AccountSecret) -> String {
        "\(accountID.uuidString).\(secret.rawValue)"
    }

    private func baseQuery(key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
    }
}
