import Foundation
import XCTest

@testable import FitnessExport

final class AnalysisComposerTests: ItalianLocalizationTestCase {
    func testComposeSingleWorkoutOmitsAggregateHeader() {
        let item = makeItem(id: UUID(), date: Date(timeIntervalSince1970: 1_738_281_600))
        let detail = makeDetail(id: item.id, date: item.startDate)

        let text = AnalysisComposer().compose(
            details: [detail],
            selectedItems: [item],
            periodDescription: "marzo 2026"
        )

        XCTAssertTrue(text.contains("Corsa"))
        XCTAssertFalse(text.contains("Passo medio aggregato"))
    }

    func testComposeMultipleWorkoutsIncludesAggregateMetrics() {
        let first = makeItem(id: UUID(), date: Date(timeIntervalSince1970: 1_738_281_600))
        let second = makeItem(id: UUID(), date: Date(timeIntervalSince1970: 1_738_368_000))

        let text = AnalysisComposer().compose(
            details: [
                makeDetail(id: first.id, date: first.startDate),
                makeDetail(id: second.id, date: second.startDate, averageHeartRate: nil, averageCadence: nil),
            ],
            selectedItems: [first, second],
            periodDescription: "marzo 2026"
        )

        XCTAssertTrue(text.contains("Attività selezionate: 2"))
        XCTAssertTrue(text.contains("Distanza totale"))
        XCTAssertTrue(text.contains("Split per km"))
    }

    private func makeItem(id: UUID, date: Date) -> WorkoutListItem {
        WorkoutListItem(
            id: id,
            activityType: .running,
            startDate: date,
            endDate: date.addingTimeInterval(1_800),
            duration: 1_800,
            distanceInMeters: 5_000,
            activeEnergyKilocalories: 320,
            hasHeartRateData: true,
            hasCadenceData: true
        )
    }

    private func makeDetail(id: UUID, date: Date, averageHeartRate: Double? = 152, averageCadence: Double? = 170)
        -> WorkoutDetailSnapshot
    {
        WorkoutDetailSnapshot(
            id: id,
            activityType: .running,
            startDate: date,
            endDate: date.addingTimeInterval(1_800),
            duration: 1_800,
            distanceInMeters: 5_000,
            activeEnergyKilocalories: 320,
            averageHeartRate: averageHeartRate,
            maxHeartRate: 164,
            averageCadence: averageCadence,
            splits: [
                RunSplitMetric(
                    kilometer: 1, duration: 360, paceSecondsPerKilometer: 360, averageHeartRate: averageHeartRate,
                    averageCadence: averageCadence)
            ]
        )
    }
}
