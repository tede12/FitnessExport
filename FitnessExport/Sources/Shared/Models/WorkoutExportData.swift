import Foundation

struct RoutePoint: Equatable, Sendable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double

    let altitude: Double?

    let speed: Double?
}

enum SwimStrokeStyle: Int, Equatable, Sendable {
    case unknown
    case mixed
    case freestyle
    case backstroke
    case breaststroke
    case butterfly
    case kickboard
}

struct SwimLength: Equatable, Sendable {
    let startDate: Date
    let endDate: Date
    let strokeCount: Double
    let style: SwimStrokeStyle
}

enum LapIntensity: String, Codable, Equatable, Sendable {

    case active

    case rest
    case warmup
    case cooldown

    case recovery
}

enum LapGoal: Equatable, Sendable {
    case open
    case time(TimeInterval)
    case distance(Double)
}

struct WorkoutLap: Equatable, Sendable {
    let interval: DateInterval
    let intensity: LapIntensity

    let name: String?

    let goal: LapGoal?

    init(interval: DateInterval, intensity: LapIntensity = .active, name: String? = nil, goal: LapGoal? = nil) {
        self.interval = interval
        self.intensity = intensity
        self.name = name
        self.goal = goal
    }

    init(start: Date, end: Date, intensity: LapIntensity = .active, name: String? = nil, goal: LapGoal? = nil) {
        self.init(interval: DateInterval(start: start, end: end), intensity: intensity, name: name, goal: goal)
    }
}

struct WorkoutExportData: Equatable, Sendable {
    let id: UUID
    let activityType: WorkoutActivityType
    let startDate: Date
    let endDate: Date

    let duration: TimeInterval
    let totalDistanceMeters: Double?
    let activeEnergyKilocalories: Double?

    let heartRateSamples: [TimedValueSample]

    let cadenceSamples: [TimedValueSample]

    let powerSamples: [TimedValueSample]

    let speedSamples: [TimedValueSample]

    let strideLengthSamples: [TimedValueSample]

    let verticalOscillationSamples: [TimedValueSample]

    let groundContactTimeSamples: [TimedValueSample]

    let temperatureSamples: [TimedValueSample]

    let energySegments: [DistanceSampleSegment]
    let distanceSegments: [DistanceSampleSegment]
    let routePoints: [RoutePoint]
    let swimLengths: [SwimLength]

    let pauses: [DateInterval]

    let laps: [WorkoutLap]

    let elevationAscendedMeters: Double?
    let elevationDescendedMeters: Double?
    let weatherTemperatureCelsius: Double?
    let isIndoor: Bool
    let poolLengthMeters: Double?
    let deviceName: String?
    let deviceModel: String?

    let timeZoneIdentifier: String?

    let workoutName: String?

    init(
        id: UUID,
        activityType: WorkoutActivityType,
        startDate: Date,
        endDate: Date,
        duration: TimeInterval,
        totalDistanceMeters: Double?,
        activeEnergyKilocalories: Double?,
        heartRateSamples: [TimedValueSample] = [],
        cadenceSamples: [TimedValueSample] = [],
        powerSamples: [TimedValueSample] = [],
        speedSamples: [TimedValueSample] = [],
        strideLengthSamples: [TimedValueSample] = [],
        verticalOscillationSamples: [TimedValueSample] = [],
        groundContactTimeSamples: [TimedValueSample] = [],
        temperatureSamples: [TimedValueSample] = [],
        energySegments: [DistanceSampleSegment] = [],
        distanceSegments: [DistanceSampleSegment] = [],
        routePoints: [RoutePoint] = [],
        swimLengths: [SwimLength] = [],
        pauses: [DateInterval] = [],
        laps: [WorkoutLap] = [],
        elevationAscendedMeters: Double? = nil,
        elevationDescendedMeters: Double? = nil,
        weatherTemperatureCelsius: Double? = nil,
        isIndoor: Bool = false,
        poolLengthMeters: Double? = nil,
        deviceName: String? = nil,
        deviceModel: String? = nil,
        timeZoneIdentifier: String? = nil,
        workoutName: String? = nil
    ) {
        self.id = id
        self.activityType = activityType
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.totalDistanceMeters = totalDistanceMeters
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.heartRateSamples = heartRateSamples
        self.cadenceSamples = cadenceSamples
        self.powerSamples = powerSamples
        self.speedSamples = speedSamples
        self.strideLengthSamples = strideLengthSamples
        self.verticalOscillationSamples = verticalOscillationSamples
        self.groundContactTimeSamples = groundContactTimeSamples
        self.temperatureSamples = temperatureSamples
        self.energySegments = energySegments
        self.distanceSegments = distanceSegments
        self.routePoints = routePoints
        self.swimLengths = swimLengths
        self.pauses = pauses
        self.laps = laps
        self.elevationAscendedMeters = elevationAscendedMeters
        self.elevationDescendedMeters = elevationDescendedMeters
        self.weatherTemperatureCelsius = weatherTemperatureCelsius
        self.isIndoor = isIndoor
        self.poolLengthMeters = poolLengthMeters
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.timeZoneIdentifier = timeZoneIdentifier
        self.workoutName = workoutName
    }

    var suggestedFileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let slug = activityType.title
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return "\(formatter.string(from: startDate))-\(slug).fit"
    }
}
