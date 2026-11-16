import FitnessUI
import Foundation

protocol WorkoutRepository: Sendable {
    func loadIndex() async -> WorkoutIndexSnapshot
    func refreshIndex() async throws -> WorkoutIndexSnapshot

    func loadDetails(for workoutIDs: [UUID], forceRefresh: Bool) async throws -> [WorkoutDetailSnapshot]
    func loadAnalysisSeries(for workoutIDs: [UUID]) async throws -> [WorkoutAnalysisSeries]

    func loadExportData(for workoutID: UUID) async throws -> WorkoutExportData?
}

extension WorkoutRepository {
    func loadAnalysisSeries(for workoutIDs: [UUID]) async throws -> [WorkoutAnalysisSeries] { [] }
    func loadDetails(for workoutIDs: [UUID]) async throws -> [WorkoutDetailSnapshot] {
        try await loadDetails(for: workoutIDs, forceRefresh: false)
    }
}

enum WorkoutRepositoryError: LocalizedError {
    case healthDataUnavailable
    case authorizationDenied
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return AppLanguage.text("HealthKit non è disponibile su questo dispositivo.")
        case .authorizationDenied:
            return AppLanguage.text("L'accesso a Salute è stato negato. Concedi i permessi e riprova.")
        case .unexpected(let message):
            return message
        }
    }
}
