import FitnessSyncKit
import HealthKit
import XCTest

@testable import FitnessExport

final class HealthCatalogUnitTests: XCTestCase {

    func testEveryQuantityIdentifierResolvesToARealType() {
        for metric in HealthCatalog.metrics where !metric.isCategory {
            XCTAssertNotNil(
                HKObjectType.quantityType(
                    forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.identifier)
                ),
                "identificatore sconosciuto: \(metric.identifier) (\(metric.key))"
            )
        }
    }

    func testEveryCategoryIdentifierResolvesToARealType() {
        for metric in HealthCatalog.metrics where metric.isCategory {
            XCTAssertNotNil(
                HKObjectType.categoryType(
                    forIdentifier: HKCategoryTypeIdentifier(rawValue: metric.identifier)
                ),
                "identificatore sconosciuto: \(metric.identifier) (\(metric.key))"
            )
        }
    }

    func testEveryUnitIsCompatibleWithItsType() {
        for metric in HealthCatalog.metrics where !metric.isCategory {
            guard
                let type = HKObjectType.quantityType(
                    forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.identifier)
                )
            else { continue }
            let unit = HKUnit(from: metric.unit)
            XCTAssertTrue(
                type.is(compatibleWith: unit),
                "\(metric.key): l'unità \"\(metric.unit)\" non vale per \(metric.identifier)"
            )
        }
    }

    func testAggregationMatchesHealthKit() {
        for metric in HealthCatalog.metrics where !metric.isCategory {
            guard
                let type = HKObjectType.quantityType(
                    forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.identifier)
                )
            else { continue }
            let expected: MetricAggregation =
                type.aggregationStyle == .cumulative ? .cumulative : .discrete
            XCTAssertEqual(
                metric.aggregation, expected,
                "\(metric.key) è dichiarata \(metric.aggregation.rawValue) ma HealthKit la tratta come \(expected.rawValue)"
            )
        }
    }
}
