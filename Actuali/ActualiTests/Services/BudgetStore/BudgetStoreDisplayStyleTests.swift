import Foundation
import Testing
@testable import Actuali

/// The Budget tab's layout preference must default to Clean, restore Compact,
/// and keep Compact-only options independent from shared Budget preferences.
@MainActor
@Suite(.serialized)
struct BudgetStoreDisplayStyleTests {
    private let styleKey = "budgetDisplayStyle"
    private let compactOptionKeys = [
        "showCompactBudgetOverview",
        "showCompactSpentColumn",
    ]

    private func withSavedDefaults(for keys: [String], _ body: () -> Void) {
        let savedValues = keys.reduce(into: [String: Any]()) { savedValues, key in
            savedValues[key] = UserDefaults.standard.object(forKey: key)
        }
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
        defer {
            for key in keys {
                if let savedValue = savedValues[key] {
                    UserDefaults.standard.set(savedValue, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        body()
    }

    @Test func selectionPersistsToUserDefaults() {
        withSavedDefaults(for: [styleKey]) {
            let store = BudgetStore.previewInstance()
            store.budgetDisplayStyle = .detailed
            #expect(UserDefaults.standard.string(forKey: styleKey) == "detailed")
            store.budgetDisplayStyle = .compact
            #expect(UserDefaults.standard.string(forKey: styleKey) == "compact")
            store.budgetDisplayStyle = .clean
            #expect(UserDefaults.standard.string(forKey: styleKey) == "clean")
        }
    }

    @Test func compactOptionsAndSharedProgressPreferencePersist() {
        let existingStyleKeys = [
            "showBudgetProgressBars",
            "showGroupTotals",
            "hideZeroBudgetCategories",
        ]
        withSavedDefaults(for: compactOptionKeys + existingStyleKeys) {
            UserDefaults.standard.set(true, forKey: "showGroupTotals")
            UserDefaults.standard.set(true, forKey: "hideZeroBudgetCategories")

            let store = BudgetStore.previewInstance()
            #expect(store.showCompactBudgetOverview)
            #expect(!store.showCompactSpentColumn)
            #expect(store.showBudgetProgressBars)

            store.showCompactBudgetOverview = false
            store.showCompactSpentColumn = true
            store.showBudgetProgressBars = false

            #expect(UserDefaults.standard.object(forKey: compactOptionKeys[0]) as? Bool == false)
            #expect(UserDefaults.standard.object(forKey: compactOptionKeys[1]) as? Bool == true)
            #expect(UserDefaults.standard.object(forKey: existingStyleKeys[0]) as? Bool == false)
            #expect(UserDefaults.standard.object(forKey: existingStyleKeys[1]) as? Bool == true)
            #expect(UserDefaults.standard.object(forKey: existingStyleKeys[2]) as? Bool == true)

            store.showCompactBudgetOverview = true
            store.showCompactSpentColumn = false
            store.showBudgetProgressBars = true

            #expect(UserDefaults.standard.object(forKey: compactOptionKeys[0]) as? Bool == true)
            #expect(UserDefaults.standard.object(forKey: compactOptionKeys[1]) as? Bool == false)
            #expect(UserDefaults.standard.object(forKey: existingStyleKeys[0]) as? Bool == true)
        }
    }

    /// Raw values round-trip, and unknown raw values (from a future build)
    /// decode to nil so init falls back to the default rather than crashing.
    @Test func rawValueRoundTrip() {
        #expect(BudgetDisplayStyle.compact.rawValue == "compact")
        for style in BudgetDisplayStyle.allCases {
            #expect(BudgetDisplayStyle(rawValue: style.rawValue) == style)
        }
        #expect(BudgetDisplayStyle(rawValue: "table-3000") == nil)
    }
}
