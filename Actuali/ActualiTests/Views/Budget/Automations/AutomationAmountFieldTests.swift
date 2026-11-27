import Testing
@testable import Actuali

/// The automation amount moved from a SwiftUI number field to the shared
/// amount keypad, which edits text; these cover the number <-> text bridge.
struct AutomationAmountFieldTests {
    @Test func storedAmountSeedsTheFieldAsItsBindingReadsIt() {
        #expect(AutomationAmountField.text(for: 12.5, conventionalAmountEntry: false) == "12.50")
        #expect(AutomationAmountField.text(for: 12, conventionalAmountEntry: true) == "12")
        #expect(AutomationAmountField.text(for: 12.5, conventionalAmountEntry: true) == "12.50")
    }

    /// No amount and zero both leave the field empty under its placeholder,
    /// so clearing it doesn't bounce back as a typed "0.00".
    @Test func missingOrZeroAmountShowsAnEmptyField() {
        #expect(AutomationAmountField.text(for: nil, conventionalAmountEntry: false) == "")
        #expect(AutomationAmountField.text(for: 0, conventionalAmountEntry: false) == "")
    }

    @Test func fieldTextBecomesTheTemplateAmount() {
        #expect(AutomationAmountField.amount(for: "18.50") == 18.5)
        #expect(AutomationAmountField.amount(for: "") == nil)
    }

    /// Opening the editor seeds "12.35" for a stored 12.345; that echo must
    /// not round the template, but a real edit still lands.
    @Test func seededTextKeepsTheStoredAmount() {
        #expect(AutomationAmountField.amount(for: "12.35", current: 12.345, conventionalAmountEntry: false) == 12.345)
        #expect(AutomationAmountField.amount(for: "12.36", current: 12.345, conventionalAmountEntry: false) == 12.36)
        #expect(AutomationAmountField.amount(for: "", current: 12.345, conventionalAmountEntry: false) == nil)
        #expect(AutomationAmountField.amount(for: "0.00", current: nil, conventionalAmountEntry: false) == 0)
    }
}
