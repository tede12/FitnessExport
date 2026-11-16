import Charts
import FitnessUI
import SwiftUI

struct VolumeChart: View {
    let buckets: [VolumeBucket]
    let resolution: SeriesResolution
    let currentBucketStart: Date?
    let labelBudget: Int
    let bucketContaining: (Date) -> VolumeBucket?

    @State private var selectedDate: Date?
    @Environment(\.calendar) private var calendar

    private struct Bar: Identifiable {
        let bucket: VolumeBucket
        let midpoint: Date
        let end: Date
        var id: Date { bucket.start }
    }

    private var bars: [Bar] {
        buckets.map { bucket in
            let end =
                resolution.advancing(bucket.start, calendar: calendar)
                ?? bucket.start.addingTimeInterval(resolution.approximateDays * 86_400)
            return Bar(
                bucket: bucket, midpoint: bucket.start.addingTimeInterval(end.timeIntervalSince(bucket.start) / 2),
                end: end)
        }
    }

    private var domain: ClosedRange<Date> {
        guard let first = bars.first, let last = bars.last else { return Date()...Date().addingTimeInterval(1) }
        return first.bucket.start...last.end
    }

    private var spansYears: Bool {
        calendar.component(.year, from: domain.lowerBound) != calendar.component(.year, from: domain.upperBound)
    }

    private var axis: ChartAxisPolicy.DateAxis {
        ChartAxisPolicy.dateAxis(
            span: domain.upperBound.timeIntervalSince(domain.lowerBound), maxLabels: labelBudget, spansYears: spansYears
        )
    }

    var body: some View {
        let bars = bars
        let axis = axis
        let spansYears = spansYears
        let yTicks = ChartAxisPolicy.valueTicks(min: 0, max: bars.map(\.bucket.kilometers).max() ?? 0, maxLabels: 5)
        GeometryReader { geometry in
            let barWidth = min(22, max(2, (geometry.size.width - 44) / CGFloat(max(bars.count, 1)) * 0.62))
            Chart {
                ForEach(bars) { bar in
                    BarMark(
                        x: .value(AppLanguage.text("Periodo"), bar.midpoint),
                        y: .value("km", bar.bucket.kilometers),
                        width: .fixed(barWidth)
                    )
                    .foregroundStyle(
                        bar.bucket.start == currentBucketStart ? ChartPalette.highlight : ChartPalette.series
                    )
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                }

                if let selectedDate, let selected = bucketContaining(selectedDate),
                    let bar = bars.first(where: { $0.bucket.start == selected.start })
                {
                    RuleMark(x: .value(AppLanguage.text("Selezione"), bar.midpoint))
                        .foregroundStyle(ChartPalette.context)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            ChartTooltip(
                                title: tooltipTitle(for: selected),
                                lines: [
                                    String(format: "%.1f km", locale: AppLanguage.locale, selected.kilometers),
                                    AppLanguage.format(
                                        "%@ attività · %@", selected.count,
                                        WorkoutFormatting.duration(selected.seconds)),
                                    WorkoutFormatting.pace(secondsPerKilometer: selected.paceSecondsPerKilometer).map {
                                        AppLanguage.format("passo %@", $0)
                                    },
                                ].compactMap { $0 }
                            )
                        }
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartXScale(domain: domain)
            .chartYScale(domain: ChartAxisPolicy.domain(of: yTicks) ?? 0...1)
            .chartYAxis {
                AxisMarks(position: .leading, values: yTicks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartPalette.grid)
                    AxisValueLabel {
                        if let km = value.as(Double.self) {
                            Text("\(WorkoutFormatting.axisNumber(km)) km").font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: axis.unit.component, count: axis.count)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartPalette.grid)
                    AxisValueLabel(
                        format: axis.format(spanningYears: spansYears), centered: false,
                        collisionResolution: .greedy(minimumSpacing: 8)
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 220)
        .accessibilityLabel(AppLanguage.format("Volume per %@", resolution.singular))
    }

    private func tooltipTitle(for bucket: VolumeBucket) -> String {
        switch resolution {
        case .week:
            return AppLanguage.format("Sett. del %@", WorkoutFormatting.shortDate(bucket.start))
        case .month: return WorkoutFormatting.monthLabel(WorkoutMonthKey(date: bucket.start, calendar: calendar))
        case .quarter:
            return AppLanguage.format("Trimestre dal %@", WorkoutFormatting.shortDate(bucket.start))
        }
    }
}

struct PaceChart: View {
    let series: PaceSeries
    let trend: [TrendPoint]
    let labelBudget: Int
    let runNearest: (Date) -> RunPoint?
    let bucketNearest: (Date) -> PaceBucket?

    @State private var selectedDate: Date?
    @Environment(\.calendar) private var calendar

    private var dates: [Date] {
        switch series {
        case .runs(let runs): return runs.map(\.date)
        case .buckets(let buckets, _): return buckets.map(\.start)
        }
    }

    private var paceRange: (min: Double, max: Double) {
        switch series {
        case .runs(let runs):
            let paces = runs.map(\.paceSecondsPerKilometer) + trend.map(\.pace)
            return (paces.min() ?? 0, paces.max() ?? 0)
        case .buckets(let buckets, _):
            return (buckets.map(\.minPace).min() ?? 0, buckets.map(\.maxPace).max() ?? 0)
        }
    }

    private var legend: [ChartLegend.Item] {
        switch series {
        case .runs:
            return [
                .init(label: AppLanguage.text("Singola corsa"), swatch: .dot(ChartPalette.context)),
                .init(label: AppLanguage.text("Media settimanale"), swatch: .line(ChartPalette.series)),
            ]
        case .buckets(_, let resolution):
            return [
                .init(
                    label: AppLanguage.format("Media per %@", resolution.singular),
                    swatch: .line(ChartPalette.series)),
                .init(label: AppLanguage.text("Intervallo min–max"), swatch: .band(ChartPalette.band)),
            ]
        }
    }

    var body: some View {
        let first = dates.first ?? Date()
        let last = dates.last ?? first.addingTimeInterval(86_400)
        let spansYears = calendar.component(.year, from: first) != calendar.component(.year, from: last)
        let axis = ChartAxisPolicy.dateAxis(
            span: max(last.timeIntervalSince(first), 86_400), maxLabels: labelBudget, spansYears: spansYears)

        let yTicks = ChartAxisPolicy.paceTicks(min: paceRange.min, max: paceRange.max, maxLabels: 5)

        VStack(alignment: .leading, spacing: Brand.Spacing.s) {
            ChartLegend(items: legend)
            Chart {
                AxisBoundsMarks(ticks: yTicks, axis: .y)
                switch series {
                case .runs(let runs):
                    ForEach(runs) { run in
                        PointMark(
                            x: .value(AppLanguage.text("Data"), run.date),
                            y: .value(AppLanguage.text("Passo"), run.paceSecondsPerKilometer)
                        )
                        .symbolSize(50)
                        .foregroundStyle(ChartPalette.context)
                    }
                    ForEach(trend) { point in
                        LineMark(
                            x: .value(AppLanguage.text("Data"), point.start),
                            y: .value(AppLanguage.text("Passo"), point.pace)
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(ChartPalette.series)
                    }
                    if let selectedDate, let run = runNearest(selectedDate) {
                        PointMark(
                            x: .value(AppLanguage.text("Data"), run.date),
                            y: .value(AppLanguage.text("Passo"), run.paceSecondsPerKilometer)
                        )
                        .symbolSize(110)
                        .foregroundStyle(ChartPalette.highlight)
                        RuleMark(x: .value(AppLanguage.text("Selezione"), run.date))
                            .foregroundStyle(ChartPalette.context)
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                ChartTooltip(
                                    title: WorkoutFormatting.shortDate(run.date),
                                    lines: [
                                        WorkoutFormatting.pace(secondsPerKilometer: run.paceSecondsPerKilometer) ?? "",
                                        String(
                                            format: "%.2f km · %@", locale: AppLanguage.locale, run.kilometers,
                                            WorkoutFormatting.duration(run.seconds)),
                                        WorkoutFormatting.heartRate(run.averageHeartRate).map {
                                            AppLanguage.format("FC media %@", $0)
                                        },
                                    ].compactMap { $0 }
                                )
                            }
                    }

                case .buckets(let buckets, _):
                    ForEach(buckets) { bucket in
                        AreaMark(
                            x: .value(AppLanguage.text("Data"), bucket.start),
                            yStart: .value("Min", bucket.minPace),
                            yEnd: .value("Max", bucket.maxPace)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(ChartPalette.band)
                    }
                    ForEach(buckets) { bucket in
                        LineMark(
                            x: .value(AppLanguage.text("Data"), bucket.start),
                            y: .value(AppLanguage.text("Passo"), bucket.averagePace)
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(ChartPalette.series)
                    }
                    if let selectedDate, let bucket = bucketNearest(selectedDate) {
                        PointMark(
                            x: .value(AppLanguage.text("Data"), bucket.start),
                            y: .value(AppLanguage.text("Passo"), bucket.averagePace)
                        )
                        .symbolSize(110)
                        .foregroundStyle(ChartPalette.highlight)
                        RuleMark(x: .value(AppLanguage.text("Selezione"), bucket.start))
                            .foregroundStyle(ChartPalette.context)
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                ChartTooltip(
                                    title: AppLanguage.format(
                                        "Dal %@", WorkoutFormatting.shortDate(bucket.start)),
                                    lines: [
                                        AppLanguage.format(
                                            "media %@",
                                            String(
                                                describing: WorkoutFormatting.pace(
                                                    secondsPerKilometer: bucket.averagePace) ?? "")),
                                        "da \(WorkoutFormatting.paceShort(secondsPerKilometer: bucket.minPace)) a \(WorkoutFormatting.paceShort(secondsPerKilometer: bucket.maxPace))",
                                        AppLanguage.format(
                                            "%@ corse · %@", bucket.count,
                                            String(
                                                describing: String(
                                                    format: "%.0f km", locale: AppLanguage.locale, bucket.kilometers))),
                                        WorkoutFormatting.heartRate(bucket.averageHeartRate).map {
                                            AppLanguage.format("FC media %@", $0)
                                        },
                                    ].compactMap { $0 }
                                )
                            }
                    }
                }
            }
            .chartXSelection(value: $selectedDate)
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
            .chartXAxis {
                AxisMarks(values: .stride(by: axis.unit.component, count: axis.count)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartPalette.grid)
                    AxisValueLabel(
                        format: axis.format(spanningYears: spansYears), collisionResolution: .greedy(minimumSpacing: 8)
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(height: 240)
        }
        .accessibilityLabel(AppLanguage.text("Passo nel tempo"))
    }
}

struct EfficiencyChart: View {
    let points: [EfficiencyPoint]

    private var paces: [Double] { points.map(\.paceSecondsPerKilometer) }
    private var heartRates: [Double] { points.map(\.heartRate) }

    var body: some View {

        let xTicks = ChartAxisPolicy.paceTicks(min: (paces.min() ?? 0) - 1, max: (paces.max() ?? 0) + 1, maxLabels: 5)
        let yTicks = ChartAxisPolicy.valueTicks(
            min: (heartRates.min() ?? 0) - 1, max: (heartRates.max() ?? 0) + 1, maxLabels: 5)

        VStack(alignment: .leading, spacing: Brand.Spacing.s) {
            HStack(spacing: 6) {
                Text(AppLanguage.text("meno recente")).font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    ForEach(Array(ChartPalette.sequential.enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
                    }
                }
                Text(AppLanguage.text("più recente")).font(.caption2).foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)

            Chart {
                AxisBoundsMarks(ticks: xTicks, axis: .x)
                ForEach(points) { point in
                    PointMark(
                        x: .value(AppLanguage.text("Passo"), point.paceSecondsPerKilometer),
                        y: .value(AppLanguage.text("FC"), point.heartRate)
                    )
                    .symbolSize(point.count > 1 ? 90 : 60)
                    .foregroundStyle(ChartPalette.sequentialColor(point.recency))
                }
            }
            .chartXScale(domain: .automatic(includesZero: false, reversed: true))
            .chartYScale(domain: ChartAxisPolicy.domain(of: yTicks) ?? 0...1)
            .chartXAxisLabel(alignment: .leading) {
                Text(AppLanguage.text("← più veloce")).font(.caption2).foregroundStyle(.secondary)
            }
            .chartXAxis {
                AxisMarks(values: xTicks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartPalette.grid)
                    AxisValueLabel(anchor: .top) {
                        if let seconds = value.as(Double.self) {
                            Text(WorkoutFormatting.paceShort(secondsPerKilometer: seconds)).font(
                                .caption2.monospacedDigit()
                            ).foregroundStyle(.secondary)
                        }
                    }
                }
            }
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
            .frame(height: 220)
        }
        .accessibilityLabel(
            AppLanguage.format("Frequenza cardiaca in base al passo, %@ punti", points.count))
    }
}

struct ConsistencyGrid: View {
    let columns: [[DayCell?]]
    let summary: TrendsViewModel.ConsistencySummary

    private let weekdayLabels = ["L", "M", "M", "G", "V", "S", "D"]

    private static let maxFittingWeeks = 26
    private static let cell: CGFloat = 14
    private static let gap: CGFloat = 3

    private var scrolls: Bool { columns.count > Self.maxFittingWeeks }

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Spacing.m) {
            HStack(alignment: .top, spacing: Self.gap) {
                VStack(spacing: Self.gap) {
                    if scrolls {
                        Color.clear.frame(width: 12, height: Self.cell)
                    }
                    ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 12, height: Self.cell)
                    }
                }
                .accessibilityHidden(true)
                if scrolls {
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: Self.gap) {
                            monthLabels
                            HStack(alignment: .top, spacing: Self.gap) {
                                weekColumns(width: Self.cell)
                            }
                        }
                    }
                    .defaultScrollAnchor(.trailing)
                } else {
                    weekColumns(width: nil)
                }
            }
            HStack(spacing: Brand.Spacing.m) {
                averageTile(
                    value: summary.daysPerWeek.formatted(
                        .number.precision(.fractionLength(1)).locale(AppLanguage.locale)),
                    unit: AppLanguage.text("giorni / sett.")
                )
                averageTile(
                    value: summary.kilometersPerWeek.formatted(
                        .number.precision(.fractionLength(1)).locale(AppLanguage.locale)),
                    unit: AppLanguage.text("km / sett.")
                )
            }
            HStack(spacing: Brand.Spacing.s) {
                Text(
                    AppLanguage.format(
                        "%@ giorni attivi su %@", summary.activeDays,
                        summary.totalDays)
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                Spacer()
                Text("meno").font(.caption2).foregroundStyle(.tertiary)
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2).fill(ChartPalette.empty).frame(width: 10, height: 10)
                    ForEach(Array(ChartPalette.sequential.enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                    }
                }
                .accessibilityHidden(true)
                Text(AppLanguage.text("più")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func averageTile(value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(AppLanguage.format("media %@", unit))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Brand.Spacing.m)
        .background(
            Color(.tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: Brand.Radius.tile, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private func weekColumns(width: CGFloat?) -> some View {
        ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
            VStack(spacing: Self.gap) {
                ForEach(0..<7, id: \.self) { index in
                    let day = week[index]
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(day.map { color(meters: $0.meters) } ?? Color.clear)
                        .frame(height: Self.cell)
                        .accessibilityLabel(
                            day.map {
                                "\(WorkoutFormatting.shortDate($0.date)): \(WorkoutFormatting.distance($0.meters) ?? "riposo")"
                            } ?? "")
                }
            }
            .frame(width: width)
            .frame(maxWidth: width == nil ? 28 : nil)
        }
    }

    private var monthLabels: some View {
        HStack(spacing: Self.gap) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, week in
                let first = week.compactMap { $0 }.first?.date
                let label = first.flatMap { date -> String? in
                    let calendar = Calendar.current
                    let previous = index > 0 ? columns[index - 1].compactMap { $0 }.first?.date : nil
                    guard
                        previous.map({ calendar.component(.month, from: $0) != calendar.component(.month, from: date) })
                            ?? true
                    else { return nil }
                    return date.formatted(.dateTime.month(.abbreviated).locale(AppLanguage.locale))
                }
                Text(label ?? "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .frame(width: Self.cell, height: Self.cell, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    private func color(meters: Double) -> Color {
        guard meters > 0 else { return ChartPalette.empty }
        return ChartPalette.sequentialColor(meters / summary.maxMeters)
    }
}
