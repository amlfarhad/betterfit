import Foundation
import Security

public struct OAuthTokens: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    /// Empty means unknown or no scopes returned; it never implies full consent.
    public let grantedScopes: [String]

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, grantedScopes: [String]) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.grantedScopes = grantedScopes
    }

    public var description: String { "OAuthTokens(redacted)" }
    public var debugDescription: String { description }
}

/// Operations are synchronous so the owning token actor can persist or remove
/// credentials without yielding between its generation check and the write.
public protocol OAuthTokenStore: Sendable {
    func load() throws -> OAuthTokens?
    func save(_ tokens: OAuthTokens) throws
    func remove() throws
}

public struct KeychainTokenStore: OAuthTokenStore {
    private let service: String
    private let account: String

    public init(clientID: String, service: String = "form.google-health.oauth") {
        self.service = service; self.account = clientID
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func load() throws -> OAuthTokens? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data),
              !tokens.accessToken.isEmpty, tokens.expiresAt.timeIntervalSince1970.isFinite else {
            throw OAuthError.secureStorageUnavailable
        }
        return tokens
    }

    public func save(_ tokens: OAuthTokens) throws {
        guard let data = try? JSONEncoder().encode(tokens) else { throw OAuthError.secureStorageUnavailable }
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(values) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw OAuthError.secureStorageUnavailable }
        } else if status != errSecSuccess {
            throw OAuthError.secureStorageUnavailable
        }
    }

    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OAuthError.secureStorageUnavailable }
    }
}
