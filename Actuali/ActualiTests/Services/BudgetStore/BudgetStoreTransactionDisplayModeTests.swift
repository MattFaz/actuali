import Foundation
import Testing
@testable import Actuali

/// The transaction list's flat/grouped switch defaults to flat and writes
/// through to UserDefaults, like the other display settings.
///
/// The restore-on-launch half isn't covered here: `previewInstance()` is built
/// by an init that skips every UserDefaults read, and the real init does file
/// system work no unit test should trigger. Same gap as the other display
/// settings suites.
@MainActor
struct BudgetStoreTransactionDisplayModeTests {

    @Test func listsAreFlatByDefault() {
        #expect(BudgetStore.previewInstance().transactionDisplayMode == .flat)
    }

    @Test func togglePersistsToUserDefaults() {
        let store = BudgetStore.previewInstance()
        store.transactionDisplayMode = .groupedByDate
        #expect(UserDefaults.standard.string(forKey: TransactionDisplayMode.defaultsKey)
            == TransactionDisplayMode.groupedByDate.rawValue)
        store.transactionDisplayMode = .flat
        #expect(UserDefaults.standard.string(forKey: TransactionDisplayMode.defaultsKey)
            == TransactionDisplayMode.flat.rawValue)
    }
}
