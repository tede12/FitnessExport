import FitnessSyncKit
import Foundation
import XCTest

@testable import FitnessExportMac

final class BriefingBuilderTests: XCTestCase {
    private var directory: URL!
    private var database: HealthDatabase!
    private let start = Date().addingTimeInterval(-3_600)

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        database = try HealthDatabase(url: directory.appendingPathComponent("test.sqlite"))
    }

    override func tearDown() async throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testAnEmptyStoreStillProducesAUsableBriefing() async throws {
        let briefing = try await BriefingBuilder.build(from: database)

        XCTAssertTrue(briefing.plan.isEmpty)
        XCTAssertTrue(briefing.series.volume.isEmpty)
        XCTAssertNil(briefing.today.sleepHours)
        XCTAssertNil(briefing.today.hrv)
    }

    func testPlanSurvivesTheRoundTrip() async throws {
        let today = PlanItem.dayFormatter.string(from: Date())
        try await database.upsertPlan([
            HealthDatabase.PlanEntry(
                day: today, slot: "long", title: "LUNGO 12 km",
                detail: "Piano davvero.", target: "135–148 bpm · 6:15–6:45/km",
                done: false, rpe: nil, note: nil
            )
        ])

        let briefing = try await BriefingBuilder.build(from: database)
        let item = try XCTUnwrap(briefing.plan.first)

        XCTAssertEqual(item.day, today)
        XCTAssertEqual(item.slot, "long")
        XCTAssertEqual(item.title, "LUNGO 12 km")
        XCTAssertEqual(item.target, "135–148 bpm · 6:15–6:45/km")
        XCTAssertFalse(item.done)
    }

    func testTickingASessionComesBackInTheBriefing() async throws {
        let today = PlanItem.dayFormatter.string(from: Date())
        try await database.upsertPlan([
            HealthDatabase.PlanEntry(
                day: today, slot: "strength", title: "Forza A", detail: nil,
                target: "30 min", done: false, rpe: nil, note: nil
            )
        ])
        try await database.markPlan(day: today, slot: "strength", done: true, rpe: 7, note: "bene")

        let briefing = try await BriefingBuilder.build(from: database)
        let item = try XCTUnwrap(briefing.plan.first)

        XCTAssertTrue(item.done)
        XCTAssertEqual(item.rpe, 7)
        XCTAssertEqual(item.note, "bene")
    }

    func testRecoveryAndSleepSeriesAreMapped() async throws {
        let source = SourceRecord(bundleID: "com.apple.health", name: "Watch")
        try await database.applyQuantities(
            [
                QuantityRecord(
                    uuid: UUID(), start: start, end: start, value: 46, sourceIndex: 0
                )
            ],
            sources: [source], metricKey: "resting_heart_rate",
            stream: .quantity("resting_heart_rate"), anchor: nil
        )
        try await database.applyQuantities(
            [
                QuantityRecord(
                    uuid: UUID(), start: start, end: start, value: 71, sourceIndex: 0
                )
            ],
            sources: [source], metricKey: "hrv_sdnn",
            stream: .quantity("hrv_sdnn"), anchor: nil
        )

        let bedtime = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-30 * 60)
        try await database.applyCategories(
            [
                CategoryRecord(
                    uuid: UUID(), start: bedtime,
                    end: bedtime.addingTimeInterval(4 * 3_600), value: 4, sourceIndex: 0
                )
            ],
            sources: [source], metricKey: "sleep_analysis",
            stream: .category("sleep_analysis"), anchor: nil
        )

        let briefing = try await BriefingBuilder.build(from: database)

        let recovery = try XCTUnwrap(briefing.series.recovery.first)
        XCTAssertEqual(recovery.restingHeartRate, 46)
        XCTAssertEqual(recovery.hrv, 71)

        let sleep = try XCTUnwrap(briefing.series.sleep.first)
        XCTAssertEqual(sleep.hours, 4, accuracy: 0.1)
        XCTAssertEqual(briefing.today.sleepHours ?? 0, 4, accuracy: 0.1)
        XCTAssertEqual(briefing.today.sleepOnset, "23:30")

        let wake = DateFormatter()
        wake.dateFormat = "HH:mm"
        XCTAssertEqual(
            briefing.today.sleepWake,
            wake.string(from: bedtime.addingTimeInterval(4 * 3_600))
        )
    }

    func testTheWholeNightCountsWhateverTheHourOfTheBriefing() async throws {

        let source = SourceRecord(bundleID: "com.apple.health", name: "Watch")
        let bedtime = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-30 * 60)
        let midnight = bedtime.addingTimeInterval(2.5 * 3_600)
        try await database.applyCategories(
            [
                CategoryRecord(
                    uuid: UUID(), start: bedtime, end: midnight, value: 3, sourceIndex: 0
                ),
                CategoryRecord(
                    uuid: UUID(), start: midnight,
                    end: midnight.addingTimeInterval(5 * 3_600), value: 5, sourceIndex: 0
                ),
            ],
            sources: [source], metricKey: "sleep_analysis",
            stream: .category("sleep_analysis"), anchor: nil
        )
        try await database.applyQuantities(
            [
                QuantityRecord(
                    uuid: UUID(), start: midnight, end: midnight, value: 44, sourceIndex: 0
                )
            ],
            sources: [source], metricKey: "heart_rate",
            stream: .quantity("heart_rate"), anchor: nil
        )

        let briefing = try await BriefingBuilder.build(from: database)

        XCTAssertEqual(briefing.today.sleepHours ?? 0, 7.5, accuracy: 0.1)
        XCTAssertEqual(briefing.today.remMinutes ?? 0, 300, accuracy: 1)
        XCTAssertEqual(briefing.today.sleepHeartRate ?? 0, 44, accuracy: 0.1)
    }

    func testBodyCompositionIsMapped() async throws {
        let source = SourceRecord(bundleID: "com.feelfit", name: "Feelfit")
        for (key, value) in [("body_mass", 70.0), ("lean_body_mass", 55.0), ("body_fat_percentage", 0.20)] {
            try await database.applyQuantities(
                [QuantityRecord(uuid: UUID(), start: start, end: start, value: value, sourceIndex: 0)],
                sources: [source], metricKey: key, stream: .quantity(key), anchor: nil
            )
        }

        let briefing = try await BriefingBuilder.build(from: database)

        XCTAssertEqual(briefing.today.bodyMass ?? 0, 70.0, accuracy: 0.05)
        XCTAssertEqual(briefing.today.leanMass ?? 0, 55.0, accuracy: 0.05)

        XCTAssertEqual(briefing.today.fatPercent ?? 0, 20.0, accuracy: 0.05)

        let point = try XCTUnwrap(briefing.series.body.first)
        XCTAssertEqual(point.mass ?? 0, 70.0, accuracy: 0.05)
        XCTAssertEqual(point.lean ?? 0, 55.0, accuracy: 0.05)
    }
}
