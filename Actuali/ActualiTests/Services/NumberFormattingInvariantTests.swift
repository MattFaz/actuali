import Testing
import SwiftUI
import UIKit
@testable import Actuali

@MainActor
struct NumberFormattingInvariantTests {
    final class TextBox {
        var value: String
        init(_ value: String = "") { self.value = value }
    }

    private func makeField(
        conventionalAmountEntry: Bool,
        numberFormat: ActualNumberFormat
    ) -> (AmountInputField.Coordinator, UITextField, TextBox) {
        let box = TextBox()
        let field = AmountInputField(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            conventionalAmountEntry: conventionalAmountEntry
        )
        let coordinator = field.makeCoordinator()
        coordinator.numberFormat = numberFormat
        let textField = UITextField()
        coordinator.textField = textField
        coordinator.sync(fromDisplay: "")
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

    @Test func calculatorEntryUsesSelectedFormatWithoutChangingCanonicalAmount() {
        let (coordinator, textField, box) = makeField(
            conventionalAmountEntry: false,
            numberFormat: .dotComma
        )
        type("324", into: coordinator, textField)

        #expect(textField.text == "3,24")
        #expect(box.value == "3.24")
        #expect(Transaction.cents(fromDollars: Double(box.value)!) == 324)
    }

    @Test func conventionalEntryUsesSelectedFormatWithoutChangingCanonicalAmount() {
        let (coordinator, textField, box) = makeField(
            conventionalAmountEntry: true,
            numberFormat: .dotComma
        )
        type("324", into: coordinator, textField)

        #expect(textField.text == "324")
        #expect(box.value == "324")
        #expect(Transaction.cents(fromDollars: Double(box.value)!) == 32400)
    }

    @Test func conventionalDecimalEntryUsesSelectedFormat() {
        let (coordinator, textField, box) = makeField(
            conventionalAmountEntry: true,
            numberFormat: .dotComma
        )
        type("324,50", into: coordinator, textField)

        #expect(textField.text == "324,50")
        #expect(box.value == "324.50")
        #expect(Transaction.cents(fromDollars: Double(box.value)!) == 32450)
    }
}
