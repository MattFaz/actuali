import Foundation
import Testing
@testable import Actuali

/// The Budget tab's layout preference must default to Clean, restore YNAB,
/// and keep YNAB-only options independent from shared Budget preferences.
@MainActor
@Suite(.serialized)
struct BudgetStoreDisplayStyleTests {
    private let styleKey = "budgetDisplayStyle"
    private let ynabOptionKeys = [
        "showYNABBudgetOverview",
        "showYNABSpentColumn",
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

    @Test func persistedStyleRestoresYNABAndFallsBackToClean() throws {
        let suiteName = "BudgetStoreDisplayStyleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(BudgetDisplayStyle.persisted(in: defaults) == .clean)

        defaults.set("ynab", forKey: styleKey)
        #expect(BudgetDisplayStyle.persisted(in: defaults) == .ynab)

        defaults.set("table-3000", forKey: styleKey)
        #expect(BudgetDisplayStyle.persisted(in: defaults) == .clean)
    }

    @Test func selectionPersistsToUserDefaults() {
        withSavedDefaults(for: [styleKey]) {
            let store = BudgetStore.previewInstance()
            store.budgetDisplayStyle = .detailed
            #expect(UserDefaults.standard.string(forKey: styleKey) == "detailed")
            store.budgetDisplayStyle = .ynab
            #expect(UserDefaults.standard.string(forKey: styleKey) == "ynab")
            store.budgetDisplayStyle = .clean
            #expect(UserDefaults.standard.string(forKey: styleKey) == "clean")
        }
    }

    @Test func ynabOptionsAndSharedProgressPreferencePersist() {
        let existingStyleKeys = [
            "showBudgetProgressBars",
            "showGroupTotals",
            "hideZeroBudgetCategories",
        ]
        withSavedDefaults(for: ynabOptionKeys + existingStyleKeys) {
            UserDefaults.standard.set(true, forKey: "showGroupTotals")
            UserDefaults.standard.set(true, forKey: "hideZeroBudgetCategories")

            let store = BudgetStore.previewInstance()
            #expect(store.showYNABBudgetOverview)
            #expect(!store.showYNABSpentColumn)
            #expect(store.showBudgetProgressBars)

            store.showYNABBudgetOverview = false
            store.showYNABSpentColumn = true
            store.showBudgetProgressBars = false

            #expect(UserDefaults.standard.object(forKey: ynabOptionKeys[0]) as? Bool == false)
            #expect(UserDefaults.standard.object(forKey: ynabOptionKeys[1]) as? Bool == true)
            #expect(UserDefaults.standard.object(forKey: existingStyleKeys[0]) as? Bool == false)
            #expect(UserDefaults.standard.object(forKey: existingStyleKeys[1]) as? Bool == true)
            #expect(UserDefaults.standard.object(forKey: existingStyleKeys[2]) as? Bool == true)

            store.showYNABBudgetOverview = true
            store.showYNABSpentColumn = false
            store.showBudgetProgressBars = true

            #expect(UserDefaults.standard.object(forKey: ynabOptionKeys[0]) as? Bool == true)
            #expect(UserDefaults.standard.object(forKey: ynabOptionKeys[1]) as? Bool == false)
            #expect(UserDefaults.standard.object(forKey: existingStyleKeys[0]) as? Bool == true)
        }
    }

    @Test func ynabOptionsRestoreDefaultAndPersistedValues() throws {
        let suiteName = "BudgetStoreYNABPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(YNABBudgetViewPreferences.persisted(in: defaults) == .defaults)

        defaults.set(false, forKey: ynabOptionKeys[0])
        defaults.set(true, forKey: ynabOptionKeys[1])

        #expect(YNABBudgetViewPreferences.persisted(in: defaults) == YNABBudgetViewPreferences(
            showOverview: false,
            showSpentColumn: true
        ))
    }

    @Test func ynabOptionsAcceptStringBooleansFromLaunchArguments() throws {
        let suiteName = "BudgetStoreYNABArgumentPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("NO", forKey: ynabOptionKeys[0])
        defaults.set("YES", forKey: ynabOptionKeys[1])

        #expect(YNABBudgetViewPreferences.persisted(in: defaults) == YNABBudgetViewPreferences(
            showOverview: false,
            showSpentColumn: true
        ))
    }

    /// Raw values round-trip, and unknown raw values (from a future build)
    /// decode to nil so init falls back to the default rather than crashing.
    @Test func rawValueRoundTrip() {
        #expect(BudgetDisplayStyle.ynab.rawValue == "ynab")
        for style in BudgetDisplayStyle.allCases {
            #expect(BudgetDisplayStyle(rawValue: style.rawValue) == style)
        }
        #expect(BudgetDisplayStyle(rawValue: "table-3000") == nil)
    }
}
