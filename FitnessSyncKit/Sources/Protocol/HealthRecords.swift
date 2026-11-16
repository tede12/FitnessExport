import Foundation

public struct QuantityRecord: Sendable, Equatable {
    public let uuid: UUID
    public let start: Date
    public let end: Date

    public let value: Double

    public let sourceIndex: Int

    public init(uuid: UUID, start: Date, end: Date, value: Double, sourceIndex: Int) {
        self.uuid = uuid
        self.start = start
        self.end = end
        self.value = value
        self.sourceIndex = sourceIndex
    }
}

public struct CategoryRecord: Sendable, Equatable {
    public let uuid: UUID
    public let start: Date
    public let end: Date
    public let value: Int
    public let sourceIndex: Int

    public init(uuid: UUID, start: Date, end: Date, value: Int, sourceIndex: Int) {
        self.uuid = uuid
        self.start = start
        self.end = end
        self.value = value
        self.sourceIndex = sourceIndex
    }
}

public struct WorkoutStatisticRecord: Codable, Sendable, Equatable {
    public let metricKey: String
    public let sum: Double?
    public let average: Double?
    public let minimum: Double?
    public let maximum: Double?

    public init(
        metricKey: String, sum: Double?, average: Double?, minimum: Double?, maximum: Double?
    ) {
        self.metricKey = metricKey
        self.sum = sum
        self.average = average
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct WorkoutEventRecord: Codable, Sendable, Equatable {

    public let type: Int
    public let start: Date
    public let end: Date
    public let metadata: [String: String]

    public init(type: Int, start: Date, end: Date, metadata: [String: String]) {
        self.type = type
        self.start = start
        self.end = end
        self.metadata = metadata
    }
}

public struct WorkoutActivityRecord: Codable, Sendable, Equatable {
    public let uuid: UUID
    public let start: Date
    public let end: Date?

    public let activityType: UInt

    public let locationType: Int
    public let metadata: [String: String]
    public let statistics: [WorkoutStatisticRecord]

    public init(
        uuid: UUID,
        start: Date,
        end: Date?,
        activityType: UInt,
        locationType: Int,
        metadata: [String: String],
        statistics: [WorkoutStatisticRecord]
    ) {
        self.uuid = uuid
        self.start = start
        self.end = end
        self.activityType = activityType
        self.locationType = locationType
        self.metadata = metadata
        self.statistics = statistics
    }
}

public struct PlannedStepRecord: Codable, Sendable, Equatable {
    public let index: Int

    public let role: String
    public let name: String?

    public let goalKind: String
    public let goalValue: Double?

    public let alert: String?

    public init(
        index: Int, role: String, name: String?, goalKind: String, goalValue: Double?,
        alert: String?
    ) {
        self.index = index
        self.role = role
        self.name = name
        self.goalKind = goalKind
        self.goalValue = goalValue
        self.alert = alert
    }
}

public struct WorkoutRecord: Codable, Sendable, Equatable {
    public let uuid: UUID

    public let activityType: UInt
    public let start: Date
    public let end: Date

    public let duration: TimeInterval
    public let totalDistance: Double?
    public let totalEnergy: Double?
    public let totalSwimmingStrokes: Double?
    public let totalFlights: Double?
    public let sourceName: String
    public let sourceBundleID: String
    public let sourceVersion: String?
    public let productType: String?
    public let deviceName: String?
    public let deviceModel: String?
    public let deviceHardware: String?
    public let deviceSoftware: String?
    public let timeZone: String?
    public let isIndoor: Bool?
    public let elevationAscended: Double?
    public let elevationDescended: Double?
    public let weatherTemperature: Double?
    public let weatherHumidity: Double?
    public let poolLength: Double?
    public let planName: String?

    public let metadata: [String: String]
    public let events: [WorkoutEventRecord]
    public let activities: [WorkoutActivityRecord]
    public let statistics: [WorkoutStatisticRecord]
    public let plannedSteps: [PlannedStepRecord]
    public let hasRoute: Bool

    public init(
        uuid: UUID, activityType: UInt, start: Date, end: Date, duration: TimeInterval,
        totalDistance: Double?, totalEnergy: Double?, totalSwimmingStrokes: Double?,
        totalFlights: Double?, sourceName: String, sourceBundleID: String,
        sourceVersion: String?, productType: String?, deviceName: String?, deviceModel: String?,
        deviceHardware: String?, deviceSoftware: String?, timeZone: String?, isIndoor: Bool?,
        elevationAscended: Double?, elevationDescended: Double?, weatherTemperature: Double?,
        weatherHumidity: Double?, poolLength: Double?, planName: String?,
        metadata: [String: String], events: [WorkoutEventRecord],
        activities: [WorkoutActivityRecord], statistics: [WorkoutStatisticRecord],
        plannedSteps: [PlannedStepRecord], hasRoute: Bool
    ) {
        self.uuid = uuid
        self.activityType = activityType
        self.start = start
        self.end = end
        self.duration = duration
        self.totalDistance = totalDistance
        self.totalEnergy = totalEnergy
        self.totalSwimmingStrokes = totalSwimmingStrokes
        self.totalFlights = totalFlights
        self.sourceName = sourceName
        self.sourceBundleID = sourceBundleID
        self.sourceVersion = sourceVersion
        self.productType = productType
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.deviceHardware = deviceHardware
        self.deviceSoftware = deviceSoftware
        self.timeZone = timeZone
        self.isIndoor = isIndoor
        self.elevationAscended = elevationAscended
        self.elevationDescended = elevationDescended
        self.weatherTemperature = weatherTemperature
        self.weatherHumidity = weatherHumidity
        self.poolLength = poolLength
        self.planName = planName
        self.metadata = metadata
        self.events = events
        self.activities = activities
        self.statistics = statistics
        self.plannedSteps = plannedSteps
        self.hasRoute = hasRoute
    }
}

public struct RoutePointRecord: Sendable, Equatable {
    public let timestamp: Date
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    public let horizontalAccuracy: Double
    public let verticalAccuracy: Double
    public let speed: Double
    public let course: Double

    public init(
        timestamp: Date, latitude: Double, longitude: Double, altitude: Double,
        horizontalAccuracy: Double, verticalAccuracy: Double, speed: Double, course: Double
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.course = course
    }
}

public struct RouteRecord: Sendable, Equatable {
    public let workoutUUID: UUID
    public let points: [RoutePointRecord]

    public init(workoutUUID: UUID, points: [RoutePointRecord]) {
        self.workoutUUID = workoutUUID
        self.points = points
    }
}

public struct SourceRecord: Codable, Sendable, Equatable, Hashable {
    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public struct AthleteProfile: Codable, Sendable, Equatable {
    public let dateOfBirth: Date?

    public let biologicalSex: String?
    public let bloodType: String?

    public let bodyMassKg: Double?

    public let heightM: Double?

    public init(
        dateOfBirth: Date?, biologicalSex: String?, bloodType: String?,
        bodyMassKg: Double?, heightM: Double?
    ) {
        self.dateOfBirth = dateOfBirth
        self.biologicalSex = biologicalSex
        self.bloodType = bloodType
        self.bodyMassKg = bodyMassKg
        self.heightM = heightM
    }

    public var ageYears: Int? {
        guard let dateOfBirth else { return nil }
        return Calendar.current.dateComponents([.year], from: dateOfBirth, to: Date()).year
    }
}

public enum WorkoutActivityNames {
    public static func name(for rawValue: UInt) -> String {
        table[rawValue] ?? "other (\(rawValue))"
    }

    public static var all: [(rawValue: UInt, name: String)] {
        table.map { ($0.key, $0.value) }.sorted { $0.rawValue < $1.rawValue }
    }

    private static let table: [UInt: String] = [
        1: "american football", 2: "archery", 3: "australian football", 4: "badminton",
        5: "baseball", 6: "basketball", 7: "bowling", 8: "boxing", 9: "climbing",
        10: "cricket", 11: "cross training", 12: "curling", 13: "cycling", 14: "dance",
        15: "dance inspired training", 16: "elliptical", 17: "equestrian sports",
        18: "fencing", 19: "fishing", 20: "functional strength training", 21: "golf",
        22: "gymnastics", 23: "handball", 24: "hiking", 25: "hockey", 26: "hunting",
        27: "lacrosse", 28: "martial arts", 29: "mind and body",
        30: "mixed metabolic cardio", 31: "paddle sports", 32: "play",
        33: "preparation and recovery", 34: "racquetball", 35: "rowing", 36: "rugby",
        37: "running", 38: "sailing", 39: "skating sports", 40: "snow sports",
        41: "soccer", 42: "softball", 43: "squash", 44: "stair climbing",
        45: "surfing sports", 46: "swimming", 47: "table tennis", 48: "tennis",
        49: "track and field", 50: "traditional strength training", 51: "volleyball",
        52: "walking", 53: "water fitness", 54: "water polo", 55: "water sports",
        56: "wrestling", 57: "yoga", 58: "barre", 59: "core training",
        60: "cross country skiing", 61: "downhill skiing", 62: "flexibility",
        63: "high intensity interval training", 64: "jump rope", 65: "kickboxing",
        66: "pilates", 67: "snowboarding", 68: "stairs", 69: "step training",
        70: "wheelchair walk pace", 71: "wheelchair run pace", 72: "tai chi",
        73: "mixed cardio", 74: "hand cycling", 75: "disc sports", 76: "fitness gaming",
        77: "cardio dance", 78: "social dance", 79: "pickleball", 80: "cooldown",
        82: "swim bike run", 83: "transition", 84: "underwater diving", 3000: "other",
    ]
}
