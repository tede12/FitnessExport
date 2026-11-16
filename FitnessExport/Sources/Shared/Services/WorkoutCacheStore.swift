import Foundation

actor WorkoutCacheStore {
    private let baseDirectoryURL: URL
    private let fileManager: FileManager

    init(baseDirectoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let baseDirectoryURL {
            self.baseDirectoryURL = baseDirectoryURL
        } else {
            let applicationSupport =
                fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.baseDirectoryURL = applicationSupport.appendingPathComponent("org.fitnessexport", isDirectory: true)
        }
    }

    func loadIndex() -> WorkoutIndexSnapshot {
        do {
            guard fileManager.fileExists(atPath: indexURL.path) else { return .empty }
            let data = try Data(contentsOf: indexURL)
            return try JSONDecoder.workoutCache.decode(WorkoutIndexSnapshot.self, from: data)
        } catch {
            try? fileManager.removeItem(at: indexURL)
            return .empty
        }
    }

    func saveIndex(_ snapshot: WorkoutIndexSnapshot) throws {
        try ensureDirectories()
        let data = try JSONEncoder.workoutCache.encode(snapshot)
        try data.write(to: indexURL, options: .atomic)
    }

    func loadDetail(for id: UUID) -> WorkoutDetailSnapshot? {
        let url = detailURL(for: id)
        do {
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            return try JSONDecoder.workoutCache.decode(WorkoutDetailSnapshot.self, from: data)
        } catch {
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    func saveDetails(_ details: [WorkoutDetailSnapshot]) throws {
        guard !details.isEmpty else { return }
        try ensureDirectories()

        for detail in details {
            let data = try JSONEncoder.workoutCache.encode(detail)
            try data.write(to: detailURL(for: detail.id), options: .atomic)
        }
    }

    private var indexURL: URL {
        baseDirectoryURL.appendingPathComponent("workout-index.json")
    }

    private var detailDirectoryURL: URL {

        baseDirectoryURL.appendingPathComponent("details-v5", isDirectory: true)
    }

    private func detailURL(for id: UUID) -> URL {
        detailDirectoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: detailDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }
}

extension JSONEncoder {
    fileprivate static var workoutCache: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var workoutCache: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
