import Foundation

public struct TrainingBriefing: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let today: TodayStatus
    public let plan: [PlanItem]
    public let week: [SessionSummary]
    public let series: TrendSeries

    public let weekZones: WeekZones?

    public let readiness: Readiness?

    public init(
        generatedAt: Date, today: TodayStatus, plan: [PlanItem],
        week: [SessionSummary], series: TrendSeries, weekZones: WeekZones? = nil,
        readiness: Readiness? = nil
    ) {
        self.generatedAt = generatedAt
        self.today = today
        self.plan = plan
        self.week = week
        self.series = series
        self.weekZones = weekZones
        self.readiness = readiness
    }

    public func replacingPlan(_ plan: [PlanItem]) -> TrainingBriefing {
        TrainingBriefing(
            generatedAt: generatedAt, today: today, plan: plan, week: week, series: series,
            weekZones: weekZones, readiness: readiness
        )
    }
}

public struct Readiness: Codable, Sendable, Equatable {

    public let day: String
    public let score: Double

    public let components: [ReadinessComponent]

    public let history: [ReadinessPoint]

    public init(
        day: String, score: Double, components: [ReadinessComponent], history: [ReadinessPoint]
    ) {
        self.day = day
        self.score = score
        self.components = components
        self.history = history
    }

    public var limiter: ReadinessComponent? {
        components.filter { $0.subscore < 6 }.min { $0.subscore < $1.subscore }
    }
}

public struct ReadinessComponent: Codable, Sendable, Equatable, Identifiable {

    public let key: String

    public let value: Double
    public let unit: String

    public let normalLow: Double
    public let normalHigh: Double

    public let subscore: Double

    public let weight: Double

    public let napHours: Double?

    public var id: String { key }

    public init(
        key: String, value: Double, unit: String, normalLow: Double, normalHigh: Double,
        subscore: Double, weight: Double, napHours: Double? = nil
    ) {
        self.key = key
        self.napHours = napHours
        self.value = value
        self.unit = unit
        self.normalLow = normalLow
        self.normalHigh = normalHigh
        self.subscore = subscore
        self.weight = weight
    }

    public enum Position: Sendable { case below, within, above }

    public var position: Position {
        value < normalLow ? .below : value > normalHigh ? .above : .within
    }
}

public struct ReadinessPoint: Codable, Sendable, Equatable, Identifiable {
    public let day: String
    public let score: Double

    public let components: [ReadinessComponent]

    public let restEpisodes: [RestEpisode]
    public var id: String { day }

    public init(
        day: String, score: Double, components: [ReadinessComponent] = [],
        restEpisodes: [RestEpisode] = []
    ) {
        self.day = day
        self.score = score
        self.components = components
        self.restEpisodes = restEpisodes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(String.self, forKey: .day)
        score = try container.decode(Double.self, forKey: .score)
        components = try container.decodeIfPresent([ReadinessComponent].self, forKey: .components) ?? []
        restEpisodes = try container.decodeIfPresent([RestEpisode].self, forKey: .restEpisodes) ?? []
    }

    public var date: Date? { SeriesDate.day(day) }

    public var limiter: ReadinessComponent? {
        components.filter { $0.subscore < 6 }.min { $0.subscore < $1.subscore }
    }
}

public struct WeekZones: Codable, Sendable, Equatable {

    public let weekStart: String

    public let zoneFloors: [Int]

    public let zonesSource: String
    public let target: WeekTarget

    public let done: [Double]

    public let unzoned: Double

    public let forecast: [DayForecast]

    public init(
        weekStart: String, zoneFloors: [Int], zonesSource: String, target: WeekTarget,
        done: [Double], unzoned: Double, forecast: [DayForecast]
    ) {
        self.weekStart = weekStart
        self.zoneFloors = zoneFloors
        self.zonesSource = zonesSource
        self.target = target
        self.done = done
        self.unzoned = unzoned
        self.forecast = forecast
    }

    public var doneTotal: Double { done.reduce(0, +) + unzoned }
    public var doneEasy: Double { ZoneBand.easy.sum(done) }
    public var doneQuality: Double { ZoneBand.quality.sum(done) }

    public var expected: [Double] {
        (0..<5).map { zone in forecast.reduce(0) { $0 + $1.expectedKilometres(in: zone) } }
    }

    public var missingEasy: Double {
        target.easyKilometres - doneEasy - ZoneBand.easy.sum(expected)
    }

    public var missingQuality: Double {
        target.qualityKilometres - doneQuality - ZoneBand.quality.sum(expected)
    }

    public var freeDays: [DayForecast] { forecast.filter { $0.probability < 0.5 } }
}

public enum ZoneBand {
    case easy, quality

    public var zones: ClosedRange<Int> { self == .easy ? 0...1 : 2...4 }

    public func sum(_ perZone: [Double]) -> Double {
        zones.reduce(0) { $0 + (perZone.indices.contains($1) ? perZone[$1] : 0) }
    }
}

public struct WeekTarget: Codable, Sendable, Equatable {
    public let kilometres: Double

    public let easyShare: Double

    public let source: String

    public init(kilometres: Double, easyShare: Double, source: String) {
        self.kilometres = kilometres
        self.easyShare = easyShare
        self.source = source
    }

    public var easyKilometres: Double { kilometres * easyShare }
    public var qualityKilometres: Double { kilometres - easyKilometres }
}

public struct DayForecast: Codable, Sendable, Equatable, Identifiable {

    public let day: String

    public let probability: Double

    public let kilometres: Double

    public let zoneShare: [Double]

    public let weeksWithRun: Int
    public let weeksObserved: Int

    public let usualPlanName: String?

    public var id: String { day }

    public init(
        day: String, probability: Double, kilometres: Double, zoneShare: [Double],
        weeksWithRun: Int, weeksObserved: Int, usualPlanName: String?
    ) {
        self.day = day
        self.probability = probability
        self.kilometres = kilometres
        self.zoneShare = zoneShare
        self.weeksWithRun = weeksWithRun
        self.weeksObserved = weeksObserved
        self.usualPlanName = usualPlanName
    }

    public func expectedKilometres(in zone: Int) -> Double {
        guard zoneShare.indices.contains(zone) else { return 0 }
        return probability * kilometres * zoneShare[zone]
    }

    public var date: Date? { SeriesDate.day(day) }
}

public struct TodayStatus: Codable, Sendable, Equatable {
    public var sleepHours: Double?
    public var deepMinutes: Double?
    public var remMinutes: Double?

    public var sleepOnset: String?
    public var sleepWake: String?

    public var sleepHeartRate: Double?
    public var sleepHeartRateBaseline: Double?
    public var hrv: Double?
    public var hrvBaseline: Double?
    public var restingHeartRate: Double?
    public var restingHeartRateBaseline: Double?
    public var bodyMass: Double?
    public var leanMass: Double?
    public var fatPercent: Double?
    public var massDay: String?
    public var lastActivity: String?
    public var lastMinutes: Double?
    public var lastKilometres: Double?
    public var lastDaysAgo: Int?
    public var longRunDaysAgo: Int?
    public var longRunKilometres: Double?

    public init() {}

    public var hrvDeviation: Double? {
        guard let hrv, let hrvBaseline, hrvBaseline > 0 else { return nil }
        return (hrv - hrvBaseline) / hrvBaseline * 100
    }

    public var restingDeviation: Double? {
        guard let restingHeartRate, let restingHeartRateBaseline else { return nil }
        return restingHeartRate - restingHeartRateBaseline
    }

    public var sleepHeartRateDeviation: Double? {
        guard let sleepHeartRate, let sleepHeartRateBaseline else { return nil }
        return sleepHeartRate - sleepHeartRateBaseline
    }
}

public struct PlanItem: Codable, Sendable, Equatable, Identifiable {

    public let day: String

    public let slot: String
    public let title: String
    public let detail: String?
    public let target: String?
    public var done: Bool
    public var rpe: Int?
    public var note: String?

    public var id: String { "\(day)|\(slot)" }

    public init(
        day: String, slot: String, title: String, detail: String?, target: String?,
        done: Bool, rpe: Int?, note: String?
    ) {
        self.day = day
        self.slot = slot
        self.title = title
        self.detail = detail
        self.target = target
        self.done = done
        self.rpe = rpe
        self.note = note
    }

    public var date: Date? {
        PlanItem.dayFormatter.date(from: day)
    }

    public var heartRateRange: ClosedRange<Double>? {
        PlanItem.heartRateRange(in: target)
    }

    public static func heartRateRange(in target: String?) -> ClosedRange<Double>? {
        guard let target else { return nil }
        let numbers =
            target
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
            .filter { (90...220).contains($0) }
        guard numbers.count >= 2, numbers[0] < numbers[1] else { return nil }
        return Double(numbers[0])...Double(numbers[1])
    }

    public static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public let day: String
    public let activity: String
    public let minutes: Double
    public let kilometres: Double?
    public let pace: String?
    public let planName: String?

    public let heartRate: Double?

    public var id: String { "\(day)|\(activity)|\(minutes)" }

    public init(
        day: String, activity: String, minutes: Double, kilometres: Double?,
        pace: String?, planName: String?, heartRate: Double? = nil
    ) {
        self.day = day
        self.activity = activity
        self.minutes = minutes
        self.kilometres = kilometres
        self.pace = pace
        self.planName = planName
        self.heartRate = heartRate
    }
}

public struct TrendSeries: Codable, Sendable, Equatable {
    public var volume: [WeekVolume]
    public var recovery: [DayRecovery]
    public var sleep: [NightSleep]
    public var body: [BodyPoint]
    public var form: [FormPoint]
    public var fitness: [FitnessPoint]

    public init(
        volume: [WeekVolume] = [], recovery: [DayRecovery] = [], sleep: [NightSleep] = [],
        body: [BodyPoint] = [], form: [FormPoint] = [], fitness: [FitnessPoint] = []
    ) {
        self.volume = volume
        self.recovery = recovery
        self.sleep = sleep
        self.body = body
        self.form = form
        self.fitness = fitness
    }
}

public struct FitnessPoint: Codable, Sendable, Equatable, Identifiable {
    public let month: String
    public let vo2Max: Double?
    public let samples: Int
    public var id: String { month }

    public init(month: String, vo2Max: Double?, samples: Int) {
        self.month = month
        self.vo2Max = vo2Max
        self.samples = samples
    }

    public var date: Date? { SeriesDate.month(month) }
}

public enum SeriesDate {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    public static func day(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
        )
    }

    public static func month(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 15))
    }

    public static func week(_ value: String) -> Date? {
        let parts = value.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]),
            let week = Int(parts[1].dropFirst())
        else { return nil }
        var components = DateComponents()
        components.yearForWeekOfYear = year
        components.weekOfYear = max(1, week)
        components.weekday = 2
        components.hour = 12
        return calendar.date(from: components)
    }
}

public struct WeekVolume: Codable, Sendable, Equatable, Identifiable {
    public let week: String
    public let kilometres: Double?
    public let runs: Int
    public let strength: Int
    public let climbing: Int
    public let hours: Double?
    public var id: String { week }

    public init(
        week: String, kilometres: Double?, runs: Int, strength: Int, climbing: Int, hours: Double?
    ) {
        self.week = week
        self.kilometres = kilometres
        self.runs = runs
        self.strength = strength
        self.climbing = climbing
        self.hours = hours
    }

    public var date: Date? { SeriesDate.week(week) }
}

public struct DayRecovery: Codable, Sendable, Equatable, Identifiable {
    public let day: String
    public let restingHeartRate: Double?
    public let hrv: Double?
    public var id: String { day }

    public init(day: String, restingHeartRate: Double?, hrv: Double?) {
        self.day = day
        self.restingHeartRate = restingHeartRate
        self.hrv = hrv
    }

    public var date: Date? { SeriesDate.day(day) }
}

public struct NightSleep: Codable, Sendable, Equatable, Identifiable {
    public let night: String
    public let hours: Double
    public var id: String { night }

    public init(night: String, hours: Double) {
        self.night = night
        self.hours = hours
    }

    public var date: Date? { SeriesDate.day(night) }
}

public struct BodyPoint: Codable, Sendable, Equatable, Identifiable {
    public let day: String
    public let mass: Double?
    public let lean: Double?
    public let fat: Double?
    public var id: String { day }

    public init(day: String, mass: Double?, lean: Double?, fat: Double?) {
        self.day = day
        self.mass = mass
        self.lean = lean
        self.fat = fat
    }

    public var date: Date? { SeriesDate.day(day) }
}

public struct FormPoint: Codable, Sendable, Equatable, Identifiable {
    public let month: String
    public let runs: Int
    public let speed: Double?
    public let heartRate: Double?
    public let efficiency: Double?
    public let cadence: Double?
    public let groundContact: Double?
    public var id: String { month }

    public init(
        month: String, runs: Int, speed: Double?, heartRate: Double?, efficiency: Double?,
        cadence: Double?, groundContact: Double?
    ) {
        self.month = month
        self.runs = runs
        self.speed = speed
        self.heartRate = heartRate
        self.efficiency = efficiency
        self.cadence = cadence
        self.groundContact = groundContact
    }

    public var date: Date? { SeriesDate.month(month) }
}

public struct RestEpisode: Codable, Sendable, Equatable, Identifiable {
    public let start: Date
    public let end: Date

    public let heartRate: Double

    public let sleepingHeartRate: Double

    public var id: Date { start }
    public var minutes: Double { end.timeIntervalSince(start) / 60 }

    public init(start: Date, end: Date, heartRate: Double, sleepingHeartRate: Double) {
        self.start = start
        self.end = end
        self.heartRate = heartRate
        self.sleepingHeartRate = sleepingHeartRate
    }
}

public struct PlanMark: Codable, Sendable, Equatable {
    public let day: String
    public let slot: String
    public let done: Bool
    public let rpe: Int?
    public let note: String?
    public let markedAt: Date

    public init(day: String, slot: String, done: Bool, rpe: Int?, note: String?, markedAt: Date) {
        self.day = day
        self.slot = slot
        self.done = done
        self.rpe = rpe
        self.note = note
        self.markedAt = markedAt
    }
}
