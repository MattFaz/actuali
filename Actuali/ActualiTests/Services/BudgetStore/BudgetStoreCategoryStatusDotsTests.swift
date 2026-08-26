import Foundation
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreCategoryStatusDotsTests {

    @Test func categoryStatusDotsShowByDefault() {
        #expect(BudgetStore.previewInstance().showCategoryStatusDots)
    }

    @Test func togglePersistsToUserDefaults() {
        let key = "showCategoryStatusDots"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let store = BudgetStore.previewInstance()
        store.showCategoryStatusDots = false
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == false)
        store.showCategoryStatusDots = true
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == true)
    }
}
