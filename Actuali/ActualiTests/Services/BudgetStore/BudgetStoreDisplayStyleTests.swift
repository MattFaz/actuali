import Foundation
import Testing
@testable import Actuali

/// The Budget tab's layout preference must default to Clean, restore List,
/// and keep List-only options independent from shared Budget preferences.
@MainActor
@Suite(.serialized)
struct BudgetStoreDisplayStyleTests {
    private let styleKey = "budgetDisplayStyle"
    private let listOptionKeys = [
        "showListBudgetOverview",
        "showListSpentColumn",
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

    @Test func persistedStyleRestoresListAndFallsBackToClean() throws {
        let suiteName = "BudgetStoreDisplayStyleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(BudgetDisplayStyle.persisted(in: defaults) == .clean)

        defaults.set("list", forKey: styleKey)
        #expect(BudgetDisplayStyle.persisted(in: defaults) == .list)

        defaults.set("table-3000", forKey: styleKey)
        #expect(BudgetDisplayStyle.persisted(in: defaults) == .clean)
    }

    @Test func selectionPersistsToUserDefaults() {
        withSavedDefaults(for: [styleKey]) {
            let store = BudgetStore.previewInstance()
            store.budgetDisplayStyle = .detailed
            #expect(UserDefaults.standard.string(forKey: styleKey) == "detailed")
            store.budgetDisplayStyle = .list
            #expect(UserDefaults.standard.string(forKey: styleKey) == "list")
            store.budgetDisplayStyle = .clean
            #expect(UserDefaults.standard.string(forKey: styleKey) == "clean")
        }
    }

    @Test func listOptionsAndSharedProgressPreferencePersist() {
        let existingStyleKeys = [
            "showBudgetProgressBars",
            "showGroupTotals",
            "hideZeroBudgetCategories",
        ]
        withSavedDefaults(for: listOptionKeys + existingStyleKeys) {
            UserDefaults.standard.set(true, forKey: "showGroupTotals")
            UserDefaults.standard.set(true, forKey: "hideZeroBudgetCategories")

            let store = BudgetStore.previewInstance()
            #expect(store.showListBudgetOverview)
            #expect(!store.showListSpentColumn)
            #expect(store.showBudgetProgressBars)

            store.showListBudgetOverview = false
            store.showListSpentColumn = true
            store.showBudgetProgressBars = false

            #expect(UserDefaults.standard.object(forKey: listOptionKeys[0]) as? Bool == false)
            #expect(UserDefaults.standard.object(forKey: listOptionKeys[1]) as? Bool == true)
            #expect(UserDefaults.standard.object(forKey: existingStyleKeys[0]) as? Bool == false)
            #expect(UserDefaults.standard.object(forKey: existingStyleKeys[1]) as? Bool == true)
            #expect(UserDefaults.standard.object(forKey: existingStyleKeys[2]) as? Bool == true)

            store.showListBudgetOverview = true
            store.showListSpentColumn = false
            store.showBudgetProgressBars = true

            #expect(UserDefaults.standard.object(forKey: listOptionKeys[0]) as? Bool == true)
            #expect(UserDefaults.standard.object(forKey: listOptionKeys[1]) as? Bool == false)
            #expect(UserDefaults.standard.object(forKey: existingStyleKeys[0]) as? Bool == true)
        }
    }

    @Test func listOptionsRestoreDefaultAndPersistedValues() throws {
        let suiteName = "BudgetStoreListPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ListBudgetViewPreferences.persisted(in: defaults) == .defaults)

        defaults.set(false, forKey: listOptionKeys[0])
        defaults.set(true, forKey: listOptionKeys[1])

        #expect(ListBudgetViewPreferences.persisted(in: defaults) == ListBudgetViewPreferences(
            showOverview: false,
            showSpentColumn: true
        ))
    }

    @Test func listOptionsAcceptStringBooleansFromLaunchArguments() throws {
        let suiteName = "BudgetStoreListArgumentPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("NO", forKey: listOptionKeys[0])
        defaults.set("YES", forKey: listOptionKeys[1])

        #expect(ListBudgetViewPreferences.persisted(in: defaults) == ListBudgetViewPreferences(
            showOverview: false,
            showSpentColumn: true
        ))
    }

    /// Raw values round-trip, and unknown raw values (from a future build)
    /// decode to nil so init falls back to the default rather than crashing.
    @Test func rawValueRoundTrip() {
        #expect(BudgetDisplayStyle.list.rawValue == "list")
        for style in BudgetDisplayStyle.allCases {
            #expect(BudgetDisplayStyle(rawValue: style.rawValue) == style)
        }
        #expect(BudgetDisplayStyle(rawValue: "table-3000") == nil)
    }
}
