import XCTest

extension XCUIApplication {
    /// The amount fields' keypad. It's a custom input view, and XCUITest
    /// only lists the system keyboard under `keyboards`, so the keypad is
    /// found by its identifier instead.
    var amountKeypad: XCUIElement {
        descendants(matching: .any)["amountKeypad"]
    }
}
