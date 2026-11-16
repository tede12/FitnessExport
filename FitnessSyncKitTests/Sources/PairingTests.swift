import CryptoKit
import Foundation
import XCTest

@testable import FitnessSyncKit

final class PairingTests: XCTestCase {

    func testQRPayloadRoundTrip() throws {
        let payload = PairingPayload(
            hostName: "Example Mac",
            host: "192.0.2.1",
            port: 7444,
            pairingKey: PairingPayload.makePairingKey()
        )

        let decoded = try XCTUnwrap(PairingPayload(qrString: payload.qrString()))
        XCTAssertEqual(decoded, payload)
    }

    func testQRPayloadRejectsForeignScheme() {
        XCTAssertNil(PairingPayload(qrString: "https://example.com"))
        XCTAssertNil(PairingPayload(qrString: "fitnessexport://pair#non-base64!"))
    }

    func testPairingKeyIsThirtyTwoBytesAndUnique() {
        let first = PairingPayload.makePairingKey()
        let second = PairingPayload.makePairingKey()
        XCTAssertEqual(first.count, 32)
        XCTAssertNotEqual(first, second)
    }

    func testBothSidesDeriveTheSameSessionKey() throws {
        let hostAgreement = AgreementKeyPair()
        let phoneAgreement = AgreementKeyPair()
        let identity = DeviceIdentity()

        let (device, reply) = try PairingEnrollment.enroll(
            request: PairRequest(
                deviceName: "Example iPhone",
                signingPublicKey: identity.publicKeyData,
                agreementPublicKey: phoneAgreement.publicKeyData
            ),
            hostAgreement: hostAgreement,
            hostName: "MacBook",
            deviceID: "device-1",
            pairedAt: Date()
        )

        guard case .paired(let hostName, let hostPublicKey) = reply else {
            return XCTFail("risposta inattesa")
        }
        XCTAssertEqual(hostName, "MacBook")

        let phoneSide = try phoneAgreement.sessionKey(withPeerPublicKeyData: hostPublicKey)
        XCTAssertEqual(phoneSide.withUnsafeBytes { Data($0) }, device.sessionKey)
        XCTAssertEqual(device.sessionKey.count, 32)
    }

    func testChallengeSignatureVerifiesOnlyForTheRightNonce() throws {
        let identity = DeviceIdentity()
        let challenge = PairingCrypto.randomSecret()
        let signature = try identity.sign(challenge)

        XCTAssertTrue(
            PairingCrypto.verify(
                signature: signature, for: challenge, publicKeyData: identity.publicKeyData
            )
        )

        XCTAssertFalse(
            PairingCrypto.verify(
                signature: signature,
                for: PairingCrypto.randomSecret(),
                publicKeyData: identity.publicKeyData
            )
        )

        XCTAssertFalse(
            PairingCrypto.verify(
                signature: signature, for: challenge,
                publicKeyData: DeviceIdentity().publicKeyData
            )
        )
    }

    func testTrustedDeviceStoreLooksUpBySigningKey() throws {
        let store = InMemoryTrustedDeviceStore()
        let identity = DeviceIdentity()
        let device = TrustedDevice(
            id: "1", name: "iPhone", signingPublicKey: identity.publicKeyData,
            sessionKey: Data(repeating: 7, count: 32), pairedAt: Date()
        )

        try store.add(device)
        XCTAssertEqual(try store.device(forSigningKey: identity.publicKeyData), device)
        XCTAssertNil(try store.device(forSigningKey: DeviceIdentity().publicKeyData))

        try store.remove(id: "1")
        XCTAssertTrue(try store.all().isEmpty)
    }
}

final class FramingTests: XCTestCase {

    func testFrameReaderReassemblesAcrossChunkBoundaries() throws {
        let message = SyncServerMessage.authChallenge(nonce: Data(repeating: 1, count: 32))
        let frame = try MessageFraming.encode(message)

        var reader = FrameReader()

        for byte in frame.dropLast() {
            reader.append(Data([byte]))
            XCTAssertNil(try reader.next(), "un frame incompleto non deve mai essere consegnato")
        }
        reader.append(Data([frame.last!]))

        let result = try XCTUnwrap(try reader.next())
        XCTAssertEqual(result.kind, .control)
        XCTAssertEqual(
            try MessageFraming.decode(SyncServerMessage.self, from: result.payload), message
        )
    }

    func testFrameReaderSeparatesControlAndPayload() throws {
        let header = BatchHeader(
            sequence: 1, stream: .quantity("heart_rate"), kind: .upsert, recordCount: 3,
            payloadBytes: 4, rawBytes: 4, compression: .none, anchor: Data([9]), isFinal: true
        )
        var buffer = Data()
        buffer.append(try MessageFraming.encode(SyncClientMessage.batch(header)))
        buffer.append(try MessageFraming.encodePayload(Data([1, 2, 3, 4])))

        var reader = FrameReader()
        reader.append(buffer)

        let first = try XCTUnwrap(try reader.next())
        XCTAssertEqual(first.kind, .control)
        let second = try XCTUnwrap(try reader.next())
        XCTAssertEqual(second.kind, .payload)
        XCTAssertEqual(second.payload, Data([1, 2, 3, 4]))
        XCTAssertNil(try reader.next())
    }

    func testFrameReaderRejectsUnknownKind() {
        var reader = FrameReader()
        reader.append(Data([0xFF, 0, 0, 0, 0]))
        XCTAssertThrowsError(try reader.next())
    }

    func testOversizedPayloadIsRefused() {
        XCTAssertThrowsError(
            try MessageFraming.encodePayload(
                Data(count: MessageFraming.maxPayloadSize + 1)
            )
        )
    }
}

final class CatalogTests: XCTestCase {

    func testMetricKeysAreUnique() {
        let keys = HealthCatalog.metrics.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "le chiavi sono la primary key nel database")
    }

    func testIdentifiersAreUnique() {
        let identifiers = HealthCatalog.metrics.map(\.identifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testEveryHighVolumeKeyExistsInTheCatalog() {
        for key in HealthCatalog.highVolumeKeys {
            XCTAssertNotNil(HealthCatalog.metric(forKey: key), "chiave sconosciuta: \(key)")
        }
    }

    func testCategoryMetricsAreMarked() {
        let sleep = HealthCatalog.metric(forKey: "sleep_analysis")
        XCTAssertEqual(sleep?.isCategory, true)
        XCTAssertEqual(HealthCatalog.metric(forKey: "heart_rate")?.isCategory, false)
    }

    func testStreamStorageKeysDoNotCollide() {
        var keys: Set<String> = [SyncStream.workouts.storageKey, SyncStream.routes.storageKey]
        for metric in HealthCatalog.metrics {
            let stream: SyncStream =
                metric.isCategory ? .category(metric.key) : .quantity(metric.key)
            XCTAssertTrue(keys.insert(stream.storageKey).inserted, "collisione: \(stream.storageKey)")
        }
    }
}
