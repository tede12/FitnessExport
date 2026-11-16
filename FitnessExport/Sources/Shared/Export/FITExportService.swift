import FitnessUI
import Foundation

struct FITExportService: Sendable {
    let repository: any WorkoutRepository
    var encoder = FITActivityEncoder()

    func export(workoutIDs: [UUID]) async throws -> [URL] {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("FITExport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var urls: [URL] = []
        for id in workoutIDs {
            guard let data = try await repository.loadExportData(for: id) else {
                throw WorkoutRepositoryError.unexpected(AppLanguage.text("Allenamento non trovato in Salute."))
            }
            let url = directory.appendingPathComponent(data.suggestedFileName)
            try encoder.encode(data).write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }
}
