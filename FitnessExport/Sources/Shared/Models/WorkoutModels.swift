import FitnessUI
import Foundation

enum WorkoutActivityType: String, Codable, CaseIterable, Hashable, Sendable {
    case running
    case walking
    case cycling
    case hiking
    case swimming
    case other

    var searchNames: String {
        switch self {
        case .running: "running corsa"
        case .walking: "walking camminata"
        case .cycling: "cycling bici"
        case .hiking: "hiking escursione"
        case .swimming: "swimming nuoto"
        case .other: "other altro"
        }
    }

    var title: String {
        switch self {
        case .running:
            return AppLanguage.text("Corsa")
        case .walking:
            return AppLanguage.text("Camminata")
        case .cycling:
            return AppLanguage.text("Bici")
        case .hiking:
            return AppLanguage.text("Escursione")
        case .swimming:
            return AppLanguage.text("Nuoto")
        case .other:
            return AppLanguage.text("Altro")
        }
    }

    var symbolName: String {
        switch self {
        case .running:
            return "figure.run"
        case .walking:
            return "figure.walk"
        case .cycling:
            return "figure.outdoor.cycle"
        case .hiking:
            return "figure.hiking"
        case .swimming:
            return "figure.pool.swim"
        case .other:
            return "figure.mixed.cardio"
        }
    }
}

struct WorkoutMonthKey: Codable, Hashable, Comparable, Sendable, Identifiable {
    let year: Int
    let month: Int

    var id: String { "\(year)-\(String(format: "%02d", month))" }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month], from: date)
        self.year = components.year ?? 0
        self.month = components.month ?? 1
    }

    var startDate: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) ?? .distantPast
    }

    static func < (lhs: WorkoutMonthKey, rhs: WorkoutMonthKey) -> Bool {
        if lhs.year != rhs.year {
            return lhs.year < rhs.year
        }
        return lhs.month < rhs.month
    }
}

struct WorkoutListItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let activityType: WorkoutActivityType
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let distanceInMeters: Double?
    let activeEnergyKilocalories: Double?
    var hasHeartRateData: Bool
    var hasCadenceData: Bool

    var monthKey: WorkoutMonthKey { WorkoutMonthKey(date: startDate) }
}

struct WorkoutIndexSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var updatedAt: Date?
    var items: [WorkoutListItem]

    static let empty = WorkoutIndexSnapshot(updatedAt: nil, items: [])

    var availableMonths: [WorkoutMonthKey] {
        Array(Set(items.map(\.monthKey))).sorted(by: >)
    }

    var latestStartDate: Date? {
        items.map(\.startDate).max()
    }

    mutating func merge(with newItems: [WorkoutListItem]) {
        var merged = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in newItems {
            merged[item.id] = item
        }
        items = merged.values.sorted { $0.startDate > $1.startDate }
        updatedAt = Date()
    }

    mutating func updateAvailability(using details: [WorkoutDetailSnapshot]) {
        let detailMap = Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0) })
        items = items.map { item in
            guard let detail = detailMap[item.id] else { return item }
            var updated = item
            updated.hasHeartRateData = detail.hasHeartRateData
            updated.hasCadenceData = detail.hasCadenceData
            return updated
        }
    }
}

enum WorkoutPeriod: Equatable, Sendable {
    case months(Set<WorkoutMonthKey>)
    case custom(start: Date, end: Date)
}

struct RunSplitMetric: Identifiable, Codable, Equatable, Sendable {
    let kilometer: Int
    let duration: TimeInterval
    let paceSecondsPerKilometer: Double
    let averageHeartRate: Double?
    let averageCadence: Double?

    var id: Int { kilometer }
}

struct LapMetric: Identifiable, Codable, Equatable, Sendable {
    let index: Int
    let intensity: LapIntensity
    let name: String?

    let startOffset: TimeInterval
    let duration: TimeInterval
    let distanceInMeters: Double?
    let averageHeartRate: Double?
    let averageCadence: Double?

    var id: Int { index }

    var paceSecondsPerKilometer: Double? {
        guard let distanceInMeters, distanceInMeters >= 50, duration > 0 else { return nil }
        return duration / (distanceInMeters / 1_000)
    }
}

struct WorkoutDetailSnapshot: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let activityType: WorkoutActivityType
    let workoutName: String?
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let distanceInMeters: Double?
    let activeEnergyKilocalories: Double?
    let averageHeartRate: Double?
    let maxHeartRate: Double?
    let averageCadence: Double?
    let splits: [RunSplitMetric]

    let laps: [LapMetric]

    init(
        id: UUID,
        activityType: WorkoutActivityType,
        startDate: Date,
        endDate: Date,
        duration: TimeInterval,
        distanceInMeters: Double?,
        activeEnergyKilocalories: Double?,
        averageHeartRate: Double?,
        maxHeartRate: Double?,
        averageCadence: Double?,
        splits: [RunSplitMetric],
        laps: [LapMetric] = [],
        workoutName: String? = nil
    ) {
        self.id = id
        self.activityType = activityType
        self.workoutName = workoutName
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.distanceInMeters = distanceInMeters
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.averageCadence = averageCadence
        self.splits = splits
        self.laps = laps
    }

    var hasIntervals: Bool {
        laps.count >= 2
    }

    var hasHeartRateData: Bool {
        averageHeartRate != nil || maxHeartRate != nil || splits.contains(where: { $0.averageHeartRate != nil })
    }

    var hasCadenceData: Bool {
        averageCadence != nil || splits.contains(where: { $0.averageCadence != nil })
    }
}

struct WorkoutAnalysisSeries: Equatable, Sendable {
    struct HeartRateZone: Equatable, Sendable, Identifiable {
        let index: Int
        let minimumBPM: Double
        let maximumBPM: Double?
        var id: Int { index }
    }

    let workoutID: UUID
    let heartRate: [TimedValueSample]
    let power: [TimedValueSample]
    let heartRateZones: [HeartRateZone]
}

enum WorkoutFilter {
    static func filter(
        items: [WorkoutListItem],
        period: WorkoutPeriod,
        activityTypes: Set<WorkoutActivityType>
    ) -> [WorkoutListItem] {
        items
            .filter { item in
                switch period {
                case .months(let months):
                    return months.contains(item.monthKey)
                case .custom(let start, let end):
                    return item.startDate >= start && item.startDate <= end
                }
            }
            .filter { activityTypes.contains($0.activityType) }
            .sorted { $0.startDate > $1.startDate }
    }
}
