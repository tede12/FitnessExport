import FitnessUI
import Foundation
import Security

struct IntervalsCredentials: Equatable, Sendable {
    var athleteID: String
    var apiKey: String

    var isConfigured: Bool {
        !athleteID.trimmingCharacters(in: .whitespaces).isEmpty && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

struct IntervalsCredentialsStore: Sendable {
    private let service: String

    private let defaultsSuite: String?
    private let account = "intervals.icu.apiKey"
    private let athleteIDKey = "intervals.icu.athleteID"

    init(service: String = Bundle.main.bundleIdentifier ?? "FitnessExport", defaultsSuite: String? = nil) {
        self.service = service
        self.defaultsSuite = defaultsSuite
    }

    private var defaults: UserDefaults {
        defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    func load() -> IntervalsCredentials {
        IntervalsCredentials(
            athleteID: defaults.string(forKey: athleteIDKey) ?? "",
            apiKey: readAPIKey() ?? ""
        )
    }

    func save(_ credentials: IntervalsCredentials) throws {
        try writeAPIKey(credentials.apiKey.trimmingCharacters(in: .whitespaces))
        defaults.set(credentials.athleteID.trimmingCharacters(in: .whitespaces), forKey: athleteIDKey)
    }

    func clear() throws {
        try writeAPIKey("")
        defaults.removeObject(forKey: athleteIDKey)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func readAPIKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeAPIKey(_ apiKey: String) throws {
        let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError(status: deleteStatus)
        }
        guard !apiKey.isEmpty else { return }

        var query = baseQuery
        query[kSecValueData as String] = Data(apiKey.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            AppLanguage.format("Impossibile salvare nel Keychain (codice %@).", status)
        }
    }
}
