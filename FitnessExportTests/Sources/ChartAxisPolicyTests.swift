import FitnessUI
import Foundation
import XCTest

@testable import FitnessExport

final class ChartAxisPolicyTests: XCTestCase {
    func testIntegerTicksNeverExceedBudget() {
        for count in [1, 5, 10, 21, 42, 100, 250] {
            for budget in [4, 6, 8, 10, 20] {
                let ticks = ChartAxisPolicy.integerTicks(count: count, maxLabels: budget)
                XCTAssertLessThanOrEqual(ticks.count, budget, "count \(count), budget \(budget)")
                XCTAssertFalse(ticks.isEmpty)
                XCTAssertEqual(ticks, ticks.sorted())
                XCTAssertTrue(ticks.allSatisfy { $0 >= 1 && $0 <= count })
            }
        }
    }

    func testIntegerTicksUseRoundSteps() {
        XCTAssertEqual(ChartAxisPolicy.integerTicks(count: 10, maxLabels: 10), Array(1...10))
        XCTAssertEqual(
            ChartAxisPolicy.integerTicks(count: 21, maxLabels: 10), [2, 4, 6, 8, 10, 12, 14, 16, 18, 20],
            "mezza maratona: ogni 2 km")
        XCTAssertEqual(
            ChartAxisPolicy.integerTicks(count: 42, maxLabels: 10), [5, 10, 15, 20, 25, 30, 35, 40],
            "maratona: ogni 5 km")
    }

    func testPaceTicksLandOnRoundValuesAndBoundTheData() {

        XCTAssertEqual(ChartAxisPolicy.paceTicks(min: 292, max: 341, maxLabels: 4), [270, 300, 330, 360])

        XCTAssertEqual(ChartAxisPolicy.paceTicks(min: 250, max: 400, maxLabels: 5), [240, 300, 360, 420])

        XCTAssertEqual(ChartAxisPolicy.paceTicks(min: 301, max: 303, maxLabels: 4), [300, 305])
        XCTAssertEqual(ChartAxisPolicy.paceTicks(min: 300, max: 300, maxLabels: 4), [300, 305])
    }

    func testValueTicksAreIntegersForIntegerMetrics() {
        XCTAssertEqual(ChartAxisPolicy.valueTicks(min: 175, max: 177, maxLabels: 4), [175, 176, 177])
        XCTAssertEqual(ChartAxisPolicy.valueTicks(min: 137, max: 149, maxLabels: 4), [135, 140, 145, 150])
        XCTAssertEqual(ChartAxisPolicy.valueTicks(min: 0, max: 38, maxLabels: 5), [0, 10, 20, 30, 40])
        XCTAssertTrue(ChartAxisPolicy.valueTicks(min: .nan, max: 10, maxLabels: 4).isEmpty)
        XCTAssertEqual(ChartAxisPolicy.domain(of: [135, 140, 145, 150]), 135...150)
        XCTAssertNil(ChartAxisPolicy.domain(of: []))
    }

    func testDateAxisGrowsWithSpan() {
        let day: TimeInterval = 86_400
        XCTAssertEqual(ChartAxisPolicy.dateAxis(span: 28 * day, maxLabels: 8), .init(unit: .week, count: 1))
        XCTAssertEqual(ChartAxisPolicy.dateAxis(span: 92 * day, maxLabels: 8), .init(unit: .month, count: 1))
        XCTAssertEqual(ChartAxisPolicy.dateAxis(span: 183 * day, maxLabels: 8), .init(unit: .month, count: 1))
        XCTAssertEqual(ChartAxisPolicy.dateAxis(span: 365 * day, maxLabels: 8), .init(unit: .month, count: 2))
        XCTAssertEqual(
            ChartAxisPolicy.dateAxis(span: 365 * day, maxLabels: 8, spansYears: true), .init(unit: .quarter, count: 3),
            "con l'anno nell'etichetta serve più spazio")
        XCTAssertEqual(
            ChartAxisPolicy.dateAxis(span: 3 * 365 * day, maxLabels: 8, spansYears: true), .init(unit: .year, count: 1))
        XCTAssertEqual(
            ChartAxisPolicy.dateAxis(span: 12 * 365 * day, maxLabels: 8, spansYears: true), .init(unit: .year, count: 2)
        )
    }

    func testDateAxisUsesBudgetOnWiderScreens() {
        let day: TimeInterval = 86_400
        XCTAssertEqual(
            ChartAxisPolicy.dateAxis(span: 365 * day, maxLabels: 12, spansYears: true), .init(unit: .month, count: 2),
            "su iPad ci stanno 6 etichette larghe")
        XCTAssertEqual(ChartAxisPolicy.dateAxis(span: 92 * day, maxLabels: 12), .init(unit: .week, count: 2))
    }
}
