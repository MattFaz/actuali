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
        allowsNegative: Bool = false
    ) -> (coordinator: AmountInputField.Coordinator, textField: UITextField, box: TextBox) {
        let box = TextBox(initial)
        let field = AmountInputField(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
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
