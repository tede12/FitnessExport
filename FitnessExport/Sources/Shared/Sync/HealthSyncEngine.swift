import CryptoKit
import FitnessSyncKit
import FitnessUI
import Foundation
@preconcurrency import Network
import os

private let syncLog = Logger(subsystem: "org.fitnessexport.FitnessExport", category: "sync")

struct SyncClientProgress: Sendable, Equatable {
    var streamTitle: String = ""
    var streamsDone: Int = 0
    var streamsTotal: Int = 0
    var recordsSent: Int = 0
    var bytesSent: Int = 0
}

actor HealthSyncEngine {
    private let exporter: HealthKitExporter
    private let identity: DeviceIdentity
    private let deviceName: String
    private let appVersion: String

    private var connection: SyncConnection?
    private var inbox: ControlInbox?
    private var readerTask: Task<Void, Never>?
    private var sequence: UInt64 = 0
    private var inFlight = 0
    private var window = 4
    private var compression: PayloadCompression = .lzfse
    private var progress = SyncClientProgress()
    private var onProgress: (@Sendable (SyncClientProgress) -> Void)?
    private var receivedBriefing: TrainingBriefing?

    init(
        exporter: HealthKitExporter,
        identity: DeviceIdentity,
        deviceName: String,
        appVersion: String
    ) {
        self.exporter = exporter
        self.identity = identity
        self.deviceName = deviceName
        self.appVersion = appVersion
    }

    func pair(with payload: PairingPayload) async throws -> PairedHost {
        guard payload.protocolVersion == SyncProtocolVersion.current else {
            throw SyncFailure(
                code: .protocolMismatch,
                message: AppLanguage.text("Il Mac usa una versione diversa dell'app. Aggiorna entrambe.")
            )
        }
        let agreement = AgreementKeyPair()
        let connection = makeConnection(
            host: payload.host, port: payload.port,
            sessionKey: SymmetricKey(data: payload.pairingKey)
        )
        try await connection.start()
        defer { Task { await connection.cancel() } }

        try await connection.sendMessage(
            SyncClientMessage.pair(
                deviceName: deviceName,
                signingPublicKey: identity.publicKeyData,
                agreementPublicKey: agreement.publicKeyData
            )
        )

        for try await message in await Self.messages(of: connection) {
            switch message {
            case .paired(let hostName, let hostAgreementKey):
                let sessionKey = try agreement.sessionKey(
                    withPeerPublicKeyData: hostAgreementKey
                )
                return PairedHost(
                    id: UUID().uuidString,
                    name: hostName,
                    host: payload.host,
                    port: payload.port,
                    sessionKey: sessionKey.withUnsafeBytes { Data($0) },
                    addedAt: Date()
                )
            case .failure(let failure):
                throw failure
            default:
                continue
            }
        }
        throw SyncFailure(code: .cancelled, message: AppLanguage.text("Associazione non completata."))
    }

    func takeBriefing() -> TrainingBriefing? {
        defer { receivedBriefing = nil }
        return receivedBriefing
    }

    func sync(
        with host: PairedHost,
        marks: [PlanMark] = [],
        onProgress: @escaping @Sendable (SyncClientProgress) -> Void
    ) async throws -> SyncSummary {
        self.onProgress = onProgress
        progress = SyncClientProgress()
        sequence = 0
        inFlight = 0
        let startedAt = Date()

        let connection = try await connect(to: host)
        self.connection = connection

        let inbox = ControlInbox()
        self.inbox = inbox
        readerTask = Task {
            do {
                for try await data in await connection.control {
                    await inbox.deliver(
                        try MessageFraming.decode(SyncServerMessage.self, from: data)
                    )
                }
                await inbox.finish()
            } catch {
                await inbox.fail(error)
            }
        }
        defer {
            readerTask?.cancel()
            readerTask = nil
            Task { await connection.cancel() }
            self.connection = nil
            self.inbox = nil
        }

        try await authenticate()
        let request = try await announceReady()
        window = max(1, request.maxInFlightBatches)
        compression = request.compression

        progress.streamsTotal = request.cursors.count
        for cursor in request.cursors {
            progress.streamTitle = cursor.stream.title
            report()
            do {
                try await run(cursor: cursor, request: request)
            } catch let failure as SyncFailure {

                syncLog.error(
                    "Stream \(cursor.stream.storageKey, privacy: .private): \(failure.message, privacy: .private)"
                )
                try await send(message: .streamFailed(failure))
            }
            progress.streamsDone += 1
            report()
        }

        try await drainAcks(untilInFlightAtMost: 0)

        if !marks.isEmpty {
            try await send(message: .planMarks(marks))
        }
        let summary = SyncSummary(
            upserted: progress.recordsSent, deleted: 0, bytesSent: progress.bytesSent,
            duration: Date().timeIntervalSince(startedAt)
        )
        try await send(message: .finished(summary))
        try await waitForCompletion()
        return summary
    }

    private func authenticate() async throws {
        guard case .authChallenge(let nonce) = try await nextServerMessage() else {
            throw SyncFailure(code: .unauthorized, message: AppLanguage.text("Il Mac non ha inviato la sfida."))
        }
        try await send(message: .authResponse(signature: try identity.sign(nonce)))
        guard case .authenticated = try await nextServerMessage() else {
            throw SyncFailure(
                code: .unauthorized,
                message: AppLanguage.text("Il Mac non riconosce questo iPhone. Rifai l'associazione.")
            )
        }
    }

    private func announceReady() async throws -> SyncRequest {
        let unavailable = try await exporter.requestAuthorization()
        let profile = await exporter.readProfile()
        try await send(
            message: .ready(
                SyncCatalogReport(
                    deviceName: deviceName, appVersion: appVersion,
                    unavailableMetricKeys: unavailable, profile: profile
                )
            )
        )
        guard case .syncRequest(let request) = try await nextServerMessage() else {
            throw SyncFailure(code: .internalError, message: AppLanguage.text("Il Mac non ha chiesto nulla."))
        }
        return request
    }

    private func run(cursor: SyncStreamCursor, request: SyncRequest) async throws {
        switch cursor.stream {
        case .quantity(let key):
            guard let metric = HealthCatalog.metric(forKey: key) else { return }
            try await runQuantity(metric: metric, cursor: cursor, request: request)
        case .category(let key):
            guard let metric = HealthCatalog.metric(forKey: key) else { return }
            try await runCategory(metric: metric, cursor: cursor, request: request)
        case .workouts:
            try await runWorkouts(cursor: cursor, request: request)
        case .routes:
            try await runRoutes(cursor: cursor, request: request)
        }
    }

    private func runQuantity(
        metric: MetricDescriptor, cursor: SyncStreamCursor, request: SyncRequest
    ) async throws {

        let pageSize =
            HealthCatalog.highVolumeKeys.contains(metric.key)
            ? min(request.maxBatchRecords, 5_000)
            : request.maxBatchRecords

        var anchor = cursor.anchor

        let first = anchor
        var pending = Task { [exporter] in
            try await exporter.nextQuantityPage(
                metric: metric, anchor: first, since: cursor.since, pageSize: pageSize
            )
        }

        while true {
            let page = try await pending.value
            let previousAnchor = anchor
            anchor = page.anchor

            if !page.isFinal {
                let next = anchor
                pending = Task { [exporter] in
                    try await exporter.nextQuantityPage(
                        metric: metric, anchor: next, since: cursor.since, pageSize: pageSize
                    )
                }
            }

            if !page.deleted.isEmpty {
                try await sendBatch(
                    stream: cursor.stream, kind: .delete, recordCount: page.deleted.count,
                    raw: SyncPayloadCodec.encodeDeletions(page.deleted),
                    anchor: previousAnchor, isFinal: false
                )
            }
            if !page.records.isEmpty {
                try await sendBatch(
                    stream: cursor.stream, kind: .upsert, recordCount: page.records.count,
                    raw: SyncPayloadCodec.encodeQuantities(page.records, sources: page.sources),
                    anchor: anchor, isFinal: page.isFinal
                )
            } else if page.isFinal, page.deleted.isEmpty {

                try await sendBatch(
                    stream: cursor.stream, kind: .upsert, recordCount: 0,
                    raw: SyncPayloadCodec.encodeQuantities([], sources: []),
                    anchor: anchor, isFinal: true
                )
            }

            if page.isFinal {
                pending.cancel()
                break
            }
        }
    }

    private func runCategory(
        metric: MetricDescriptor, cursor: SyncStreamCursor, request: SyncRequest
    ) async throws {
        var anchor = cursor.anchor
        let first = anchor
        var pending = Task { [exporter] in
            try await exporter.nextCategoryPage(
                metric: metric, anchor: first, since: cursor.since,
                pageSize: request.maxBatchRecords
            )
        }

        while true {
            let page = try await pending.value
            let previousAnchor = anchor
            anchor = page.anchor

            if !page.isFinal {
                let next = anchor
                pending = Task { [exporter] in
                    try await exporter.nextCategoryPage(
                        metric: metric, anchor: next, since: cursor.since,
                        pageSize: request.maxBatchRecords
                    )
                }
            }

            if !page.deleted.isEmpty {
                try await sendBatch(
                    stream: cursor.stream, kind: .delete, recordCount: page.deleted.count,
                    raw: SyncPayloadCodec.encodeDeletions(page.deleted),
                    anchor: previousAnchor, isFinal: false
                )
            }
            if !page.records.isEmpty || page.isFinal {
                try await sendBatch(
                    stream: cursor.stream, kind: .upsert, recordCount: page.records.count,
                    raw: SyncPayloadCodec.encodeCategories(page.records, sources: page.sources),
                    anchor: anchor, isFinal: page.isFinal
                )
            }

            if page.isFinal {
                pending.cancel()
                break
            }
        }
    }

    private func runWorkouts(cursor: SyncStreamCursor, request: SyncRequest) async throws {
        var anchor = cursor.anchor
        while true {
            let page = try await exporter.nextWorkoutPage(
                anchor: anchor, since: cursor.since, pageSize: 100
            )
            let previousAnchor = anchor
            anchor = page.anchor

            if !page.deleted.isEmpty {
                try await sendBatch(
                    stream: .workouts, kind: .delete, recordCount: page.deleted.count,
                    raw: SyncPayloadCodec.encodeDeletions(page.deleted),
                    anchor: previousAnchor, isFinal: false
                )
            }
            if !page.records.isEmpty || page.isFinal {
                try await sendBatch(
                    stream: .workouts, kind: .upsert, recordCount: page.records.count,
                    raw: try SyncPayloadCodec.encodeWorkouts(page.records),
                    anchor: anchor, isFinal: page.isFinal
                )
            }
            if page.isFinal { break }
        }
    }

    private func runRoutes(cursor: SyncStreamCursor, request: SyncRequest) async throws {
        var anchor = cursor.anchor
        while true {
            let page = try await exporter.nextRoutePage(
                cursor: anchor, since: cursor.since, maxPoints: 20_000
            )
            anchor = page.anchor
            if !page.records.isEmpty || page.isFinal {
                try await sendBatch(
                    stream: .routes, kind: .upsert,
                    recordCount: page.records.reduce(0) { $0 + $1.points.count },
                    raw: SyncPayloadCodec.encodeRoutes(page.records),
                    anchor: anchor, isFinal: page.isFinal
                )
            }
            if page.isFinal { break }
        }
    }

    private func sendBatch(
        stream: SyncStream, kind: BatchKind, recordCount: Int, raw: Data, anchor: Data?,
        isFinal: Bool
    ) async throws {
        guard let connection else {
            throw SyncFailure(code: .cancelled, message: AppLanguage.text("Connessione chiusa."))
        }
        let compressed = compression.compress(raw)
        sequence += 1
        let header = BatchHeader(
            sequence: sequence, stream: stream, kind: kind, recordCount: recordCount,
            payloadBytes: compressed.count, rawBytes: raw.count, compression: compression,
            anchor: anchor, isFinal: isFinal
        )
        try await connection.sendMessage(SyncClientMessage.batch(header))
        try await connection.sendPayload(compressed)

        inFlight += 1
        progress.recordsSent += recordCount
        progress.bytesSent += compressed.count
        report()

        if inFlight >= window {
            try await drainAcks(untilInFlightAtMost: window - 1)
        }
    }

    private func drainAcks(untilInFlightAtMost limit: Int) async throws {
        while inFlight > limit {
            let message = try await nextServerMessage()
            switch message {
            case .batchAck:
                inFlight -= 1
            case .failure(let failure):
                throw failure
            case .completed:
                inFlight = 0
                return
            default:
                continue
            }
        }
    }

    private func waitForCompletion() async throws {
        while true {
            let message = try await nextServerMessage()
            switch message {
            case .briefing(let briefing):
                receivedBriefing = briefing
            case .completed:
                return
            case .failure(let failure):
                throw failure
            default:
                continue
            }
        }
    }

    private func send(message: SyncClientMessage) async throws {
        guard let connection else {
            throw SyncFailure(code: .cancelled, message: AppLanguage.text("Connessione chiusa."))
        }
        try await connection.sendMessage(message)
    }

    private func nextServerMessage() async throws -> SyncServerMessage {
        guard let inbox else {
            throw SyncFailure(code: .cancelled, message: AppLanguage.text("Connessione chiusa."))
        }
        return try await inbox.next()
    }

    private func connect(to host: PairedHost) async throws -> SyncConnection {
        var lastError: Error?
        for attempt in 0..<2 {
            let connection = makeConnection(
                host: host.host, port: host.port, sessionKey: SymmetricKey(data: host.sessionKey)
            )
            do {
                try await connection.start()
                return connection
            } catch {
                lastError = error
                await connection.cancel()
                syncLog.notice(
                    "Connection to \(host.host, privacy: .private) failed (attempt \(attempt + 1))"
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw SyncFailure(
            code: .cancelled,
            message:
                AppLanguage.format(
                    "Non riesco a raggiungere %@ (%@). Controlla che l'app sia aperta sul Mac e che siate sulla stessa rete.",
                    host.name, host.host)
                + (lastError.map { " — \($0.localizedDescription)" } ?? "")
        )
    }

    private func makeConnection(host: String, port: UInt16, sessionKey: SymmetricKey)
        -> SyncConnection
    {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: 7444)!
        )
        return SyncConnection(
            to: endpoint, parameters: SecureTransport.parameters(sessionKey: sessionKey)
        )
    }

    private func report() {
        onProgress?(progress)
    }

    private static func messages(
        of connection: SyncConnection
    ) async -> AsyncThrowingStream<SyncServerMessage, Error> {
        let control = await connection.control
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in control {
                        continuation.yield(
                            try MessageFraming.decode(SyncServerMessage.self, from: data)
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor ControlInbox {
    private var buffered: [SyncServerMessage] = []
    private var waiter: CheckedContinuation<SyncServerMessage, Error>?
    private var terminalError: Error?
    private var isFinished = false

    func deliver(_ message: SyncServerMessage) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            buffered.append(message)
        }
    }

    func fail(_ error: Error) {
        terminalError = error
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: error)
        }
    }

    func finish() {
        isFinished = true
        if let waiter {
            self.waiter = nil
            waiter.resume(
                throwing: SyncFailure(code: .cancelled, message: AppLanguage.text("Il Mac ha chiuso la connessione."))
            )
        }
    }

    func next() async throws -> SyncServerMessage {
        if !buffered.isEmpty {
            return buffered.removeFirst()
        }
        if let terminalError { throw terminalError }
        if isFinished {
            throw SyncFailure(code: .cancelled, message: AppLanguage.text("Il Mac ha chiuso la connessione."))
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }
}
