import Foundation
import Testing
@testable import Actuali

/// Only `resolved(from:)` is exercised here, like `StartTabTests`. Asserting on
/// `persisted` would mean writing the real `UserDefaults.standard` key, and
/// Swift Testing runs a suite's tests in parallel — two tests sharing one key
/// race each other.
struct TransactionDisplayModeTests {

    @Test func resolvesDefaultWhenUnset() {
        #expect(TransactionDisplayMode.resolved(from: nil) == .flat)
    }

    @Test func resolvesDefaultForUnknownValue() {
        #expect(TransactionDisplayMode.resolved(from: "grouped") == .flat)
        #expect(TransactionDisplayMode.resolved(from: "") == .flat)
    }

    @Test func resolvesPersistedRawValues() {
        for mode in TransactionDisplayMode.allCases {
            #expect(TransactionDisplayMode.resolved(from: mode.rawValue) == mode)
        }
    }

    @Test func labelsAreDescriptive() {
        let locale = Locale(identifier: "en_US")
        let bundle = Bundle(identifier: "com.mfazz.ActualiOS")!
        #expect(TransactionDisplayMode.flat.label(locale: locale, bundle: bundle) == "Flat List")
        #expect(TransactionDisplayMode.groupedByDate.label(locale: locale, bundle: bundle) == "Grouped by Date")
    }
}
