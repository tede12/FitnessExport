import Foundation
import Security

struct GarminSession: Codable, Equatable, Sendable {
    var oauthToken: String
    var oauthTokenSecret: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var displayName: String?

    var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-60)
    }
}

struct GarminSessionStore: Sendable {
    private let service: String
    private let account = "garmin.connect.session.v2"

    init(service: String = Bundle.main.bundleIdentifier ?? "FitnessExport") {
        self.service = service
    }

    func load() -> GarminSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(GarminSession.self, from: data)
    }

    func save(_ session: GarminSession) throws {
        try delete()
        var query = baseQuery
        query[kSecValueData as String] = try JSONEncoder().encode(session)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw IntervalsCredentialsStore.KeychainError(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IntervalsCredentialsStore.KeychainError(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
