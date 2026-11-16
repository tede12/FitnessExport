import CryptoKit
import Foundation

public struct PairRequest: Sendable {
    public let deviceName: String
    public let signingPublicKey: Data
    public let agreementPublicKey: Data

    public init(deviceName: String, signingPublicKey: Data, agreementPublicKey: Data) {
        self.deviceName = deviceName
        self.signingPublicKey = signingPublicKey
        self.agreementPublicKey = agreementPublicKey
    }
}

public enum PairingEnrollment {
    public static func enroll(
        request: PairRequest,
        hostAgreement: AgreementKeyPair,
        hostName: String,
        deviceID: String,
        pairedAt: Date
    ) throws -> (device: TrustedDevice, reply: SyncServerMessage) {
        let sessionKey = try hostAgreement.sessionKey(
            withPeerPublicKeyData: request.agreementPublicKey
        )
        let device = TrustedDevice(
            id: deviceID,
            name: request.deviceName,
            signingPublicKey: request.signingPublicKey,
            sessionKey: sessionKey.withUnsafeBytes { Data($0) },
            pairedAt: pairedAt
        )
        let reply = SyncServerMessage.paired(
            hostName: hostName,
            agreementPublicKey: hostAgreement.publicKeyData
        )
        return (device, reply)
    }
}
