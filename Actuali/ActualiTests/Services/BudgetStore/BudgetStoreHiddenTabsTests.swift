import Foundation
import Testing
@testable import Actuali

/// Hiding Add or Reports from the tab bar persists, and a hidden page can't
/// stay the start page.
@MainActor
@Suite(.serialized)
struct BudgetStoreHiddenTabsTests {
    private let keys = [StartTab.hiddenDefaultsKey, StartTab.defaultsKey]

    private func withSavedDefaults(_ body: () -> Void) {
        let saved = keys.map(UserDefaults.standard.object(forKey:))
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
        defer {
            for (key, value) in zip(keys, saved) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        body()
    }

    @Test func nothingIsHiddenByDefault() {
        withSavedDefaults {
            #expect(BudgetStore.previewInstance().hiddenTabs.isEmpty)
            #expect(StartTab.persistedHidden.isEmpty)
        }
    }

    @Test func hiddenTabsPersistToUserDefaults() {
        withSavedDefaults {
            let store = BudgetStore.previewInstance()
            store.hiddenTabs = [.reports]
            #expect(StartTab.persistedHidden == [.reports])

            store.hiddenTabs = [.addTransaction, .reports]
            #expect(StartTab.persistedHidden == [.addTransaction, .reports])

            store.hiddenTabs = []
            #expect(StartTab.persistedHidden.isEmpty)
        }
    }

    @Test func hidingTheStartPageResetsItToAccounts() {
        withSavedDefaults {
            let store = BudgetStore.previewInstance()
            store.startTab = .reports
            store.hiddenTabs = [.reports]
            #expect(store.startTab == .accounts)
            #expect(StartTab.persisted == .accounts)
        }
    }

    @Test func hidingAnotherTabKeepsTheStartPage() {
        withSavedDefaults {
            let store = BudgetStore.previewInstance()
            store.startTab = .reports
            store.hiddenTabs = [.addTransaction]
            #expect(store.startTab == .reports)
            #expect(StartTab.persisted == .reports)
        }
    }

    /// Launch and Cancel in the add flow read this, not the raw start page.
    @Test func persistedStartPageFallsBackWhenItsTabIsHidden() {
        withSavedDefaults {
            UserDefaults.standard.set(StartTab.reports.rawValue, forKey: StartTab.defaultsKey)
            #expect(StartTab.persistedEffective == .reports)

            UserDefaults.standard.set([StartTab.reports.rawValue], forKey: StartTab.hiddenDefaultsKey)
            #expect(StartTab.persistedEffective == .accounts)
        }
    }
}
