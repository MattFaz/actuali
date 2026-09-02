import Testing
import SwiftUI
import UIKit
@testable import Actuali

/// Drives AmountInputField's UITextFieldDelegate coordinator directly,
/// simulating keystrokes the way UIKit delivers them.
@MainActor
struct AmountInputFieldTests {

    final class TextBox {
        var value: String
        init(_ value: String = "") { self.value = value }
    }

    /// Builds a coordinator wired to a real UITextField, mirroring makeUIView.
    private func makeField(
        initial: String = "",
        allowsNegative: Bool = false,
        conventionalAmountEntry: Bool = false
    ) -> (coordinator: AmountInputField.Coordinator, textField: UITextField, box: TextBox) {
        let box = TextBox(initial)
        let field = AmountInputField(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            conventionalAmountEntry: conventionalAmountEntry,
            allowsNegative: allowsNegative
        )
        let coordinator = field.makeCoordinator()
        let textField = UITextField()
        textField.text = initial
        coordinator.textField = textField
        coordinator.sync(fromDisplay: initial)
        return (coordinator, textField, box)
    }

    private func type(
        _ string: String,
        into coordinator: AmountInputField.Coordinator,
        _ textField: UITextField
    ) {
        for character in string {
            let end = (textField.text as NSString?)?.length ?? 0
            _ = coordinator.textField(
                textField,
                shouldChangeCharactersIn: NSRange(location: end, length: 0),
                replacementString: String(character)
            )
        }
    }

    private func backspace(
        _ coordinator: AmountInputField.Coordinator,
        _ textField: UITextField
    ) {
        let length = (textField.text as NSString?)?.length ?? 0
        _ = coordinator.textField(
            textField,
            shouldChangeCharactersIn: NSRange(location: max(0, length - 1), length: min(1, length)),
            replacementString: ""
        )
    }

    @Test func calculatorModeShiftsDigitsIntoCents() {
        let (coordinator, textField, box) = makeField()
        type("120", into: coordinator, textField)
        #expect(textField.text == "1.20")
        #expect(box.value == "1.20")
    }

    // MARK: - Conventional entry

    @Test func conventionalModeEntersWholeDigitsWithoutShiftingCents() {
        let (coordinator, textField, box) = makeField(conventionalAmountEntry: true)
        type("12", into: coordinator, textField)
        #expect(textField.text == "12")
        #expect(box.value == "12")
    }

    @Test func pastingGroupedDecimalPreservesTheWholeAmount() {
        let (coordinator, textField, box) = makeField()
        _ = coordinator.textField(
            textField,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "450,046.23"
        )

        #expect(textField.text == "450046.23")
        #expect(box.value == "450046.23")
    }

    @Test func pastingAnOversizedNumberFallsBackInsteadOfCrashing() {
        let (coordinator, textField, box) = makeField()
        _ = coordinator.textField(
            textField,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "1,000,000,000,000,000,000,000"
        )

        #expect(Double(box.value) != nil)
    }

    @Test func pastingGroupedDecimalInConventionalModeKeepsSignAndCents() {
        let (coordinator, textField, box) = makeField(
            allowsNegative: true, conventionalAmountEntry: true
        )
        _ = coordinator.textField(
            textField,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "-450,046.23"
        )

        #expect(box.value == "-450046.23")
    }

    @Test func conventionalModeKeepsExplicitDecimalEntry() {
        let (coordinator, textField, box) = makeField(conventionalAmountEntry: true)
        type("12.05", into: coordinator, textField)
        #expect(textField.text == "12.05")
        #expect(box.value == "12.05")
    }

    @Test func conventionalModeLimitsFractionToTwoDigits() {
        let (coordinator, textField, box) = makeField(conventionalAmountEntry: true)
        type("12.056", into: coordinator, textField)
        #expect(textField.text == "12.05")
        #expect(box.value == "12.05")
    }

    @Test func conventionalModeBackspaceWorksThroughDecimalAndDigits() {
        let (coordinator, textField, box) = makeField(conventionalAmountEntry: true)
        type("12.05", into: coordinator, textField)
        backspace(coordinator, textField)
        #expect(box.value == "12.0")
        backspace(coordinator, textField)
        #expect(box.value == "12.")
        backspace(coordinator, textField)
        #expect(box.value == "12")
        backspace(coordinator, textField)
        #expect(box.value == "1")
    }

    @Test func conventionalModeKeepsEmptyFieldEmpty() {
        let (coordinator, textField, box) = makeField(conventionalAmountEntry: true)
        backspace(coordinator, textField)
        #expect(textField.text == "")
        #expect(box.value == "")
    }

    @Test func conventionalModeEditsPrefilledAmount() {
        let (coordinator, textField, box) = makeField(
            initial: "12.5", conventionalAmountEntry: true
        )
        type("0", into: coordinator, textField)
        #expect(textField.text == "12.50")
        #expect(box.value == "12.50")
    }

    @Test func conventionalModeSupportsNegativeAmounts() {
        let (coordinator, textField, box) = makeField(
            allowsNegative: true, conventionalAmountEntry: true
        )
        coordinator.toggleSign()
        type("12.05", into: coordinator, textField)
        #expect(textField.text == "-12.05")
        #expect(box.value == "-12.05")
    }

    @Test func conventionalModeAdditionEvaluatesWhenEditingEnds() {
        let (coordinator, textField, box) = makeField(conventionalAmountEntry: true)
        type("12", into: coordinator, textField)
        coordinator.addTapped()
        type("6", into: coordinator, textField)
        coordinator.textFieldDidEndEditing(textField)
        #expect(box.value == "18")
    }

    @Test func conventionalModeSubtractionEvaluatesWhenEditingEnds() {
        let (coordinator, textField, box) = makeField(conventionalAmountEntry: true)
        type("12", into: coordinator, textField)
        coordinator.subtractTapped()
        type("6", into: coordinator, textField)
        coordinator.textFieldDidEndEditing(textField)
        #expect(box.value == "6")
    }

    @Test func conventionalModeMultiplicationEvaluatesWhenEditingEnds() {
        let (coordinator, textField, box) = makeField(conventionalAmountEntry: true)
        type("12", into: coordinator, textField)
        coordinator.multiplyTapped()
        type("6", into: coordinator, textField)
        coordinator.textFieldDidEndEditing(textField)
        #expect(box.value == "72")
    }

    @Test func conventionalModeDivisionEvaluatesWhenEditingEnds() {
        let (coordinator, textField, box) = makeField(conventionalAmountEntry: true)
        type("12", into: coordinator, textField)
        coordinator.divideTapped()
        type("6", into: coordinator, textField)
        coordinator.textFieldDidEndEditing(textField)
        #expect(box.value == "2")
    }

    @Test func conventionalModeEvaluatesLeftToRight() {
        let (coordinator, textField, box) = makeField(conventionalAmountEntry: true)
        type("2", into: coordinator, textField)
        coordinator.addTapped()
        type("3", into: coordinator, textField)
        coordinator.multiplyTapped()
        type("4", into: coordinator, textField)
        coordinator.textFieldDidEndEditing(textField)
        #expect(box.value == "20")
    }

    @Test func conventionalModeBindingStaysValidDuringExpression() {
        let (coordinator, textField, box) = makeField(conventionalAmountEntry: true)
        type("12", into: coordinator, textField)
        coordinator.addTapped()
        type("6", into: coordinator, textField)
        #expect(textField.text == "12 + 6")
        #expect(box.value == "18")
        #expect(Double(box.value) == 18)
    }

    /// A fractional result still carries its cents — the whole-number display
    /// is about not inventing a fraction, not about dropping one.
    @Test func conventionalModeKeepsCentsOnFractionalResult() {
        let (coordinator, textField, box) = makeField(conventionalAmountEntry: true)
        type("5", into: coordinator, textField)
        coordinator.divideTapped()
        type("2", into: coordinator, textField)
        coordinator.textFieldDidEndEditing(textField)
        #expect(textField.text == "2.50")
        #expect(box.value == "2.50")
    }

    /// A prefilled whole amount must survive the round trip through
    /// `sync(fromDisplay:)` — the field is handed "%.2f" strings by callers.
    @Test func conventionalModeEditsPrefilledWholeAmount() {
        let (coordinator, textField, box) = makeField(
            initial: "324", conventionalAmountEntry: true
        )
        type("5", into: coordinator, textField)
        #expect(textField.text == "3245")
        #expect(box.value == "3245")
    }

    @Test func toggleSignNegatesAndRestores() {
        let (coordinator, textField, box) = makeField(allowsNegative: true)
        type("5", into: coordinator, textField)
        #expect(box.value == "0.05")
        coordinator.toggleSign()
        #expect(textField.text == "-0.05")
        #expect(box.value == "-0.05")
        coordinator.toggleSign()
        #expect(box.value == "0.05")
    }

    @Test func toggleSignBeforeTypingCarriesIntoAmount() {
        let (coordinator, textField, box) = makeField(allowsNegative: true)
        coordinator.toggleSign()
        #expect(textField.text == "-")
        type("250", into: coordinator, textField)
        #expect(box.value == "-2.50")
    }

    @Test func prefilledNegativeAmountKeepsSignWhenEdited() {
        // Reconcile prefills e.g. a credit card's cleared balance.
        let (coordinator, textField, box) = makeField(initial: "-123.4", allowsNegative: true)
        type("5", into: coordinator, textField)
        #expect(box.value == "-123.45")
    }

    @Test func fullReplaceResetsSign() {
        // Tapping the field selects all; the next digit replaces everything.
        let (coordinator, textField, box) = makeField(initial: "-123.45", allowsNegative: true)
        _ = coordinator.textField(
            textField,
            shouldChangeCharactersIn: NSRange(location: 0, length: 7),
            replacementString: "9"
        )
        #expect(box.value == "0.09")
    }

    @Test func backspaceClearsBareSign() {
        let (coordinator, textField, box) = makeField(allowsNegative: true)
        coordinator.toggleSign()
        #expect(textField.text == "-")
        backspace(coordinator, textField)
        #expect(textField.text == "")
        type("7", into: coordinator, textField)
        #expect(box.value == "0.07")
    }

    @Test func hardwareKeyboardMinusTogglesSign() {
        let (coordinator, textField, box) = makeField(allowsNegative: true)
        type("120-", into: coordinator, textField)
        #expect(box.value == "-1.20")
    }

    // MARK: - Toolbar arithmetic

    @Test func additionEvaluatesWhenEditingEnds() {
        let (coordinator, textField, box) = makeField()
        type("1250", into: coordinator, textField)
        coordinator.addTapped()
        type("600", into: coordinator, textField)
        #expect(textField.text == "12.50 + 6.00")
        coordinator.textFieldDidEndEditing(textField)
        #expect(textField.text == "18.50")
        #expect(box.value == "18.50")
    }

    /// The Save button is an ordinary form row, so it never ends editing —
    /// the binding has to be parseable while the expression is still visible.
    @Test func bindingHoldsEvaluatedValueMidExpression() {
        let (coordinator, textField, box) = makeField()
        type("1250", into: coordinator, textField)
        coordinator.addTapped()
        #expect(box.value == "12.50")
        type("600", into: coordinator, textField)
        #expect(textField.text == "12.50 + 6.00")
        #expect(box.value == "18.50")
        #expect(Double(box.value) == 18.50)
    }

    @Test func evaluatesLeftToRightWithoutPrecedence() {
        let (coordinator, textField, box) = makeField()
        type("200", into: coordinator, textField)
        coordinator.addTapped()
        type("300", into: coordinator, textField)
        coordinator.multiplyTapped()
        #expect(box.value == "5.00")
        type("400", into: coordinator, textField)
        coordinator.textFieldDidEndEditing(textField)
        #expect(box.value == "20.00")
    }

    @Test func divisionSplitsAnAmount() {
        let (coordinator, textField, box) = makeField()
        type("4500", into: coordinator, textField)
        coordinator.divideTapped()
        type("300", into: coordinator, textField)
        coordinator.textFieldDidEndEditing(textField)
        #expect(box.value == "15.00")
    }

    @Test func divisionByZeroLeavesRunningTotalIntact() {
        let (coordinator, textField, box) = makeField()
        type("1000", into: coordinator, textField)
        coordinator.divideTapped()
        type("000", into: coordinator, textField)
        coordinator.textFieldDidEndEditing(textField)
        #expect(box.value == "10.00")
    }

    /// "12.50 ×" then Done must not multiply by an implied zero.
    @Test func danglingOperatorCollapsesToRunningTotal() {
        let (coordinator, textField, box) = makeField()
        type("1250", into: coordinator, textField)
        coordinator.multiplyTapped()
        coordinator.textFieldDidEndEditing(textField)
        #expect(box.value == "12.50")
    }

    @Test func secondOperatorSwapsTheArmedOne() {
        let (coordinator, textField, box) = makeField()
        type("1000", into: coordinator, textField)
        coordinator.addTapped()
        coordinator.subtractTapped()
        type("400", into: coordinator, textField)
        coordinator.textFieldDidEndEditing(textField)
        #expect(box.value == "6.00")
    }

    @Test func operatorBeforeAnyInputIsIgnored() {
        let (coordinator, textField, box) = makeField()
        coordinator.addTapped()
        #expect(textField.text == "")
        type("500", into: coordinator, textField)
        #expect(box.value == "5.00")
    }

    @Test func backspaceThroughEmptyOperandUndoesTheOperator() {
        let (coordinator, textField, box) = makeField()
        type("1250", into: coordinator, textField)
        coordinator.addTapped()
        #expect(textField.text == "12.50 + ")
        backspace(coordinator, textField)
        #expect(textField.text == "12.50")
        #expect(box.value == "12.50")
        backspace(coordinator, textField)
        #expect(box.value == "12.5")
    }

    @Test func fullReplaceClearsAPendingExpression() {
        let (coordinator, textField, box) = makeField()
        type("1250", into: coordinator, textField)
        coordinator.addTapped()
        type("600", into: coordinator, textField)
        let length = (textField.text as NSString?)?.length ?? 0
        _ = coordinator.textField(
            textField,
            shouldChangeCharactersIn: NSRange(location: 0, length: length),
            replacementString: "9"
        )
        #expect(textField.text == "0.09")
        #expect(box.value == "0.09")
    }

    /// Reconcile can show a negative balance, so the true signed result stands.
    @Test func negativeResultKeepsItsSignWhereAllowed() {
        let (coordinator, textField, box) = makeField(allowsNegative: true)
        type("500", into: coordinator, textField)
        coordinator.subtractTapped()
        type("2000", into: coordinator, textField)
        coordinator.textFieldDidEndEditing(textField)
        #expect(box.value == "-15.00")
    }

    /// Elsewhere the sign comes from the expense/income toggle, so the field
    /// carries the magnitude rather than silently zeroing the entry.
    @Test func negativeResultBecomesMagnitudeWhereSignIsNotAllowed() {
        let (coordinator, textField, box) = makeField()
        type("500", into: coordinator, textField)
        coordinator.subtractTapped()
        type("2000", into: coordinator, textField)
        coordinator.textFieldDidEndEditing(textField)
        #expect(box.value == "15.00")
    }

    @Test func resultStaysEditableAfterEvaluating() {
        let (coordinator, textField, box) = makeField()
        type("1250", into: coordinator, textField)
        coordinator.addTapped()
        type("600", into: coordinator, textField)
        coordinator.textFieldDidEndEditing(textField)
        backspace(coordinator, textField)
        #expect(box.value == "18.5")
    }

    @Test func minusIsIgnoredWhenNegativeNotAllowed() {
        let (coordinator, textField, box) = makeField(initial: "-1.20")
        type("-", into: coordinator, textField)
        #expect(box.value.hasPrefix("-") == false)
        coordinator.toggleSign()
        // Sign toggle exists but sync/full-replace never mark unsigned fields
        // negative; typed digits keep the amount positive.
        type("5", into: coordinator, textField)
        #expect(textField.text?.hasPrefix("-") == false)
    }
}
