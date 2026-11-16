import FitnessUI
import SwiftUI

struct UploadProgressView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var job: UploadJob

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(
                                job.isRunning
                                    ? AppLanguage.format("Caricamento su %@…", job.platform.title)
                                    : AppLanguage.text("Completato")
                            )
                            .font(.headline)
                            Spacer()
                            Text("\(job.completedCount) di \(job.items.count)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: job.progress)
                            .tint(job.failedCount > 0 && !job.isRunning ? Brand.warning : Brand.ink)
                        if !job.isRunning {
                            summaryLine
                        }
                        if let fatalError = job.fatalError, fatalError != AppLanguage.text("Annullato") {
                            Label(fatalError, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(Brand.bad)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section(AppLanguage.text("Allenamenti")) {
                    ForEach(job.items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            StateIcon(state: item.state)
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline.weight(.medium))
                                Text(item.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(description(for: item.state))
                                    .font(.caption)
                                    .foregroundStyle(color(for: item.state))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle(AppLanguage.text("Caricamento"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if job.isRunning {
                        Button(AppLanguage.text("Annulla"), role: .destructive) { job.cancel() }
                    } else {
                        Button("OK") { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(job.isRunning)
        }
        .tint(Brand.ink)
    }

    private var summaryLine: some View {
        HStack(spacing: 12) {
            if job.uploadedCount - job.replacedCount > 0 {
                Label(
                    AppLanguage.format("%@ caricati", job.uploadedCount - job.replacedCount),
                    systemImage: "checkmark.circle.fill"
                ).foregroundStyle(Brand.good)
            }
            if job.replacedCount > 0 {
                Label(
                    AppLanguage.format("%@ sostituiti", job.replacedCount),
                    systemImage: "arrow.triangle.2.circlepath.circle.fill"
                ).foregroundStyle(Brand.good)
            }
            if job.duplicateCount > 0 {
                Label(
                    AppLanguage.format("%@ già presenti", job.duplicateCount),
                    systemImage: "doc.on.doc.fill"
                ).foregroundStyle(Brand.warning)
            }
            if job.skippedCount > 0 {
                Label(
                    AppLanguage.format("%@ saltati", job.skippedCount),
                    systemImage: "forward.end.fill"
                ).foregroundStyle(.secondary)
            }
            if job.failedCount > 0 {
                Label(
                    AppLanguage.format("%@ errori", job.failedCount),
                    systemImage: "xmark.circle.fill"
                ).foregroundStyle(Brand.bad)
            }
        }
        .font(.caption.weight(.medium))
    }

    private func description(for state: UploadJob.ItemState) -> String {
        switch state {
        case .queued: return AppLanguage.text("In coda")
        case .checking: return AppLanguage.text("Verifica sulla piattaforma…")
        case .exporting: return AppLanguage.text("Generazione .fit…")
        case .replacing: return AppLanguage.text("Eliminazione della copia già caricata…")
        case .uploading: return AppLanguage.text("Invio in corso…")
        case .uploaded(let activityID):
            return activityID.map { AppLanguage.format("Caricato · attività %@", $0) }
                ?? AppLanguage.text("Caricato")
        case .replaced(let activityID):
            return activityID.map { AppLanguage.format("Sostituito · attività %@", $0) }
                ?? AppLanguage.text("Sostituito")
        case .duplicate: return AppLanguage.text("Già presente sulla piattaforma")
        case .skipped: return AppLanguage.text("Saltato: già presente sulla piattaforma")
        case .failed(let message): return message
        }
    }

    private func color(for state: UploadJob.ItemState) -> Color {
        switch state {
        case .uploaded, .replaced: return Brand.good
        case .duplicate: return Brand.warning
        case .failed: return Brand.bad
        default: return .secondary
        }
    }
}

private struct StateIcon: View {
    let state: UploadJob.ItemState

    var body: some View {
        switch state {
        case .queued:
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .checking, .exporting, .replacing, .uploading:
            ProgressView()
        case .uploaded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.good)
        case .replaced:
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(Brand.good)
        case .duplicate:
            Image(systemName: "doc.on.doc.fill").foregroundStyle(Brand.warning)
        case .skipped:
            Image(systemName: "forward.end.circle.fill").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.bad)
        }
    }
}
