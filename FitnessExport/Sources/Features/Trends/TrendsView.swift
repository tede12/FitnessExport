import Charts
import FitnessUI
import SwiftUI

struct TrendsView: View {
    @StateObject private var viewModel: TrendsViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showVolumeTable = false
    @State private var showPaceTable = false

    init(repository: any WorkoutRepository) {
        _viewModel = StateObject(wrappedValue: TrendsViewModel(repository: repository))
    }

    private var gridColumns: [GridItem] {
        let count = sizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: Brand.Spacing.m), count: count)
    }

    private var axisLabelBudget: Int {
        sizeClass == .regular ? 12 : 8
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Brand.Spacing.xl) {
                filters
                if viewModel.hasData {
                    kpiRow
                    volumeCard
                    paceCard
                    efficiencyCard
                    consistencyCard
                } else {
                    ContentUnavailableView {
                        Label(AppLanguage.text("Nessun dato nel periodo"), systemImage: "chart.xyaxis.line")
                    } description: {
                        Text(AppLanguage.text("Allarga il periodo o crea l'indice da Salute."))
                    }
                    .padding(.top, 40)
                }
            }
            .padding(Brand.Spacing.l)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .environment(\.locale, AppLanguage.locale)
        .navigationTitle(AppLanguage.text("Andamento"))
        .navigationBarTitleDisplayMode(.large)
        .task { await viewModel.load() }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: Brand.Spacing.m) {
            Picker(AppLanguage.text("Periodo"), selection: $viewModel.period) {
                ForEach(TrendsPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.period == .custom {
                dateRow(from: $viewModel.customStart, to: $viewModel.customEnd)
            }

            comparisonControls

            if viewModel.availableActivityTypes.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Brand.Spacing.s) {
                        ForEach(viewModel.availableActivityTypes, id: \.self) { activity in
                            let isSelected = viewModel.activityTypes.contains(activity)
                            FilterChip(title: activity.title, symbolName: activity.symbolName, isSelected: isSelected) {
                                var updated = viewModel.activityTypes
                                if isSelected, updated.count > 1 {
                                    updated.remove(activity)
                                } else {
                                    updated.insert(activity)
                                }
                                viewModel.activityTypes = updated
                            }
                        }
                    }
                }
            }
        }
    }

    private func dateRow(from: Binding<Date>, to: Binding<Date>) -> some View {
        HStack(spacing: Brand.Spacing.s) {
            DatePicker(AppLanguage.text("Dal"), selection: from, in: ...to.wrappedValue, displayedComponents: .date)
            DatePicker("al", selection: to, in: from.wrappedValue..., displayedComponents: .date)
        }
        .font(.subheadline)
        .labelsHidden()
    }

    private var comparisonControls: some View {
        VStack(alignment: .leading, spacing: Brand.Spacing.s) {
            Text(AppLanguage.text("Confronta con"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Picker(AppLanguage.text("Confronta con"), selection: $viewModel.comparisonMode) {
                ForEach(ComparisonMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            if viewModel.comparisonMode == .custom {
                dateRow(from: $viewModel.comparisonStart, to: $viewModel.comparisonEnd)
            }
            if let current = viewModel.currentLabel, let comparison = viewModel.comparisonLabel {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(current)  vs  \(comparison)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let distance = viewModel.comparisonDistanceText {
                        Text(distance)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
    }

    private var kpiRow: some View {
        LazyVGrid(columns: gridColumns, spacing: Brand.Spacing.m) {
            ForEach(viewModel.kpis) { kpi in
                StatTile(
                    title: kpi.title,
                    value: kpi.value,
                    symbolName: kpi.symbolName,
                    change: viewModel.hasComparison ? kpi.change : nil,
                    direction: kpi.direction,
                    comparisonPlaceholder: viewModel.hasComparison ? AppLanguage.text("nessun confronto") : nil,
                    comparisonValue: viewModel.hasComparison ? kpi.comparisonValue : nil,
                    comparisonName: viewModel.comparisonMode == .custom
                        ? AppLanguage.text("confronto") : AppLanguage.text("periodo prec.")
                )
            }
        }
    }

    private var volumeCard: some View {
        ChartCard(
            title: AppLanguage.text("Volume"),
            subtitle: AppLanguage.format(
                "Chilometri per %@ · tocca una barra", viewModel.volumeResolution.singular),
            showTable: $showVolumeTable
        ) {
            VolumeChart(
                buckets: viewModel.volume,
                resolution: viewModel.volumeResolution,
                currentBucketStart: viewModel.currentBucketStart,
                labelBudget: axisLabelBudget,
                bucketContaining: viewModel.volumeBucket(containing:)
            )
        } table: {
            DataTable(
                header: [
                    viewModel.volumeResolution.singular.capitalized, "km", AppLanguage.text("Attività"),
                    AppLanguage.text("Tempo"),
                ],
                rows: viewModel.volume.reversed().filter { $0.count > 0 }.map { bucket in
                    [
                        WorkoutFormatting.shortDate(bucket.start),
                        String(format: "%.1f", locale: AppLanguage.locale, bucket.kilometers),
                        "\(bucket.count)",
                        WorkoutFormatting.duration(bucket.seconds),
                    ]
                }
            )
        }
    }

    private var paceCard: some View {
        ChartCard(
            title: AppLanguage.text("Passo"),
            subtitle: paceSubtitle,
            showTable: $showPaceTable
        ) {
            PaceChart(
                series: viewModel.paceSeries,
                trend: viewModel.paceTrend,
                labelBudget: axisLabelBudget,
                runNearest: viewModel.run(nearest:),
                bucketNearest: viewModel.paceBucket(nearest:)
            )
        } table: {
            paceTable
        }
    }

    private var paceSubtitle: String {
        switch viewModel.paceSeries {
        case .runs:
            return AppLanguage.text("min/km · ogni corsa e la media settimanale · in alto = più veloce")
        case .buckets(_, let resolution):
            return AppLanguage.format(
                "min/km · media e intervallo per %@ · in alto = più veloce", resolution.singular)
        }
    }

    @ViewBuilder
    private var paceTable: some View {
        switch viewModel.paceSeries {
        case .runs(let runs):
            DataTable(
                header: [AppLanguage.text("Data"), AppLanguage.text("Passo"), "km", AppLanguage.text("FC")],
                rows: runs.reversed().map { run in
                    [
                        WorkoutFormatting.shortDate(run.date),
                        WorkoutFormatting.pace(secondsPerKilometer: run.paceSecondsPerKilometer) ?? "",
                        String(format: "%.1f", locale: AppLanguage.locale, run.kilometers),
                        run.averageHeartRate.map { String(format: "%.0f", locale: AppLanguage.locale, $0) } ?? "–",
                    ]
                }
            )
        case .buckets(let buckets, let resolution):
            DataTable(
                header: [
                    resolution.singular.capitalized, AppLanguage.text("Media"), "Min–max", AppLanguage.text("Corse"),
                ],
                rows: buckets.reversed().map { bucket in
                    [
                        WorkoutFormatting.shortDate(bucket.start),
                        WorkoutFormatting.pace(secondsPerKilometer: bucket.averagePace) ?? "",
                        "\(WorkoutFormatting.pace(secondsPerKilometer: bucket.minPace)?.replacingOccurrences(of: "/km", with: "") ?? "")–\(WorkoutFormatting.pace(secondsPerKilometer: bucket.maxPace)?.replacingOccurrences(of: "/km", with: "") ?? "")",
                        "\(bucket.count)",
                    ]
                }
            )
        }
    }

    private var efficiencyCard: some View {
        ChartCard(
            title: AppLanguage.text("Cuore e passo"),
            subtitle: viewModel.isEfficiencyAggregated
                ? AppLanguage.text("bpm medi per settimana in base al passo · il colore dice quanto è recente")
                : AppLanguage.text("bpm medi di ogni corsa in base al passo · il colore dice quanto è recente"),
            loading: viewModel.detailsProgressText
        ) {
            if viewModel.efficiency.count < 3 {
                Text(
                    viewModel.isLoadingDetails
                        ? AppLanguage.text("Sto leggendo la frequenza cardiaca da Salute…")
                        : AppLanguage.text("Servono almeno 3 corse con frequenza cardiaca.")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                EfficiencyChart(points: viewModel.efficiency)
                Text(
                    AppLanguage.text(
                        "Se col tempo i punti scendono a parità di passo, la forma aerobica sta migliorando.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var consistencyCard: some View {
        ChartCard(
            title: AppLanguage.text("Costanza"),
            subtitle: AppLanguage.format(
                "%@ settimane · un quadrato per giorno", viewModel.consistency.weeks)
        ) {
            ConsistencyGrid(columns: viewModel.consistencyColumns, summary: viewModel.consistency)
        }
    }
}
