import FitnessUI
import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    func testMacUsesBothFrameworkLocalizations() {
        let previous = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: AppLanguage.preferenceKey) }
        UserDefaults.standard.set("it", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.text("Impostazioni"), "Impostazioni")
        XCTAssertEqual(AppLanguage.count("selected.count", 2), "2 attività selezionate")
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.text("Impostazioni"), "Settings")
        XCTAssertEqual(AppLanguage.count("selected.count", 2), "2 selected activities")
    }
}
