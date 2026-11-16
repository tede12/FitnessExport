import Foundation

enum AppContext {
    static func makeRepository() -> any WorkoutRepository {
        if CommandLine.arguments.contains("-ui-testing") {
            let scenario: MockWorkoutRepository.Scenario =
                CommandLine.arguments.contains("-mock-empty-index")
                ? .emptyThenRefresh
                : .preview
            return MockWorkoutRepository(scenario: scenario)
        }

        return LiveWorkoutRepository(cacheStore: WorkoutCacheStore())
    }
}
