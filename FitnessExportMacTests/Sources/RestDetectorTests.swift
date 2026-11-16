import FitnessSyncKit
import Foundation
import XCTest

@testable import FitnessExportMac

final class RestDetectorTests: XCTestCase {
    private let base: Int64 = 1_792_000_000_000 / RestDetector.binMs * RestDetector.binMs

    private func bins(_ spec: [(hr: Double?, steps: Double)]) -> [RestDetector.Bin] {
        spec.enumerated().map { index, bin in
            RestDetector.Bin(
                startMs: base + Int64(index) * RestDetector.binMs, heartRate: bin.hr, steps: bin.steps
            )
        }
    }

    func testNinetyMinutesAtSleepingHeartRateWithoutStepsIsOneEpisode() throws {
        let input = bins([(56, 30)] + Array(repeating: (47, 0), count: 9) + [(57, 40)])
        let episodes = RestDetector.detect(bins: input, busy: [], sleepingHeartRate: 45)
        let episode = try XCTUnwrap(episodes.first)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episode.minutes, 90)
        XCTAssertEqual(episode.heartRate, 47)
    }

    func testAShortStillStretchIsNotRest() {
        let input = bins([(47, 0), (47, 0)])
        XCTAssertTrue(RestDetector.detect(bins: input, busy: [], sleepingHeartRate: 45).isEmpty)
    }

    func testHeartRateAwakeOnTheSofaIsNotRest() {

        let input = bins(Array(repeating: (52, 0), count: 6))
        XCTAssertTrue(RestDetector.detect(bins: input, busy: [], sleepingHeartRate: 45).isEmpty)
    }

    func testStepsBreakAnEpisode() {
        let input = bins(
            Array(repeating: (47, 0), count: 3) + [(47, 200)] + Array(repeating: (47, 0), count: 3)
        )
        let episodes = RestDetector.detect(bins: input, busy: [], sleepingHeartRate: 45)
        XCTAssertEqual(episodes.map(\.minutes), [30, 30])
    }

    func testOneBinWithoutSamplesIsBridged() {

        var input = bins(Array(repeating: (47, 0), count: 5))
        input.remove(at: 2)
        let episodes = RestDetector.detect(bins: input, busy: [], sleepingHeartRate: 45)
        XCTAssertEqual(episodes.map(\.minutes), [50])
    }

    func testRecordedSleepAndWorkoutsAreNotCountedAgain() {
        let input = bins(Array(repeating: (47, 0), count: 6))
        let busy = [base...(base + 6 * RestDetector.binMs)]
        XCTAssertTrue(RestDetector.detect(bins: input, busy: busy, sleepingHeartRate: 45).isEmpty)
    }

    func testAnAfternoonBelongsToTheNextMorning() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let friday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 17, minute: 30))!
        let episode = RestEpisode(
            start: friday, end: friday.addingTimeInterval(5_400), heartRate: 47, sleepingHeartRate: 45
        )
        XCTAssertEqual(RestDetector.key(for: episode), "2026-10-31")
    }
}
