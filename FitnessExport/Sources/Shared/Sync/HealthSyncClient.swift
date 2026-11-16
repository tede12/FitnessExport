import FitnessSyncKit
import FitnessUI
import Foundation
import Observation
import UIKit

struct PairedHost: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let host: String
    let port: UInt16
    let sessionKey: Data
    let addedAt: Date
}

@MainActor
@Observable
final class HealthSyncClient {
    private static let identityService = "org.fitnessexport.sync.identity"
    private static let identityAccount = "device-identity"
    private static let hostsService = "org.fitnessexport.sync.hosts"

    private(set) var hosts: [PairedHost] = []
    private(set) var progress: SyncClientProgress?
    private(set) var isSyncing = false
    private(set) var lastSummary: SyncSummary?
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?

    let training = TrainingStore()
    private let engine: HealthSyncEngine

    init() {
        let identity = Self.loadOrCreateIdentity()
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
        engine = HealthSyncEngine(
            exporter: HealthKitExporter(),
            identity: identity,
            deviceName: UIDevice.current.name,
            appVersion: version
        )
        refreshHosts()
    }

    func refreshHosts() {
        let items = (try? Keychain.items(service: Self.hostsService)) ?? []
        hosts =
            items
            .compactMap { try? JSONDecoder().decode(PairedHost.self, from: $0.data) }
            .sorted { $0.addedAt < $1.addedAt }
    }

    func forget(_ host: PairedHost) {
        Keychain.delete(service: Self.hostsService, account: host.id)
        refreshHosts()
    }

    @discardableResult
    func pair(withQRString string: String) async throws -> PairedHost {
        guard let payload = PairingPayload(qrString: string) else {
            throw SyncFailure(
                code: .payloadInvalid, message: AppLanguage.text("Questo codice non è di FitnessExport.")
            )
        }
        let host = try await engine.pair(with: payload)
        try store(host)
        refreshHosts()
        return host
    }

    func sync(with host: PairedHost? = nil) async {
        guard !isSyncing else { return }
        guard let target = host ?? hosts.first else {
            lastError = AppLanguage.text("Nessun Mac associato.")
            return
        }

        isSyncing = true
        lastError = nil
        progress = SyncClientProgress()
        defer { isSyncing = false }

        do {
            let marks = training.pendingMarks
            let summary = try await engine.sync(with: target, marks: marks) { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.progress = update
                }
            }
            if let briefing = await engine.takeBriefing() {
                training.apply(briefing)
                training.clearPendingMarks()
            }
            lastSummary = summary
            lastSyncAt = Date()
            progress = nil
        } catch let failure as SyncFailure {
            lastError = failure.message
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func store(_ host: PairedHost) throws {
        try Keychain.set(
            try JSONEncoder().encode(host), service: Self.hostsService, account: host.id
        )
    }

    private static func loadOrCreateIdentity() -> DeviceIdentity {
        if let data = try? Keychain.get(service: identityService, account: identityAccount),
            let identity = try? DeviceIdentity(privateKeyData: data)
        {
            return identity
        }
        let identity = DeviceIdentity()
        try? Keychain.set(
            identity.privateKeyData, service: identityService, account: identityAccount
        )
        return identity
    }
}
