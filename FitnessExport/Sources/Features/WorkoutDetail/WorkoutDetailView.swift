import Charts
import FitnessUI
import SwiftUI

struct WorkoutDetailView: View {
    let item: WorkoutListItem
    let repository: any WorkoutRepository

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model: WorkoutDetailModel?
    @State private var isLoading = true
    @State private var errorMessage: String?

    @State private var selectedX: Double?

    private var gridColumns: [GridItem] {
        let count = sizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: Brand.Spacing.m), count: count)
    }

    private var axisLabelBudget: Int {
        sizeClass == .regular ? 20 : 10
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Brand.Spacing.xl) {
                header
                if isLoading {
                    loadingState
                } else if let errorMessage {
                    StatusBanner(
                        kind: .error, title: AppLanguage.text("Dettagli non disponibili"), message: errorMessage)
                } else if let model {
                    summary(model)
                    if let intervals = model.intervals {
                        intervalsChart(model, intervals)
                        lapsTable(intervals)
                    }
                    if model.hasSplits {
                        paceChart(model)
                        if !model.heartRate.isEmpty {
                            heartRateChart(model)
                        }
                        if !model.cadence.isEmpty {
                            cadenceChart(model)
                        }
                        splitsTable(model)
                    } else {
                        StatusBanner(
                            kind: .info,
                            title: AppLanguage.text("Nessuno split per km"),
                            message: AppLanguage.text(
                                "Serve almeno 2 km con campioni di distanza per disegnare i grafici.")
                        )
                    }
                }
            }
            .padding(Brand.Spacing.l)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(item.activityType.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                if let detail = try await repository.loadDetails(for: [item.id]).first {
                    model = WorkoutDetailModel(detail: detail)
                } else {
                    errorMessage = AppLanguage.text("Allenamento non trovato in Salute.")
                }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isLoading = false
        }
    }

    private var header: some View {
        HStack(spacing: Brand.Spacing.m) {
            IconTile(systemName: item.activityType.symbolName, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(WorkoutFormatting.workoutDate(item.startDate)).font(.headline)
                Text(
                    [WorkoutFormatting.distance(item.distanceInMeters), WorkoutFormatting.duration(item.duration)]
                        .compactMap { $0 }.joined(separator: " · ")
                )
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: Brand.Spacing.m) {
            LazyVGrid(columns: gridColumns, spacing: Brand.Spacing.m) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Brand.Radius.tile, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                        .frame(height: 78)
                }
            }
            RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(height: 260)
            HStack(spacing: 10) {
                ProgressView()
                Text(AppLanguage.text("Leggo i dettagli da Salute…")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppLanguage.text("Caricamento dei dettagli"))
    }

    private func summary(_ model: WorkoutDetailModel) -> some View {
        LazyVGrid(columns: gridColumns, spacing: Brand.Spacing.m) {
            ForEach(model.summaries) { summary in
                StatTile(title: summary.title, value: summary.value, symbolName: summary.symbolName)
            }
        }
    }

    private func intervalsChart(_ model: WorkoutDetailModel, _ intervals: WorkoutDetailModel.Intervals) -> some View {
        let yTicks = ChartAxisPolicy.paceTicks(min: intervals.paceRange.min, max: intervals.paceRange.max, maxLabels: 6)
        let xTicks = ChartAxisPolicy.durationTicks(
            total: intervals.totalDuration, maxLabels: sizeClass == .regular ? 10 : 6)

        let slowest = yTicks.last ?? intervals.paceRange.max
        let bars = intervals.laps.compactMap { lap -> LapBar? in
            guard let pace = lap.paceSecondsPerKilometer else { return nil }
            return LapBar(
                id: lap.index, xStart: lap.startOffset, xEnd: lap.startOffset + lap.duration, pace: pace,
                color: Self.lapColor(lap.intensity), opacity: lap.index == intervals.fastestLapIndex ? 1 : 0.85)
        }
        let subtitle = [
            intervals.activeCount > 0
                ? AppLanguage.format("%@ ripetute", intervals.activeCount) : nil,
            intervals.activePace.flatMap { WorkoutFormatting.pace(secondsPerKilometer: $0) }.map {
                AppLanguage.format("lavoro %@", $0)
            },
            intervals.recoveryPace.flatMap { WorkoutFormatting.pace(secondsPerKilometer: $0) }.map {
                AppLanguage.format("recupero %@", $0)
            },
        ].compactMap { $0 }.joined(separator: " · ")
        return ChartCard(
            title: AppLanguage.text("Intervalli"),
            subtitle: subtitle.isEmpty ? AppLanguage.text("Lap registrati dal Watch") : subtitle
        ) {
            Chart {
                AxisBoundsMarks(ticks: yTicks, axis: .y)
                ForEach(bars) { bar in
                    RectangleMark(
                        xStart: PlottableValue.value(AppLanguage.text("Inizio"), bar.xStart),
                        xEnd: PlottableValue.value(AppLanguage.text("Fine"), bar.xEnd),
                        yStart: PlottableValue.value(AppLanguage.text("Base"), slowest),
                        yEnd: PlottableValue.value(AppLanguage.text("Passo"), bar.pace)
                    )
                    .foregroundStyle(bar.color)
                    .opacity(bar.opacity)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false, reversed: true))
            .chartXScale(domain: ChartAxisPolicy.domain(of: xTicks) ?? 0...max(intervals.totalDuration, 1))
            .chartYAxis {
                AxisMarks(position: .leading, values: yTicks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartPalette.grid)
                    AxisValueLabel {
                        if let seconds = value.as(Double.self) {
                            Text(WorkoutFormatting.paceShort(secondsPerKilometer: seconds)).font(
                                .caption2.monospacedDigit()
                            ).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: xTicks.filter { $0 > 0 }) { value in
                    AxisTick(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartPalette.grid)
                    AxisValueLabel(collisionResolution: .greedy) {
                        if let seconds = value.as(Double.self) {
                            Text(WorkoutFormatting.clock(seconds)).font(.caption2.monospacedDigit()).foregroundStyle(
                                .secondary)
                        }
                    }
                }
            }
            .frame(height: 180)
            .accessibilityLabel(AppLanguage.text("Passo per intervallo"))

            ChartLegend(items: [
                .init(label: "lavoro", swatch: .bar(ChartPalette.highlight)),
                .init(label: "recupero", swatch: .bar(ChartPalette.context)),
                .init(label: AppLanguage.text("riscaldamento / defaticamento"), swatch: .bar(ChartPalette.series)),
            ])
        }
    }

    private struct LapBar: Identifiable {
        let id: Int
        let xStart: Double
        let xEnd: Double
        let pace: Double
        let color: Color
        let opacity: Double
    }

    private static func lapColor(_ intensity: LapIntensity) -> Color {
        switch intensity {
        case .active: return ChartPalette.highlight
        case .recovery, .rest: return ChartPalette.context
        case .warmup, .cooldown: return ChartPalette.series
        }
    }

    private func lapsTable(_ intervals: WorkoutDetailModel.Intervals) -> some View {
        SectionCard(title: "Lap", subtitle: AppLanguage.text("Come registrati dal Watch · ▲ ripetuta più veloce")) {
            Grid(alignment: .leading, horizontalSpacing: Brand.Spacing.m, verticalSpacing: 6) {
                GridRow {
                    ForEach(
                        [
                            "#", AppLanguage.text("Tipo"), AppLanguage.text("Tempo"), "Dist.",
                            AppLanguage.text("Passo"), AppLanguage.text("FC"),
                        ], id: \.self
                    ) {
                        Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Divider()
                ForEach(intervals.laps) { lap in
                    GridRow {
                        HStack(spacing: 3) {
                            Text("\(lap.index)")
                            if lap.index == intervals.fastestLapIndex {
                                Image(systemName: "arrowtriangle.up.fill").font(.system(size: 7)).foregroundStyle(
                                    ChartPalette.highlight)
                            }
                        }
                        Text(lap.name ?? Self.lapTitle(lap.intensity))
                            .foregroundStyle(lap.intensity == .active ? Color.primary : Color.secondary)
                            .lineLimit(1)
                        Text(WorkoutFormatting.clock(lap.duration))
                        Text(lap.distanceInMeters.map { WorkoutFormatting.lapDistance($0) } ?? "–")
                        Text(
                            lap.paceSecondsPerKilometer.flatMap { WorkoutFormatting.pace(secondsPerKilometer: $0) }
                                ?? "–")
                        Text(lap.averageHeartRate.map { String(format: "%.0f", locale: AppLanguage.locale, $0) } ?? "–")
                    }
                    .font(.caption.monospacedDigit())
                    .fontWeight(lap.intensity == .active ? .semibold : .regular)
                }
            }
        }
    }

    private static func lapTitle(_ intensity: LapIntensity) -> String {
        switch intensity {
        case .active: return AppLanguage.text("Lavoro")
        case .recovery: return AppLanguage.text("Recupero")
        case .rest: return AppLanguage.text("Pausa")
        case .warmup: return AppLanguage.text("Riscaldamento")
        case .cooldown: return AppLanguage.text("Defaticamento")
        }
    }

    private func paceChart(_ model: WorkoutDetailModel) -> some View {
        let yTicks = ChartAxisPolicy.paceTicks(min: model.paceRange.min, max: model.paceRange.max, maxLabels: 5)
        return ChartCard(
            title: AppLanguage.text("Passo per km"),
            subtitle: AppLanguage.text("min/km · in alto = più veloce · linea grigia = media")
        ) {
            Chart {
                AxisBoundsMarks(ticks: yTicks, axis: .y)
                if let average = model.averagePace, average > 0 {
                    RuleMark(y: .value(AppLanguage.text("Media"), average))
                        .foregroundStyle(ChartPalette.context)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                            Text("media")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
                ForEach(model.pace) { sample in
                    LineMark(x: .value("km", sample.x), y: .value(AppLanguage.text("Passo"), sample.value))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(ChartPalette.series)
                }
                ForEach(model.pace) { sample in
                    PointMark(x: .value("km", sample.x), y: .value(AppLanguage.text("Passo"), sample.value))
                        .symbolSize(sample.kilometer == model.fastestKilometer ? 80 : 40)
                        .foregroundStyle(
                            sample.kilometer == model.fastestKilometer ? ChartPalette.highlight : ChartPalette.series)
                }
                selectionMarks(model, values: model.pace)
            }
            .chartYScale(domain: .automatic(includesZero: false, reversed: true))
            .chartYAxis {
                AxisMarks(position: .leading, values: yTicks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartPalette.grid)
                    AxisValueLabel {
                        if let seconds = value.as(Double.self) {
                            Text(WorkoutFormatting.paceShort(secondsPerKilometer: seconds)).font(
                                .caption2.monospacedDigit()
                            ).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .modifier(KilometerAxis(model: model, labelBudget: axisLabelBudget, selection: $selectedX))
            .chartPlotStyle { $0.padding(.trailing, 36) }
            .frame(height: 200)
            .accessibilityLabel(AppLanguage.text("Passo per chilometro"))

            HStack(spacing: Brand.Spacing.m) {
                ChartLegend(items: [
                    .init(label: AppLanguage.text("km più veloce"), swatch: .dot(ChartPalette.highlight))
                ])
                Spacer()
            }
        }
    }

    private func heartRateChart(_ model: WorkoutDetailModel) -> some View {
        let yTicks = ChartAxisPolicy.valueTicks(
            min: model.range(of: model.heartRate).min, max: model.range(of: model.heartRate).max, maxLabels: 4)
        return ChartCard(
            title: AppLanguage.text("Frequenza cardiaca per km"),
            subtitle: AppLanguage.text("bpm · media di ogni chilometro")
        ) {
            Chart {
                ForEach(model.heartRate) { sample in
                    LineMark(x: .value("km", sample.x), y: .value(AppLanguage.text("FC"), sample.value))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(ChartPalette.series)
                }
                ForEach(model.heartRate) { sample in
                    PointMark(x: .value("km", sample.x), y: .value(AppLanguage.text("FC"), sample.value))
                        .symbolSize(40)
                        .foregroundStyle(ChartPalette.series)
                }
                selectionMarks(model, values: model.heartRate)
            }
            .chartYScale(domain: ChartAxisPolicy.domain(of: yTicks) ?? 0...1)
            .chartYAxis {
                AxisMarks(position: .leading, values: yTicks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartPalette.grid)
                    AxisValueLabel {
                        if let bpm = value.as(Double.self) {
                            Text(WorkoutFormatting.axisNumber(bpm)).font(.caption2.monospacedDigit()).foregroundStyle(
                                .secondary)
                        }
                    }
                }
            }
            .modifier(KilometerAxis(model: model, labelBudget: axisLabelBudget, selection: $selectedX))
            .frame(height: 160)
            .accessibilityLabel(AppLanguage.text("Frequenza cardiaca per chilometro"))
        }
    }

    private func cadenceChart(_ model: WorkoutDetailModel) -> some View {
        let yTicks = ChartAxisPolicy.valueTicks(
            min: model.range(of: model.cadence).min, max: model.range(of: model.cadence).max, maxLabels: 4)
        return ChartCard(title: AppLanguage.text("Cadenza per km"), subtitle: AppLanguage.text("passi al minuto")) {
            Chart {
                ForEach(model.cadence) { sample in
                    LineMark(x: .value("km", sample.x), y: .value("spm", sample.value))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(ChartPalette.series)
                }
                ForEach(model.cadence) { sample in
                    PointMark(x: .value("km", sample.x), y: .value("spm", sample.value))
                        .symbolSize(40)
                        .foregroundStyle(ChartPalette.series)
                }
                selectionMarks(model, values: model.cadence)
            }
            .chartYScale(domain: ChartAxisPolicy.domain(of: yTicks) ?? 0...1)
            .chartYAxis {
                AxisMarks(position: .leading, values: yTicks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartPalette.grid)
                    AxisValueLabel {
                        if let spm = value.as(Double.self) {
                            Text(WorkoutFormatting.axisNumber(spm)).font(.caption2.monospacedDigit()).foregroundStyle(
                                .secondary)
                        }
                    }
                }
            }
            .modifier(KilometerAxis(model: model, labelBudget: axisLabelBudget, selection: $selectedX))
            .frame(height: 160)
            .accessibilityLabel(AppLanguage.text("Cadenza per chilometro"))
        }
    }

    @ChartContentBuilder
    private func selectionMarks(_ model: WorkoutDetailModel, values: [WorkoutDetailModel.Sample]) -> some ChartContent {
        if let selectedX, let split = model.split(nearestTo: selectedX) {
            RuleMark(x: .value("km", Double(split.kilometer)))
                .foregroundStyle(ChartPalette.context)
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    ChartTooltip(
                        title: "km \(split.kilometer)",
                        lines: [
                            WorkoutFormatting.pace(secondsPerKilometer: split.paceSecondsPerKilometer) ?? "",
                            WorkoutFormatting.heartRate(split.averageHeartRate),
                            WorkoutFormatting.cadence(split.averageCadence),
                        ].compactMap { $0 })
                }
            if let sample = values.first(where: { $0.kilometer == split.kilometer }) {
                PointMark(x: .value("km", sample.x), y: .value(AppLanguage.text("Valore"), sample.value))
                    .symbolSize(110)
                    .foregroundStyle(ChartPalette.highlight)
            }
        }
    }

    private func splitsTable(_ model: WorkoutDetailModel) -> some View {
        SectionCard(title: "Split", subtitle: AppLanguage.text("Tabella completa · ▲ km più veloce · ▽ più lento")) {
            Grid(alignment: .leading, horizontalSpacing: Brand.Spacing.l, verticalSpacing: 6) {
                GridRow {
                    ForEach(
                        ["km", AppLanguage.text("Passo"), AppLanguage.text("FC"), AppLanguage.text("Cadenza")],
                        id: \.self
                    ) {
                        Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Divider()
                ForEach(model.detail.splits) { split in
                    GridRow {
                        HStack(spacing: 3) {
                            Text("\(split.kilometer)")
                            if split.kilometer == model.fastestKilometer {
                                Image(systemName: "arrowtriangle.up.fill").font(.system(size: 7)).foregroundStyle(
                                    ChartPalette.highlight)
                            } else if split.kilometer == model.slowestKilometer {
                                Image(systemName: "arrowtriangle.down").font(.system(size: 7)).foregroundStyle(
                                    .secondary)
                            }
                        }
                        Text(WorkoutFormatting.pace(secondsPerKilometer: split.paceSecondsPerKilometer) ?? "–")
                        Text(
                            split.averageHeartRate.map { String(format: "%.0f", locale: AppLanguage.locale, $0) } ?? "–"
                        )
                        Text(split.averageCadence.map { String(format: "%.0f", locale: AppLanguage.locale, $0) } ?? "–")
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }
}

private struct KilometerAxis: ViewModifier {
    let model: WorkoutDetailModel
    let labelBudget: Int
    @Binding var selection: Double?

    func body(content: Content) -> some View {
        content
            .chartXScale(domain: model.xDomain)
            .chartXSelection(value: $selection)
            .chartXAxis {
                AxisMarks(values: model.axisTicks(maxLabels: labelBudget)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartPalette.grid)
                    AxisValueLabel(anchor: .top, collisionResolution: .greedy(minimumSpacing: 6)) {
                        if let km = value.as(Double.self) {
                            Text("\(Int(km))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
    }
}
