import Charts
import FitnessSyncKit
import SwiftUI

public struct AxisBudgetReader<Content: View>: View {
    let labelWidth: CGFloat
    @ViewBuilder let content: (Int) -> Content

    public init(labelWidth: CGFloat = 46, @ViewBuilder content: @escaping (Int) -> Content) {
        self.labelWidth = labelWidth
        self.content = content
    }

    public var body: some View {
        GeometryReader { geometry in
            content(
                ChartAxisPolicy.labelBudget(
                    plotWidth: geometry.size.width - 44, labelWidth: labelWidth
                )
            )
        }
    }
}

struct DateAxisModifier: ViewModifier {
    let domain: ClosedRange<Date>
    let budget: Int

    private var spansYears: Bool {
        Calendar.current.component(.year, from: domain.lowerBound)
            != Calendar.current.component(.year, from: domain.upperBound)
    }

    private var axis: ChartAxisPolicy.DateAxis {
        ChartAxisPolicy.dateAxis(
            span: domain.upperBound.timeIntervalSince(domain.lowerBound),
            maxLabels: budget,
            spansYears: spansYears
        )
    }

    func body(content: Content) -> some View {
        content
            .chartXScale(domain: domain)
            .chartXAxis {
                AxisMarks(values: .stride(by: axis.unit.component, count: axis.count)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(ChartPalette.grid)
                    AxisValueLabel(
                        format: axis.format(spanningYears: spansYears),
                        centered: false,
                        collisionResolution: .greedy(minimumSpacing: 8)
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
    }
}

extension View {
    func dateAxis(domain: ClosedRange<Date>, budget: Int) -> some View {
        modifier(DateAxisModifier(domain: domain, budget: budget))
    }
}

struct ValueAxisModifier: ViewModifier {
    let ticks: [Double]
    let suffix: String
    let decimals: Int

    func body(content: Content) -> some View {
        content
            .chartYScale(domain: ChartAxisPolicy.domain(of: ticks) ?? 0...1)
            .chartYAxis {
                AxisMarks(position: .leading, values: ticks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(ChartPalette.grid)
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(format(number))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
    }

    private func format(_ value: Double) -> String {
        let number =
            decimals > 0
            ? String(format: "%.\(decimals)f", locale: AppLanguage.locale, value)
            : String(Int(value.rounded()))
        return suffix.isEmpty ? number : "\(number) \(suffix)"
    }
}

extension View {
    func valueAxis(ticks: [Double], suffix: String = "", decimals: Int = 0) -> some View {
        modifier(ValueAxisModifier(ticks: ticks, suffix: suffix, decimals: decimals))
    }
}

public struct SeriesPoint: Identifiable {
    public let date: Date
    public let value: Double
    public let label: String
    public let detail: [String]
    public var id: Date { date }

    public init(date: Date, value: Double, label: String, detail: [String]) {
        self.date = date
        self.value = value
        self.label = label
        self.detail = detail
    }
}

extension Array where Element == SeriesPoint {

    func domain(padding: TimeInterval) -> ClosedRange<Date>? {
        guard let first = first?.date, let last = last?.date else { return nil }
        guard first < last else {
            return first.addingTimeInterval(-padding)...first.addingTimeInterval(padding)
        }
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
    }

    func nearest(to date: Date) -> SeriesPoint? {
        self.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
}

public struct VolumeTrendChart: View {
    let weeks: [WeekVolume]
    @State private var selected: Date?

    public init(weeks: [WeekVolume]) {
        self.weeks = weeks
    }

    private var points: [SeriesPoint] {
        weeks.compactMap { week in
            guard let date = week.date else { return nil }
            var detail = [AppLanguage.format("%@ corse", week.runs)]
            if week.strength > 0 { detail.append(AppLanguage.format("%@ forza", week.strength)) }
            if week.climbing > 0 {
                detail.append(AppLanguage.format("%@ arrampicata", week.climbing))
            }
            if let hours = week.hours {
                detail.append(String(format: AppLanguage.text("%.1f h totali"), locale: AppLanguage.locale, hours))
            }
            return SeriesPoint(
                date: date, value: week.kilometres ?? 0,
                label: weekLabel(date), detail: detail
            )
        }
    }

    public var body: some View {
        let points = points
        let ticks = ChartAxisPolicy.valueTicks(
            min: 0, max: points.map(\.value).max() ?? 10, maxLabels: 5
        )
        AxisBudgetReader { budget in
            Chart {
                ForEach(points) { point in
                    BarMark(
                        x: .value(AppLanguage.text("Settimana"), point.date, unit: .weekOfYear),
                        y: .value("km", point.value)
                    )
                    .foregroundStyle(
                        selected.flatMap { points.nearest(to: $0) }?.id == point.id
                            ? ChartPalette.highlight : ChartPalette.series
                    )
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
                }
                ForEach(points.filter { $0.detail.contains(where: { $0.contains(AppLanguage.text("forza")) }) }) {
                    point in
                    PointMark(
                        x: .value(AppLanguage.text("Settimana"), point.date, unit: .weekOfYear),
                        y: .value("km", point.value)
                    )
                    .symbol(.circle)
                    .symbolSize(44)
                    .foregroundStyle(ChartPalette.highlight)
                }
                if let selected, let point = points.nearest(to: selected) {
                    RuleMark(x: .value(AppLanguage.text("Selezione"), point.date, unit: .weekOfYear))
                        .foregroundStyle(ChartPalette.context)
                        .annotation(
                            position: .top,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            ChartTooltip(
                                title: point.label,
                                lines: [String(format: "%.1f km", locale: AppLanguage.locale, point.value)]
                                    + point.detail
                            )
                        }
                }
            }
            .chartXSelection(value: $selected)
            .valueAxis(ticks: ticks, suffix: "km")
            .dateAxis(domain: points.domain(padding: 4 * 86_400) ?? fallbackDomain, budget: budget)
        }
    }

    private var fallbackDomain: ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(-86_400)...now
    }

    private func weekLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale
        formatter.dateFormat = AppLanguage.text("'settimana del' d MMM")
        return formatter.string(from: date)
    }
}

public enum NormalRange {
    public static func of(_ values: [Double]) -> ClosedRange<Double>? {
        guard values.count >= 7 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        let sd = variance.squareRoot()
        return (mean - sd)...(mean + sd)
    }
}

public struct LineTrendChart: View {
    public struct Series {
        let name: String
        let colour: Color
        let points: [SeriesPoint]
        let showsBaseline: Bool

        let showsNormalBand: Bool

        public init(
            name: String, colour: Color, points: [SeriesPoint], showsBaseline: Bool,
            showsNormalBand: Bool = false
        ) {
            self.name = name
            self.colour = colour
            self.points = points
            self.showsBaseline = showsBaseline
            self.showsNormalBand = showsNormalBand
        }

        public var normalRange: ClosedRange<Double>? {
            NormalRange.of(points.map(\.value))
        }
    }

    let series: [Series]
    let suffix: String
    let decimals: Int
    let reference: Double?
    let referenceLabel: String?
    @State private var selected: Date?

    public init(
        series: [Series], suffix: String = "", decimals: Int = 0,
        reference: Double? = nil, referenceLabel: String? = nil
    ) {
        self.series = series
        self.suffix = suffix
        self.decimals = decimals
        self.reference = reference
        self.referenceLabel = referenceLabel
    }

    private var allPoints: [SeriesPoint] {
        series.flatMap(\.points).sorted { $0.date < $1.date }
    }

    public var body: some View {
        let points = allPoints
        let values = points.map(\.value) + (reference.map { [$0] } ?? [])
        let ticks = ChartAxisPolicy.valueTicks(
            min: values.min() ?? 0, max: values.max() ?? 1, maxLabels: 5
        )
        AxisBudgetReader { budget in
            Chart {
                if let reference {
                    RuleMark(y: .value(AppLanguage.text("Riferimento"), reference))
                        .foregroundStyle(ChartPalette.highlight.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing) {
                            if let referenceLabel {
                                Text(referenceLabel)
                                    .font(.caption2)
                                    .foregroundStyle(ChartPalette.highlight)
                            }
                        }
                }
                ForEach(Array(series.enumerated()), id: \.offset) { _, line in
                    if line.showsNormalBand, let range = line.normalRange,
                        let first = line.points.first?.date, let last = line.points.last?.date
                    {
                        RectangleMark(
                            xStart: .value(AppLanguage.text("Inizio"), first),
                            xEnd: .value(AppLanguage.text("Fine"), last),
                            yStart: .value(AppLanguage.text("Normale min"), range.lowerBound),
                            yEnd: .value(AppLanguage.text("Normale max"), range.upperBound)
                        )
                        .foregroundStyle(line.colour.opacity(0.12))
                    }
                    ForEach(line.points) { point in
                        LineMark(
                            x: .value(AppLanguage.text("Giorno"), point.date),
                            y: .value(line.name, point.value),
                            series: .value("serie", line.name)
                        )
                        .foregroundStyle(line.colour)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    if line.points.count <= 40 {
                        ForEach(line.points) { point in
                            PointMark(
                                x: .value(AppLanguage.text("Giorno"), point.date),
                                y: .value(line.name, point.value)
                            )
                            .foregroundStyle(line.colour)
                            .symbolSize(26)
                        }
                    }
                    if line.showsBaseline {
                        ForEach(baseline(of: line.points)) { point in
                            LineMark(
                                x: .value(AppLanguage.text("Giorno"), point.date),
                                y: .value("media", point.value),
                                series: .value("serie", AppLanguage.format("%@ base", line.name))
                            )
                            .foregroundStyle(line.colour.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 6, lineCap: .round))
                        }
                    }
                }
                if let selected, let point = points.nearest(to: selected) {
                    RuleMark(x: .value(AppLanguage.text("Selezione"), point.date))
                        .foregroundStyle(ChartPalette.context)
                        .annotation(
                            position: .top,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            ChartTooltip(title: point.label, lines: point.detail)
                        }
                }
            }
            .chartXSelection(value: $selected)
            .valueAxis(ticks: ticks, suffix: suffix, decimals: decimals)
            .dateAxis(domain: points.domain(padding: 43_200) ?? fallbackDomain, budget: budget)
        }
    }

    private var fallbackDomain: ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(-86_400)...now
    }

    private func baseline(of points: [SeriesPoint]) -> [SeriesPoint] {
        guard points.count >= 4 else { return [] }
        let window = 7
        return points.indices.compactMap { index in
            let lower = Swift.max(0, index - window + 1)
            let slice = points[lower...index]
            guard slice.count >= 3 else { return nil }
            let mean = slice.map(\.value).reduce(0, +) / Double(slice.count)
            return SeriesPoint(
                date: points[index].date, value: mean, label: points[index].label, detail: []
            )
        }
    }
}

public struct ThresholdBarChart: View {
    let points: [SeriesPoint]
    let threshold: Double
    let thresholdLabel: String
    let suffix: String
    @State private var selected: Date?

    public init(
        points: [SeriesPoint], threshold: Double, thresholdLabel: String, suffix: String = ""
    ) {
        self.points = points
        self.threshold = threshold
        self.thresholdLabel = thresholdLabel
        self.suffix = suffix
    }

    public var body: some View {
        let ticks = ChartAxisPolicy.valueTicks(
            min: 0, max: Swift.max(points.map(\.value).max() ?? threshold, threshold),
            maxLabels: 5, steps: [1, 2, 3, 4, 6, 12]
        )
        AxisBudgetReader { budget in
            Chart {
                ForEach(points) { point in
                    BarMark(
                        x: .value(AppLanguage.text("Giorno"), point.date, unit: .day),
                        y: .value("valore", point.value)
                    )
                    .foregroundStyle(
                        point.value < threshold ? ChartPalette.bad : ChartPalette.series
                    )
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
                }
                RuleMark(y: .value(AppLanguage.text("Soglia"), threshold))
                    .foregroundStyle(ChartPalette.highlight.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(thresholdLabel)
                            .font(.caption2)
                            .foregroundStyle(ChartPalette.highlight)
                    }
                if let selected, let point = points.nearest(to: selected) {
                    RuleMark(x: .value(AppLanguage.text("Selezione"), point.date, unit: .day))
                        .foregroundStyle(ChartPalette.context)
                        .annotation(
                            position: .top,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            ChartTooltip(title: point.label, lines: point.detail)
                        }
                }
            }
            .chartXSelection(value: $selected)
            .valueAxis(ticks: ticks, suffix: suffix, decimals: 0)
            .dateAxis(domain: points.domain(padding: 43_200) ?? fallbackDomain, budget: budget)
        }
    }

    private var fallbackDomain: ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(-86_400)...now
    }
}

extension TrendSeries {

    public func hrvPoints() -> [SeriesPoint] {
        recovery.compactMap { day in
            guard let date = day.date, let hrv = day.hrv else { return nil }
            return SeriesPoint(
                date: date, value: hrv, label: Self.dayLabel(date),
                detail: [String(format: "HRV %.0f ms", locale: AppLanguage.locale, hrv)]
            )
        }
    }

    public func restingPoints() -> [SeriesPoint] {
        recovery.compactMap { day in
            guard let date = day.date, let rhr = day.restingHeartRate else { return nil }
            return SeriesPoint(
                date: date, value: rhr, label: Self.dayLabel(date),
                detail: [String(format: AppLanguage.text("FC a riposo %.0f bpm"), locale: AppLanguage.locale, rhr)]
            )
        }
    }

    public func sleepPoints() -> [SeriesPoint] {
        sleep.compactMap { night in
            guard let date = night.date else { return nil }
            let hours = Int(night.hours)
            let minutes = Int((night.hours - Double(hours)) * 60)
            return SeriesPoint(
                date: date, value: night.hours, label: Self.dayLabel(date),
                detail: ["\(hours) h \(minutes) min"]
            )
        }
    }

    public func massPoints() -> [SeriesPoint] {
        body.compactMap { point in
            guard let date = point.date, let mass = point.mass else { return nil }
            var detail = [String(format: "%.1f kg", locale: AppLanguage.locale, mass)]
            if let fat = point.fat {
                detail.append(String(format: AppLanguage.text("grasso %.1f%%"), locale: AppLanguage.locale, fat))
            }
            return SeriesPoint(date: date, value: mass, label: Self.dayLabel(date), detail: detail)
        }
    }

    public func leanPoints() -> [SeriesPoint] {
        body.compactMap { point in
            guard let date = point.date, let lean = point.lean else { return nil }
            return SeriesPoint(
                date: date, value: lean, label: Self.dayLabel(date),
                detail: [String(format: AppLanguage.text("massa magra %.1f kg"), locale: AppLanguage.locale, lean)]
            )
        }
    }

    public func vo2Points() -> [SeriesPoint] {
        fitness.compactMap { point in
            guard let date = point.date, let value = point.vo2Max else { return nil }
            return SeriesPoint(
                date: date, value: value, label: Self.monthLabel(date),
                detail: [
                    String(format: "%.1f ml/kg·min", locale: AppLanguage.locale, value),
                    AppLanguage.format("%@ misure", point.samples),
                ]
            )
        }
    }

    public func efficiencyPoints() -> [SeriesPoint] {
        form.compactMap { point in
            guard let date = point.date, let value = point.efficiency else { return nil }
            var detail = [String(format: AppLanguage.text("%.2f (vel ÷ FC)"), locale: AppLanguage.locale, value)]
            if let speed = point.speed, let hr = point.heartRate {
                detail.append(
                    String(format: AppLanguage.text("%.2f m/s a %.0f bpm"), locale: AppLanguage.locale, speed, hr))
            }
            detail.append(AppLanguage.format("%@ corse", point.runs))
            return SeriesPoint(date: date, value: value, label: Self.monthLabel(date), detail: detail)
        }
    }

    public func groundContactPoints() -> [SeriesPoint] {
        form.compactMap { point in
            guard let date = point.date, let value = point.groundContact else { return nil }
            return SeriesPoint(
                date: date, value: value, label: Self.monthLabel(date),
                detail: [String(format: AppLanguage.text("%.0f ms a terra"), locale: AppLanguage.locale, value)]
            )
        }
    }

    public func cadencePoints() -> [SeriesPoint] {
        form.compactMap { point in
            guard let date = point.date, let value = point.cadence else { return nil }
            return SeriesPoint(
                date: date, value: value, label: Self.monthLabel(date),
                detail: [String(format: AppLanguage.text("%.0f passi/min"), locale: AppLanguage.locale, value)]
            )
        }
    }

    static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: date).capitalized
    }

    static func monthLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date).capitalized
    }
}
