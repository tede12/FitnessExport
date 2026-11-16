import CryptoKit
import FitnessSyncKit
import Foundation
@preconcurrency import Network
import XCTest

@testable import FitnessExportMac

final class SyncSessionIntegrationTests: XCTestCase {
    private var directory: URL!
    private var database: HealthDatabase!
    private var listener: SyncListener!
    private var phone: SyncConnection!
    private var mac: SyncConnection!
    private var identity: DeviceIdentity!
    private var store: InMemoryTrustedDeviceStore!

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        database = try HealthDatabase(url: directory.appendingPathComponent("test.sqlite"))

        identity = DeviceIdentity()
        let sessionKey = SymmetricKey(data: PairingCrypto.randomSecret())
        store = InMemoryTrustedDeviceStore()
        try store.add(
            TrustedDevice(
                id: "1", name: "iPhone di prova", signingPublicKey: identity.publicKeyData,
                sessionKey: sessionKey.withUnsafeBytes { Data($0) }, pairedAt: Date()
            )
        )

        listener = try SyncListener(
            parameters: SecureTransport.parameters(sessionKey: sessionKey), port: .any
        )
        let port = try await listener.start()
        let connections = await listener.connections
        let accepted = Task { () -> SyncConnection? in
            for await connection in connections { return connection }
            return nil
        }
        phone = SyncConnection(
            to: .hostPort(host: .ipv4(.loopback), port: port),
            parameters: SecureTransport.parameters(sessionKey: sessionKey)
        )
        try await phone.start()
        let connection = await accepted.value
        mac = try XCTUnwrap(connection)
    }

    override func tearDown() async throws {
        await phone?.cancel()
        await mac?.cancel()
        await listener?.cancel()
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testAFullSessionReachesTheDatabase() async throws {
        let session = SyncServerSession(
            connection: mac, store: store, database: database,
            hostName: "Mac di prova", historyStart: nil, onProgress: { _ in }
        )
        let running = Task { await session.run() }
        defer { running.cancel() }

        var inbound = await phone.control.makeAsyncIterator()
        func next() async throws -> SyncServerMessage {
            guard let data = try await inbound.next() else {
                throw XCTSkip("the Mac closed the connection")
            }
            return try MessageFraming.decode(SyncServerMessage.self, from: data)
        }

        guard case .authChallenge(let nonce) = try await next() else {
            return XCTFail("expected a challenge")
        }
        try await phone.sendMessage(
            SyncClientMessage.authResponse(signature: try identity.sign(nonce))
        )
        guard case .authenticated = try await next() else {
            return XCTFail("expected authentication to succeed")
        }

        try await phone.sendMessage(
            SyncClientMessage.ready(
                SyncCatalogReport(
                    deviceName: "iPhone di prova", appVersion: "1.0", unavailableMetricKeys: []
                )
            )
        )
        guard case .syncRequest(let request) = try await next() else {
            return XCTFail("expected a sync request")
        }
        XCTAssertFalse(request.cursors.isEmpty)

        let start = Date(timeIntervalSince1970: 1_773_298_500)
        let records = (0..<100).map { index in
            QuantityRecord(
                uuid: UUID(), start: start.addingTimeInterval(Double(index)),
                end: start.addingTimeInterval(Double(index)),
                value: Double(140 + index % 20), sourceIndex: 0
            )
        }
        let raw = SyncPayloadCodec.encodeQuantities(
            records, sources: [SourceRecord(bundleID: "com.apple.health", name: "Watch")]
        )
        let compressed = PayloadCompression.lzfse.compress(raw)
        try await phone.sendMessage(
            SyncClientMessage.batch(
                BatchHeader(
                    sequence: 1, stream: .quantity("heart_rate"), kind: .upsert,
                    recordCount: records.count, payloadBytes: compressed.count,
                    rawBytes: raw.count, compression: .lzfse, anchor: Data([7]), isFinal: true
                )
            )
        )
        try await phone.sendPayload(compressed)

        guard case .batchAck(let sequence) = try await next() else {
            return XCTFail("expected an acknowledgement")
        }
        XCTAssertEqual(sequence, 1)

        try await phone.sendMessage(
            SyncClientMessage.finished(
                SyncSummary(upserted: records.count, deleted: 0, bytesSent: compressed.count, duration: 1)
            )
        )

        var briefing: TrainingBriefing?
        var completed = false
        for _ in 0..<3 {
            switch try await next() {
            case .briefing(let received): briefing = received
            case .completed: completed = true
            default: continue
            }
            if completed { break }
        }
        XCTAssertTrue(completed, "expected completion")
        let delivered = try XCTUnwrap(briefing, "the phone must receive a briefing")

        XCTAssertLessThanOrEqual(
            delivered.generatedAt.timeIntervalSinceNow, 0,
            "the briefing is generated at the end of the session"
        )

        let stats = try await database.stats()
        XCTAssertEqual(stats.samples, records.count)
        let cursor = try await database.cursor(for: .quantity("heart_rate"))
        XCTAssertEqual(cursor, Data([7]))
    }
}
