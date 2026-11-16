import FitnessSyncKit
import Foundation
import XCTest

@testable import FitnessExportMac

final class WeekZonesBuilderTests: XCTestCase {
    private let zones = WeekZonesBuilder.Zones(floors: [140, 154, 169, 184], source: "athlete")
    private let calendar = WeekZonesBuilder.isoCalendar

    private var thursday: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12))!
    }

    private func day(_ offset: Int, from base: String = "2026-10-19") -> String {
        let start = PlanItem.dayFormatter.date(from: base)!
        return PlanItem.dayFormatter.string(
            from: calendar.date(byAdding: .day, value: offset, to: start)!
        )
    }

    private func run(
        _ day: String, _ km: Double, easy: Int = 0, threshold: Int = 0, name: String? = nil
    ) -> WeekZonesBuilder.Run {
        WeekZonesBuilder.Run(
            day: day, kilometres: km, zoneSamples: [0, easy, 0, threshold, 0], planName: name
        )
    }

    func testMissingHeartRateAndZonesDoNotInventAPanel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try HealthDatabase(url: directory.appendingPathComponent("health.sqlite"))
        let panel = try await WeekZonesBuilder.build(from: database)
        XCTAssertNil(panel)
    }

    func testConfirmedProfileZonesOverrideLegacyFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"Z2":120,"Z3":140,"Z4":160,"Z5":180}"#.utf8)
            .write(to: directory.appendingPathComponent("heart-rate-zones.json"))
        try Data(#"{"zones":{"Z2":125,"Z3":145,"Z4":165,"Z5":185}}"#.utf8)
            .write(to: directory.appendingPathComponent("personal-context.json"))
        XCTAssertEqual(WeekZonesBuilder.loadZones(from: directory)?.floors, [125, 145, 165, 185])
    }

    func testDuplicateOrBooleanZoneBoundsAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for text in [
            #"{"Z2":140,"Z3":140,"Z4":160,"Z5":180}"#,
            #"{"Z2":true,"Z3":140,"Z4":160,"Z5":180}"#,
        ] {
            try Data(text.utf8).write(to: directory.appendingPathComponent("heart-rate-zones.json"))
            XCTAssertNil(WeekZonesBuilder.loadZones(from: directory))
        }
    }

    func testNoRunsMeansNoPanel() {
        XCTAssertNil(
            WeekZonesBuilder.make(runs: [], zones: zones, athleteTarget: nil, now: thursday)
        )
    }

    func testKilometresAreSplitByTheShareOfSamplesInEachZone() throws {

        let week = try XCTUnwrap(
            WeekZonesBuilder.make(
                runs: [run(day(0), 10, easy: 300, threshold: 100)],
                zones: zones, athleteTarget: nil, now: thursday
            )
        )
        XCTAssertEqual(week.weekStart, "2026-10-19")
        XCTAssertEqual(week.done[1], 7.5, accuracy: 1e-9)
        XCTAssertEqual(week.done[3], 2.5, accuracy: 1e-9)
        XCTAssertEqual(week.doneTotal, 10, accuracy: 1e-9)
    }

    func testARunWithoutHeartRateCountsInTheTotalButInNoZone() throws {
        let week = try XCTUnwrap(
            WeekZonesBuilder.make(
                runs: [run(day(0), 5)], zones: zones, athleteTarget: nil, now: thursday
            )
        )
        XCTAssertEqual(week.unzoned, 5)
        XCTAssertEqual(week.doneEasy, 0)
        XCTAssertEqual(week.doneTotal, 5)
    }

    func testOnlyTheDaysStillToComeAreForecast() throws {

        let open = try XCTUnwrap(
            WeekZonesBuilder.make(
                runs: [run(day(0), 5, easy: 1)], zones: zones, athleteTarget: nil, now: thursday
            )
        )
        XCTAssertEqual(open.forecast.map(\.day), [day(3), day(4), day(5), day(6)])

        let closed = try XCTUnwrap(
            WeekZonesBuilder.make(
                runs: [run(day(3), 5, easy: 1)], zones: zones, athleteTarget: nil, now: thursday
            )
        )
        XCTAssertEqual(closed.forecast.map(\.day), [day(4), day(5), day(6)])
    }

    func testAWeekdayHabitBecomesAHighProbabilityForecast() throws {

        let history = (1...4).map { week in
            run(day(5 - week * 7), 8, easy: 100, name: "Lungo")
        }
        let week = try XCTUnwrap(
            WeekZonesBuilder.make(runs: history, zones: zones, athleteTarget: nil, now: thursday)
        )
        let saturday = try XCTUnwrap(week.forecast.first { $0.day == day(5) })
        XCTAssertEqual(saturday.probability, 1, accuracy: 1e-9)
        XCTAssertEqual(saturday.kilometres, 8)
        XCTAssertEqual(saturday.weeksWithRun, 4)
        XCTAssertEqual(saturday.weeksObserved, 4)
        XCTAssertEqual(saturday.usualPlanName, "Lungo")
        XCTAssertEqual(saturday.zoneShare[1], 1, accuracy: 1e-9)

        let friday = try XCTUnwrap(week.forecast.first { $0.day == day(4) })
        XCTAssertEqual(friday.probability, 0)
        XCTAssertEqual(week.freeDays.map(\.day), [day(3), day(4), day(6)])
    }

    func testRecentWeeksWeighMoreThanOldOnes() throws {

        let history = [
            run(day(-28), 5, easy: 1),
            run(day(5 - 7), 10, easy: 1),
        ]
        let week = try XCTUnwrap(
            WeekZonesBuilder.make(runs: history, zones: zones, athleteTarget: nil, now: thursday)
        )
        let saturday = try XCTUnwrap(week.forecast.first { $0.day == day(5) })
        let weights = [3.0, 2, 1, 0].map { pow(0.5, $0 / 3) }
        XCTAssertEqual(saturday.probability, 1 / weights.reduce(0, +), accuracy: 1e-9)
        XCTAssertGreaterThan(saturday.probability, 0.25)
    }

    func testOneLongRunDoesNotTurnEverySundayIntoALongRun() throws {

        let history = [6.0, 6, 20, 6].enumerated().map { index, km in
            run(day(6 - (index + 1) * 7), km, easy: 1)
        }
        let week = try XCTUnwrap(
            WeekZonesBuilder.make(runs: history, zones: zones, athleteTarget: nil, now: thursday)
        )
        let sunday = try XCTUnwrap(week.forecast.first { $0.day == day(6) })
        XCTAssertEqual(sunday.kilometres, 6)
    }

    func testMissingSubtractsWhatIsDoneAndWhatIsExpected() throws {

        let history = (1...4).map { run(day(5 - $0 * 7), 8, easy: 1) }
        let target = WeekTarget(kilometres: 40, easyShare: 0.8, source: "athlete")
        let week = try XCTUnwrap(
            WeekZonesBuilder.make(
                runs: history + [run(day(0), 10, threshold: 1)],
                zones: zones, athleteTarget: target, now: thursday
            )
        )
        XCTAssertEqual(week.missingEasy, 32 - 8, accuracy: 1e-9)
        XCTAssertEqual(week.missingQuality, 8 - 10, accuracy: 1e-9)
    }

    func testWithoutAnAthleteTargetTheTrendPlusTenPercentIsUsed() throws {

        let history = (1...4).map { run(day(-$0 * 7), 30, easy: 1) }
        let week = try XCTUnwrap(
            WeekZonesBuilder.make(runs: history, zones: zones, athleteTarget: nil, now: thursday)
        )
        XCTAssertEqual(week.target.kilometres, 33)
        XCTAssertEqual(week.target.source, "trend")
        XCTAssertEqual(week.target.easyShare, 0.8)
    }

    func testFilesNextToTheArchiveAreRead() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data(#"{"Z2": 140, "Z3": 154, "Z4": 169, "Z5": 184}"#.utf8)
            .write(to: directory.appendingPathComponent("heart-rate-zones.json"))
        try Data(#"{"kilometres": 45, "easy_share": 0.75}"#.utf8)
            .write(to: directory.appendingPathComponent("weekly-target.json"))

        XCTAssertEqual(WeekZonesBuilder.loadZones(from: directory)?.floors, [140, 154, 169, 184])
        let target = try XCTUnwrap(WeekZonesBuilder.loadTarget(from: directory))
        XCTAssertEqual(target.kilometres, 45)
        XCTAssertEqual(target.easyShare, 0.75)
        XCTAssertEqual(target.source, "athlete")
    }

    func testUnorderedZonesAreRejectedRatherThanMisread() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"Z2": 154, "Z3": 140, "Z4": 169, "Z5": 184}"#.utf8)
            .write(to: directory.appendingPathComponent("heart-rate-zones.json"))
        XCTAssertNil(WeekZonesBuilder.loadZones(from: directory))
    }

    func testTheRunsQueryExecutesAgainstARealStore() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try HealthDatabase(url: directory.appendingPathComponent("test.sqlite"))

        let week = try await WeekZonesBuilder.build(from: database)
        XCTAssertNil(week)
    }

    func testABriefingWithoutTheWeekStillDecodes() throws {

        let old = TrainingBriefing(
            generatedAt: Date(timeIntervalSince1970: 0), today: TodayStatus(), plan: [],
            week: [], series: TrendSeries()
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any]
        )
        object.removeValue(forKey: "weekZones")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TrainingBriefing.self, from: data)
        XCTAssertNil(decoded.weekZones)
    }
}
