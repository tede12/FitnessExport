import FitnessSyncKit
import Foundation

final class KeychainTrustedDeviceStore: TrustedDeviceStore, @unchecked Sendable {
    private let service = "org.fitnessexport.sync.devices"

    init() {}

    func all() throws -> [TrustedDevice] {
        try Keychain.items(service: service)
            .compactMap { try? JSONDecoder().decode(TrustedDevice.self, from: $0.data) }
            .sorted { $0.pairedAt < $1.pairedAt }
    }

    func device(forSigningKey key: Data) throws -> TrustedDevice? {
        try all().first { $0.signingPublicKey == key }
    }

    func add(_ device: TrustedDevice) throws {
        try Keychain.set(try JSONEncoder().encode(device), service: service, account: device.id)
    }

    func remove(id: String) throws {
        Keychain.delete(service: service, account: id)
    }
}

enum HostKeyStore {
    private static let service = "org.fitnessexport.sync.host"
    private static let account = "agreement-key"

    static func loadOrCreateAgreementKey() -> AgreementKeyPair {
        if let data = try? Keychain.get(service: service, account: account),
            let pair = try? AgreementKeyPair(privateKeyData: data)
        {
            return pair
        }
        let pair = AgreementKeyPair()
        try? Keychain.set(pair.privateKeyData, service: service, account: account)
        return pair
    }
}
