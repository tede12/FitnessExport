import FitnessSyncKit
import FitnessUI
import SwiftUI

struct TrainingView: View {
    @Bindable var client: HealthSyncClient
    @State private var watchResult: WatchResult?
    @State private var isPresentingExercises = false

    private var store: TrainingStore { client.training }

    private struct WatchResult: Identifiable {
        let message: String
        let success: Bool
        var id: String { message }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let briefing = store.briefing {
                    TrainingDashboard(
                        briefing: merged(briefing),
                        pendingMarks: store.pendingMarks.count,
                        onToggle: { item in store.mark(item, done: !item.done) },
                        onSendToWatch: { item in await send(item) },
                        onRefresh: { await client.sync() },
                        isSyncing: client.isSyncing,
                        syncError: client.lastError
                    )
                } else {
                    emptyState
                }
            }
            .navigationTitle(AppLanguage.text("Allenamento"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await client.sync() }
                    } label: {
                        if client.isSyncing {
                            ProgressView()
                        } else {
                            Label(AppLanguage.text("Sincronizza"), systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(client.isSyncing || client.hosts.isEmpty)
                    .accessibilityIdentifier("training.sync")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingExercises = true
                    } label: {
                        Label(AppLanguage.text("Come si fanno"), systemImage: "book")
                    }
                    .accessibilityIdentifier("training.exercises")
                }
            }
            .sheet(isPresented: $isPresentingExercises) {
                NavigationStack { ExercisesView() }
            }
            .alert(item: $watchResult) { result in
                Alert(
                    title: Text(result.success ? AppLanguage.text("Sul Watch") : AppLanguage.text("Non riesco")),
                    message: Text(result.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .refreshable { await client.sync() }
        }
        .tint(Brand.ink)
    }

    private func merged(_ briefing: TrainingBriefing) -> TrainingBriefing {
        briefing.replacingPlan(store.merged)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(AppLanguage.text("Nessun piano"), systemImage: "figure.run")
        } description: {
            Text(
                client.hosts.isEmpty
                    ? AppLanguage.text("Associa prima un Mac, dalle impostazioni dell'archivio.")
                    : AppLanguage.text("Sincronizza col Mac: da lì arrivano il piano e i tuoi numeri.")
            )
        } actions: {
            Button(AppLanguage.text("Sincronizza")) {
                Task { await client.sync() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.signal)
            .disabled(client.isSyncing || client.hosts.isEmpty)
        }
    }

    private func send(_ item: PlanItem) async {
        do {
            let scheduled = try await WatchWorkoutBuilder.send(item)
            let formatter = DateFormatter()
            formatter.locale = AppLanguage.locale
            formatter.dateFormat = AppLanguage.text("EEEE d MMMM 'alle' HH:mm")
            watchResult = WatchResult(
                message: AppLanguage.format(
                    "“%@” è programmato per %@. Lo trovi nell'app Allenamento del Watch.",
                    item.title, formatter.string(from: scheduled)),
                success: true
            )
        } catch {
            watchResult = WatchResult(message: error.localizedDescription, success: false)
        }
    }
}

struct ExercisesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(ExerciseLibrary.all) { exercise in
            NavigationLink {
                ExerciseDetailView(exercise: exercise)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name).font(.headline)
                    Text(exercise.why)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .navigationTitle(AppLanguage.text("Come si fanno"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLanguage.text("Fine")) { dismiss() }
            }
        }
    }
}

struct ExerciseDetailView: View {
    let exercise: Exercise

    var body: some View {
        List {
            Section {
                Text(exercise.why).font(.callout)
            }
            Section(AppLanguage.text("Prescrizione")) {
                ForEach(exercise.prescription, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0).foregroundStyle(.secondary)
                        Spacer(minLength: Brand.Spacing.m)
                        Text(row.1).multilineTextAlignment(.trailing)
                    }
                    .font(.callout)
                }
            }
            Section(AppLanguage.text("Cosa guardare")) {
                ForEach(exercise.cues, id: \.self) { cue in
                    Label {
                        Text(cue).font(.callout)
                    } icon: {
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(Brand.ink)
                    }
                }
            }
            Section(AppLanguage.text("Quando progredire")) {
                Text(exercise.progression).font(.callout)
            }
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
