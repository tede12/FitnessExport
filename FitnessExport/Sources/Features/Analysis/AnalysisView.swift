import FitnessUI
import SwiftUI

struct AnalysisView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject var viewModel: AnalysisViewModel

    private var gridColumns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: Brand.Spacing.m), count: count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Brand.Spacing.xl) {
                    summarySection
                    workoutReportsSection
                    if let errorMessage = viewModel.errorMessage {
                        StatusBanner(
                            kind: .error, title: AppLanguage.text("Operazione non riuscita"), message: errorMessage)
                    }
                    diagnosticsSection
                    exportSection
                    AnalysisEditor(
                        text: viewModel.draftText,
                        didCopy: viewModel.didCopy,
                        onChange: viewModel.updateDraft,
                        onRegenerate: viewModel.regenerate,
                        onCopy: viewModel.copy
                    )
                }
                .padding(Brand.Spacing.l)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(AppLanguage.text("Analisi"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLanguage.text("Chiudi")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: viewModel.draftText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(viewModel.draftText.isEmpty)
                }
            }
            .task {
                await viewModel.loadIfNeeded()
            }
            .sheet(item: $viewModel.exportedFiles) { files in
                ShareSheet(items: files.urls)
            }
            .sheet(item: $viewModel.reportFiles) { files in
                ShareSheet(items: files.urls)
            }
            .sheet(item: $viewModel.uploadJob) { job in
                UploadProgressView(job: job)
            }
            .confirmationDialog(
                AppLanguage.text("Sostituire i caricamenti?"),
                isPresented: Binding(
                    get: { viewModel.pendingReplace != nil },
                    set: { if !$0 { viewModel.pendingReplace = nil } }
                ),
                titleVisibility: .visible,
                presenting: viewModel.pendingReplace
            ) { _ in
                Button(AppLanguage.text("Elimina e ricarica"), role: .destructive) {
                    Task { await viewModel.confirmReplace() }
                }
                Button(AppLanguage.text("Annulla"), role: .cancel) { viewModel.pendingReplace = nil }
            } message: { platform in
                Text(
                    AppLanguage.format(
                        "%@ allenamenti su %@ risultano già su %@. Le copie caricate verranno eliminate e sostituite con i file generati adesso; gli altri vengono caricati normalmente.",
                        viewModel.alreadyUploadedCount(to: platform),
                        viewModel.selectedItems.count, platform.title))
            }
        }
        .tint(Brand.ink)
    }

    @ViewBuilder
    private var workoutReportsSection: some View {
        if !viewModel.isLoading && !viewModel.details.isEmpty {
            VStack(alignment: .leading, spacing: Brand.Spacing.m) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppLanguage.text("Dettaglio allenamenti")).font(.title3.weight(.semibold))
                        Text(AppLanguage.text("Metriche, potenza, intervalli e split"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: viewModel.exportReportImages) {
                        Label(AppLanguage.text("Immagini"), systemImage: "photo")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.signal)
                    .accessibilityIdentifier("analysis.exportImages.button")
                }
                ForEach(viewModel.details) { detail in
                    VStack(spacing: Brand.Spacing.m) {
                        AnalysisReportPageView(
                            detail: detail, series: viewModel.analysisSeries[detail.id], page: .overview)
                        if detail.hasIntervals || !detail.splits.isEmpty {
                            AnalysisReportPageView(
                                detail: detail, series: viewModel.analysisSeries[detail.id], page: .details)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous))
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
                }
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: Brand.Spacing.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.periodDescription)
                    .font(.title3.weight(.semibold))
                Text(AppLanguage.count("selected.count", viewModel.selectedItems.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if viewModel.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(AppLanguage.text("Recupero dettagli e split per km…"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, Brand.Spacing.s)
            } else if !viewModel.summaryMetrics.isEmpty {

                let lead = viewModel.leadMetrics
                let rest = viewModel.summaryMetrics.filter { metric in !lead.contains(metric) }
                HStack(spacing: Brand.Spacing.m) {
                    ForEach(lead) { metric in
                        StatTile(title: metric.title, value: metric.value, symbolName: metric.symbolName)
                    }
                }
                if !rest.isEmpty {
                    MetricList(metrics: rest)
                }
            }
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        if !viewModel.isLoading, viewModel.workoutsWithoutHeartRate > 0 || viewModel.missingWorkouts > 0 {
            StatusBanner(
                kind: .warning,
                title: diagnosticsTitle,
                message: AppLanguage.text(
                    "Controlla i permessi in Impostazioni ▸ Salute ▸ Accesso ai dati, poi ricarica.")
            ) {
                Button {
                    Task { await viewModel.reloadFromHealth() }
                } label: {
                    Label(AppLanguage.text("Ricarica da Salute"), systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("analysis.reload.button")
            }
        }
    }

    private var diagnosticsTitle: String {
        var parts: [String] = []
        if viewModel.workoutsWithoutHeartRate > 0 {
            parts.append(
                AppLanguage.format(
                    "%@ senza frequenza cardiaca", viewModel.workoutsWithoutHeartRate))
        }
        if viewModel.missingWorkouts > 0 {
            parts.append(AppLanguage.format("%@ non trovate in Salute", viewModel.missingWorkouts))
        }
        return AppLanguage.text("Attività incomplete: ") + parts.joined(separator: ", ")
    }

    private var exportSection: some View {
        SectionCard(
            title: AppLanguage.text("File .fit"),
            subtitle: AppLanguage.text("Generati in locale con lap, ripetute e running dynamics")
        ) {
            VStack(spacing: Brand.Spacing.s) {
                ForEach(UploadPlatform.allCases, id: \.self) { platform in
                    if viewModel.configuredPlatforms.contains(platform) {
                        Button {
                            Task { await viewModel.upload(to: platform) }
                        } label: {
                            HStack(spacing: 8) {
                                if viewModel.isUploading {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "icloud.and.arrow.up")
                                }
                                Text(AppLanguage.format("Carica su %@", platform.title))
                                if viewModel.alreadyUploadedCount(to: platform) > 0 {
                                    Text(
                                        AppLanguage.format(
                                            "· %@ già caricati",
                                            viewModel.alreadyUploadedCount(to: platform))
                                    )
                                    .font(.footnote)
                                    .opacity(0.85)
                                }
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.signal)
                        .controlSize(.large)
                        .disabled(viewModel.isUploading || viewModel.isExporting || viewModel.selectedItems.isEmpty)
                        .accessibilityIdentifier("analysis.upload.\(platform.rawValue).button")

                        if viewModel.alreadyUploadedCount(to: platform) > 0 {
                            Button {
                                viewModel.pendingReplace = platform
                            } label: {
                                Label(
                                    AppLanguage.format(
                                        "Sostituisci i %@ già caricati su %@…",
                                        viewModel.alreadyUploadedCount(to: platform),
                                        platform.title),
                                    systemImage: "arrow.triangle.2.circlepath.icloud"
                                )
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(viewModel.isUploading || viewModel.isExporting)
                            .accessibilityIdentifier("analysis.replace.\(platform.rawValue).button")
                        }
                    }
                }

                Button {
                    Task { await viewModel.exportFIT() }
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isExporting {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Text(
                            viewModel.isExporting
                                ? AppLanguage.text("Generazione in corso…")
                                : AppLanguage.count("export.count", viewModel.selectedItems.count))
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }

                .modifier(PrimaryOrSecondaryButton(isPrimary: viewModel.configuredPlatforms.isEmpty))
                .controlSize(.large)
                .disabled(viewModel.isExporting || viewModel.selectedItems.isEmpty)
                .accessibilityIdentifier("analysis.exportFit.button")

                if viewModel.configuredPlatforms.isEmpty {
                    Text(
                        AppLanguage.text(
                            "Configura Garmin Connect o Intervals.icu in Impostazioni per caricare direttamente.")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct MetricList: View {
    let metrics: [AnalysisViewModel.SummaryMetric]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                HStack(spacing: Brand.Spacing.s) {
                    Image(systemName: metric.symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.ink)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text(metric.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Brand.Spacing.s)
                    Text(metric.value)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                if index < metrics.count - 1 {
                    Divider()
                }
            }
        }
        .padding(.horizontal, Brand.Spacing.l)
        .padding(.vertical, Brand.Spacing.xs)
        .cardBackground()
    }
}

private struct PrimaryOrSecondaryButton: ViewModifier {
    let isPrimary: Bool

    func body(content: Content) -> some View {
        if isPrimary {
            content.buttonStyle(.borderedProminent).tint(Brand.signal)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct AnalysisEditor: View {
    let text: String
    let didCopy: Bool
    let onChange: (String) -> Void
    let onRegenerate: () -> Void
    let onCopy: () -> Void

    @State private var localText = ""

    var body: some View {
        SectionCard(
            title: AppLanguage.text("Testo esportabile"), subtitle: AppLanguage.text("Modificabile · copia o condividi")
        ) {
            if didCopy {
                Label(AppLanguage.text("Copiato"), systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.good)
                    .accessibilityIdentifier("analysis.copied.label")
            }
        } content: {
            VStack(spacing: Brand.Spacing.m) {
                TextEditor(text: $localText)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 280)
                    .padding(Brand.Spacing.s)
                    .background(
                        Color(.tertiarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                    )
                    .accessibilityIdentifier("analysis.textEditor")

                HStack(spacing: Brand.Spacing.m) {
                    Button(action: onRegenerate) {
                        Label(AppLanguage.text("Rigenera"), systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("analysis.regenerate.button")

                    Button(action: onCopy) {
                        Label(AppLanguage.text("Copia"), systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("analysis.copy.button")
                }
            }
        }
        .onAppear { localText = text }
        .onChange(of: text) { _, newValue in
            if newValue != localText { localText = newValue }
        }
        .onChange(of: localText) { _, newValue in
            if newValue != text { onChange(newValue) }
        }
    }
}
