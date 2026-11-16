import FitnessUI
import Foundation

struct EfficiencyPoint: Identifiable, Equatable, Sendable {
    let id: Date
    let date: Date
    let paceSecondsPerKilometer: Double
    let heartRate: Double

    let recency: Double
    let count: Int
}

struct TrendPoint: Identifiable, Equatable, Sendable {
    let start: Date
    let pace: Double

    var id: Date { start }
}

@MainActor
final class TrendsViewModel: ObservableObject {
    struct KPI: Identifiable, Equatable {
        let title: String
        let value: String
        let change: Double?
        let direction: MetricDirection
        let symbolName: String

        let comparisonValue: String?

        var id: String { title }
    }

    struct ConsistencySummary: Equatable {
        var activeDays = 0
        var totalDays = 0
        var maxMeters: Double = 1
        var weeks = 0
        var meters: Double = 0

        var daysPerWeek: Double { totalDays > 0 ? Double(activeDays) / (Double(totalDays) / 7) : 0 }
        var kilometersPerWeek: Double { totalDays > 0 ? meters / 1_000 / (Double(totalDays) / 7) : 0 }
    }

    @Published var period: TrendsPeriod = .threeMonths { didSet { recompute() } }
    @Published var customStart: Date { didSet { if period == .custom { recompute() } } }
    @Published var customEnd: Date { didSet { if period == .custom { recompute() } } }
    @Published var comparisonMode: ComparisonMode = .previous { didSet { recompute() } }
    @Published var comparisonStart: Date { didSet { if comparisonMode == .custom { recompute() } } }
    @Published var comparisonEnd: Date { didSet { if comparisonMode == .custom { recompute() } } }
    @Published var activityTypes: Set<WorkoutActivityType> = [.running] { didSet { recompute() } }

    @Published private(set) var volume: [VolumeBucket] = []
    @Published private(set) var volumeResolution: SeriesResolution = .week
    @Published private(set) var paceSeries: PaceSeries = .runs([])
    @Published private(set) var paceTrend: [TrendPoint] = []
    @Published private(set) var efficiency: [EfficiencyPoint] = []
    @Published private(set) var isEfficiencyAggregated = false
    @Published private(set) var consistencyColumns: [[DayCell?]] = []
    @Published private(set) var consistency = ConsistencySummary()
    @Published private(set) var kpis: [KPI] = []
    @Published private(set) var availableActivityTypes: [WorkoutActivityType] = []
    @Published private(set) var isLoadingDetails = false
    @Published private(set) var detailsLoaded = 0
    @Published private(set) var detailsTotal = 0

    private let repository: any WorkoutRepository
    private let calendar: Calendar
    private let reference: Date
    private var items: [WorkoutListItem] = []
    private var details: [UUID: WorkoutDetailSnapshot] = [:]
    private var detailTask: Task<Void, Never>?

    private var runs: [RunPoint] = []

    init(repository: any WorkoutRepository, calendar: Calendar = .current, reference: Date = Date()) {
        self.repository = repository
        self.calendar = calendar
        self.reference = reference

        let today = calendar.startOfDay(for: reference)
        let monthAgo = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        customStart = monthAgo
        customEnd = today
        comparisonStart = calendar.date(byAdding: .year, value: -1, to: monthAgo) ?? monthAgo
        comparisonEnd = calendar.date(byAdding: .year, value: -1, to: today) ?? today
    }

    var currentRange: DateInterval? {
        period == .custom
            ? .days(from: customStart, to: customEnd, calendar: calendar)
            : period.range(endingAt: reference, calendar: calendar)
    }

    var comparisonRange: DateInterval? {
        switch comparisonMode {
        case .previous:
            return currentRange.map { DateInterval(start: $0.start.addingTimeInterval(-$0.duration), end: $0.start) }
        case .custom:
            return .days(from: comparisonStart, to: comparisonEnd, calendar: calendar)
        }
    }

    var comparisonLabel: String? {
        comparisonRange.map(label(for:))
    }

    var comparisonDistanceText: String? {
        guard let current = currentRange, let comparison = comparisonRange else { return nil }
        let days = { (range: DateInterval) in
            self.calendar.dateComponents([.day], from: range.start, to: range.end).day ?? 0
        }
        let gap = abs(calendar.dateComponents([.day], from: comparison.start, to: current.start).day ?? 0)
        let lengths =
            days(current) == days(comparison)
            ? AppLanguage.format("%@ giorni ciascuno", days(current))
            : AppLanguage.format(
                "%@ giorni vs %@", days(current), days(comparison))
        return AppLanguage.format(
            "%@ · a %@ %@ di distanza", lengths, gap,
            gap == 1 ? AppLanguage.text("giorno") : AppLanguage.text("giorni"))
    }

    var currentLabel: String? {
        currentRange.map(label(for:))
    }

    private func label(for range: DateInterval) -> String {
        let last = range.end.addingTimeInterval(-1)
        let style = Date.FormatStyle(locale: AppLanguage.locale).day().month(.abbreviated)
        let sameYear = calendar.component(.year, from: range.start) == calendar.component(.year, from: last)
        let start = sameYear ? range.start.formatted(style) : range.start.formatted(style.year())
        return "\(start) – \(last.formatted(style.year()))"
    }

    func load() async {
        let snapshot = await repository.loadIndex()
        items = snapshot.items
        let present = Set(items.map(\.activityType))
        availableActivityTypes = WorkoutActivityType.allCases.filter { present.contains($0) }
        if activityTypes.intersection(present).isEmpty, let first = availableActivityTypes.first {
            activityTypes = [first]
        }
        recompute()
    }

    private func recompute() {
        let range = currentRange
        let scoped = TrendsAggregator.filter(items, activityTypes: activityTypes, range: range)

        let span = range?.duration ?? scopedSpan(scoped)
        volumeResolution = TrendsAggregator.volumeResolution(for: span)
        volume = TrendsAggregator.buckets(
            scoped, resolution: volumeResolution, range: range, calendar: calendar, reference: reference)

        let today = calendar.startOfDay(for: reference)
        let consistencyRange =
            range
            ?? scoped.map(\.startDate).min().map {
                DateInterval.days(from: $0, to: today, calendar: calendar)
            }
        let cells =
            consistencyRange.map {
                TrendsAggregator.dayCells(scoped, range: $0, calendar: calendar, reference: reference)
            } ?? []
        consistencyColumns = TrendsAggregator.weekColumns(cells, calendar: calendar)

        let counted = cells.filter { consistencyRange?.contains($0.date) ?? false }
        consistency = ConsistencySummary(
            activeDays: counted.filter { $0.meters > 0 }.count,
            totalDays: counted.count,
            maxMeters: max(cells.map(\.meters).max() ?? 0, 1),
            weeks: consistencyColumns.count,
            meters: counted.reduce(0) { $0 + $1.meters }
        )

        kpis = makeKPIs(current: scoped)
        recomputeRunSeries(scoped: scoped)
        loadDetailsIfNeeded(for: scoped)
    }

    private func recomputeRunSeries(scoped: [WorkoutListItem]) {
        runs = TrendsAggregator.runPoints(scoped, details: details)
        paceSeries = TrendsAggregator.paceSeries(runs, calendar: calendar)
        paceTrend = TrendsAggregator.paceBuckets(runs, resolution: .week, calendar: calendar)
            .map { TrendPoint(start: $0.start, pace: $0.averagePace) }

        let withHeartRate = runs.filter { $0.averageHeartRate != nil }
        if withHeartRate.count > TrendsAggregator.maxScatterPoints {
            let buckets = TrendsAggregator.paceBuckets(withHeartRate, resolution: .week, calendar: calendar)
            efficiency = Self.efficiencyPoints(
                buckets.map { bucket in
                    (bucket.start, bucket.averagePace, bucket.averageHeartRate ?? 0, bucket.count)
                })
            isEfficiencyAggregated = true
        } else {
            efficiency = Self.efficiencyPoints(
                withHeartRate.map { ($0.date, $0.paceSecondsPerKilometer, $0.averageHeartRate ?? 0, 1) })
            isEfficiencyAggregated = false
        }
    }

    private static func efficiencyPoints(_ raw: [(date: Date, pace: Double, heartRate: Double, count: Int)])
        -> [EfficiencyPoint]
    {
        guard let first = raw.first?.date.timeIntervalSince1970, let last = raw.last?.date.timeIntervalSince1970 else {
            return []
        }
        let span = max(last - first, 1)
        return raw.map { point in
            EfficiencyPoint(
                id: point.date,
                date: point.date,
                paceSecondsPerKilometer: point.pace,
                heartRate: point.heartRate,
                recency: (point.date.timeIntervalSince1970 - first) / span,
                count: point.count
            )
        }
    }

    private func scopedSpan(_ scoped: [WorkoutListItem]) -> TimeInterval {
        guard let first = scoped.map(\.startDate).min() else { return 0 }
        return reference.timeIntervalSince(first)
    }

    private func makeKPIs(current: [WorkoutListItem]) -> [KPI] {
        let totals = TrendsAggregator.totals(current)
        let previous = comparisonRange.map {
            TrendsAggregator.totals(TrendsAggregator.filter(items, activityTypes: activityTypes, range: $0))
        }

        return [
            KPI(
                title: AppLanguage.text("Distanza"),
                value: WorkoutFormatting.distance(totals.meters) ?? "0 km",
                change: previous.flatMap {
                    TrendsAggregator.relativeChange(current: totals.meters, previous: $0.meters)
                },
                direction: .upIsGood,
                symbolName: "point.topleft.down.to.point.bottomright.curvepath",
                comparisonValue: previous.map { WorkoutFormatting.distance($0.meters) ?? "0 km" }
            ),
            KPI(
                title: AppLanguage.text("Attività"),
                value: "\(totals.count)",
                change: previous.flatMap {
                    TrendsAggregator.relativeChange(current: Double(totals.count), previous: Double($0.count))
                },
                direction: .upIsGood,
                symbolName: "figure.run",
                comparisonValue: previous.map { "\($0.count)" }
            ),
            KPI(
                title: AppLanguage.text("Tempo"),
                value: WorkoutFormatting.duration(totals.seconds),
                change: previous.flatMap {
                    TrendsAggregator.relativeChange(current: totals.seconds, previous: $0.seconds)
                },
                direction: .neutral,
                symbolName: "clock",
                comparisonValue: previous.map { WorkoutFormatting.duration($0.seconds) }
            ),
            KPI(
                title: AppLanguage.text("Passo medio"),
                value: WorkoutFormatting.pace(secondsPerKilometer: totals.paceSecondsPerKilometer) ?? "–",
                change: zip(totals.paceSecondsPerKilometer, previous?.paceSecondsPerKilometer)
                    .flatMap { TrendsAggregator.relativeChange(current: $0, previous: $1) },
                direction: .downIsGood,
                symbolName: "speedometer",
                comparisonValue: previous.map {
                    WorkoutFormatting.pace(secondsPerKilometer: $0.paceSecondsPerKilometer) ?? "–"
                }
            ),
        ]
    }

    private func loadDetailsIfNeeded(for scoped: [WorkoutListItem]) {
        let missing = scoped.filter { details[$0.id] == nil && ($0.distanceInMeters ?? 0) >= 500 }.map(\.id)
        detailTask?.cancel()
        guard !missing.isEmpty else {
            isLoadingDetails = false
            return
        }

        isLoadingDetails = true
        detailsLoaded = 0
        detailsTotal = missing.count
        detailTask = Task { [weak self] in
            guard let self else { return }

            for chunk in missing.chunked(into: 20) {
                if Task.isCancelled { return }
                if let loaded = try? await repository.loadDetails(for: chunk) {
                    for detail in loaded { details[detail.id] = detail }
                }
                if Task.isCancelled { return }
                detailsLoaded += chunk.count
                recomputeRunSeries(
                    scoped: TrendsAggregator.filter(
                        items,
                        activityTypes: activityTypes,
                        range: currentRange
                    ))
            }
            isLoadingDetails = false
        }
    }

    var hasData: Bool {
        volume.contains { $0.count > 0 }
    }

    var hasComparison: Bool {
        comparisonRange != nil
    }

    var currentBucketStart: Date? {
        TrendsAggregator.startOfPeriod(reference, resolution: volumeResolution, calendar: calendar)
    }

    var detailsProgressText: String? {
        isLoadingDetails ? "FC \(detailsLoaded)/\(detailsTotal)" : nil
    }

    func volumeBucket(containing date: Date) -> VolumeBucket? {
        guard let start = TrendsAggregator.startOfPeriod(date, resolution: volumeResolution, calendar: calendar) else {
            return nil
        }
        return volume.first { $0.start == start }
    }

    func run(nearest date: Date) -> RunPoint? {
        Self.nearest(in: runs, to: date, key: \.date)
    }

    func paceBucket(nearest date: Date) -> PaceBucket? {
        guard case .buckets(let buckets, _) = paceSeries else { return nil }
        return Self.nearest(in: buckets, to: date, key: \.start)
    }

    private static func nearest<T>(in sorted: [T], to date: Date, key: KeyPath<T, Date>) -> T? {
        guard !sorted.isEmpty else { return nil }
        var low = 0
        var high = sorted.count - 1
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid][keyPath: key] < date { low = mid + 1 } else { high = mid }
        }
        let candidate = sorted[low]
        guard low > 0 else { return candidate }
        let previous = sorted[low - 1]
        return abs(previous[keyPath: key].timeIntervalSince(date))
            <= abs(candidate[keyPath: key].timeIntervalSince(date))
            ? previous : candidate
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
