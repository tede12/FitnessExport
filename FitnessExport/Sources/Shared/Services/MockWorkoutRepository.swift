import FitnessUI
import Foundation

/// Synthetic metrics and routes near (0, 0); no user data is embedded.
actor MockWorkoutRepository: WorkoutRepository {
    enum Scenario {
        case preview
        case emptyThenRefresh
    }

    private let populatedSnapshot: WorkoutIndexSnapshot
    private let detailSnapshots: [UUID: WorkoutDetailSnapshot]
    private var currentSnapshot: WorkoutIndexSnapshot

    init(scenario: Scenario) {
        let dataset = MockWorkoutRepository.makeDataset()
        populatedSnapshot = dataset.snapshot
        detailSnapshots = dataset.details
        currentSnapshot = scenario == .preview ? dataset.snapshot : .empty
    }

    func loadIndex() async -> WorkoutIndexSnapshot {
        currentSnapshot
    }

    func refreshIndex() async throws -> WorkoutIndexSnapshot {
        try await Task.sleep(for: .milliseconds(250))
        currentSnapshot = populatedSnapshot
        return currentSnapshot
    }

    func loadDetails(for workoutIDs: [UUID], forceRefresh: Bool) async throws -> [WorkoutDetailSnapshot] {
        try await Task.sleep(for: .milliseconds(120))
        return workoutIDs.compactMap { detailSnapshots[$0] }
    }

    func loadAnalysisSeries(for workoutIDs: [UUID]) async throws -> [WorkoutAnalysisSeries] {
        workoutIDs.compactMap { id in
            guard let detail = detailSnapshots[id] else { return nil }
            let data = Self.makeExportData(from: detail)
            return WorkoutAnalysisSeries(
                workoutID: id, heartRate: data.heartRateSamples, power: data.powerSamples, heartRateZones: [])
        }
    }

    func loadExportData(for workoutID: UUID) async throws -> WorkoutExportData? {
        guard let detail = detailSnapshots[workoutID] else { return nil }
        return MockWorkoutRepository.makeExportData(from: detail)
    }

    static func makeExportData(from detail: WorkoutDetailSnapshot) -> WorkoutExportData {
        let seconds = Int(detail.duration)
        let start = detail.startDate
        let distance = detail.distanceInMeters ?? 0
        let metersPerSecond = distance / max(detail.duration, 1)

        let heartRate =
            detail.averageHeartRate.map { average in
                stride(from: 0, to: seconds, by: 5).map { offset in
                    TimedValueSample(
                        startDate: start.addingTimeInterval(Double(offset)),
                        endDate: start.addingTimeInterval(Double(offset)), value: average - 10 + Double(offset % 20))
                }
            } ?? []
        let cadence =
            detail.averageCadence.map { average in
                stride(from: 0, to: seconds, by: 10).map { offset in
                    TimedValueSample(
                        startDate: start.addingTimeInterval(Double(offset)),
                        endDate: start.addingTimeInterval(Double(offset + 10)), value: average)
                }
            } ?? []
        let distanceSegments = stride(from: 0, to: seconds, by: 5).map { offset in
            DistanceSampleSegment(
                startDate: start.addingTimeInterval(Double(offset)),
                endDate: start.addingTimeInterval(Double(offset + 5)), meters: metersPerSecond * 5)
        }
        let route =
            detail.activityType == .running
            ? stride(from: 0, to: seconds, by: 1).map { offset in
                RoutePoint(
                    timestamp: start.addingTimeInterval(Double(offset)),
                    latitude: 0.0 + Double(offset) * 0.00001,
                    longitude: 0.0 + Double(offset) * 0.000005,
                    altitude: 120 + sin(Double(offset) / 60) * 8,
                    speed: metersPerSecond
                )
            } : []
        let power =
            detail.activityType == .running
            ? stride(from: 0, to: seconds, by: 1).map { offset in
                TimedValueSample(
                    startDate: start.addingTimeInterval(Double(offset)),
                    endDate: start.addingTimeInterval(Double(offset + 1)), value: 250 + Double(offset % 30))
            } : []

        return WorkoutExportData(
            id: detail.id,
            activityType: detail.activityType,
            startDate: start,
            endDate: detail.endDate,
            duration: detail.duration,
            totalDistanceMeters: detail.distanceInMeters,
            activeEnergyKilocalories: detail.activeEnergyKilocalories,
            heartRateSamples: heartRate,
            cadenceSamples: cadence,
            powerSamples: power,
            distanceSegments: distanceSegments,
            routePoints: route,
            deviceName: "Apple Watch",
            deviceModel: "Apple Watch Ultra 3"
        )
    }

    private static func makeDataset() -> (snapshot: WorkoutIndexSnapshot, details: [UUID: WorkoutDetailSnapshot]) {
        let calendar = Calendar(identifier: .gregorian)
        let march12 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 7, minute: 15))!
        let march10 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 18, minute: 30))!
        let march8 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 9, minute: 5))!
        let feb28 = calendar.date(from: DateComponents(year: 2026, month: 2, day: 28, hour: 8, minute: 0))!

        let runOneID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let runTwoID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let walkID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let bikeID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

        let items = [
            WorkoutListItem(
                id: runOneID, activityType: .running, startDate: march12, endDate: march12.addingTimeInterval(2_940),
                duration: 2_940, distanceInMeters: 10_000, activeEnergyKilocalories: 640, hasHeartRateData: true,
                hasCadenceData: true),
            WorkoutListItem(
                id: runTwoID, activityType: .running, startDate: march10, endDate: march10.addingTimeInterval(1_980),
                duration: 1_980, distanceInMeters: 6_000, activeEnergyKilocalories: 380, hasHeartRateData: true,
                hasCadenceData: true),
            WorkoutListItem(
                id: walkID, activityType: .walking, startDate: march8, endDate: march8.addingTimeInterval(3_000),
                duration: 3_000, distanceInMeters: 4_200, activeEnergyKilocalories: 260, hasHeartRateData: false,
                hasCadenceData: false),
            WorkoutListItem(
                id: bikeID, activityType: .cycling, startDate: feb28, endDate: feb28.addingTimeInterval(4_200),
                duration: 4_200, distanceInMeters: 18_500, activeEnergyKilocalories: 510, hasHeartRateData: false,
                hasCadenceData: false),
        ]

        let details = [
            runOneID: WorkoutDetailSnapshot(
                id: runOneID,
                activityType: .running,
                startDate: march12,
                endDate: march12.addingTimeInterval(2_940),
                duration: 2_940,
                distanceInMeters: 10_000,
                activeEnergyKilocalories: 640,
                averageHeartRate: 153,
                maxHeartRate: 168,
                averageCadence: 171,
                splits: [
                    RunSplitMetric(
                        kilometer: 1, duration: 302, paceSecondsPerKilometer: 302, averageHeartRate: 145,
                        averageCadence: 168),
                    RunSplitMetric(
                        kilometer: 2, duration: 296, paceSecondsPerKilometer: 296, averageHeartRate: 149,
                        averageCadence: 169),
                    RunSplitMetric(
                        kilometer: 3, duration: 293, paceSecondsPerKilometer: 293, averageHeartRate: 152,
                        averageCadence: 170),
                    RunSplitMetric(
                        kilometer: 4, duration: 291, paceSecondsPerKilometer: 291, averageHeartRate: 154,
                        averageCadence: 171),
                    RunSplitMetric(
                        kilometer: 5, duration: 289, paceSecondsPerKilometer: 289, averageHeartRate: 156,
                        averageCadence: 172),
                    RunSplitMetric(
                        kilometer: 6, duration: 288, paceSecondsPerKilometer: 288, averageHeartRate: 157,
                        averageCadence: 172),
                    RunSplitMetric(
                        kilometer: 7, duration: 286, paceSecondsPerKilometer: 286, averageHeartRate: 158,
                        averageCadence: 173),
                    RunSplitMetric(
                        kilometer: 8, duration: 284, paceSecondsPerKilometer: 284, averageHeartRate: 160,
                        averageCadence: 173),
                    RunSplitMetric(
                        kilometer: 9, duration: 282, paceSecondsPerKilometer: 282, averageHeartRate: 162,
                        averageCadence: 174),
                    RunSplitMetric(
                        kilometer: 10, duration: 279, paceSecondsPerKilometer: 279, averageHeartRate: 164,
                        averageCadence: 175),
                ]
            ),
            runTwoID: WorkoutDetailSnapshot(
                id: runTwoID,
                activityType: .running,
                startDate: march10,
                endDate: march10.addingTimeInterval(1_980),
                duration: 1_980,
                distanceInMeters: 6_000,
                activeEnergyKilocalories: 380,
                averageHeartRate: 148,
                maxHeartRate: 161,
                averageCadence: 168,
                splits: [
                    RunSplitMetric(
                        kilometer: 1, duration: 338, paceSecondsPerKilometer: 338, averageHeartRate: 140,
                        averageCadence: 166),
                    RunSplitMetric(
                        kilometer: 2, duration: 333, paceSecondsPerKilometer: 333, averageHeartRate: 145,
                        averageCadence: 167),
                    RunSplitMetric(
                        kilometer: 3, duration: 329, paceSecondsPerKilometer: 329, averageHeartRate: 148,
                        averageCadence: 168),
                    RunSplitMetric(
                        kilometer: 4, duration: 327, paceSecondsPerKilometer: 327, averageHeartRate: 150,
                        averageCadence: 169),
                    RunSplitMetric(
                        kilometer: 5, duration: 326, paceSecondsPerKilometer: 326, averageHeartRate: 152,
                        averageCadence: 169),
                    RunSplitMetric(
                        kilometer: 6, duration: 327, paceSecondsPerKilometer: 327, averageHeartRate: 153,
                        averageCadence: 169),
                ],
                laps: Self.intervalLaps
            ),
            walkID: WorkoutDetailSnapshot(
                id: walkID,
                activityType: .walking,
                startDate: march8,
                endDate: march8.addingTimeInterval(3_000),
                duration: 3_000,
                distanceInMeters: 4_200,
                activeEnergyKilocalories: 260,
                averageHeartRate: nil,
                maxHeartRate: nil,
                averageCadence: nil,
                splits: []
            ),
            bikeID: WorkoutDetailSnapshot(
                id: bikeID,
                activityType: .cycling,
                startDate: feb28,
                endDate: feb28.addingTimeInterval(4_200),
                duration: 4_200,
                distanceInMeters: 18_500,
                activeEnergyKilocalories: 510,
                averageHeartRate: nil,
                maxHeartRate: nil,
                averageCadence: nil,
                splits: []
            ),
        ]

        var allItems = items
        var allDetails = details

        let season = makeSeason(weeks: 130, endingAt: Date())
        allItems.append(contentsOf: season.items)
        allDetails.merge(season.details) { current, _ in current }

        return (
            WorkoutIndexSnapshot(updatedAt: march12, items: allItems.sorted { $0.startDate > $1.startDate }),
            allDetails
        )
    }

    private static func makeSeason(weeks: Int, endingAt end: Date) -> (
        items: [WorkoutListItem], details: [UUID: WorkoutDetailSnapshot]
    ) {
        let calendar = Calendar.current
        var items: [WorkoutListItem] = []
        var details: [UUID: WorkoutDetailSnapshot] = [:]
        var generator = SeededGenerator(seed: 42)

        for weekIndex in 0..<weeks {
            let progress = Double(weekIndex) / Double(max(weeks - 1, 1))
            for dayOffset in [1, 3, 6] {
                guard
                    let date = calendar.date(
                        byAdding: .day, value: -((weeks - 1 - weekIndex) * 7) - (6 - dayOffset),
                        to: calendar.startOfDay(for: end))?
                        .addingTimeInterval(7 * 3_600 + Double(Int.random(in: 0..<3_600, using: &generator)))
                else { continue }
                guard date <= end else { continue }

                let kilometers =
                    dayOffset == 6
                    ? Double(Int.random(in: 12...18, using: &generator))
                    : Double(Int.random(in: 5...10, using: &generator))
                let paceSeconds =
                    340 - 40 * progress + Double(Int.random(in: -12...12, using: &generator))
                    + (dayOffset == 6 ? 15 : 0)
                let duration = kilometers * paceSeconds
                let heartRate = 152 - 8 * progress + Double(Int.random(in: -4...4, using: &generator))
                let cadence = 166 + 8 * progress + Double(Int.random(in: -2...2, using: &generator))
                let id = UUID(uuidString: String(format: "%08X-0000-4000-8000-%012X", weekIndex, dayOffset))!

                items.append(
                    WorkoutListItem(
                        id: id, activityType: .running, startDate: date, endDate: date.addingTimeInterval(duration),
                        duration: duration, distanceInMeters: kilometers * 1_000,
                        activeEnergyKilocalories: kilometers * 62,
                        hasHeartRateData: true, hasCadenceData: true
                    ))
                details[id] = WorkoutDetailSnapshot(
                    id: id, activityType: .running, startDate: date, endDate: date.addingTimeInterval(duration),
                    duration: duration, distanceInMeters: kilometers * 1_000, activeEnergyKilocalories: kilometers * 62,
                    averageHeartRate: heartRate, maxHeartRate: heartRate + 14, averageCadence: cadence,
                    splits: (1...Int(kilometers)).map { km in
                        let splitPace =
                            paceSeconds + Double(Int.random(in: -8...8, using: &generator)) - Double(km) * 0.6
                        return RunSplitMetric(
                            kilometer: km, duration: splitPace, paceSecondsPerKilometer: splitPace,
                            averageHeartRate: heartRate - 6 + Double(km) * 0.9,
                            averageCadence: cadence + Double(Int.random(in: -1...1, using: &generator)))
                    },

                    laps: dayOffset == 3 ? intervalLaps : []
                )
            }
        }
        return (items, details)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

extension MockWorkoutRepository {

    static let intervalLaps: [LapMetric] = {
        var laps: [LapMetric] = []
        var offset: TimeInterval = 0
        func add(
            _ intensity: LapIntensity, name: String? = nil, duration: TimeInterval, meters: Double, hr: Double,
            cadence: Double
        ) {
            laps.append(
                LapMetric(
                    index: laps.count + 1, intensity: intensity, name: name, startOffset: offset, duration: duration,
                    distanceInMeters: meters, averageHeartRate: hr, averageCadence: cadence))
            offset += duration
        }
        add(.warmup, name: AppLanguage.text("Riscaldamento"), duration: 600, meters: 1_700, hr: 128, cadence: 162)
        for repetition in 0..<5 {
            add(
                .active, name: "400 m", duration: 88 + Double(repetition) * 1.5, meters: 400,
                hr: 165 + Double(repetition) * 2, cadence: 184)
            add(.recovery, name: AppLanguage.text("Recupero"), duration: 75, meters: 200, hr: 142, cadence: 160)
        }
        add(.cooldown, name: AppLanguage.text("Defaticamento"), duration: 565, meters: 1_300, hr: 130, cadence: 163)
        return laps
    }()
}
