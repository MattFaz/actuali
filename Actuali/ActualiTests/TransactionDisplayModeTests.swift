import Foundation
import Testing
@testable import Actuali

struct TransactionDisplayModeTests {

    @Test func defaultPersistedIsFlat() {
        UserDefaults.standard.removeObject(forKey: TransactionDisplayMode.defaultsKey)
        #expect(TransactionDisplayMode.persisted == .flat)
    }

    @Test func resolvesFromRawString() {
        #expect(TransactionDisplayMode.resolved(from: "flat") == .flat)
        #expect(TransactionDisplayMode.resolved(from: "groupedByDate") == .groupedByDate)
        #expect(TransactionDisplayMode.resolved(from: "unknown") == .flat)
        #expect(TransactionDisplayMode.resolved(from: nil) == .flat)
    }

    @Test func labelsAreDescriptive() {
        #expect(TransactionDisplayMode.flat.label == "Flat List")
        #expect(TransactionDisplayMode.groupedByDate.label == "Grouped by Date")
    }

    @Test func persistedReadsSavedValue() {
        UserDefaults.standard.set(TransactionDisplayMode.groupedByDate.rawValue, forKey: TransactionDisplayMode.defaultsKey)
        #expect(TransactionDisplayMode.persisted == .groupedByDate)
        UserDefaults.standard.removeObject(forKey: TransactionDisplayMode.defaultsKey)
    }
}
