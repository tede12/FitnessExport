import Charts
import FitnessUI
import SwiftUI

enum AnalysisReportPage: Equatable {
    case overview
    case details
}

struct AnalysisReportPageView: View {
    private struct HeartRatePoint: Identifiable {
        let id: Int
        let offset: TimeInterval
        let bpm: Double
    }

    private struct HeartRateRun: Identifiable {
        let id: Int
        let zoneIndex: Int
        let points: [HeartRatePoint]
    }

    let detail: WorkoutDetailSnapshot
    let series: WorkoutAnalysisSeries?
    let page: AnalysisReportPage
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let ink = Color(red: 0.10, green: 0.13, blue: 0.18)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if page == .overview {
                metrics
                heartRateChart
            } else {
                if detail.hasIntervals { intervals }
                if !detail.splits.isEmpty { splits }
                if !detail.hasIntervals && detail.splits.isEmpty {
                    Text(AppLanguage.text("Nessuno split o intervallo registrato")).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("FitnessExport")
                Spacer()
                Text(page == .overview ? AppLanguage.text("Riepilogo") : AppLanguage.text("Split e intervalli"))
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .foregroundStyle(ink)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: detail.activityType.symbolName)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Brand.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.workoutName?.isEmpty == false ? detail.workoutName! : detail.activityType.title)
                    .font(.system(size: 19, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                Text(
                    "\(detail.activityType.title) · \(detail.startDate.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(AppLanguage.locale)))"
                )
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.opacity(0.8)).lineLimit(1).minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(page == .overview ? AppLanguage.text("ALLENAMENTO") : AppLanguage.text("DETTAGLIO"))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.signal)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Brand.signal.opacity(0.10), in: Capsule())
        }
    }

    private var metrics: some View {
        let power = series?.power.map(\.value) ?? []
        let values: [(String, String, Color)] = [
            (AppLanguage.text("DISTANZA"), WorkoutFormatting.distance(detail.distanceInMeters) ?? "–", Brand.ink),
            (AppLanguage.text("DURATA"), WorkoutFormatting.duration(detail.duration), Brand.ink),
            (
                AppLanguage.text("PASSO MEDIO"),
                WorkoutFormatting.pace(distanceInMeters: detail.distanceInMeters, duration: detail.duration) ?? "–",
                Brand.signal
            ),
            (AppLanguage.text("FC MEDIA / MAX"), heartRateSummary, Color(red: 0.76, green: 0.20, blue: 0.22)),
            (
                AppLanguage.text("POTENZA MEDIA / MAX"),
                power.isEmpty
                    ? "–"
                    : "\(Int((power.reduce(0, +) / Double(power.count)).rounded())) / \(Int((power.max() ?? 0).rounded())) W",
                Color(red: 0.55, green: 0.32, blue: 0.72)
            ),
            (
                AppLanguage.text("CADENZA MEDIA"), WorkoutFormatting.cadence(detail.averageCadence) ?? "–",
                Color(red: 0.12, green: 0.48, blue: 0.31)
            ),
            (
                AppLanguage.text("ENERGIA"), WorkoutFormatting.kilocalories(detail.activeEnergyKilocalories) ?? "–",
                Color(red: 0.58, green: 0.38, blue: 0.08)
            ),
        ]
        let columnCount = sizeClass == .compact ? 2 : 4
        return VStack(spacing: 6) {
            if sizeClass == .compact {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columnCount), spacing: 6)
                {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, item in metric(item) }
                }
            } else {
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { index in metric(values[index]) }
                }
                HStack(spacing: 6) {
                    ForEach(4..<values.count, id: \.self) { index in metric(values[index]) }
                }
            }
        }
    }

    private func metric(_ item: (String, String, Color)) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.0).font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(ink.opacity(0.82)).lineLimit(1).minimumScaleFactor(0.7)
            Text(item.1.isEmpty ? "–" : item.1).font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(item.2).minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(item.2.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder private var heartRateChart: some View {
        let samples = series?.heartRate ?? []
        if !samples.isEmpty {
            let visibleBPM = yDomain(for: samples)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(AppLanguage.text("Frequenza cardiaca")).font(
                        .system(size: 14, weight: .bold, design: .rounded)
                    ).foregroundStyle(Brand.ink)
                    Spacer()
                    Text("BPM").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(Brand.ink)
                }
                Chart {
                    ForEach(series?.heartRateZones ?? []) { zone in
                        let lower = max(zone.minimumBPM, visibleBPM.lowerBound)
                        let upper = min(zone.maximumBPM ?? visibleBPM.upperBound, visibleBPM.upperBound)
                        if upper > lower {
                            RectangleMark(
                                xStart: .value(AppLanguage.text("Inizio"), 0.0),
                                xEnd: .value(AppLanguage.text("Fine"), detail.duration),
                                yStart: .value(AppLanguage.text("Minimo zona"), lower),
                                yEnd: .value(AppLanguage.text("Massimo zona"), upper)
                            )
                            .foregroundStyle(Self.zoneColor(zone.index).opacity(0.10))
                        }
                    }
                    ForEach(heartRateRuns) { run in
                        ForEach(run.points) { point in
                            LineMark(
                                x: .value(AppLanguage.text("Tempo"), point.offset),
                                y: .value(AppLanguage.text("FC"), point.bpm),
                                series: .value(AppLanguage.text("Tratto"), run.id)
                            )
                            .interpolationMethod(.linear)
                            .foregroundStyle(Self.lineColor(for: run.zoneIndex))
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
                .chartPlotStyle { plot in plot.clipped() }
                .chartXScale(domain: 0...max(detail.duration, 1))
                .chartYScale(domain: visibleBPM)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.8)).foregroundStyle(ink.opacity(0.20))
                        AxisTick(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ink.opacity(0.8))
                        AxisValueLabel {
                            if let bpm = value.as(Double.self) {
                                Text("\(Int(bpm.rounded()))")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .monospacedDigit().foregroundStyle(ink)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.8)).foregroundStyle(ink.opacity(0.16))
                        AxisTick(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ink.opacity(0.8))
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) {
                                Text(WorkoutFormatting.clock(seconds)).font(
                                    .system(size: 10, weight: .bold, design: .rounded)
                                ).foregroundStyle(ink)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 126)
                if let zones = series?.heartRateZones, !zones.isEmpty {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 3), count: sizeClass == .compact ? 3 : 5),
                        spacing: 5
                    ) {
                        ForEach(zones) { zone in
                            HStack(spacing: 3) {
                                Circle().fill(Self.zoneColor(zone.index)).frame(width: 7, height: 7)
                                Text("Z\(zone.index + 1)").fontWeight(.bold)
                                Text(zoneRange(zone)).monospacedDigit()
                            }
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(ink)
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    Text(AppLanguage.text("Range personali non disponibili in Salute"))
                        .font(.system(size: 9, design: .rounded)).foregroundStyle(ink)
                }
            }
            .padding(.vertical, 8)
        } else {
            Text(AppLanguage.text("Campioni di frequenza cardiaca non disponibili")).font(
                .system(size: 15, design: .rounded)
            ).foregroundStyle(.secondary)
        }
    }

    private var splits: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(AppLanguage.text("Split per km")).font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.ink)
            let power = series?.power ?? []
            let hasPower = !power.isEmpty
            HStack(spacing: 5) {
                tableCell("KM", header: true)
                tableCell(AppLanguage.text("PASSO"), header: true)
                tableCell(AppLanguage.text("FC"), header: true)
                tableCell(AppLanguage.text("CADENZA"), header: true)
                if hasPower { tableCell("WATT", header: true) }
            }.frame(maxWidth: .infinity)
            ForEach(detail.splits) { split in
                let elapsed = detail.splits.filter { $0.kilometer < split.kilometer }.reduce(0) { $0 + $1.duration }
                let interval = DateInterval(
                    start: detail.startDate.addingTimeInterval(elapsed), duration: split.duration)
                HStack(spacing: 5) {
                    tableCell("\(split.kilometer)")
                    tableCell(
                        WorkoutFormatting.pace(secondsPerKilometer: split.paceSecondsPerKilometer) ?? "–",
                        color: Self.paceInk)
                    tableCell(
                        WorkoutFormatting.heartRate(split.averageHeartRate)?.replacingOccurrences(of: " bpm", with: "")
                            ?? "–", color: Color(red: 0.76, green: 0.20, blue: 0.22))
                    tableCell(
                        WorkoutFormatting.cadence(split.averageCadence)?.replacingOccurrences(of: " spm", with: "")
                            ?? "–", color: Color(red: 0.12, green: 0.48, blue: 0.31))
                    if hasPower {
                        tableCell(
                            SplitComputation.weightedAverage(samples: power, in: interval).map {
                                "\(Int($0.rounded()))"
                            } ?? "–", color: Color(red: 0.55, green: 0.32, blue: 0.72))
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                if split.id != detail.splits.last?.id { Divider().overlay(Color.gray.opacity(0.12)) }
            }
        }
        .padding(.vertical, 6)
    }

    private var intervals: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppLanguage.text("Intervalli · lavoro e recupero")).font(
                .system(size: 14, weight: .bold, design: .rounded)
            ).foregroundStyle(Brand.ink)
            HStack(spacing: 4) {
                Text(AppLanguage.text("FASE")).frame(width: phaseWidth, alignment: .leading)
                ForEach(
                    [
                        AppLanguage.text("TEMPO"), AppLanguage.text("DIST."), AppLanguage.text("PASSO"),
                        AppLanguage.text("FC"), "SPM", "W",
                    ], id: \.self
                ) { label in
                    Text(label).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(ink.opacity(0.85))
            ForEach(detail.laps) { lap in
                wideLapRow(lap)
                if lap.id != detail.laps.last?.id { Divider().overlay(ink.opacity(0.20)) }
            }
        }
        .padding(.vertical, 2)
    }

    private func wideLapRow(_ lap: LapMetric) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Self.lapColor(lap.intensity)).frame(width: 3, height: 16)
                Text(lapTitle(lap))
                    .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(
                        Self.lapColor(lap.intensity)
                    )
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: phaseWidth, alignment: .leading)
            lapValue(WorkoutFormatting.duration(lap.duration), color: ink)
            lapValue(lap.distanceInMeters.map(WorkoutFormatting.lapDistance) ?? "–", color: ink)
            lapValue(
                WorkoutFormatting.pace(secondsPerKilometer: lap.paceSecondsPerKilometer) ?? "–",
                color: Self.lapColor(lap.intensity))
            lapValue(
                lap.averageHeartRate.map { String(Int($0.rounded())) } ?? "–",
                color: Color(red: 0.76, green: 0.20, blue: 0.22))
            lapValue(
                lap.averageCadence.map { String(Int($0.rounded())) } ?? "–",
                color: Color(red: 0.12, green: 0.48, blue: 0.31))
            lapValue(
                lapPower(lap).map { String(Int($0.rounded())) } ?? "–", color: Color(red: 0.55, green: 0.32, blue: 0.72)
            )
        }
        .frame(minHeight: 24)
    }

    private func lapValue(_ value: String, color: Color) -> some View {
        Text(value).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(color)
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var phaseWidth: CGFloat { sizeClass == .compact ? 90 : 148 }

    private func lapTitle(_ lap: LapMetric) -> String {
        let phase = Self.intensityTitle(lap.intensity)
        guard let name = lap.name, !name.isEmpty, name.localizedCaseInsensitiveCompare(phase) != .orderedSame else {
            return "\(lap.index). \(phase)"
        }
        return "\(lap.index). \(phase) · \(name)"
    }

    private func lapPower(_ lap: LapMetric) -> Double? {
        guard let power = series?.power else { return nil }
        let interval = DateInterval(start: detail.startDate.addingTimeInterval(lap.startOffset), duration: lap.duration)
        return SplitComputation.weightedAverage(samples: power, in: interval)
    }

    private func tableCell(_ text: String, header: Bool = false, color: Color? = nil) -> some View {
        Text(text).font(.system(size: header ? 9 : 11, weight: .bold, design: .rounded))
            .foregroundStyle(color ?? ink.opacity(header ? 0.85 : 1))
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1).minimumScaleFactor(0.75)
    }

    private var heartRateRuns: [HeartRateRun] {
        let samples = series?.heartRate ?? []
        guard !samples.isEmpty else { return [] }
        let zones = series?.heartRateZones ?? []
        var result: [HeartRateRun] = []
        var currentPoints: [HeartRatePoint] = []
        var currentZone: Int?
        var runID = 0
        for (index, sample) in samples.enumerated() {
            let zone = Self.zoneIndex(for: sample.value, zones: zones)
            let point = HeartRatePoint(
                id: index, offset: sample.startDate.timeIntervalSince(detail.startDate), bpm: sample.value)
            if let currentZone, currentZone != zone, !currentPoints.isEmpty {
                result.append(HeartRateRun(id: runID, zoneIndex: currentZone, points: currentPoints))
                runID += 1
                currentPoints = [currentPoints[currentPoints.count - 1]]
            }
            currentZone = zone
            currentPoints.append(point)
        }
        if let currentZone, !currentPoints.isEmpty {
            result.append(HeartRateRun(id: runID, zoneIndex: currentZone, points: currentPoints))
        }
        return result
    }

    private var heartRateSummary: String {
        let values = [detail.averageHeartRate, detail.maxHeartRate].compactMap { $0 }.map {
            String(format: "%.0f", locale: AppLanguage.locale, $0)
        }
        return values.isEmpty ? "–" : values.joined(separator: " / ") + " bpm"
    }

    private func yDomain(for samples: [TimedValueSample]) -> ClosedRange<Double> {
        let values = samples.map(\.value)
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? minimum
        let padding = max(5, (maximum - minimum) * 0.12)
        return max(0, minimum - padding)...(maximum + padding)
    }

    private func zoneRange(_ zone: WorkoutAnalysisSeries.HeartRateZone) -> String {
        if zone.index == 0, let maximum = zone.maximumBPM {
            return "<\(Int(maximum.rounded()))"
        }
        if let maximum = zone.maximumBPM {
            return "\(Int(zone.minimumBPM.rounded()))–\(Int(maximum.rounded()))"
        }
        return "≥\(Int(zone.minimumBPM.rounded()))"
    }

    private static func zoneColor(_ index: Int) -> Color {
        [
            Color(red: 0.00, green: 0.39, blue: 0.78),
            Color(red: 0.08, green: 0.51, blue: 0.24),
            Color(red: 0.62, green: 0.40, blue: 0.00),
            Color(red: 0.76, green: 0.33, blue: 0.00),
            Color(red: 0.79, green: 0.15, blue: 0.18),
        ][min(max(index, 0), 4)]
    }

    private static let paceInk = Color(red: 0.08, green: 0.27, blue: 0.46)

    private static func lineColor(for zoneIndex: Int) -> Color {
        zoneIndex < 0 ? ChartPalette.series : zoneColor(zoneIndex)
    }

    private static func zoneIndex(for bpm: Double, zones: [WorkoutAnalysisSeries.HeartRateZone]) -> Int {
        guard !zones.isEmpty else { return -1 }
        if let match = zones.first(where: { bpm >= $0.minimumBPM && bpm < ($0.maximumBPM ?? .infinity) }) {
            return match.index
        }
        return bpm < (zones.first?.minimumBPM ?? bpm) ? (zones.first?.index ?? 0) : (zones.last?.index ?? 4)
    }

    private static func lapColor(_ intensity: LapIntensity) -> Color {
        switch intensity {
        case .active: zoneColor(4)
        case .recovery: zoneColor(1)
        case .warmup: zoneColor(0)
        case .cooldown: zoneColor(3)
        case .rest: Color(red: 0.30, green: 0.34, blue: 0.39)
        }
    }

    private static func intensityTitle(_ intensity: LapIntensity) -> String {
        switch intensity {
        case .active: AppLanguage.text("Lavoro")
        case .recovery: AppLanguage.text("Recupero")
        case .rest: AppLanguage.text("Pausa")
        case .warmup: AppLanguage.text("Riscaldamento")
        case .cooldown: AppLanguage.text("Defaticamento")
        }
    }
}
