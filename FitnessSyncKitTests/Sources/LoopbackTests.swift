import CryptoKit
import Foundation
@preconcurrency import Network
import XCTest

@testable import FitnessSyncKit

final class LoopbackTests: XCTestCase {

    private func makePair(sessionKey: SymmetricKey) async throws -> (
        listener: SyncListener, client: SyncConnection, server: SyncConnection
    ) {
        let parameters = SecureTransport.parameters(sessionKey: sessionKey)
        let listener = try SyncListener(parameters: parameters, port: .any)
        let port = try await listener.start()

        let connections = await listener.connections
        let accepted = Task { () -> SyncConnection? in
            for await connection in connections { return connection }
            return nil
        }

        let client = SyncConnection(
            to: .hostPort(host: .ipv4(.loopback), port: port),
            parameters: SecureTransport.parameters(sessionKey: sessionKey)
        )
        try await client.start()

        guard let server = try await accepted.value else {
            throw XCTSkip("nessuna connessione accettata")
        }
        return (listener, client, server)
    }

    func testControlMessagesSurviveTheWire() async throws {
        let key = SymmetricKey(data: PairingCrypto.randomSecret())
        let (listener, client, server) = try await makePair(sessionKey: key)
        defer {
            Task {
                await client.cancel()
                await server.cancel()
                await listener.cancel()
            }
        }

        let nonce = PairingCrypto.randomSecret()
        try await server.sendMessage(SyncServerMessage.authChallenge(nonce: nonce))

        var received: SyncServerMessage?
        for try await data in await client.control {
            received = try MessageFraming.decode(SyncServerMessage.self, from: data)
            break
        }
        XCTAssertEqual(received, .authChallenge(nonce: nonce))
    }

    func testBatchHeaderAndPayloadArriveInOrderAndPaired() async throws {
        let key = SymmetricKey(data: PairingCrypto.randomSecret())
        let (listener, client, server) = try await makePair(sessionKey: key)
        defer {
            Task {
                await client.cancel()
                await server.cancel()
                await listener.cancel()
            }
        }

        let start = Date(timeIntervalSince1970: 1_773_298_500)
        let records = (0..<1_800).map { index in
            QuantityRecord(
                uuid: UUID(),
                start: start.addingTimeInterval(Double(index)),
                end: start.addingTimeInterval(Double(index)),
                value: Double(140 + index % 30),
                sourceIndex: 0
            )
        }
        let sources = [SourceRecord(bundleID: "com.apple.health", name: "Apple Watch")]
        let raw = SyncPayloadCodec.encodeQuantities(records, sources: sources)
        let compressed = PayloadCompression.lzfse.compress(raw)
        let header = BatchHeader(
            sequence: 1, stream: .quantity("heart_rate"), kind: .upsert,
            recordCount: records.count, payloadBytes: compressed.count, rawBytes: raw.count,
            compression: .lzfse, anchor: Data([1, 2, 3]), isFinal: true
        )

        try await client.sendMessage(SyncClientMessage.batch(header))
        try await client.sendPayload(compressed)

        var payloads = await server.payloads.makeAsyncIterator()
        var decodedHeader: BatchHeader?
        for try await data in await server.control {
            guard
                case .batch(let value) = try MessageFraming.decode(
                    SyncClientMessage.self, from: data
                )
            else { continue }
            decodedHeader = value
            break
        }

        let payload = try await payloads.next()
        let unwrappedHeader = try XCTUnwrap(decodedHeader)
        let unwrappedPayload = try XCTUnwrap(payload)

        XCTAssertEqual(unwrappedHeader, header)
        XCTAssertEqual(unwrappedPayload.count, header.payloadBytes)

        let restored = try unwrappedHeader.compression.decompress(
            unwrappedPayload, expectedByteCount: unwrappedHeader.rawBytes
        )
        let decoded = try SyncPayloadCodec.decodeQuantities(restored)
        XCTAssertEqual(decoded.records.count, records.count)
        XCTAssertEqual(decoded.records.map(\.uuid), records.map(\.uuid))
        XCTAssertEqual(decoded.records.map(\.value), records.map(\.value))
        XCTAssertEqual(decoded.sources, sources)
    }

    func testFullPairingAndAuthenticationHandshake() async throws {

        let pairingKey = PairingPayload.makePairingKey()
        let (listener, client, server) = try await makePair(
            sessionKey: SymmetricKey(data: pairingKey)
        )

        let hostAgreement = AgreementKeyPair()
        let phoneAgreement = AgreementKeyPair()
        let identity = DeviceIdentity()
        let store = InMemoryTrustedDeviceStore()

        try await client.sendMessage(
            SyncClientMessage.pair(
                deviceName: "iPhone di prova",
                signingPublicKey: identity.publicKeyData,
                agreementPublicKey: phoneAgreement.publicKeyData
            )
        )

        var enrolled: TrustedDevice?
        for try await data in await server.control {
            guard
                case .pair(let name, let signing, let agreement) = try MessageFraming.decode(
                    SyncClientMessage.self, from: data
                )
            else { continue }
            let (device, reply) = try PairingEnrollment.enroll(
                request: PairRequest(
                    deviceName: name, signingPublicKey: signing, agreementPublicKey: agreement
                ),
                hostAgreement: hostAgreement, hostName: "Mac di prova",
                deviceID: "1", pairedAt: Date()
            )
            try store.add(device)
            try await server.sendMessage(reply)
            enrolled = device
            break
        }

        var phoneSessionKey: Data?
        for try await data in await client.control {
            guard
                case .paired(_, let hostKey) = try MessageFraming.decode(
                    SyncServerMessage.self, from: data
                )
            else { continue }
            phoneSessionKey = try phoneAgreement.sessionKey(withPeerPublicKeyData: hostKey)
                .withUnsafeBytes { Data($0) }
            break
        }

        await client.cancel()
        await server.cancel()
        await listener.cancel()

        let device = try XCTUnwrap(enrolled)
        let sessionKey = try XCTUnwrap(phoneSessionKey)
        XCTAssertEqual(sessionKey, device.sessionKey)

        let (listener2, client2, server2) = try await makePair(
            sessionKey: SymmetricKey(data: sessionKey)
        )
        defer {
            Task {
                await client2.cancel()
                await server2.cancel()
                await listener2.cancel()
            }
        }

        let challenge = PairingCrypto.randomSecret()
        try await server2.sendMessage(SyncServerMessage.authChallenge(nonce: challenge))

        for try await data in await client2.control {
            guard
                case .authChallenge(let nonce) = try MessageFraming.decode(
                    SyncServerMessage.self, from: data
                )
            else { continue }
            try await client2.sendMessage(
                SyncClientMessage.authResponse(signature: try identity.sign(nonce))
            )
            break
        }

        var authenticated = false
        for try await data in await server2.control {
            guard
                case .authResponse(let signature) = try MessageFraming.decode(
                    SyncClientMessage.self, from: data
                )
            else { continue }
            authenticated = try store.all().contains {
                PairingCrypto.verify(
                    signature: signature, for: challenge, publicKeyData: $0.signingPublicKey
                )
            }
            break
        }
        XCTAssertTrue(authenticated, "il dispositivo arruolato deve riconnettersi da solo")
    }

    func testAWrongKeyNeverEstablishesASession() async throws {
        let parameters = SecureTransport.parameters(
            sessionKey: SymmetricKey(data: PairingCrypto.randomSecret())
        )
        let listener = try SyncListener(parameters: parameters, port: .any)
        let port = try await listener.start()
        defer { Task { await listener.cancel() } }

        let intruder = SyncConnection(
            to: .hostPort(host: .ipv4(.loopback), port: port),
            parameters: SecureTransport.parameters(
                sessionKey: SymmetricKey(data: PairingCrypto.randomSecret())
            )
        )

        let outcome = Task { () -> Bool in
            do {
                try await intruder.start()
                try await intruder.sendMessage(SyncClientMessage.authResponse(signature: Data()))
                for try await _ in await intruder.control { return true }
                return false
            } catch {
                return false
            }
        }

        try await Task.sleep(nanoseconds: 2_000_000_000)
        await intruder.cancel()

        let reachedTheOtherSide = await outcome.value
        XCTAssertFalse(reachedTheOtherSide, "una chiave sbagliata non deve mai aprire il canale")
    }
}
