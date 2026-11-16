import FitnessUI
import Foundation

struct WorkoutDetailModel: Equatable, Sendable {
    struct Sample: Identifiable, Equatable, Sendable {
        let kilometer: Int
        let value: Double

        var id: Int { kilometer }
        var x: Double { Double(kilometer) }
    }

    struct Summary: Identifiable, Equatable, Sendable {
        let title: String
        let value: String
        let symbolName: String

        var id: String { title }
    }

    let detail: WorkoutDetailSnapshot
    let summaries: [Summary]
    let pace: [Sample]
    let heartRate: [Sample]
    let cadence: [Sample]

    let averagePace: Double?
    let splitByKilometer: [Int: RunSplitMetric]
    let fastestKilometer: Int?
    let slowestKilometer: Int?

    let intervals: Intervals?

    struct Intervals: Equatable, Sendable {
        let laps: [LapMetric]
        let activeCount: Int

        let activePace: Double?
        let recoveryPace: Double?
        let fastestLapIndex: Int?

        let paceRange: (min: Double, max: Double)
        let totalDuration: TimeInterval

        static func == (lhs: Intervals, rhs: Intervals) -> Bool { lhs.laps == rhs.laps }

        init?(laps: [LapMetric]) {
            guard laps.count >= 2 else { return nil }
            self.laps = laps
            let active = laps.filter { $0.intensity == .active }
            activeCount = active.count
            activePace = Self.weightedPace(active)
            recoveryPace = Self.weightedPace(laps.filter { $0.intensity == .recovery })
            fastestLapIndex =
                active.filter { $0.paceSecondsPerKilometer != nil }.min {
                    $0.paceSecondsPerKilometer! < $1.paceSecondsPerKilometer!
                }?.index
            let paces = laps.compactMap(\.paceSecondsPerKilometer)
            paceRange = (paces.min() ?? 0, paces.max() ?? 0)
            totalDuration = laps.reduce(0) { $0 + $1.duration }
        }

        private static func weightedPace(_ laps: [LapMetric]) -> Double? {
            let measured = laps.filter { $0.paceSecondsPerKilometer != nil }
            let meters = measured.reduce(0) { $0 + ($1.distanceInMeters ?? 0) }
            guard meters > 0 else { return nil }
            return measured.reduce(0) { $0 + $1.duration } / (meters / 1_000)
        }
    }

    var kilometerCount: Int { detail.splits.count }
    var hasSplits: Bool { detail.splits.count >= 2 }

    var xDomain: ClosedRange<Double> { 0.5...(Double(max(kilometerCount, 1)) + 0.5) }

    init(detail: WorkoutDetailSnapshot) {
        self.detail = detail
        pace = detail.splits.map { Sample(kilometer: $0.kilometer, value: $0.paceSecondsPerKilometer) }
        heartRate = detail.splits.compactMap { split in
            split.averageHeartRate.map { Sample(kilometer: split.kilometer, value: $0) }
        }
        cadence = detail.splits.compactMap { split in
            split.averageCadence.map { Sample(kilometer: split.kilometer, value: $0) }
        }
        averagePace = detail.distanceInMeters.flatMap { meters in meters > 0 ? detail.duration / (meters / 1_000) : nil
        }
        splitByKilometer = Dictionary(uniqueKeysWithValues: detail.splits.map { ($0.kilometer, $0) })
        fastestKilometer = detail.splits.min { $0.paceSecondsPerKilometer < $1.paceSecondsPerKilometer }?.kilometer
        slowestKilometer = detail.splits.max { $0.paceSecondsPerKilometer < $1.paceSecondsPerKilometer }?.kilometer
        intervals = Intervals(laps: detail.laps)

        let heartRateText: String = {
            let average = WorkoutFormatting.heartRate(detail.averageHeartRate)?.replacingOccurrences(
                of: " bpm", with: "")
            let maximum = WorkoutFormatting.heartRate(detail.maxHeartRate)?.replacingOccurrences(of: " bpm", with: "")
            let parts = [average, maximum].compactMap { $0 }
            return parts.isEmpty ? "–" : parts.joined(separator: " / ") + " bpm"
        }()
        summaries = [
            Summary(
                title: AppLanguage.text("Passo medio"),
                value: WorkoutFormatting.pace(distanceInMeters: detail.distanceInMeters, duration: detail.duration)
                    ?? "–", symbolName: "speedometer"),
            Summary(title: AppLanguage.text("FC media / max"), value: heartRateText, symbolName: "heart.fill"),
            Summary(
                title: AppLanguage.text("Cadenza"), value: WorkoutFormatting.cadence(detail.averageCadence) ?? "–",
                symbolName: "metronome"),
            Summary(
                title: AppLanguage.text("Energia"),
                value: WorkoutFormatting.kilocalories(detail.activeEnergyKilocalories) ?? "–", symbolName: "flame"),
        ]
    }

    var paceRange: (min: Double, max: Double) {
        let values = pace.map(\.value) + (averagePace.map { [$0] } ?? [])
        return (values.min() ?? 0, values.max() ?? 0)
    }

    func range(of samples: [Sample]) -> (min: Double, max: Double) {
        let values = samples.map(\.value)
        return (values.min() ?? 0, values.max() ?? 0)
    }

    func axisTicks(maxLabels: Int) -> [Double] {
        ChartAxisPolicy.integerTicks(count: kilometerCount, maxLabels: maxLabels).map(Double.init)
    }

    func split(nearestTo x: Double) -> RunSplitMetric? {
        splitByKilometer[Int(x.rounded())]
    }
}
