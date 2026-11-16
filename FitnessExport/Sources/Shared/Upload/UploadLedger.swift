import Foundation

enum UploadPlatform: String, Codable, CaseIterable, Hashable, Sendable {
    case intervals
    case garmin

    var title: String {
        switch self {
        case .intervals: return "Intervals.icu"
        case .garmin: return "Garmin Connect"
        }
    }

    var badge: String {
        switch self {
        case .intervals: return "icu"
        case .garmin: return "G"
        }
    }
}

struct UploadRecord: Codable, Equatable, Sendable {
    let date: Date
    let remoteID: String?
}

actor UploadLedger {
    typealias Entries = [UUID: [UploadPlatform: UploadRecord]]

    private let fileURL: URL
    private var entries: Entries?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base =
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = base.appendingPathComponent("org.fitnessexport", isDirectory: true).appendingPathComponent(
                "upload-ledger.json")
        }
    }

    func all() -> Entries {
        if let entries { return entries }
        let loaded =
            (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Entries.self, from: $0) } ?? [:]
        entries = loaded
        return loaded
    }

    func record(workoutID: UUID, platform: UploadPlatform, remoteID: String?) throws {
        var current = all()
        current[workoutID, default: [:]][platform] = UploadRecord(date: Date(), remoteID: remoteID)
        try save(current)
    }

    func remove(workoutID: UUID, platform: UploadPlatform) throws {
        var current = all()
        current[workoutID]?[platform] = nil
        if current[workoutID]?.isEmpty == true { current[workoutID] = nil }
        try save(current)
    }

    private func save(_ current: Entries) throws {
        entries = current
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(current).write(to: fileURL, options: .atomic)
    }
}
