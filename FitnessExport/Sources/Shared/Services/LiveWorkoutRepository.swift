import CoreLocation
import Foundation
import HealthKit
import WorkoutKit

actor LiveWorkoutRepository: WorkoutRepository {
    private let healthStore: HKHealthStore
    private let cacheStore: WorkoutCacheStore
    private var hasRequestedAuthorization = false

    private static let countPerMinute = HKUnit(from: "count/min")

    init(healthStore: HKHealthStore = HKHealthStore(), cacheStore: WorkoutCacheStore) {
        self.healthStore = healthStore
        self.cacheStore = cacheStore
    }

    func loadIndex() async -> WorkoutIndexSnapshot {
        await cacheStore.loadIndex()
    }

    func refreshIndex() async throws -> WorkoutIndexSnapshot {
        try await ensureAuthorization()

        let currentSnapshot = await cacheStore.loadIndex()
        let workouts = try await fetchWorkouts(since: currentSnapshot.latestStartDate?.addingTimeInterval(-86_400))
        let newItems = workouts.map(makeListItem(from:))

        var snapshot = currentSnapshot
        if currentSnapshot.items.isEmpty || currentSnapshot.latestStartDate == nil {
            snapshot = WorkoutIndexSnapshot(updatedAt: Date(), items: newItems.sorted { $0.startDate > $1.startDate })
        } else {
            snapshot.merge(with: newItems)
        }

        try await cacheStore.saveIndex(snapshot)
        return snapshot
    }

    func loadDetails(for workoutIDs: [UUID], forceRefresh: Bool) async throws -> [WorkoutDetailSnapshot] {
        try await ensureAuthorization()

        var cachedResults: [UUID: WorkoutDetailSnapshot] = [:]
        var idsToLoad: [UUID] = []

        for id in workoutIDs {
            if !forceRefresh, let cached = await cacheStore.loadDetail(for: id) {
                cachedResults[id] = cached
            } else {
                idsToLoad.append(id)
            }
        }

        if !idsToLoad.isEmpty {
            let loadedDetails = try await withThrowingTaskGroup(of: WorkoutDetailSnapshot?.self) { group in
                for id in idsToLoad {
                    group.addTask { [self] in
                        try await loadDetail(for: id)
                    }
                }

                var details: [WorkoutDetailSnapshot] = []
                for try await detail in group {
                    if let detail {
                        details.append(detail)
                    }
                }
                return details
            }

            try await cacheStore.saveDetails(loadedDetails)
            var snapshot = await cacheStore.loadIndex()
            snapshot.updateAvailability(using: loadedDetails)
            try await cacheStore.saveIndex(snapshot)

            for detail in loadedDetails {
                cachedResults[detail.id] = detail
            }
        }

        return workoutIDs.compactMap { cachedResults[$0] }
    }

    func loadAnalysisSeries(for workoutIDs: [UUID]) async throws -> [WorkoutAnalysisSeries] {
        try await ensureAuthorization()
        let zones: [WorkoutAnalysisSeries.HeartRateZone]
        if #available(iOS 27.0, *), let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
            let configuration = try? await healthStore.preferredWorkoutZoneConfiguration(for: heartRateType)
        {
            zones = configuration.zones.map { zone in
                WorkoutAnalysisSeries.HeartRateZone(
                    index: zone.index,
                    minimumBPM: zone.minimum?.doubleValue(for: Self.countPerMinute) ?? 0,
                    maximumBPM: zone.maximum?.doubleValue(for: Self.countPerMinute)
                )
            }
        } else {
            zones = []
        }

        return try await withThrowingTaskGroup(of: WorkoutAnalysisSeries?.self) { group in
            for id in workoutIDs {
                group.addTask { [self] in
                    guard let workout = try await fetchWorkout(id: id) else { return nil }
                    async let heartRate = fetchHeartRateSamples(for: workout)
                    let powerType: HKQuantityTypeIdentifier =
                        workout.workoutActivityType.exportActivityType == .cycling ? .cyclingPower : .runningPower
                    async let power = fetchRateSeries(
                        powerType, unit: .watt(), workout: workout,
                        preferredSource: workout.sourceRevision.source.bundleIdentifier)
                    return WorkoutAnalysisSeries(
                        workoutID: id, heartRate: try await heartRate, power: try await power, heartRateZones: zones)
                }
            }
            var result: [WorkoutAnalysisSeries] = []
            for try await series in group {
                if let series { result.append(series) }
            }
            return result
        }
    }

    func loadExportData(for workoutID: UUID) async throws -> WorkoutExportData? {
        try await ensureAuthorization()
        guard let workout = try await fetchWorkout(id: workoutID) else { return nil }

        let source = workout.sourceRevision.source.bundleIdentifier
        let activityType = workout.workoutActivityType.exportActivityType

        async let heartRate = fetchRateSeries(
            .heartRate, unit: Self.countPerMinute, workout: workout, preferredSource: source)
        async let cadence = fetchCadenceSamples(for: workout)
        async let power = fetchRateSeries(
            activityType == .cycling ? .cyclingPower : .runningPower, unit: .watt(), workout: workout,
            preferredSource: source)
        async let speed = fetchRateSeries(
            activityType == .cycling ? .cyclingSpeed : .runningSpeed, unit: HKUnit.meter().unitDivided(by: .second()),
            workout: workout, preferredSource: source)
        async let stride = fetchRateSeries(
            .runningStrideLength, unit: .meter(), workout: workout, preferredSource: source)
        async let oscillation = fetchRateSeries(
            .runningVerticalOscillation, unit: .meter(), workout: workout, preferredSource: source)
        async let contactTime = fetchRateSeries(
            .runningGroundContactTime, unit: .second(), workout: workout, preferredSource: source)
        async let temperature = fetchRateSeries(
            .waterTemperature, unit: .degreeCelsius(), workout: workout, preferredSource: source)
        async let energy = fetchCumulativeSeries(
            .activeEnergyBurned, unit: .kilocalorie(), workout: workout, expectedTotal: totalActiveEnergy(of: workout))
        async let distance = fetchDistanceSamples(for: workout)
        async let route = fetchRoute(for: workout)
        async let strokes = fetchSwimLengths(for: workout)
        async let plan = Self.customPlan(for: workout)

        let metadata = workout.metadata ?? [:]
        let events = workout.workoutEvents ?? []

        return WorkoutExportData(
            id: workout.uuid,
            activityType: activityType,
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration,
            totalDistanceMeters: totalDistance(of: workout),
            activeEnergyKilocalories: totalActiveEnergy(of: workout),
            heartRateSamples: try await heartRate,
            cadenceSamples: try await cadence,
            powerSamples: try await power,
            speedSamples: try await speed,
            strideLengthSamples: try await stride,
            verticalOscillationSamples: try await oscillation,
            groundContactTimeSamples: try await contactTime,
            temperatureSamples: try await temperature,
            energySegments: try await energy,
            distanceSegments: try await distance,
            routePoints: try await route,
            swimLengths: try await strokes,
            pauses: Self.pauseIntervals(from: events),
            laps: WorkoutLapExtraction.laps(activities: workout.workoutActivities, plan: await plan, events: events),
            elevationAscendedMeters: (metadata[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(
                for: .meter()),
            elevationDescendedMeters: (metadata[HKMetadataKeyElevationDescended] as? HKQuantity)?.doubleValue(
                for: .meter()),
            weatherTemperatureCelsius: (metadata[HKMetadataKeyWeatherTemperature] as? HKQuantity)?.doubleValue(
                for: .degreeCelsius()),
            isIndoor: (metadata[HKMetadataKeyIndoorWorkout] as? Bool) ?? false,
            poolLengthMeters: (metadata[HKMetadataKeyLapLength] as? HKQuantity)?.doubleValue(for: .meter()),
            deviceName: workout.device?.name ?? workout.sourceRevision.source.name,
            deviceModel: workout.device?.model.map { model in

                let productType = workout.sourceRevision.productType ?? ""
                return productType.isEmpty ? model : "\(model) (\(productType))"
            },
            timeZoneIdentifier: metadata[HKMetadataKeyTimeZone] as? String,
            workoutName: (await plan)?.displayName
        )
    }

    private static func customPlan(for workout: HKWorkout) async -> CustomWorkout? {
        guard workout.workoutActivities.count >= 2 else { return nil }
        guard case .custom(let plan)? = (try? await workout.workoutPlan)?.workout else { return nil }
        return plan
    }

    private func fetchRateSeries(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        workout: HKWorkout,
        preferredSource: String
    ) async throws -> [TimedValueSample] {
        if identifier == .heartRate { return try await fetchHeartRateSamples(for: workout) }
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else { return [] }
        let samples = try await fetchQuantitySamples(type: quantityType, for: workout)
        return SampleSourceSelection.pickRateSource(
            samples.map(makeSourcedSample(unit: unit)), preferredSource: preferredSource
        )
        .map { TimedValueSample(startDate: $0.startDate, endDate: $0.endDate, value: $0.value) }
    }

    private func fetchCumulativeSeries(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        workout: HKWorkout,
        expectedTotal: Double?
    ) async throws -> [DistanceSampleSegment] {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else { return [] }
        let samples = try await fetchQuantitySamples(type: quantityType, for: workout)
        return SampleSourceSelection.pickDistanceSource(
            samples.map(makeSourcedSample(unit: unit)), expectedTotal: expectedTotal
        )
        .map { DistanceSampleSegment(startDate: $0.startDate, endDate: $0.endDate, meters: $0.value) }
    }

    private func fetchRoute(for workout: HKWorkout) async throws -> [RoutePoint] {
        let routes = try await runSampleQuery(
            sampleType: HKSeriesType.workoutRoute(),
            predicate: HKQuery.predicateForObjects(from: workout),
            limit: HKObjectQueryNoLimit,
            sortDescriptors: nil
        ).compactMap { $0 as? HKWorkoutRoute }

        var points: [RoutePoint] = []
        for route in routes {
            points.append(contentsOf: try await locations(of: route))
        }
        return points.sorted { $0.timestamp < $1.timestamp }
    }

    private func locations(of route: HKWorkoutRoute) async throws -> [RoutePoint] {
        let accumulator = RouteAccumulator()
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    if accumulator.finish() { continuation.resume(throwing: error) }
                    return
                }
                accumulator.append(locations ?? [])
                if done, accumulator.finish() {
                    continuation.resume(returning: accumulator.points)
                }
            }
            healthStore.execute(query)
        }
    }

    private func fetchSwimLengths(for workout: HKWorkout) async throws -> [SwimLength] {
        guard workout.workoutActivityType == .swimming,
            let quantityType = HKObjectType.quantityType(forIdentifier: .swimmingStrokeCount)
        else { return [] }

        return try await fetchQuantitySamples(type: quantityType, for: workout).map { sample in
            let rawStyle = sample.metadata?[HKMetadataKeySwimmingStrokeStyle] as? Int ?? 0
            return SwimLength(
                startDate: sample.startDate,
                endDate: sample.endDate,
                strokeCount: sample.quantity.doubleValue(for: .count()),
                style: SwimStrokeStyle(rawValue: rawStyle) ?? .unknown
            )
        }
    }

    static func pauseIntervals(from events: [HKWorkoutEvent]) -> [DateInterval] {
        var intervals: [DateInterval] = []
        var openPause: Date?
        for event in events.sorted(by: { $0.dateInterval.start < $1.dateInterval.start }) {
            switch event.type {
            case .pause, .motionPaused:
                if openPause == nil { openPause = event.dateInterval.start }
            case .resume, .motionResumed:
                if let start = openPause, event.dateInterval.start > start {
                    intervals.append(DateInterval(start: start, end: event.dateInterval.start))
                }
                openPause = nil
            default:
                break
            }
        }
        return intervals
    }

    private func ensureAuthorization() async throws {
        if hasRequestedAuthorization {
            return
        }

        guard HKHealthStore.isHealthDataAvailable() else {
            throw WorkoutRepositoryError.healthDataUnavailable
        }

        var readTypes: Set<HKObjectType> = [HKObjectType.workoutType()]
        readTypes.insert(HKSeriesType.workoutRoute())
        let identifiers: [HKQuantityTypeIdentifier] = [
            .heartRate,
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming,
            .activeEnergyBurned,
            .stepCount,
            .cyclingCadence,

            .runningPower,
            .runningSpeed,
            .runningStrideLength,
            .runningVerticalOscillation,
            .runningGroundContactTime,
            .cyclingPower,
            .cyclingSpeed,
            .swimmingStrokeCount,
            .waterTemperature,
        ]
        for identifier in identifiers {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                readTypes.insert(type)
            }
        }

        let success = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            healthStore.requestAuthorization(toShare: nil, read: readTypes) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }

        guard success else {
            throw WorkoutRepositoryError.authorizationDenied
        }

        hasRequestedAuthorization = true
    }

    private func fetchWorkouts(since startDate: Date?) async throws -> [HKWorkout] {
        let predicate: NSPredicate?
        if let startDate {
            predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: .strictStartDate)
        } else {
            predicate = nil
        }

        return try await runSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
        ) as? [HKWorkout] ?? []
    }

    private func makeListItem(from workout: HKWorkout) -> WorkoutListItem {
        WorkoutListItem(
            id: workout.uuid,
            activityType: workout.workoutActivityType.exportActivityType,
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration,
            distanceInMeters: totalDistance(of: workout),
            activeEnergyKilocalories: totalActiveEnergy(of: workout),
            hasHeartRateData: false,
            hasCadenceData: false
        )
    }

    private func loadDetail(for id: UUID) async throws -> WorkoutDetailSnapshot? {
        guard let workout = try await fetchWorkout(id: id) else { return nil }

        async let distanceSamples = fetchDistanceSamples(for: workout)
        async let heartRateSamples = fetchHeartRateSamples(for: workout)
        async let cadenceSamples = fetchCadenceSamples(for: workout)
        async let plan = Self.customPlan(for: workout)

        let resolvedDistanceSamples = try await distanceSamples
        let resolvedHeartRateSamples = try await heartRateSamples
        let resolvedCadenceSamples = try await cadenceSamples
        let interval = DateInterval(start: workout.startDate, end: workout.endDate)

        let resolvedPlan = await plan
        let laps = WorkoutLapExtraction.laps(
            activities: workout.workoutActivities, plan: resolvedPlan, events: workout.workoutEvents ?? [])

        let heartRateStatistics = HKObjectType.quantityType(forIdentifier: .heartRate).flatMap {
            workout.statistics(for: $0)
        }
        let averageHeartRate =
            SplitComputation.weightedAverage(samples: resolvedHeartRateSamples, in: interval)
            ?? heartRateStatistics?.averageQuantity()?.doubleValue(for: Self.countPerMinute)
        let maxHeartRate =
            resolvedHeartRateSamples.map(\.value).max()
            ?? heartRateStatistics?.maximumQuantity()?.doubleValue(for: Self.countPerMinute)

        return WorkoutDetailSnapshot(
            id: workout.uuid,
            activityType: workout.workoutActivityType.exportActivityType,
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration,
            distanceInMeters: totalDistance(of: workout),
            activeEnergyKilocalories: totalActiveEnergy(of: workout),
            averageHeartRate: averageHeartRate,
            maxHeartRate: maxHeartRate,
            averageCadence: SplitComputation.weightedAverage(samples: resolvedCadenceSamples, in: interval),
            splits: SplitComputation.computeKilometerSplits(
                distanceSamples: resolvedDistanceSamples,
                heartRateSamples: resolvedHeartRateSamples,
                cadenceSamples: resolvedCadenceSamples
            ),
            laps: SplitComputation.computeLapMetrics(
                laps: laps,
                workoutStart: workout.startDate,
                distanceSamples: resolvedDistanceSamples,
                heartRateSamples: resolvedHeartRateSamples,
                cadenceSamples: resolvedCadenceSamples
            ),
            workoutName: resolvedPlan?.displayName
        )
    }

    private func fetchWorkout(id: UUID) async throws -> HKWorkout? {
        try await runSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: HKQuery.predicateForObject(with: id),
            limit: 1,
            sortDescriptors: nil
        )
        .compactMap { $0 as? HKWorkout }
        .first
    }

    private func totalDistance(of workout: HKWorkout) -> Double? {
        let identifier = workout.workoutActivityType.distanceTypeIdentifier
        if let type = HKObjectType.quantityType(forIdentifier: identifier),
            let sum = workout.statistics(for: type)?.sumQuantity()
        {
            return sum.doubleValue(for: .meter())
        }
        return workout.totalDistance?.doubleValue(for: .meter())
    }

    private func totalActiveEnergy(of workout: HKWorkout) -> Double? {
        if let type = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
            let sum = workout.statistics(for: type)?.sumQuantity()
        {
            return sum.doubleValue(for: .kilocalorie())
        }
        return workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
    }

    private func fetchDistanceSamples(for workout: HKWorkout) async throws -> [DistanceSampleSegment] {
        guard
            let quantityType = HKObjectType.quantityType(
                forIdentifier: workout.workoutActivityType.distanceTypeIdentifier)
        else {
            return []
        }

        let samples = try await fetchQuantitySamples(type: quantityType, for: workout)
        return SampleSourceSelection.pickDistanceSource(
            samples.map(makeSourcedSample(unit: .meter())),
            expectedTotal: totalDistance(of: workout)
        )
        .map { DistanceSampleSegment(startDate: $0.startDate, endDate: $0.endDate, meters: $0.value) }
    }

    private func fetchHeartRateSamples(for workout: HKWorkout) async throws -> [TimedValueSample] {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            return []
        }

        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let attached =
            try await runSampleQuery(
                sampleType: quantityType,
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sort
            ) as? [HKQuantitySample] ?? []
        let timed =
            try await runSampleQuery(
                sampleType: quantityType,
                predicate: HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: []),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sort
            ) as? [HKQuantitySample] ?? []
        let samples = Dictionary((attached + timed).map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
            .values.filter { $0.startDate >= workout.startDate && $0.startDate < workout.endDate }
        return SampleSourceSelection.mergeHeartRateSources(
            samples.map(makeSourcedSample(unit: Self.countPerMinute)),
            preferredSource: workout.sourceRevision.source.bundleIdentifier
        )
        .map { TimedValueSample(startDate: $0.startDate, endDate: $0.endDate, value: $0.value) }
    }

    private func fetchCadenceSamples(for workout: HKWorkout) async throws -> [TimedValueSample] {
        switch workout.workoutActivityType.exportActivityType {
        case .cycling:
            guard let quantityType = HKObjectType.quantityType(forIdentifier: .cyclingCadence) else {
                return []
            }
            let samples = try await fetchQuantitySamples(type: quantityType, for: workout)
            return SampleSourceSelection.pickRateSource(
                samples.map(makeSourcedSample(unit: Self.countPerMinute)),
                preferredSource: workout.sourceRevision.source.bundleIdentifier
            )
            .map { TimedValueSample(startDate: $0.startDate, endDate: $0.endDate, value: $0.value) }

        case .running, .walking, .hiking:
            guard let quantityType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
                return []
            }
            let samples = try await fetchQuantitySamples(type: quantityType, for: workout)
            let steps = SampleSourceSelection.pickRateSource(
                samples.map(makeSourcedSample(unit: .count())),
                preferredSource: workout.sourceRevision.source.bundleIdentifier
            )
            return CadenceDerivation.stepsPerMinute(
                from: steps.map {
                    DistanceSampleSegment(startDate: $0.startDate, endDate: $0.endDate, meters: $0.value)
                })

        case .swimming, .other:
            return []
        }
    }

    private func fetchQuantitySamples(type: HKQuantityType, for workout: HKWorkout) async throws -> [HKQuantitySample] {
        let sortDescriptors = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]

        let attached =
            try await runSampleQuery(
                sampleType: type,
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sortDescriptors
            ) as? [HKQuantitySample] ?? []

        if !attached.isEmpty {
            return attached
        }

        return try await runSampleQuery(
            sampleType: type,
            predicate: HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: []),
            limit: HKObjectQueryNoLimit,
            sortDescriptors: sortDescriptors
        ) as? [HKQuantitySample] ?? []
    }

    private func makeSourcedSample(unit: HKUnit) -> (HKQuantitySample) -> SourcedSample {
        { sample in
            SourcedSample(
                source: sample.sourceRevision.source.bundleIdentifier,
                startDate: sample.startDate,
                endDate: sample.endDate,
                value: sample.quantity.doubleValue(for: unit)
            )
        }
    }

    private func runSampleQuery(
        sampleType: HKSampleType,
        predicate: NSPredicate?,
        limit: Int,
        sortDescriptors: [NSSortDescriptor]?
    ) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: sortDescriptors
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }

            healthStore.execute(query)
        }
    }
}

extension HKWorkoutActivityType {
    var exportActivityType: WorkoutActivityType {
        switch self {
        case .running:
            return .running
        case .walking:
            return .walking
        case .cycling:
            return .cycling
        case .hiking:
            return .hiking
        case .swimming:
            return .swimming
        default:
            return .other
        }
    }

    var distanceTypeIdentifier: HKQuantityTypeIdentifier {
        switch self {
        case .cycling:
            return .distanceCycling
        case .swimming:
            return .distanceSwimming
        default:
            return .distanceWalkingRunning
        }
    }
}

private final class RouteAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [RoutePoint] = []
    private var isFinished = false

    var points: [RoutePoint] {
        lock.withLock { collected }
    }

    func append(_ locations: [CLLocation]) {
        lock.withLock {
            collected.append(
                contentsOf: locations.map { location in
                    RoutePoint(
                        timestamp: location.timestamp,
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude,
                        altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                        speed: location.speed >= 0 ? location.speed : nil
                    )
                })
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
