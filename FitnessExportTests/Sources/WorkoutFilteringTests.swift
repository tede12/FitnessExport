import Foundation
import XCTest

@testable import FitnessExport

final class WorkoutFilteringTests: XCTestCase {
    func testFilterByMonthAndActivity() {
        let calendar = Calendar(identifier: .gregorian)
        let januaryRun = makeItem(
            id: UUID(),
            activity: .running,
            date: calendar.date(from: DateComponents(year: 2026, month: 1, day: 11, hour: 7, minute: 0))!
        )
        let februaryWalk = makeItem(
            id: UUID(),
            activity: .walking,
            date: calendar.date(from: DateComponents(year: 2026, month: 2, day: 9, hour: 7, minute: 0))!
        )
        let februaryRun = makeItem(
            id: UUID(),
            activity: .running,
            date: calendar.date(from: DateComponents(year: 2026, month: 2, day: 12, hour: 7, minute: 0))!
        )

        let filtered = WorkoutFilter.filter(
            items: [januaryRun, februaryWalk, februaryRun],
            period: .months([WorkoutMonthKey(date: februaryWalk.startDate)]),
            activityTypes: [.running]
        )

        XCTAssertEqual(filtered.map(\.id), [februaryRun.id])
    }

    func testFilterByMultipleMonths() {
        let calendar = Calendar(identifier: .gregorian)
        let januaryRun = makeItem(
            id: UUID(),
            activity: .running,
            date: calendar.date(from: DateComponents(year: 2026, month: 1, day: 11, hour: 7, minute: 0))!
        )
        let marchRun = makeItem(
            id: UUID(),
            activity: .running,
            date: calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 7, minute: 0))!
        )
        let februaryWalk = makeItem(
            id: UUID(),
            activity: .walking,
            date: calendar.date(from: DateComponents(year: 2026, month: 2, day: 9, hour: 7, minute: 0))!
        )

        let filtered = WorkoutFilter.filter(
            items: [januaryRun, marchRun, februaryWalk],
            period: .months([WorkoutMonthKey(date: januaryRun.startDate), WorkoutMonthKey(date: marchRun.startDate)]),
            activityTypes: [.running]
        )

        XCTAssertEqual(filtered.map(\.id), [marchRun.id, januaryRun.id])
    }

    func testCustomRangeHonorsBounds() {
        let start = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 2, day: 9, hour: 7, minute: 0))!
        let included = makeItem(id: UUID(), activity: .running, date: start)
        let excluded = makeItem(id: UUID(), activity: .running, date: start.addingTimeInterval(86_400 * 5))

        let filtered = WorkoutFilter.filter(
            items: [included, excluded],
            period: .custom(start: start, end: start.addingTimeInterval(86_400 * 2)),
            activityTypes: [.running]
        )

        XCTAssertEqual(filtered.map(\.id), [included.id])
    }

    private func makeItem(id: UUID, activity: WorkoutActivityType, date: Date) -> WorkoutListItem {
        WorkoutListItem(
            id: id,
            activityType: activity,
            startDate: date,
            endDate: date.addingTimeInterval(1_800),
            duration: 1_800,
            distanceInMeters: 5_000,
            activeEnergyKilocalories: 300,
            hasHeartRateData: true,
            hasCadenceData: true
        )
    }
}
