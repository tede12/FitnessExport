import Foundation
import XCTest

@testable import FitnessExport

final class TrendsAggregatorTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }

    private let reference = Date(timeIntervalSince1970: 1_789_552_800)

    private func run(daysAgo: Int, km: Double, minutes: Double) -> WorkoutListItem {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: reference)!
        return WorkoutListItem(
            id: UUID(), activityType: .running, startDate: date, endDate: date.addingTimeInterval(minutes * 60),
            duration: minutes * 60, distanceInMeters: km * 1_000, activeEnergyKilocalories: nil,
            hasHeartRateData: false, hasCadenceData: false)
    }

    func testWeeksIncludeEmptyWeeksAndSumDistance() {
        let items = [
            run(daysAgo: 0, km: 5, minutes: 25), run(daysAgo: 2, km: 10, minutes: 55),
            run(daysAgo: 16, km: 8, minutes: 40),
        ]
        let range = TrendsPeriod.fourWeeks.range(endingAt: reference, calendar: calendar)
        let weeks = TrendsAggregator.weeks(items, range: range, calendar: calendar, reference: reference)

        XCTAssertEqual(weeks.count, 5, "4 settimane di calendario coprono 5 settimane ISO parziali")
        XCTAssertEqual(weeks.last?.kilometers ?? 0, 15, accuracy: 0.001)
        XCTAssertEqual(weeks.last?.count, 2)
        XCTAssertTrue(weeks.contains { $0.count == 0 }, "le settimane vuote restano nel grafico")
        XCTAssertEqual(weeks.map(\.start), weeks.map(\.start).sorted())
    }

    func testPeriodRangeAndPreviousComparison() {
        let range = TrendsPeriod.fourWeeks.range(endingAt: reference, calendar: calendar)!
        XCTAssertEqual(range.duration, 28 * 86_400, accuracy: 3_601)
        XCTAssertNil(TrendsPeriod.all.range(endingAt: reference, calendar: calendar))

        XCTAssertEqual(TrendsAggregator.relativeChange(current: 120, previous: 100)!, 0.2, accuracy: 0.0001)
        XCTAssertNil(TrendsAggregator.relativeChange(current: 10, previous: 0))
    }

    func testRunPointsSkipTooShortAndAttachHeartRate() {
        let long = run(daysAgo: 1, km: 10, minutes: 50)
        let short = run(daysAgo: 1, km: 0.3, minutes: 5)
        let detail = WorkoutDetailSnapshot(
            id: long.id, activityType: .running, startDate: long.startDate, endDate: long.endDate,
            duration: long.duration, distanceInMeters: 10_000, activeEnergyKilocalories: nil, averageHeartRate: 150,
            maxHeartRate: 160, averageCadence: nil, splits: [])

        let points = TrendsAggregator.runPoints([long, short], details: [long.id: detail])
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].paceSecondsPerKilometer, 300, accuracy: 0.001)
        XCTAssertEqual(points[0].averageHeartRate, 150)
    }

    func testMonthlyBucketsCoverRangeAndSumDistance() {
        let items = [
            run(daysAgo: 0, km: 5, minutes: 25), run(daysAgo: 40, km: 10, minutes: 55),
            run(daysAgo: 100, km: 8, minutes: 40),
        ]
        let range = TrendsPeriod.sixMonths.range(endingAt: reference, calendar: calendar)
        let months = TrendsAggregator.buckets(
            items, resolution: .month, range: range, calendar: calendar, reference: reference)

        XCTAssertEqual(months.count, 7, "6 mesi di calendario coprono 7 mesi parziali")
        XCTAssertEqual(months.reduce(0) { $0 + $1.kilometers }, 23, accuracy: 0.001)
        XCTAssertEqual(calendar.component(.day, from: months.first!.start), 1, "ogni bucket parte dal primo del mese")
        XCTAssertEqual(months.last?.count, 1)
    }

    func testQuarterStartsOnFirstMonthOfQuarter() {
        let start = TrendsAggregator.startOfPeriod(reference, resolution: .quarter, calendar: calendar)!
        let components = calendar.dateComponents([.year, .month, .day], from: start)
        XCTAssertEqual(components.month, 7, "settembre → trimestre che inizia a luglio")
        XCTAssertEqual(components.day, 1)
    }

    func testVolumeResolutionKeepsBarsReadable() {
        XCTAssertEqual(TrendsAggregator.volumeResolution(for: 28 * 86_400), .week)
        XCTAssertEqual(
            TrendsAggregator.volumeResolution(for: 365 * 86_400), .week, "52 settimane stanno sotto le 60 barre")
        XCTAssertEqual(TrendsAggregator.volumeResolution(for: 3 * 365 * 86_400), .month)
        XCTAssertEqual(TrendsAggregator.volumeResolution(for: 8 * 365 * 86_400), .quarter)
    }

    func testPaceSeriesSwitchesToBucketsWhenTooManyRuns() {
        let few = (0..<10).map { run(daysAgo: $0 * 3, km: 8, minutes: 40) }
        guard
            case .runs(let points) = TrendsAggregator.paceSeries(
                TrendsAggregator.runPoints(few, details: [:]), calendar: calendar)
        else {
            return XCTFail("poche corse → punti singoli")
        }
        XCTAssertEqual(points.count, 10)

        let many = (0..<400).map { run(daysAgo: $0 * 2, km: 8, minutes: 40) }
        guard
            case .buckets(let buckets, let resolution) = TrendsAggregator.paceSeries(
                TrendsAggregator.runPoints(many, details: [:]), calendar: calendar)
        else {
            return XCTFail("molte corse → bucket")
        }
        XCTAssertEqual(resolution, .month, "800 giorni → oltre 60 settimane, quindi mesi")
        XCTAssertLessThanOrEqual(buckets.count, 60)
        XCTAssertEqual(buckets.map(\.start), buckets.map(\.start).sorted())
    }

    func testPaceBucketsAggregateWeightedByDistance() {
        let fast = run(daysAgo: 1, km: 10, minutes: 40)
        let slow = run(daysAgo: 2, km: 5, minutes: 30)
        let detail = WorkoutDetailSnapshot(
            id: fast.id, activityType: .running, startDate: fast.startDate, endDate: fast.endDate,
            duration: fast.duration, distanceInMeters: 10_000, activeEnergyKilocalories: nil, averageHeartRate: 150,
            maxHeartRate: 160, averageCadence: nil, splits: [])

        let buckets = TrendsAggregator.paceBuckets(
            TrendsAggregator.runPoints([fast, slow], details: [fast.id: detail]), resolution: .week, calendar: calendar)
        XCTAssertEqual(buckets.count, 1)
        let bucket = buckets[0]
        XCTAssertEqual(bucket.count, 2)
        XCTAssertEqual(bucket.minPace, 240, accuracy: 0.001)
        XCTAssertEqual(bucket.maxPace, 360, accuracy: 0.001)
        XCTAssertEqual(bucket.averagePace, 70 * 60 / 15, accuracy: 0.001, "media ponderata sui km: 70 min / 15 km")
        XCTAssertEqual(bucket.averageHeartRate, 150, "solo la corsa con FC pesa nella media")
    }

    func testWeekColumnsPlaceMondayFirstAndLeaveFutureDaysEmpty() {
        let cells = TrendsAggregator.dayCells(
            [run(daysAgo: 0, km: 5, minutes: 25)], weeks: 2, calendar: calendar, reference: reference)
        let columns = TrendsAggregator.weekColumns(cells, calendar: calendar)

        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0].compactMap { $0 }.count, 7, "settimana scorsa completa")
        XCTAssertEqual(columns[1].compactMap { $0 }.count, 3, "lun-mer di questa settimana")
        XCTAssertNil(columns[1][6], "domenica futura resta vuota")
        XCTAssertEqual(columns[1][2]?.meters, 5_000, "mercoledì = indice 2")
    }

    func testDayCellsCoverFullWeeksUpToToday() {
        let cells = TrendsAggregator.dayCells(
            [run(daysAgo: 0, km: 5, minutes: 25)], weeks: 2, calendar: calendar, reference: reference)
        XCTAssertEqual(calendar.component(.weekday, from: cells.first!.date), 2, "parte dal lunedì")
        XCTAssertEqual(cells.last!.date, calendar.startOfDay(for: reference))
        XCTAssertEqual(cells.count, 7 + 3)
        XCTAssertEqual(cells.last?.meters, 5_000)
    }
}
