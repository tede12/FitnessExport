import FitnessUI
import SwiftUI

@main
struct FitnessExportApp: App {
    @AppStorage(AppLanguage.preferenceKey) private var language = "system"
    private let repository: any WorkoutRepository
    private let composer = AnalysisComposer()

    @State private var client = HealthSyncClient()

    init() {
        repository = AppContext.makeRepository()
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                TrainingView(client: client)
                    .tabItem { Label(AppLanguage.text("Allenamento"), systemImage: "figure.run") }
                    .accessibilityIdentifier("tab.training")

                LibraryView(
                    viewModel: LibraryViewModel(repository: repository),
                    analysisComposer: composer,
                    repository: repository
                )
                .tabItem { Label(AppLanguage.text("Archivio"), systemImage: "tray.full") }
                .accessibilityIdentifier("tab.library")
            }
            .environment(\.locale, AppLanguage.locale(for: language))
            .tint(Brand.ink)
        }
    }
}
