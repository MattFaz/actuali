import Foundation
import SwiftUI
import UIKit
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreCategoryStatusDotsTests {

    @Test func categoryStatusDotsShowByDefault() {
        #expect(BudgetStore.previewInstance().showCategoryStatusDots)
    }

    @Test func customColorPersistsAndLoadsFromUserDefaults() {
        let key = "categoryStatusDotColors"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let store = BudgetStore.previewInstance()
        let selectedColor = Color(red: 1, green: 0.25, blue: 0.5)
        store.setCategoryStatusDotColor(selectedColor, for: .overspent)

        let colors = UserDefaults.standard.dictionary(forKey: key) as? [String: Data]
        #expect(colors?["overspent"] != nil)

        let reloadedStore = BudgetStore.previewInstance()
        let restoredColor = reloadedStore.categoryStatusDotColor(for: .overspent)

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(UIColor(restoredColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        #expect(abs(Double(red) - 1.0) < 0.01)
        #expect(abs(Double(green) - 0.25) < 0.01)
        #expect(abs(Double(blue) - 0.5) < 0.01)
        #expect(abs(Double(alpha) - 1.0) < 0.01)
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
