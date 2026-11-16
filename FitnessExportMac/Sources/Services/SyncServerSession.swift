import FitnessSyncKit
import FitnessUI
import Foundation
import os

private let sessionLog = Logger(subsystem: "org.fitnessexport.FitnessExportMac", category: "session")

struct SyncProgress: Sendable, Equatable {
    var deviceName: String
    var currentStream: String
    var upserted: Int
    var deleted: Int
    var bytesReceived: Int
    var isFinished: Bool
    var failure: String?

    init(
        deviceName: String = "", currentStream: String = "", upserted: Int = 0, deleted: Int = 0,
        bytesReceived: Int = 0, isFinished: Bool = false, failure: String? = nil
    ) {
        self.deviceName = deviceName
        self.currentStream = currentStream
        self.upserted = upserted
        self.deleted = deleted
        self.bytesReceived = bytesReceived
        self.isFinished = isFinished
        self.failure = failure
    }
}

actor SyncServerSession {
    private let connection: SyncConnection
    private let store: TrustedDeviceStore
    private let database: HealthDatabase
    private let hostName: String
    private let historyStart: Date?
    private let onProgress: @Sendable (SyncProgress) -> Void

    private var challenge = Data()
    private var device: TrustedDevice?
    private var progress = SyncProgress()
    private let startedAt = Date()

    init(
        connection: SyncConnection,
        store: TrustedDeviceStore,
        database: HealthDatabase,
        hostName: String,
        historyStart: Date?,
        onProgress: @escaping @Sendable (SyncProgress) -> Void
    ) {
        self.connection = connection
        self.store = store
        self.database = database
        self.hostName = hostName
        self.historyStart = historyStart
        self.onProgress = onProgress
    }

    func run() async {
        do {
            try await authenticate()
            try await negotiate()
            try await receiveBatches()
        } catch let failure as SyncFailure {
            await fail(failure)
        } catch {
            await fail(SyncFailure(code: .internalError, message: error.localizedDescription))
        }
        await connection.cancel()
        await database.finalizeSync()
    }

    private func authenticate() async throws {
        challenge = PairingCrypto.randomSecret()
        try await connection.sendMessage(SyncServerMessage.authChallenge(nonce: challenge))

        for try await payload in await connection.control {
            let message = try MessageFraming.decode(SyncClientMessage.self, from: payload)
            guard case .authResponse(let signature) = message else {
                throw SyncFailure(code: .unauthorized, message: AppLanguage.text("Attesa l'autenticazione."))
            }

            let matched = try store.all().first {
                PairingCrypto.verify(
                    signature: signature, for: challenge, publicKeyData: $0.signingPublicKey
                )
            }
            guard let matched else {
                throw SyncFailure(
                    code: .unauthorized, message: AppLanguage.text("Dispositivo sconosciuto o non autorizzato.")
                )
            }
            device = matched
            progress.deviceName = matched.name
            report()
            try await connection.sendMessage(SyncServerMessage.authenticated(hostName: hostName))
            return
        }
        throw SyncFailure(code: .cancelled, message: AppLanguage.text("Connessione chiusa prima dell'autenticazione."))
    }

    private func negotiate() async throws {
        for try await payload in await connection.control {
            let message = try MessageFraming.decode(SyncClientMessage.self, from: payload)
            guard case .ready(let report) = message else {
                throw SyncFailure(code: .internalError, message: AppLanguage.text("Atteso il catalogo del telefono."))
            }
            guard report.protocolVersion == SyncProtocolVersion.current else {
                throw SyncFailure(
                    code: .protocolMismatch,
                    message:
                        AppLanguage.format(
                            "Versioni di protocollo diverse (telefono %@, Mac %@). Aggiorna l'app.",
                            report.protocolVersion, SyncProtocolVersion.current)
                )
            }
            if let profile = report.profile {
                try? await database.saveProfile(profile)
                sessionLog.log(
                    "Profile updated: age \(profile.ageYears ?? -1, privacy: .private)"
                )
            }
            if !report.unavailableMetricKeys.isEmpty {
                sessionLog.notice(
                    "Unavailable phone metrics: \(report.unavailableMetricKeys.joined(separator: ", "), privacy: .private)"
                )
            }
            let request = try await makeRequest(excluding: Set(report.unavailableMetricKeys))
            try await connection.sendMessage(SyncServerMessage.syncRequest(request))
            return
        }
        throw SyncFailure(code: .cancelled, message: AppLanguage.text("Connessione chiusa durante la negoziazione."))
    }

    private func makeRequest(excluding unavailable: Set<String>) async throws -> SyncRequest {
        let stored = try await database.allCursors()
        var cursors: [SyncStreamCursor] = []

        for stream in [SyncStream.workouts, .routes] {
            cursors.append(
                SyncStreamCursor(
                    stream: stream, anchor: stored[stream.storageKey], since: historyStart
                )
            )
        }
        for metric in HealthCatalog.metrics where !unavailable.contains(metric.key) {
            let stream: SyncStream =
                metric.isCategory ? .category(metric.key) : .quantity(metric.key)
            cursors.append(
                SyncStreamCursor(
                    stream: stream, anchor: stored[stream.storageKey], since: historyStart
                )
            )
        }
        return SyncRequest(cursors: cursors)
    }

    private func receiveBatches() async throws {

        var payloads = await connection.payloads.makeAsyncIterator()

        for try await controlPayload in await connection.control {
            let message = try MessageFraming.decode(SyncClientMessage.self, from: controlPayload)
            switch message {
            case .batch(let header):
                guard let raw = try await payloads.next() else {
                    throw SyncFailure(
                        code: .payloadInvalid,
                        message: AppLanguage.format(
                            "Payload mancante per il batch %@.", header.sequence)
                    )
                }
                try await apply(header: header, payload: raw)
                try await connection.sendMessage(SyncServerMessage.batchAck(sequence: header.sequence))

            case .planMarks(let marks):

                for mark in marks {
                    try? await database.markPlan(
                        day: mark.day, slot: mark.slot, done: mark.done,
                        rpe: mark.rpe, note: mark.note
                    )
                }
                sessionLog.log("\(marks.count, privacy: .private) completion marks applied")

            case .streamFailed(let failure):

                sessionLog.error(
                    "Stream \(failure.stream?.storageKey ?? "?", privacy: .private) failed: \(failure.message, privacy: .private)"
                )
                progress.failure = failure.message
                report()

            case .finished(let summary):

                if let briefing = try? await BriefingBuilder.build(from: database) {
                    try? await connection.sendMessage(SyncServerMessage.briefing(briefing))
                }
                try await connection.sendMessage(SyncServerMessage.completed)
                progress.isFinished = true
                report()
                try? await database.recordRun(
                    deviceName: device?.name ?? "?", started: startedAt, finished: Date(),
                    upserted: progress.upserted, deleted: progress.deleted,
                    bytes: progress.bytesReceived, status: "ok"
                )
                sessionLog.log(
                    "Sync completed: \(summary.upserted, privacy: .private) record, \(summary.bytesSent, privacy: .private) byte"
                )
                return

            case .failure(let failure):
                throw failure

            case .pair, .authResponse, .ready:
                break
            }
        }
    }

    private func apply(header: BatchHeader, payload: Data) async throws {
        guard payload.count == header.payloadBytes else {
            throw SyncFailure(
                code: .payloadInvalid,
                message: AppLanguage.format(
                    "Batch %@: attesi %@ byte, ricevuti %@.", header.sequence,
                    header.payloadBytes, payload.count)
            )
        }
        let raw = try header.compression.decompress(payload, expectedByteCount: header.rawBytes)
        guard raw.count == header.rawBytes else {
            throw SyncFailure(
                code: .payloadInvalid,
                message: AppLanguage.format(
                    "Batch %@ corrotto dopo la decompressione.", header.sequence)
            )
        }

        progress.currentStream = header.stream.title
        progress.bytesReceived += payload.count

        if header.kind == .delete {
            let uuids = try SyncPayloadCodec.decodeDeletions(raw)
            let removed = try await database.applyDeletions(
                uuids, stream: header.stream, anchor: header.anchor
            )
            progress.deleted += removed
            report()
            return
        }

        switch header.stream {
        case .quantity(let key):
            let decoded = try SyncPayloadCodec.decodeQuantities(raw)
            progress.upserted += try await database.applyQuantities(
                decoded.records, sources: decoded.sources, metricKey: key,
                stream: header.stream, anchor: header.anchor
            )
        case .category(let key):
            let decoded = try SyncPayloadCodec.decodeCategories(raw)
            progress.upserted += try await database.applyCategories(
                decoded.records, sources: decoded.sources, metricKey: key,
                stream: header.stream, anchor: header.anchor
            )
        case .workouts:
            let workouts = try SyncPayloadCodec.decodeWorkouts(raw)
            progress.upserted += try await database.applyWorkouts(workouts, anchor: header.anchor)
        case .routes:
            let routes = try SyncPayloadCodec.decodeRoutes(raw)
            progress.upserted += try await database.applyRoutes(routes, anchor: header.anchor)
        }
        report()
    }

    private func fail(_ failure: SyncFailure) async {
        sessionLog.error("Session failed: \(failure.message, privacy: .private)")
        progress.failure = failure.message
        progress.isFinished = true
        report()
        try? await connection.sendMessage(SyncServerMessage.failure(failure))
        try? await database.recordRun(
            deviceName: device?.name ?? "?", started: startedAt, finished: Date(),
            upserted: progress.upserted, deleted: progress.deleted,
            bytes: progress.bytesReceived, status: failure.code.rawValue
        )
    }

    private func report() {
        onProgress(progress)
    }
}
