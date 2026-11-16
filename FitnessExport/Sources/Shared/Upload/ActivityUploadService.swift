import FitnessUI
import Foundation

struct ActivityUploadService: Sendable {
    enum Mode: Sendable {
        case skipUploaded
        case replaceUploaded
    }

    let exportService: FITExportService
    let ledger: UploadLedger
    var intervalsClient = IntervalsClient()
    var intervalsCredentials = IntervalsCredentialsStore()
    var garminClient = GarminClient()

    @MainActor
    func run(_ job: UploadJob, workoutIDs: [UUID], mode: Mode = .skipUploaded) async {
        let client: PlatformClient
        do {
            client = try await makeClient(for: job.platform)
        } catch {
            job.finish(fatalError: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return
        }
        await run(job, workoutIDs: workoutIDs, mode: mode, client: client)
    }

    @MainActor
    func run(_ job: UploadJob, workoutIDs: [UUID], mode: Mode, client: PlatformClient) async {
        let platform = job.platform
        let already = await ledger.all()

        for id in workoutIDs {
            if job.isCancelled { break }
            var previous = already[id]?[platform]

            do {

                if mode == .skipUploaded, previous != nil {
                    job.update(id, to: .checking)
                    if let remoteID = try await resolveRemoteID(previous, id: id, job: job, client: client),
                        try await client.exists(remoteID)
                    {
                        try? await ledger.record(workoutID: id, platform: platform, remoteID: remoteID)
                        job.update(id, to: .skipped)
                        continue
                    }
                    try? await ledger.remove(workoutID: id, platform: platform)
                    previous = nil
                }

                var deletedIDs: Set<String> = []
                if mode == .replaceUploaded {
                    job.update(id, to: .replacing)
                    if let existingID = try await resolveRemoteID(previous, id: id, job: job, client: client) {
                        try await client.delete(existingID)
                        try? await ledger.remove(workoutID: id, platform: platform)
                        deletedIDs.insert(existingID)
                    }
                }

                job.update(id, to: .exporting)
                guard let fileURL = try await exportService.export(workoutIDs: [id]).first else {
                    job.update(id, to: .failed(AppLanguage.text("Allenamento non trovato in Salute")))
                    continue
                }

                job.update(id, to: .uploading)
                var outcome = try await client.upload(fileURL, id)

                if mode == .replaceUploaded {
                    for attempt in 1...Self.replaceRetries {
                        guard case .duplicate(let reportedID, _) = outcome else { break }
                        var existingID = reportedID
                        if existingID == nil {
                            existingID = try await client.find(id, job.startDate(of: id) ?? Date())
                        }
                        if let existingID, !deletedIDs.contains(existingID) {
                            job.update(id, to: .replacing)
                            try await client.delete(existingID)
                            deletedIDs.insert(existingID)
                        }
                        try await Task.sleep(for: .seconds(replaceRetryDelay * Double(attempt)))
                        job.update(id, to: .uploading)
                        outcome = try await client.upload(fileURL, id)
                    }
                }

                switch outcome {
                case .uploaded(let activityID):
                    try? await ledger.record(workoutID: id, platform: platform, remoteID: activityID)
                    job.update(
                        id,
                        to: deletedIDs.isEmpty ? .uploaded(activityID: activityID) : .replaced(activityID: activityID))
                case .duplicate(let activityID, let message):
                    if mode == .replaceUploaded {
                        job.update(
                            id,
                            to: .failed(
                                AppLanguage.format(
                                    "%@ la considera ancora un duplicato (%@). Riprova tra qualche minuto.",
                                    platform.title, message)))
                    } else {
                        try? await ledger.record(
                            workoutID: id, platform: platform, remoteID: activityID ?? previous?.remoteID)
                        job.update(id, to: .duplicate)
                    }
                }
            } catch IntervalsClient.ClientError.unauthorized {
                job.update(id, to: .failed(IntervalsClient.ClientError.unauthorized.errorDescription ?? ""))
                job.finish(fatalError: IntervalsClient.ClientError.unauthorized.errorDescription)
                return
            } catch GarminClient.ClientError.unauthorized, GarminClient.ClientError.notLoggedIn {
                let message = GarminClient.ClientError.unauthorized.errorDescription ?? ""
                job.update(id, to: .failed(message))
                job.finish(fatalError: message)
                return
            } catch {
                job.update(id, to: .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }

        job.finish(fatalError: job.isCancelled ? AppLanguage.text("Annullato") : nil)
    }

    static let replaceRetries = 3

    var replaceRetryDelay: TimeInterval = 2

    @MainActor
    private func resolveRemoteID(_ previous: UploadRecord?, id: UUID, job: UploadJob, client: PlatformClient)
        async throws -> String?
    {
        if let remoteID = previous?.remoteID { return remoteID }
        return try await client.find(id, job.startDate(of: id) ?? Date())
    }

    enum Outcome: Equatable, Sendable {
        case uploaded(activityID: String?)
        case duplicate(activityID: String?, message: String)
    }

    struct PlatformClient: Sendable {
        let upload: @Sendable (URL, UUID) async throws -> Outcome

        let exists: @Sendable (String) async throws -> Bool
        let delete: @Sendable (String) async throws -> Void

        let find: @Sendable (UUID, Date) async throws -> String?
    }

    private func makeClient(for platform: UploadPlatform) async throws -> PlatformClient {
        switch platform {
        case .intervals:
            let credentials = intervalsCredentials.load()
            guard credentials.isConfigured else { throw IntervalsClient.ClientError.notConfigured }
            let client = intervalsClient
            return PlatformClient(
                upload: { fileURL, id in
                    switch try await client.upload(
                        fileURL: fileURL, name: nil, externalID: id.uuidString, credentials: credentials)
                    {
                    case .uploaded(let activityID): return .uploaded(activityID: activityID)
                    case .duplicate(let activityID, let message):
                        return .duplicate(activityID: activityID, message: message)
                    }
                },
                exists: { activityID in
                    try await client.exists(activityID: activityID, credentials: credentials)
                },
                delete: { activityID in
                    try await client.delete(activityID: activityID, credentials: credentials)
                },
                find: { id, startDate in
                    try await client.findActivityID(
                        externalID: id.uuidString, around: startDate, credentials: credentials)
                }
            )

        case .garmin:
            let session = try await GarminAuthenticator().validSession()
            let client = garminClient
            return PlatformClient(
                upload: { fileURL, _ in
                    switch try await client.upload(fileURL: fileURL, session: session) {
                    case .uploaded(let activityID): return .uploaded(activityID: activityID)
                    case .duplicate(let activityID, let message):
                        return .duplicate(activityID: activityID, message: message)
                    }
                },
                exists: { activityID in
                    try await client.exists(activityID: activityID, session: session)
                },
                delete: { activityID in
                    try await client.delete(activityID: activityID, session: session)
                },
                find: { _, startDate in
                    try await client.findActivityID(startDate: startDate, session: session)
                }
            )
        }
    }
}
