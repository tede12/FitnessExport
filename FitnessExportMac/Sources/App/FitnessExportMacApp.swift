import FitnessSyncKit
import FitnessUI
import SwiftUI
import os

private let appLog = Logger(subsystem: "org.fitnessexport.FitnessExportMac", category: "app")

@main
struct FitnessExportMacApp: App {
    @AppStorage(AppLanguage.preferenceKey) private var language = "system"
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            if let host = model.host {
                MenuBarView(host: host)
                    .environment(\.locale, AppLanguage.locale(for: language))
            } else {
                VStack(spacing: 8) {
                    if let error = model.startupError {
                        Text(AppLanguage.text("Avvio fallito"))
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        ProgressView()
                    }
                }
                .padding()
                .frame(width: 280)
            }
        } label: {
            Image(systemName: "waveform.path.ecg")
        }
        .menuBarExtraStyle(.window)

        Window(AppLanguage.text("Allenamento"), id: "training") {
            if let host = model.host {
                TrainingWindow(host: host)
                    .environment(\.locale, AppLanguage.locale(for: language))
            } else {
                ProgressView().frame(width: 400, height: 300)
            }
        }
        .defaultSize(width: 720, height: 860)
        .windowResizability(.contentMinSize)

        Settings {
            Form {
                LanguageSettingsSection()
                PersonalSetupSection()
            }
            .padding()
            .frame(width: 480)
            .environment(\.locale, AppLanguage.locale(for: language))
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var host: SyncHost?
    private(set) var startupError: String?

    init() {
        Task { await bootstrap() }
    }

    static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return
            base
            .appendingPathComponent("org.fitnessexport", isDirectory: true)
            .appendingPathComponent("health.sqlite")
    }

    private func bootstrap() async {
        do {
            let url = try Self.databaseURL()
            let database = try HealthDatabase(url: url)
            let host = SyncHost(database: database)
            self.host = host
            await host.autostart()
            appLog.log("Archive ready: \(url.path, privacy: .private)")
        } catch {
            startupError = error.localizedDescription
            appLog.error("avvio failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
