import CryptoKit
import Foundation

public struct DeviceIdentity: Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey

    public var publicKeyData: Data { privateKey.publicKey.rawRepresentation }
    public var privateKeyData: Data { privateKey.rawRepresentation }

    public init() {
        privateKey = Curve25519.Signing.PrivateKey()
    }

    public init(privateKeyData: Data) throws {
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
    }

    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data)
    }
}

public struct AgreementKeyPair: Sendable {
    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    public var publicKeyData: Data { privateKey.publicKey.rawRepresentation }
    public var privateKeyData: Data { privateKey.rawRepresentation }

    public init() {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    public init(privateKeyData: Data) throws {
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
    }

    public func sessionKey(withPeerPublicKeyData peerKeyData: Data) throws -> SymmetricKey {
        try PairingCrypto.deriveSessionKey(
            localAgreementPrivateKey: privateKey,
            remoteAgreementPublicKeyData: peerKeyData,
            salt: PairingCrypto.sessionSalt,
            info: PairingCrypto.sessionInfo
        )
    }
}

public enum PairingCrypto {

    public static let sessionSalt = Data("fitnessexport.sync.v1".utf8)
    public static let sessionInfo = Data("health-sync-channel".utf8)

    public static func verify(signature: Data, for data: Data, publicKeyData: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            return false
        }
        return key.isValidSignature(signature, for: data)
    }

    public static func deriveSessionKey(
        localAgreementPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        remoteAgreementPublicKeyData: Data,
        salt: Data,
        info: Data
    ) throws -> SymmetricKey {
        let remote = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: remoteAgreementPublicKeyData
        )
        let shared = try localAgreementPrivateKey.sharedSecretFromKeyAgreement(with: remote)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        )
    }

    public static func randomSecret(byteCount: Int = 32) -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes ha fallito: \(status)")
        return Data(bytes)
    }
}
