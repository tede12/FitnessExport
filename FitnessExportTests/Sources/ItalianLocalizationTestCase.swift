import FitnessUI
import Foundation
import XCTest

class ItalianLocalizationTestCase: XCTestCase {
    private var previousLanguage: Any?

    override func setUp() {
        super.setUp()
        previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set("it", forKey: AppLanguage.preferenceKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
        super.tearDown()
    }
}
