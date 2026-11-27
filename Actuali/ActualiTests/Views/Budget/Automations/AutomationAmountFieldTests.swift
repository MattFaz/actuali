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
}
