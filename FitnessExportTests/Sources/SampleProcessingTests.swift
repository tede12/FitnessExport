import Foundation
import XCTest

@testable import FitnessExport

final class SampleProcessingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_738_281_600)

    func testDistanceSourcePicksTotalClosestToWorkout() {
        let watch = (0..<10).map { index in
            SourcedSample(
                source: "watch", startDate: start.addingTimeInterval(Double(index) * 60),
                endDate: start.addingTimeInterval(Double(index + 1) * 60), value: 100)
        }
        let phone = (0..<3).map { index in
            SourcedSample(
                source: "phone", startDate: start.addingTimeInterval(Double(index) * 60),
                endDate: start.addingTimeInterval(Double(index + 1) * 60), value: 80)
        }

        let picked = SampleSourceSelection.pickDistanceSource(watch + phone, expectedTotal: 1_000)

        XCTAssertEqual(picked.count, 10)
        XCTAssertTrue(picked.allSatisfy { $0.source == "watch" })

        XCTAssertEqual(SampleSourceSelection.pickDistanceSource(watch + phone, expectedTotal: nil).count, 10)
    }

    func testRateSourcePrefersWorkoutSourceThenLargestGroup() {
        let strava = [SourcedSample(source: "strava", startDate: start, endDate: start, value: 150)]
        let watch = (0..<5).map { index in
            SourcedSample(
                source: "watch", startDate: start.addingTimeInterval(Double(index)),
                endDate: start.addingTimeInterval(Double(index)), value: 140)
        }

        XCTAssertEqual(SampleSourceSelection.pickRateSource(strava + watch, preferredSource: "strava").count, 1)
        XCTAssertEqual(SampleSourceSelection.pickRateSource(strava + watch, preferredSource: "garmin").count, 5)
        XCTAssertTrue(SampleSourceSelection.pickRateSource([], preferredSource: nil).isEmpty)
    }

    func testHeartRateUsesOtherDeviceInWatchGapsWithoutDuplicatingOverlap() {
        let bluetooth = [0, 10, 20, 40, 50].map { second in
            SourcedSample(
                source: "bluetooth", startDate: start.addingTimeInterval(Double(second)),
                endDate: start.addingTimeInterval(Double(second)), value: 145)
        }
        let watch = [20, 30].map { second in
            SourcedSample(
                source: "watch", startDate: start.addingTimeInterval(Double(second)),
                endDate: start.addingTimeInterval(Double(second)), value: 150)
        }

        let merged = SampleSourceSelection.mergeHeartRateSources(bluetooth + watch, preferredSource: "watch")

        XCTAssertEqual(merged.map { Int($0.startDate.timeIntervalSince(start)) }, [0, 10, 20, 30, 40, 50])
        XCTAssertEqual(merged.first { $0.startDate == start.addingTimeInterval(20) }?.source, "watch")
    }

    func testCadenceDerivedFromStepCount() {

        let steps = [
            DistanceSampleSegment(startDate: start, endDate: start.addingTimeInterval(8), meters: 20),
            DistanceSampleSegment(startDate: start, endDate: start, meters: 5),
            DistanceSampleSegment(startDate: start, endDate: start.addingTimeInterval(10), meters: 0),
        ]

        let cadence = CadenceDerivation.stepsPerMinute(from: steps)

        XCTAssertEqual(cadence.count, 1)
        XCTAssertEqual(cadence[0].value, 150, accuracy: 0.001)
    }
}
