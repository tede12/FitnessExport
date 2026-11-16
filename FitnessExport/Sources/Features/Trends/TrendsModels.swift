import FitnessUI
import Foundation

enum TrendsPeriod: String, CaseIterable, Identifiable, Sendable {
    case fourWeeks
    case threeMonths
    case sixMonths
    case year
    case all

    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fourWeeks: return AppLanguage.text("4 sett.")
        case .threeMonths: return AppLanguage.text("3 mesi")
        case .sixMonths: return AppLanguage.text("6 mesi")
        case .year: return AppLanguage.text("1 anno")
        case .all: return AppLanguage.text("Tutto")
        case .custom: return AppLanguage.text("Date")
        }
    }

    func range(endingAt reference: Date, calendar: Calendar) -> DateInterval? {
        let end = calendar.startOfDay(for: reference).addingTimeInterval(86_400)
        let start: Date?
        switch self {
        case .fourWeeks: start = calendar.date(byAdding: .day, value: -28, to: end)
        case .threeMonths: start = calendar.date(byAdding: .month, value: -3, to: end)
        case .sixMonths: start = calendar.date(byAdding: .month, value: -6, to: end)
        case .year: start = calendar.date(byAdding: .year, value: -1, to: end)
        case .all, .custom: start = nil
        }
        return start.map { DateInterval(start: $0, end: end) }
    }
}

enum ComparisonMode: String, CaseIterable, Identifiable, Sendable {

    case previous

    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .previous: return AppLanguage.text("Precedente")
        case .custom: return AppLanguage.text("Date specifiche")
        }
    }
}

extension DateInterval {

    static func days(from: Date, to: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: min(from, to))
        let end = calendar.startOfDay(for: max(from, to)).addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }
}

enum SeriesResolution: Equatable, Sendable, CaseIterable {
    case week
    case month
    case quarter

    var singular: String {
        switch self {
        case .week: return AppLanguage.text("settimana")
        case .month: return AppLanguage.text("mese")
        case .quarter: return "trimestre"
        }
    }

    var plural: String {
        switch self {
        case .week: return AppLanguage.text("settimane")
        case .month: return AppLanguage.text("mesi")
        case .quarter: return "trimestri"
        }
    }

    var approximateDays: Double {
        switch self {
        case .week: return 7
        case .month: return 30.44
        case .quarter: return 91.31
        }
    }

    func advancing(_ date: Date, calendar: Calendar) -> Date? {
        switch self {
        case .week: return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .month: return calendar.date(byAdding: .month, value: 1, to: date)
        case .quarter: return calendar.date(byAdding: .month, value: 3, to: date)
        }
    }
}

struct VolumeBucket: Identifiable, Equatable, Sendable {
    let start: Date
    var meters: Double
    var seconds: TimeInterval
    var count: Int

    var id: Date { start }
    var kilometers: Double { meters / 1_000 }
    var paceSecondsPerKilometer: Double? { meters > 0 ? seconds / (meters / 1_000) : nil }
}

struct RunPoint: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let meters: Double
    let seconds: TimeInterval
    let averageHeartRate: Double?

    var kilometers: Double { meters / 1_000 }
    var paceSecondsPerKilometer: Double { seconds / (meters / 1_000) }
}

struct PaceBucket: Identifiable, Equatable, Sendable {
    let start: Date
    let count: Int
    let meters: Double
    let seconds: TimeInterval
    let minPace: Double
    let maxPace: Double

    let averageHeartRate: Double?

    var id: Date { start }
    var kilometers: Double { meters / 1_000 }
    var averagePace: Double { seconds / (meters / 1_000) }
}

enum PaceSeries: Equatable, Sendable {
    case runs([RunPoint])
    case buckets([PaceBucket], resolution: SeriesResolution)

    var isEmpty: Bool {
        switch self {
        case .runs(let runs): return runs.isEmpty
        case .buckets(let buckets, _): return buckets.isEmpty
        }
    }
}

struct DayCell: Identifiable, Equatable, Sendable {
    let date: Date
    let meters: Double

    var id: Date { date }
}

struct PeriodTotals: Equatable, Sendable {
    var meters: Double = 0
    var seconds: TimeInterval = 0
    var count: Int = 0

    var paceSecondsPerKilometer: Double? { meters > 0 ? seconds / (meters / 1_000) : nil }
}

enum TrendsAggregator {

    static let maxScatterPoints = 150

    static let maxVolumeBars = 60

    static func filter(_ items: [WorkoutListItem], activityTypes: Set<WorkoutActivityType>, range: DateInterval?)
        -> [WorkoutListItem]
    {
        items.filter { item in
            activityTypes.contains(item.activityType) && (range?.contains(item.startDate) ?? true)
        }
    }

    static func totals(_ items: [WorkoutListItem]) -> PeriodTotals {
        items.reduce(into: PeriodTotals()) { totals, item in
            totals.meters += item.distanceInMeters ?? 0
            totals.seconds += item.duration
            totals.count += 1
        }
    }

    static func volumeResolution(for span: TimeInterval, maxBars: Int = maxVolumeBars) -> SeriesResolution {
        let days = max(span / 86_400, 1)
        for resolution in SeriesResolution.allCases where days / resolution.approximateDays <= Double(maxBars) {
            return resolution
        }
        return .quarter
    }

    static func weeks(_ items: [WorkoutListItem], range: DateInterval?, calendar: Calendar, reference: Date)
        -> [VolumeBucket]
    {
        buckets(items, resolution: .week, range: range, calendar: calendar, reference: reference)
    }

    static func buckets(
        _ items: [WorkoutListItem],
        resolution: SeriesResolution,
        range: DateInterval?,
        calendar: Calendar,
        reference: Date
    ) -> [VolumeBucket] {
        guard let first = range?.start ?? items.map(\.startDate).min() else { return [] }
        let end = range?.end ?? calendar.startOfDay(for: reference).addingTimeInterval(86_400)
        guard let firstBucket = startOfPeriod(first, resolution: resolution, calendar: calendar) else { return [] }

        var buckets: [Date: VolumeBucket] = [:]
        var cursor = firstBucket
        while cursor < end {
            buckets[cursor] = VolumeBucket(start: cursor, meters: 0, seconds: 0, count: 0)
            guard let next = resolution.advancing(cursor, calendar: calendar) else { break }
            cursor = next
        }

        for item in items {
            guard let start = startOfPeriod(item.startDate, resolution: resolution, calendar: calendar),
                buckets[start] != nil
            else { continue }
            buckets[start]!.meters += item.distanceInMeters ?? 0
            buckets[start]!.seconds += item.duration
            buckets[start]!.count += 1
        }
        return buckets.values.sorted { $0.start < $1.start }
    }

    static func runPoints(_ items: [WorkoutListItem], details: [UUID: WorkoutDetailSnapshot]) -> [RunPoint] {
        items.compactMap { item in
            guard let meters = item.distanceInMeters, meters >= 500, item.duration > 0 else { return nil }
            return RunPoint(
                id: item.id,
                date: item.startDate,
                meters: meters,
                seconds: item.duration,
                averageHeartRate: details[item.id]?.averageHeartRate
            )
        }
        .sorted { $0.date < $1.date }
    }

    static func paceSeries(_ runs: [RunPoint], calendar: Calendar, maxPoints: Int = maxScatterPoints) -> PaceSeries {
        guard runs.count > maxPoints, let first = runs.first?.date, let last = runs.last?.date else {
            return .runs(runs)
        }
        let resolution = volumeResolution(for: last.timeIntervalSince(first), maxBars: maxVolumeBars)
        return .buckets(paceBuckets(runs, resolution: resolution, calendar: calendar), resolution: resolution)
    }

    static func paceBuckets(_ runs: [RunPoint], resolution: SeriesResolution, calendar: Calendar) -> [PaceBucket] {
        var grouped: [Date: [RunPoint]] = [:]
        for run in runs {
            guard let start = startOfPeriod(run.date, resolution: resolution, calendar: calendar) else { continue }
            grouped[start, default: []].append(run)
        }
        return grouped.map { start, group in
            let meters = group.reduce(0) { $0 + $1.meters }
            let seconds = group.reduce(0) { $0 + $1.seconds }
            let paces = group.map(\.paceSecondsPerKilometer)
            let withHeartRate = group.compactMap { run in run.averageHeartRate.map { ($0, run.seconds) } }
            let heartRate: Double? =
                withHeartRate.isEmpty
                ? nil
                : withHeartRate.reduce(0) { $0 + $1.0 * $1.1 } / withHeartRate.reduce(0) { $0 + $1.1 }
            return PaceBucket(
                start: start,
                count: group.count,
                meters: meters,
                seconds: seconds,
                minPace: paces.min() ?? 0,
                maxPace: paces.max() ?? 0,
                averageHeartRate: heartRate
            )
        }
        .sorted { $0.start < $1.start }
    }

    static func dayCells(_ items: [WorkoutListItem], weeks: Int, calendar: Calendar, reference: Date) -> [DayCell] {
        let today = calendar.startOfDay(for: reference)
        guard let thisWeek = startOfWeek(today, calendar: calendar),
            let firstDay = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)
        else { return [] }

        var metersByDay: [Date: Double] = [:]
        for item in items {
            let day = calendar.startOfDay(for: item.startDate)
            guard day >= firstDay, day <= today else { continue }
            metersByDay[day, default: 0] += item.distanceInMeters ?? 0
        }

        var cells: [DayCell] = []
        var cursor = firstDay
        while cursor <= today {
            cells.append(DayCell(date: cursor, meters: metersByDay[cursor] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return cells
    }

    static func dayCells(_ items: [WorkoutListItem], range: DateInterval, calendar: Calendar, reference: Date)
        -> [DayCell]
    {
        let today = calendar.startOfDay(for: reference)
        let lastDay = min(calendar.startOfDay(for: range.end.addingTimeInterval(-1)), today)
        guard let firstDay = startOfWeek(range.start, calendar: calendar), firstDay <= lastDay else { return [] }

        var metersByDay: [Date: Double] = [:]
        for item in items {
            let day = calendar.startOfDay(for: item.startDate)
            guard day >= firstDay, day <= lastDay else { continue }
            metersByDay[day, default: 0] += item.distanceInMeters ?? 0
        }

        var cells: [DayCell] = []
        var cursor = firstDay
        while cursor <= lastDay {
            cells.append(DayCell(date: cursor, meters: metersByDay[cursor] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return cells
    }

    static func weekColumns(_ cells: [DayCell], calendar: Calendar) -> [[DayCell?]] {
        var columns: [Date: [DayCell?]] = [:]
        for cell in cells {
            guard let week = startOfWeek(cell.date, calendar: calendar) else { continue }

            let index = (calendar.component(.weekday, from: cell.date) + 5) % 7
            var column = columns[week] ?? Array(repeating: nil, count: 7)
            column[index] = cell
            columns[week] = column
        }
        return columns.sorted { $0.key < $1.key }.map(\.value)
    }

    static func startOfWeek(_ date: Date, calendar: Calendar) -> Date? {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start
    }

    static func startOfPeriod(_ date: Date, resolution: SeriesResolution, calendar: Calendar) -> Date? {
        switch resolution {
        case .week:
            return startOfWeek(date, calendar: calendar)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start
        case .quarter:
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let month = components.month else { return nil }
            let quarterStart = ((month - 1) / 3) * 3 + 1
            return calendar.date(from: DateComponents(year: components.year, month: quarterStart, day: 1))
        }
    }

    static func relativeChange(current: Double, previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous
    }
}
