import CryptoKit
import FitnessSyncKit
import FitnessUI
import Foundation
@preconcurrency import Network
import Observation
import os

private let hostLog = Logger(subsystem: "org.fitnessexport.FitnessExportMac", category: "host")

@MainActor
@Observable
final class SyncHost {
    enum Status: Equatable, Sendable {
        case idle
        case pairing
        case listening
        case syncing
    }

    private(set) var status: Status = .idle
    private(set) var devices: [TrustedDevice] = []
    private(set) var pairingPayload: PairingPayload?
    private(set) var advertisedHost = ""
    private(set) var activeDevice: TrustedDevice?
    private(set) var progress: SyncProgress?
    private(set) var stats: HealthDatabase.Stats?
    private(set) var lastSyncAt: Date?

    private(set) var listenFailure: String?
    private(set) var log: [String] = []

    private(set) var briefing: TrainingBriefing?

    let hostName: String
    let port: UInt16

    var historyStart: Date?

    private let nwPort: NWEndpoint.Port
    private let agreement: AgreementKeyPair
    private let store: TrustedDeviceStore
    private let database: HealthDatabase

    private var listener: SyncListener?
    private var acceptTask: Task<Void, Never>?

    init(
        hostName: String = HostIdentity().hostName,
        port: UInt16 = 7445,
        store: TrustedDeviceStore = KeychainTrustedDeviceStore(),
        database: HealthDatabase,
        agreement: AgreementKeyPair? = nil
    ) {
        self.hostName = hostName
        self.port = port
        self.nwPort = NWEndpoint.Port(rawValue: port) ?? 7444
        self.store = store
        self.database = database
        self.agreement = agreement ?? HostKeyStore.loadOrCreateAgreementKey()
        refreshDevices()
    }

    var databaseURL: URL {
        get async { database.url }
    }

    func autostart() async {
        refreshDevices()
        advertisedHost = HostIdentity.reachableHost(fallback: hostName)

        if let device = devices.first {
            await startListening(for: device)
        }
        await refreshStats()
        await refreshBriefing()
    }

    func refreshDevices() {
        devices = (try? store.all()) ?? []
    }

    func refreshStats() async {
        stats = try? await database.stats()
    }

    func refreshBriefing() async {
        briefing = try? await BriefingBuilder.build(from: database)
    }

    func mark(_ item: PlanItem, done: Bool) async {
        try? await database.markPlan(
            day: item.day, slot: item.slot, done: done, rpe: item.rpe, note: item.note
        )
        await refreshBriefing()
    }

    func revoke(_ device: TrustedDevice) async {
        try? store.remove(id: device.id)
        refreshDevices()
        if activeDevice?.id == device.id {
            await stop()
            if let next = devices.first {
                await startListening(for: next)
            }
        }
    }

    func resetCursors() async {
        try? await database.resetCursors()
        append(AppLanguage.text("Cursori azzerati: la prossima sincronizzazione ripartirà dall'inizio."))
    }

    func startPairing() async {
        await stop()
        let host = HostIdentity.reachableHost(fallback: hostName)
        advertisedHost = host
        let pairingKey = PairingPayload.makePairingKey()
        pairingPayload = PairingPayload(
            hostName: hostName, host: host, port: port, pairingKey: pairingKey
        )
        status = .pairing

        do {
            let params = SecureTransport.parameters(sessionKey: SymmetricKey(data: pairingKey))
            let listener = try await openListener(parameters: params)
            self.listener = listener
            listenFailure = nil
            append(
                AppLanguage.format(
                    "In attesa di associazione su %@:%@…", host, port))
            let stream = await listener.connections
            acceptTask = Task { [weak self] in
                for await connection in stream {
                    await self?.handlePairing(connection)
                    break
                }
            }
        } catch {
            listenFailure = error.localizedDescription
            append(AppLanguage.format("Associazione fallita: %@", error.localizedDescription))
            status = .idle
        }
    }

    private func handlePairing(_ connection: SyncConnection) async {
        var paired: TrustedDevice?
        do {
            for try await payload in await connection.control {
                let message = try MessageFraming.decode(SyncClientMessage.self, from: payload)
                guard case .pair(let name, let signing, let agreementPub) = message else { continue }
                let (device, reply) = try PairingEnrollment.enroll(
                    request: PairRequest(
                        deviceName: name, signingPublicKey: signing,
                        agreementPublicKey: agreementPub
                    ),
                    hostAgreement: agreement,
                    hostName: hostName,
                    deviceID: UUID().uuidString,
                    pairedAt: Date()
                )
                try store.add(device)
                try await connection.sendMessage(reply)
                append(AppLanguage.format("Associato “%@”.", name))
                paired = device
                break
            }
        } catch {
            append(AppLanguage.format("Errore di associazione: %@", error.localizedDescription))
        }
        await connection.cancel()
        pairingPayload = nil
        refreshDevices()

        if let paired {

            await startListening(for: paired)
        } else {
            await stop()
            status = .idle
        }
    }

    func startListening(for device: TrustedDevice) async {
        await stop()
        status = .listening
        activeDevice = device
        advertisedHost = HostIdentity.reachableHost(fallback: hostName)

        do {
            let params = SecureTransport.parameters(
                sessionKey: SymmetricKey(data: device.sessionKey)
            )
            let listener = try await openListener(parameters: params)
            self.listener = listener
            listenFailure = nil
            append(
                AppLanguage.format(
                    "In ascolto per “%@” su %@:%@.", device.name,
                    advertisedHost, port))
            hostLog.log("Listening on port \(self.port, privacy: .public)")

            let stream = await listener.connections
            let store = self.store
            let database = self.database
            let hostName = self.hostName
            let historyStart = self.historyStart
            acceptTask = Task { [weak self] in
                for await connection in stream {
                    let session = SyncServerSession(
                        connection: connection,
                        store: store,
                        database: database,
                        hostName: hostName,
                        historyStart: historyStart,
                        onProgress: { [weak self] progress in
                            Task { @MainActor in
                                self?.apply(progress)
                            }
                        }
                    )
                    await session.run()
                    await self?.finishSync()
                }
            }
        } catch {
            listenFailure = error.localizedDescription
            append(AppLanguage.format("Ascolto fallito: %@", error.localizedDescription))
            hostLog.error("Listener failed: \(error.localizedDescription, privacy: .public)")
            status = .idle
        }
    }

    private func openListener(parameters: NWParameters) async throws -> SyncListener {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let listener = try SyncListener(parameters: parameters, port: nwPort)
                _ = try await listener.start()
                return listener
            } catch {
                lastError = error
                hostLog.notice(
                    "Bind on port \(self.port, privacy: .public) failed (attempt \(attempt + 1)): \(error.localizedDescription, privacy: .public)"
                )
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        throw lastError ?? SyncFailure(code: .internalError, message: AppLanguage.text("Porta non disponibile."))
    }

    func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        if let listener { await listener.cancel() }
        listener = nil
        if status != .pairing {
            status = .idle
            activeDevice = nil
        }
    }

    private func apply(_ progress: SyncProgress) {
        self.progress = progress
        if status == .listening, !progress.isFinished {
            status = .syncing
        }
    }

    private func finishSync() async {
        if let failure = progress?.failure {
            append(AppLanguage.format("Sincronizzazione interrotta: %@", failure))
        } else if let progress, progress.upserted > 0 || progress.deleted > 0 {
            append(
                AppLanguage.format(
                    "Sincronizzati %@ record (%@ rimossi, %@).", progress.upserted,
                    progress.deleted, byteText(progress.bytesReceived))
            )
            lastSyncAt = Date()
        }
        await refreshStats()
        await refreshBriefing()

        if let device = activeDevice {
            await startListening(for: device)
        }
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func append(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("\(stamp)  \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
