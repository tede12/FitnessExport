import FitnessUI
import Foundation
import XCTest

@testable import FitnessExport

final class LibrarySearchTests: ItalianLocalizationTestCase {
    private func item(activity: WorkoutActivityType = .running, km: Double = 10) -> WorkoutListItem {
        let date = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 3, day: 12, hour: 7, minute: 15))!
        return WorkoutListItem(
            id: UUID(), activityType: activity, startDate: date, endDate: date.addingTimeInterval(3_000),
            duration: 3_000, distanceInMeters: km * 1_000, activeEnergyKilocalories: nil, hasHeartRateData: true,
            hasCadenceData: true)
    }

    func testSearchIgnoresCaseAndAccents() {
        XCTAssertTrue(LibraryViewModel.matches(item(), query: "CORSA"))
        XCTAssertTrue(LibraryViewModel.matches(item(activity: .hiking), query: "escursione"))
        XCTAssertTrue(LibraryViewModel.matches(item(), query: "12 mar"))
        XCTAssertTrue(LibraryViewModel.matches(item(), query: "10 km"))
    }

    func testSearchRequiresEveryTerm() {
        XCTAssertTrue(LibraryViewModel.matches(item(), query: "corsa 10"))
        XCTAssertFalse(LibraryViewModel.matches(item(), query: "corsa 21"))
        XCTAssertFalse(LibraryViewModel.matches(item(activity: .walking), query: "corsa"))
    }

    func testSearchSurvivesLanguageChangeAndAcceptsBothDecimalSeparators() {
        let workout = item(km: 10.5)
        let index = LibraryViewModel.searchHaystack(for: workout)
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        for query in ["running 10.50", "corsa 10,50", "march", "marzo"] {
            XCTAssertTrue(LibraryViewModel.matches(haystack: index, terms: LibraryViewModel.searchTerms(query)))
        }
    }

    func testPrebuiltHaystackMatchesLiveSearch() {
        let workout = item()
        let haystack = LibraryViewModel.searchHaystack(for: workout)
        XCTAssertEqual(
            LibraryViewModel.matches(haystack: haystack, terms: LibraryViewModel.searchTerms("Corsa 12 Mar")),
            LibraryViewModel.matches(workout, query: "Corsa 12 Mar")
        )
    }
}
