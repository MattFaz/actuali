import XCTest

/// The Settings > Connection password field can be revealed with an eye button.
/// Both behaviors here are only observable through the view: swapping
/// SecureField for TextField makes a new view, so the field has to re-claim
/// focus or the keyboard drops mid-typing, and the reveal has to be undone
/// before iOS snapshots the screen for the app switcher.
final class PasswordVisibilityUITests: XCTestCase {

    @MainActor
    func testRevealKeepsKeyboardAndResetsOnBackground() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()

        let connectionAndData = app.buttons["Connection & Data"]
        XCTAssertTrue(connectionAndData.waitForExistence(timeout: 5))
        connectionAndData.tap()

        let secure = app.secureTextFields["Password"]
        XCTAssertTrue(secure.waitForExistence(timeout: 5),
                      "password field should start masked")
        secure.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5),
                      "tapping the field should raise the keyboard")

        app.buttons["Show password"].tap()

        let plain = app.textFields["Password"]
        XCTAssertTrue(plain.waitForExistence(timeout: 5),
                      "eye button should swap in a plain TextField")
        XCTAssertTrue(app.keyboards.element.exists,
                      "keyboard dropped when the field was revealed")

        // Backgrounding must re-mask, so the app switcher snapshot can't
        // capture a plain-text password.
        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 5),
                      "password stayed visible across a background/foreground cycle")
    }
}
