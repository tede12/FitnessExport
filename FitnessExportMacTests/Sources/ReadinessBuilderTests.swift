import FitnessSyncKit
import Foundation
import XCTest

@testable import FitnessExportMac

final class ReadinessBuilderTests: XCTestCase {
    private let calendar = WeekZonesBuilder.isoCalendar
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9))!
    }

    private func key(_ back: Int) -> String {
        PlanItem.dayFormatter.string(
            from: calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now))!
        )
    }

    private func steadyHistory() -> [String: ReadinessBuilder.Day] {
        var days: [String: ReadinessBuilder.Day] = [:]
        for back in 1...80 {
            let odd = back % 2 == 1
            days[key(back)] = ReadinessBuilder.Day(
                hrv: odd ? 63 : 77, resting: odd ? 45 : 49, sleep: 7.5, load: 40
            )
        }
        return days
    }

    func testADayAtYourNormScoresAboutSevenAndAHalfOnTheBodyParts() throws {
        var days = steadyHistory()
        days[key(0)] = ReadinessBuilder.Day(hrv: (63 * 77.0).squareRoot(), resting: 47, sleep: 8, load: 0)
        let readiness = try XCTUnwrap(ReadinessBuilder.make(days: days, now: now))

        let hrv = try XCTUnwrap(readiness.components.first { $0.key == "hrv" })
        let resting = try XCTUnwrap(readiness.components.first { $0.key == "resting" })
        XCTAssertEqual(hrv.subscore, 7.5, accuracy: 0.05)
        XCTAssertEqual(resting.subscore, 7.5, accuracy: 0.05)
        XCTAssertEqual(hrv.position, .within)
        XCTAssertEqual(readiness.day, key(0))
    }

    func testALowHrvAndAHighRestingHeartRatePullTheScoreDown() throws {
        var normal = steadyHistory()
        normal[key(0)] = ReadinessBuilder.Day(hrv: 70, resting: 47, sleep: 7.5)
        var tired = steadyHistory()
        tired[key(0)] = ReadinessBuilder.Day(hrv: 45, resting: 54, sleep: 7.5)

        let good = try XCTUnwrap(ReadinessBuilder.make(days: normal, now: now))
        let bad = try XCTUnwrap(ReadinessBuilder.make(days: tired, now: now))
        XCTAssertLessThan(bad.score, good.score - 2)

        let hrv = try XCTUnwrap(bad.components.first { $0.key == "hrv" })
        XCTAssertEqual(hrv.position, .below)
        XCTAssertEqual(hrv.subscore, 0, "45 ms is several deviations under a 63–77 norm")
        XCTAssertEqual(bad.limiter?.key, "hrv")
    }

    func testSleepIsScoredOnAnAbsoluteScale() {
        XCTAssertEqual(ReadinessBuilder.clamp((4.5 - 4.5) / 3.5 * 10), 0)
        XCTAssertEqual(ReadinessBuilder.clamp((8 - 4.5) / 3.5 * 10), 10)
        XCTAssertEqual(ReadinessBuilder.clamp((9.5 - 4.5) / 3.5 * 10), 10)
    }

    func testLoadBandsMatchTheAcuteChronicReading() {
        XCTAssertEqual(ReadinessBuilder.loadSubscore(0.7), 10)
        XCTAssertEqual(ReadinessBuilder.loadSubscore(1.0), 10)
        XCTAssertEqual(ReadinessBuilder.loadSubscore(1.3), 7.5, accuracy: 1e-9)
        XCTAssertEqual(ReadinessBuilder.loadSubscore(1.7), 0, accuracy: 1e-9)
        XCTAssertEqual(ReadinessBuilder.loadSubscore(2.5), 0)
    }

    func testARampInLoadShowsUp() throws {
        var days = steadyHistory()

        for back in 1...7 { days[key(back)]?.load = 80 }
        days[key(0)] = ReadinessBuilder.Day(hrv: 70, resting: 47, sleep: 7.5)
        let readiness = try XCTUnwrap(ReadinessBuilder.make(days: days, now: now))
        let load = try XCTUnwrap(readiness.components.first { $0.key == "load" })
        XCTAssertEqual(load.value, 80 / ((80.0 * 7 + 40 * 35) / 42), accuracy: 1e-9)
        XCTAssertEqual(load.position, .above)
        XCTAssertLessThan(load.subscore, 7.5)
    }

    func testWeightsAreRescaledWhenAPartIsMissing() throws {
        var days = steadyHistory()
        days[key(0)] = ReadinessBuilder.Day(hrv: 70, resting: 47, sleep: nil)
        let readiness = try XCTUnwrap(ReadinessBuilder.make(days: days, now: now))
        XCTAssertFalse(readiness.components.contains { $0.key == "sleep" })
        XCTAssertEqual(readiness.components.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-9)
    }

    func testWithoutABodySignalThereIsNoScore() {
        var days = steadyHistory()

        days[key(0)] = ReadinessBuilder.Day(hrv: nil, resting: nil, sleep: 8)
        days[key(1)] = ReadinessBuilder.Day(hrv: nil, resting: nil, sleep: 8, load: 40)
        XCTAssertNil(ReadinessBuilder.make(days: days, now: now))
    }

    func testANapCountsTowardsTheNextMorningAndIsReportedApart() throws {
        var days = steadyHistory()
        days[key(0)] = ReadinessBuilder.Day(hrv: 70, resting: 47, sleep: 7.0, nap: 0.75)
        let readiness = try XCTUnwrap(ReadinessBuilder.make(days: days, now: now))
        let sleep = try XCTUnwrap(readiness.components.first { $0.key == "sleep" })
        XCTAssertEqual(sleep.value, 7.0)
        XCTAssertEqual(sleep.napHours, 0.75)
    }

    func testBeforeThisMorningsReadingsYesterdayIsShown() throws {
        var days = steadyHistory()
        days[key(0)] = ReadinessBuilder.Day(hrv: nil, resting: nil, sleep: nil)
        let readiness = try XCTUnwrap(ReadinessBuilder.make(days: days, now: now))
        XCTAssertEqual(readiness.day, key(1))
    }

    func testTooShortAHistoryGivesNoBaselineRatherThanAWildOne() {
        var days: [String: ReadinessBuilder.Day] = [:]
        for back in 1...5 { days[key(back)] = ReadinessBuilder.Day(hrv: 70, resting: 47, sleep: 7) }
        days[key(0)] = ReadinessBuilder.Day(hrv: 30, resting: 60, sleep: 7)
        XCTAssertNil(ReadinessBuilder.make(days: days, now: now))
    }

    func testHistoryCoversSixtyDaysEndingTodayWithTheirParts() throws {
        var days = steadyHistory()
        days[key(0)] = ReadinessBuilder.Day(hrv: 70, resting: 47, sleep: 7.5)
        let readiness = try XCTUnwrap(ReadinessBuilder.make(days: days, now: now))

        XCTAssertEqual(readiness.history.count, 60)
        XCTAssertEqual(readiness.history.last?.components, readiness.components)
        XCTAssertEqual(readiness.history.last?.day, key(0))
        XCTAssertEqual(readiness.history.last?.score, readiness.score)
    }

    func testTheQueriesExecuteAgainstARealStore() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try HealthDatabase(url: directory.appendingPathComponent("test.sqlite"))
        let readiness = try await ReadinessBuilder.build(from: database)
        XCTAssertNil(readiness)
    }
}
