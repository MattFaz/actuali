import XCTest

/// Accounts can be renamed from the account row's long-press menu, regardless
/// of whether the connected Actual Server supports account groups.
final class AccountRenameUITests: XCTestCase {
    @MainActor
    private func launchAccounts(groupWrites: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-serverURL", "",
            "-accountGroupWritesEnabled_", groupWrites ? "1" : "0",
        ]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        return app
    }

    @MainActor
    private func promptTextField(in app: XCUIApplication) -> XCUIElement {
        // SwiftUI text fields inside native alerts aren't consistently
        // discoverable through app.alerts.textFields across iOS runtimes.
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Prompt text field not found")
        return field
    }

    @MainActor
    private func longPressAccount(named name: String, in app: XCUIApplication) {
        let matches = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", name)
        )
        XCTAssertTrue(
            matches.firstMatch.waitForExistence(timeout: 10),
            "\(name) account not found in the accessibility hierarchy"
        )

        // Prefer the visible name label when SwiftUI exposes it separately.
        // Otherwise use the one combined row element. This handles both a
        // NavigationLink with a merged label and a row with exposed children.
        let hittableMatches = (0..<matches.count)
            .map { matches.element(boundBy: $0) }
            .filter { $0.isHittable }
        let exactTextMatches = hittableMatches.filter {
            $0.elementType == .staticText && $0.label == name
        }
        let exactLabelMatches = hittableMatches.filter { $0.label == name }

        let account: XCUIElement
        if exactTextMatches.count == 1 {
            account = exactTextMatches[0]
        } else if exactLabelMatches.count == 1 {
            account = exactLabelMatches[0]
        } else if hittableMatches.count == 1 {
            account = hittableMatches[0]
        } else {
            XCTFail(
                "Expected one hittable accessibility element for \(name), found \(hittableMatches.count)"
            )
            return
        }

        account.press(forDuration: 1.2)
    }

    @MainActor
    private func openRename(groupWrites: Bool = false) -> XCUIApplication {
        let app = launchAccounts(groupWrites: groupWrites)
        longPressAccount(named: "Chase Checking", in: app)

        if groupWrites {
            XCTAssertTrue(
                app.buttons["Set Account Group"].waitForExistence(timeout: 5),
                "the existing group action should remain available"
            )
        }
        let rename = app.buttons["accountRename.action"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "the long-press menu should offer Rename Account")
        rename.tap()

        XCTAssertTrue(
            app.alerts["Rename Account"].waitForExistence(timeout: 5),
            "the rename prompt should be presented"
        )
        let field = promptTextField(in: app)
        XCTAssertEqual(field.value as? String, "Chase Checking", "the prompt starts with the current name")
        return app
    }

    @MainActor
    func testRenameFromLongPressMenu() {
        let app = openRename()
        let field = promptTextField(in: app)
        replaceText("  Primary Checking  ", in: field)
        app.alerts.buttons["Save"].tap()

        XCTAssertTrue(app.staticTexts["Primary Checking"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Chase Checking"].exists)
    }

    @MainActor
    func testRenameRemainsAvailableAlongsideAccountGroupActions() {
        let app = openRename(groupWrites: true)
        let field = promptTextField(in: app)
        replaceText("Primary Checking", in: field)
        app.alerts.buttons["Save"].tap()

        XCTAssertTrue(app.staticTexts["Primary Checking"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Chase Checking"].exists)
    }

    @MainActor
    func testAddNewAccountGroupPromptStillWorks() {
        let app = launchAccounts(groupWrites: true)
        longPressAccount(named: "Chase Checking", in: app)

        let groupMenu = app.buttons["Set Account Group"]
        XCTAssertTrue(groupMenu.waitForExistence(timeout: 5))
        groupMenu.tap()

        let addNew = app.buttons["Add New"]
        XCTAssertTrue(addNew.waitForExistence(timeout: 5))
        addNew.tap()

        XCTAssertTrue(
            app.alerts["Create Group"].waitForExistence(timeout: 5),
            "the create-group prompt should be presented"
        )
        let field = promptTextField(in: app)
        replaceText("Rename Review Group", in: field)
        app.alerts.buttons["Add"].tap()

        XCTAssertTrue(app.staticTexts["Rename Review Group"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testBlankNamesDisableSave() {
        let app = openRename()
        let field = promptTextField(in: app)
        replaceText("", in: field)

        let save = app.alerts.buttons["Save"]
        XCTAssertFalse(save.isEnabled, "an empty name must not enable Save")

        field.typeText("   ")
        XCTAssertFalse(save.isEnabled, "a whitespace-only name must not enable Save")
        XCTAssertTrue(app.alerts["Rename Account"].exists)

        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Chase Checking"].waitForExistence(timeout: 5))
    }
}
