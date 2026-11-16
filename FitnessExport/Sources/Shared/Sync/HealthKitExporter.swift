import CoreLocation
import FitnessSyncKit
import FitnessUI
import Foundation
import HealthKit
import WorkoutKit

struct ExportPage<Record: Sendable>: Sendable {
    var records: [Record]
    var deleted: [UUID]
    var sources: [SourceRecord]
    var anchor: Data?
    var isFinal: Bool
}

actor HealthKitExporter {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    func requestAuthorization() async throws -> [String] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw SyncFailure(
                code: .healthUnavailable, message: AppLanguage.text("Salute non è disponibile su questo dispositivo."))
        }

        var readTypes: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
        ]

        for identifier in [
            HKCharacteristicTypeIdentifier.dateOfBirth,
            .biologicalSex,
            .bloodType,
        ] {
            if let type = HKObjectType.characteristicType(forIdentifier: identifier) {
                readTypes.insert(type)
            }
        }
        var unavailable: [String] = []

        for metric in HealthCatalog.metrics {
            if let type = Self.objectType(for: metric) {
                readTypes.insert(type)
            } else {
                unavailable.append(metric.key)
            }
        }

        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
        return unavailable
    }

    func readProfile() async -> AthleteProfile {
        let birth = try? healthStore.dateOfBirthComponents().date
        let sex = try? healthStore.biologicalSex().biologicalSex
        let blood = try? healthStore.bloodType().bloodType
        return AthleteProfile(
            dateOfBirth: birth,
            biologicalSex: sex.map(Self.name(for:)),
            bloodType: blood.map { "\($0.rawValue)" },
            bodyMassKg: try? await latestValue(.bodyMass, unit: .gramUnit(with: .kilo)),
            heightM: try? await latestValue(.height, unit: .meter())
        )
    }

    private static func name(for sex: HKBiologicalSex) -> String {
        switch sex {
        case .female: return "female"
        case .male: return "male"
        case .other: return "other"
        case .notSet: return "notSet"
        @unknown default: return "notSet"
        }
    }

    private func latestValue(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws
        -> Double?
    {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let samples = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(
                sampleType: type, predicate: nil, limit: 1,
                sortDescriptors: [
                    NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
                ]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            healthStore.execute(query)
        }
        return (samples.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
    }

    static func objectType(for metric: MetricDescriptor) -> HKObjectType? {
        if metric.isCategory {
            return HKObjectType.categoryType(
                forIdentifier: HKCategoryTypeIdentifier(rawValue: metric.identifier)
            )
        }
        return HKObjectType.quantityType(
            forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.identifier)
        )
    }

    func nextQuantityPage(
        metric: MetricDescriptor, anchor: Data?, since: Date?, pageSize: Int
    ) async throws -> ExportPage<QuantityRecord> {
        guard
            let type = HKObjectType.quantityType(
                forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.identifier)
            )
        else {
            return ExportPage(records: [], deleted: [], sources: [], anchor: anchor, isFinal: true)
        }
        let unit = HKUnit(from: metric.unit)
        let current = Self.decodeAnchor(anchor)
        let page = try await fetchAnchoredPage(
            type: type,
            predicate: Self.predicate(since: since, anchor: current),
            anchor: current,
            limit: pageSize
        )

        var table = SourceTable()
        var records: [QuantityRecord] = []
        records.reserveCapacity(page.samples.count)
        for sample in page.samples {
            guard let quantity = sample as? HKQuantitySample else { continue }
            records.append(
                QuantityRecord(
                    uuid: quantity.uuid,
                    start: quantity.startDate,
                    end: quantity.endDate,
                    value: quantity.quantity.doubleValue(for: unit),
                    sourceIndex: table.index(for: quantity.sourceRevision.source)
                )
            )
        }
        return ExportPage(
            records: records,
            deleted: page.deleted.map(\.uuid),
            sources: table.sources,
            anchor: Self.encodeAnchor(page.anchor) ?? anchor,
            isFinal: Self.isFinal(page: page, limit: pageSize)
        )
    }

    func nextCategoryPage(
        metric: MetricDescriptor, anchor: Data?, since: Date?, pageSize: Int
    ) async throws -> ExportPage<CategoryRecord> {
        guard
            let type = HKObjectType.categoryType(
                forIdentifier: HKCategoryTypeIdentifier(rawValue: metric.identifier)
            )
        else {
            return ExportPage(records: [], deleted: [], sources: [], anchor: anchor, isFinal: true)
        }
        let current = Self.decodeAnchor(anchor)
        let page = try await fetchAnchoredPage(
            type: type,
            predicate: Self.predicate(since: since, anchor: current),
            anchor: current,
            limit: pageSize
        )

        var table = SourceTable()
        var records: [CategoryRecord] = []
        records.reserveCapacity(page.samples.count)
        for sample in page.samples {
            guard let category = sample as? HKCategorySample else { continue }
            records.append(
                CategoryRecord(
                    uuid: category.uuid,
                    start: category.startDate,
                    end: category.endDate,
                    value: category.value,
                    sourceIndex: table.index(for: category.sourceRevision.source)
                )
            )
        }
        return ExportPage(
            records: records,
            deleted: page.deleted.map(\.uuid),
            sources: table.sources,
            anchor: Self.encodeAnchor(page.anchor) ?? anchor,
            isFinal: Self.isFinal(page: page, limit: pageSize)
        )
    }

    func nextWorkoutPage(
        anchor: Data?, since: Date?, pageSize: Int
    ) async throws -> ExportPage<WorkoutRecord> {

        let limit = max(1, min(pageSize, 100))
        let current = Self.decodeAnchor(anchor)
        let page = try await fetchAnchoredPage(
            type: HKObjectType.workoutType(),
            predicate: Self.predicate(since: since, anchor: current),
            anchor: current,
            limit: limit
        )

        var records: [WorkoutRecord] = []
        records.reserveCapacity(page.samples.count)
        for sample in page.samples {
            guard let workout = sample as? HKWorkout else { continue }
            records.append(await makeRecord(from: workout))
        }
        return ExportPage(
            records: records,
            deleted: page.deleted.map(\.uuid),
            sources: [],
            anchor: Self.encodeAnchor(page.anchor) ?? anchor,
            isFinal: Self.isFinal(page: page, limit: limit)
        )
    }

    func nextRoutePage(
        cursor: Data?, since: Date?, maxPoints: Int
    ) async throws -> ExportPage<RouteRecord> {
        let mark = RouteCursor(from: cursor)?.lastWorkoutEnd ?? since
        let workouts = try await fetchWorkouts(after: mark, limit: 25)
        guard !workouts.isEmpty else {
            return ExportPage(
                records: [], deleted: [], sources: [],
                anchor: RouteCursor(lastWorkoutEnd: mark).encoded(), isFinal: true
            )
        }

        var routes: [RouteRecord] = []
        var points = 0
        var lastEnd = mark
        for workout in workouts {
            let collected = try await routePoints(for: workout)
            lastEnd = workout.endDate
            if !collected.isEmpty {
                routes.append(RouteRecord(workoutUUID: workout.uuid, points: collected))
                points += collected.count
            }
            if points >= maxPoints { break }
        }
        return ExportPage(
            records: routes, deleted: [], sources: [],
            anchor: RouteCursor(lastWorkoutEnd: lastEnd).encoded(), isFinal: false
        )
    }

    private func makeRecord(from workout: HKWorkout) async -> WorkoutRecord {
        let metadata = workout.metadata ?? [:]
        let plan = await Self.customPlan(for: workout)

        return WorkoutRecord(
            uuid: workout.uuid,
            activityType: workout.workoutActivityType.rawValue,
            start: workout.startDate,
            end: workout.endDate,
            duration: workout.duration,
            totalDistance: Self.statistic(workout, .distanceWalkingRunning, .meter())
                ?? Self.statistic(workout, .distanceCycling, .meter())
                ?? Self.statistic(workout, .distanceSwimming, .meter()),
            totalEnergy: Self.statistic(workout, .activeEnergyBurned, .kilocalorie()),
            totalSwimmingStrokes: Self.statistic(workout, .swimmingStrokeCount, .count()),
            totalFlights: Self.statistic(workout, .flightsClimbed, .count()),
            sourceName: workout.sourceRevision.source.name,
            sourceBundleID: workout.sourceRevision.source.bundleIdentifier,
            sourceVersion: workout.sourceRevision.version,
            productType: workout.sourceRevision.productType,
            deviceName: workout.device?.name,
            deviceModel: workout.device?.model,
            deviceHardware: workout.device?.hardwareVersion,
            deviceSoftware: workout.device?.softwareVersion,
            timeZone: metadata[HKMetadataKeyTimeZone] as? String,
            isIndoor: metadata[HKMetadataKeyIndoorWorkout] as? Bool,
            elevationAscended: (metadata[HKMetadataKeyElevationAscended] as? HKQuantity)?
                .doubleValue(for: .meter()),
            elevationDescended: (metadata[HKMetadataKeyElevationDescended] as? HKQuantity)?
                .doubleValue(for: .meter()),
            weatherTemperature: (metadata[HKMetadataKeyWeatherTemperature] as? HKQuantity)?
                .doubleValue(for: .degreeCelsius()),
            weatherHumidity: (metadata[HKMetadataKeyWeatherHumidity] as? HKQuantity)?
                .doubleValue(for: .percent()),
            poolLength: (metadata[HKMetadataKeyLapLength] as? HKQuantity)?.doubleValue(for: .meter()),
            planName: plan?.displayName,
            metadata: Self.stringify(metadata),
            events: (workout.workoutEvents ?? []).map { event in
                WorkoutEventRecord(
                    type: event.type.rawValue,
                    start: event.dateInterval.start,
                    end: event.dateInterval.end,
                    metadata: Self.stringify(event.metadata ?? [:])
                )
            },
            activities: workout.workoutActivities.map { activity in
                WorkoutActivityRecord(
                    uuid: activity.uuid,
                    start: activity.startDate,
                    end: activity.endDate,
                    activityType: activity.workoutConfiguration.activityType.rawValue,
                    locationType: activity.workoutConfiguration.locationType.rawValue,
                    metadata: Self.stringify(activity.metadata ?? [:]),
                    statistics: Self.statistics(for: activity)
                )
            },
            statistics: Self.statistics(for: workout),
            plannedSteps: Self.plannedSteps(from: plan),
            hasRoute: (try? await hasRoute(workout)) ?? false
        )
    }

    private static func customPlan(for workout: HKWorkout) async -> CustomWorkout? {
        guard workout.workoutActivities.count >= 2 else { return nil }
        guard case .custom(let plan)? = (try? await workout.workoutPlan)?.workout else { return nil }
        return plan
    }

    private static func plannedSteps(from plan: CustomWorkout?) -> [PlannedStepRecord] {
        guard let plan else { return [] }
        var steps: [PlannedStepRecord] = []
        var index = 0

        func append(_ step: IntervalStep, role: String) {
            steps.append(
                PlannedStepRecord(
                    index: index,
                    role: role,
                    name: nil,
                    goalKind: goalKind(step.step.goal),
                    goalValue: goalValue(step.step.goal),
                    alert: step.step.alert.map { String(describing: $0) }
                )
            )
            index += 1
        }

        if let warmup = plan.warmup {
            steps.append(
                PlannedStepRecord(
                    index: index, role: "warmup", name: nil,
                    goalKind: goalKind(warmup.goal), goalValue: goalValue(warmup.goal),
                    alert: warmup.alert.map { String(describing: $0) }
                )
            )
            index += 1
        }
        for block in plan.blocks {
            for _ in 0..<block.iterations {
                for step in block.steps {
                    append(step, role: step.purpose == .work ? "work" : "recovery")
                }
            }
        }
        if let cooldown = plan.cooldown {
            steps.append(
                PlannedStepRecord(
                    index: index, role: "cooldown", name: nil,
                    goalKind: goalKind(cooldown.goal), goalValue: goalValue(cooldown.goal),
                    alert: cooldown.alert.map { String(describing: $0) }
                )
            )
        }
        return steps
    }

    private static func goalKind(_ goal: WorkoutGoal) -> String {
        switch goal {
        case .open: return "open"
        case .time: return "time"
        case .distance: return "distance"
        case .energy: return "energy"
        case .poolSwimDistanceWithTime: return "open"
        @unknown default: return "open"
        }
    }

    private static func goalValue(_ goal: WorkoutGoal) -> Double? {
        switch goal {
        case .time(let value, let unit):
            return Measurement(value: value, unit: unit).converted(to: .seconds).value
        case .distance(let value, let unit):
            return Measurement(value: value, unit: unit).converted(to: .meters).value
        case .energy(let value, let unit):
            return Measurement(value: value, unit: unit).converted(to: .kilocalories).value
        case .open, .poolSwimDistanceWithTime:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func statistics(for workout: HKWorkout) -> [WorkoutStatisticRecord] {
        HealthCatalog.metrics.compactMap { metric -> WorkoutStatisticRecord? in
            guard !metric.isCategory,
                let type = HKObjectType.quantityType(
                    forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.identifier)
                ),
                let statistics = workout.statistics(for: type)
            else { return nil }
            return makeStatistic(metric: metric, statistics: statistics)
        }
    }

    private static func statistics(for activity: HKWorkoutActivity) -> [WorkoutStatisticRecord] {
        HealthCatalog.metrics.compactMap { metric -> WorkoutStatisticRecord? in
            guard !metric.isCategory,
                let type = HKObjectType.quantityType(
                    forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.identifier)
                ),
                let statistics = activity.statistics(for: type)
            else { return nil }
            return makeStatistic(metric: metric, statistics: statistics)
        }
    }

    private static func makeStatistic(
        metric: MetricDescriptor, statistics: HKStatistics
    ) -> WorkoutStatisticRecord? {
        let unit = HKUnit(from: metric.unit)
        let sum = statistics.sumQuantity()?.doubleValue(for: unit)
        let average = statistics.averageQuantity()?.doubleValue(for: unit)
        let minimum = statistics.minimumQuantity()?.doubleValue(for: unit)
        let maximum = statistics.maximumQuantity()?.doubleValue(for: unit)
        guard sum != nil || average != nil || minimum != nil || maximum != nil else { return nil }
        return WorkoutStatisticRecord(
            metricKey: metric.key, sum: sum, average: average, minimum: minimum, maximum: maximum
        )
    }

    private static func statistic(
        _ workout: HKWorkout, _ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit
    ) -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        return workout.statistics(for: type)?.sumQuantity()?.doubleValue(for: unit)
    }

    private static func stringify(_ metadata: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in metadata {
            switch value {
            case let quantity as HKQuantity:
                result[key] = quantity.description
            case let date as Date:
                result[key] = ISO8601DateFormatter().string(from: date)
            case let number as NSNumber:
                result[key] = number.stringValue
            case let string as String:
                result[key] = string
            default:
                result[key] = String(describing: value)
            }
        }
        return result
    }

    private struct AnchoredPage {
        let samples: [HKSample]
        let deleted: [HKDeletedObject]
        let anchor: HKQueryAnchor?
    }

    private func fetchAnchoredPage(
        type: HKSampleType, predicate: NSPredicate?, anchor: HKQueryAnchor?, limit: Int
    ) async throws -> AnchoredPage {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: predicate,
                anchor: anchor,
                limit: limit
            ) { _, samples, deleted, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(
                        returning: AnchoredPage(
                            samples: samples ?? [],
                            deleted: deleted ?? [],
                            anchor: newAnchor
                        )
                    )
                }
            }
            healthStore.execute(query)
        }
    }

    private func fetchWorkouts(after date: Date?, limit: Int) async throws -> [HKWorkout] {
        let predicate = date.map {
            HKQuery.predicateForSamples(withStart: $0, end: nil, options: .strictStartDate)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: limit,
                sortDescriptors: [
                    NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
                ]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples ?? []).compactMap { $0 as? HKWorkout })
                }
            }
            healthStore.execute(query)
        }
    }

    private func hasRoute(_ workout: HKWorkout) async throws -> Bool {
        try await !routeObjects(for: workout).isEmpty
    }

    private func routeObjects(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(
                        returning: (samples ?? []).compactMap { $0 as? HKWorkoutRoute }
                    )
                }
            }
            healthStore.execute(query)
        }
    }

    private func routePoints(for workout: HKWorkout) async throws -> [RoutePointRecord] {
        var points: [RoutePointRecord] = []
        for route in try await routeObjects(for: workout) {
            points.append(contentsOf: try await locations(of: route))
        }
        return points.sorted { $0.timestamp < $1.timestamp }
    }

    private func locations(of route: HKWorkoutRoute) async throws -> [RoutePointRecord] {
        let accumulator = LocationAccumulator()
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKWorkoutRouteQuery(route: route) { query, locations, done, error in
                if let error {
                    if accumulator.finish() {
                        self.healthStore.stop(query)
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if let locations {
                    accumulator.append(locations)
                }
                if done, accumulator.finish() {
                    continuation.resume(returning: accumulator.points)
                }
            }
            healthStore.execute(query)
        }
    }

    private static func isFinal(page: AnchoredPage, limit: Int) -> Bool {
        page.samples.count + page.deleted.count < limit
    }

    private static func predicate(since: Date?, anchor: HKQueryAnchor?) -> NSPredicate? {

        guard anchor == nil, let since else { return nil }
        return HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
    }

    static func encodeAnchor(_ anchor: HKQueryAnchor?) -> Data? {
        guard let anchor else { return nil }
        return try? NSKeyedArchiver.archivedData(
            withRootObject: anchor, requiringSecureCoding: true
        )
    }

    static func decodeAnchor(_ data: Data?) -> HKQueryAnchor? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
}

struct SourceTable {
    private(set) var sources: [SourceRecord] = []
    private var indices: [SourceRecord: Int] = [:]

    mutating func index(for source: HKSource) -> Int {
        let record = SourceRecord(bundleID: source.bundleIdentifier, name: source.name)
        if let existing = indices[record] { return existing }
        let index = sources.count
        sources.append(record)
        indices[record] = index
        return index
    }
}

struct RouteCursor: Codable {
    var lastWorkoutEnd: Date?

    init(lastWorkoutEnd: Date?) {
        self.lastWorkoutEnd = lastWorkoutEnd
    }

    init?(from data: Data?) {
        guard let data, let decoded = try? JSONDecoder().decode(RouteCursor.self, from: data) else {
            return nil
        }
        self = decoded
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

private final class LocationAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [RoutePointRecord] = []
    private var isFinished = false

    var points: [RoutePointRecord] {
        lock.withLock { collected }
    }

    func append(_ locations: [CLLocation]) {
        lock.withLock {
            collected.append(
                contentsOf: locations.map { location in
                    RoutePointRecord(
                        timestamp: location.timestamp,
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        altitude: location.altitude,
                        horizontalAccuracy: location.horizontalAccuracy,
                        verticalAccuracy: location.verticalAccuracy,
                        speed: location.speed,
                        course: location.course
                    )
                }
            )
        }
    }

    func finish() -> Bool {
        lock.withLock {
            guard !isFinished else { return false }
            isFinished = true
            return true
        }
    }
}
