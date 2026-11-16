import FitnessUI
import Foundation
import XCTest

@testable import FitnessExport

final class AppLanguageTests: XCTestCase {
    func testExplicitLanguagesPersistAndUseFrameworkCatalog() {
        let previous = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: AppLanguage.preferenceKey) }
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.code, "en")
        XCTAssertEqual(AppLanguage.text("Corsa"), "Running")
        XCTAssertEqual(AppLanguage.count("selected.count", 1), "1 selected activity")
        XCTAssertEqual(AppLanguage.count("selected.count", 2), "2 selected activities")
        XCTAssertEqual(AppLanguage.format("Connesso come %@", "Example"), "Connected as Example")
        XCTAssertEqual(AppLanguage.format("Versione %@ (%@)", "1.0", UInt16(5)), "Version 1.0 (5)")
        XCTAssertEqual(1.5.formatted(.number.locale(AppLanguage.locale)), "1.5")
        XCTAssertEqual(WorkoutFormatting.distance(1500), "1.50 km")
        XCTAssertEqual(WorkoutFormatting.distance(397000), "397.0 km")
        UserDefaults.standard.set("it", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppLanguage.preferenceKey), "it")
        XCTAssertEqual(AppLanguage.text("Corsa"), "Corsa")
        XCTAssertEqual(AppLanguage.count("selected.count", 1), "1 attività selezionata")
        XCTAssertEqual(AppLanguage.count("selected.count", 2), "2 attività selezionate")
        XCTAssertEqual(AppLanguage.format("Connesso come %@", "Example"), "Connesso come Example")
        XCTAssertEqual(AppLanguage.format("Versione %@ (%@)", "1.0", UInt16(5)), "Versione 1.0 (5)")
        XCTAssertEqual(1.5.formatted(.number.locale(AppLanguage.locale)), "1,5")
        XCTAssertEqual(WorkoutFormatting.distance(1500), "1,50 km")
        XCTAssertEqual(WorkoutFormatting.distance(397000), "397,0 km")
    }

    func testUnsupportedPreferenceUsesSupportedSystemDefault() {
        let previous = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: AppLanguage.preferenceKey) }
        UserDefaults.standard.set("unsupported", forKey: AppLanguage.preferenceKey)
        XCTAssertTrue(["en", "it"].contains(AppLanguage.code))
    }
}
