import Foundation
import XCTest

@testable import FitnessExport

final class SplitComputationTests: XCTestCase {

    func testLapMetricsSplitDistanceAcrossLapBoundary() {
        let start = Date(timeIntervalSince1970: 1_738_281_600)

        let laps = [
            WorkoutLap(start: start, end: start.addingTimeInterval(90), intensity: .active, name: "400 m"),
            WorkoutLap(start: start.addingTimeInterval(90), end: start.addingTimeInterval(150), intensity: .recovery),
        ]
        let distance = [
            DistanceSampleSegment(startDate: start, endDate: start.addingTimeInterval(80), meters: 350),
            DistanceSampleSegment(
                startDate: start.addingTimeInterval(80), endDate: start.addingTimeInterval(100), meters: 100),
            DistanceSampleSegment(
                startDate: start.addingTimeInterval(100), endDate: start.addingTimeInterval(150), meters: 150),
        ]
        let heartRate = [
            TimedValueSample(startDate: start, endDate: start.addingTimeInterval(90), value: 170),
            TimedValueSample(
                startDate: start.addingTimeInterval(90), endDate: start.addingTimeInterval(150), value: 140),
        ]

        let metrics = SplitComputation.computeLapMetrics(
            laps: laps, workoutStart: start, distanceSamples: distance, heartRateSamples: heartRate, cadenceSamples: [])

        XCTAssertEqual(metrics.count, 2)
        XCTAssertEqual(metrics[0].index, 1)
        XCTAssertEqual(metrics[0].intensity, .active)
        XCTAssertEqual(metrics[0].name, "400 m")
        XCTAssertEqual(metrics[0].startOffset, 0)
        XCTAssertEqual(metrics[0].duration, 90)
        XCTAssertEqual(metrics[0].distanceInMeters ?? 0, 400, accuracy: 0.01)
        XCTAssertEqual(metrics[0].paceSecondsPerKilometer ?? 0, 225, accuracy: 0.01)
        XCTAssertEqual(metrics[0].averageHeartRate ?? 0, 170, accuracy: 0.01)
        XCTAssertEqual(metrics[1].startOffset, 90)
        XCTAssertEqual(metrics[1].distanceInMeters ?? 0, 200, accuracy: 0.01)
        XCTAssertEqual(metrics[1].averageHeartRate ?? 0, 140, accuracy: 0.01)
    }

    func testLapWithoutDistanceHasNoPace() {
        let start = Date(timeIntervalSince1970: 1_738_281_600)
        let laps = [WorkoutLap(start: start, end: start.addingTimeInterval(60), intensity: .rest)]
        let metrics = SplitComputation.computeLapMetrics(
            laps: laps, workoutStart: start, distanceSamples: [], heartRateSamples: [], cadenceSamples: [])
        XCTAssertNil(metrics[0].distanceInMeters)
        XCTAssertNil(metrics[0].paceSecondsPerKilometer)
    }

    func testComputesPerKilometerMetrics() {
        let start = Date(timeIntervalSince1970: 1_738_281_600)

        let distanceSamples = [
            DistanceSampleSegment(startDate: start, endDate: start.addingTimeInterval(300), meters: 1_000),
            DistanceSampleSegment(
                startDate: start.addingTimeInterval(300), endDate: start.addingTimeInterval(605), meters: 1_000),
        ]

        let heartRateSamples = [
            TimedValueSample(startDate: start, endDate: start.addingTimeInterval(300), value: 150),
            TimedValueSample(
                startDate: start.addingTimeInterval(300), endDate: start.addingTimeInterval(605), value: 160),
        ]

        let cadenceSamples = [
            TimedValueSample(startDate: start, endDate: start.addingTimeInterval(300), value: 170),
            TimedValueSample(
                startDate: start.addingTimeInterval(300), endDate: start.addingTimeInterval(605), value: 174),
        ]

        let splits = SplitComputation.computeKilometerSplits(
            distanceSamples: distanceSamples,
            heartRateSamples: heartRateSamples,
            cadenceSamples: cadenceSamples
        )

        XCTAssertEqual(splits.count, 2)
        XCTAssertEqual(splits[0].kilometer, 1)
        XCTAssertEqual(splits[0].duration, 300, accuracy: 0.1)
        XCTAssertEqual(splits[0].averageHeartRate ?? 0, 150, accuracy: 0.1)
        XCTAssertEqual(splits[1].averageCadence ?? 0, 174, accuracy: 0.1)
    }
}
