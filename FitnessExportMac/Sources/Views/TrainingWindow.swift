import FitnessSyncKit
import FitnessUI
import SwiftUI

struct TrainingWindow: View {
    @Bindable var host: SyncHost

    var body: some View {
        Group {
            if let briefing = host.briefing, !briefing.plan.isEmpty || !briefing.series.volume.isEmpty {
                TrainingDashboard(
                    briefing: briefing,
                    onToggle: { item in
                        Task { await host.mark(item, done: !item.done) }
                    },
                    onRefresh: { await host.refreshBriefing() }
                )
            } else {
                ContentUnavailableView {
                    Label(AppLanguage.text("Nessun dato"), systemImage: "figure.run")
                } description: {
                    Text(AppLanguage.text("Sincronizza dall'iPhone: da lì arrivano allenamenti e misure."))
                } actions: {
                    Button(AppLanguage.text("Aggiorna")) {
                        Task { await host.refreshBriefing() }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 600)
        .task { await host.refreshBriefing() }
    }
}
