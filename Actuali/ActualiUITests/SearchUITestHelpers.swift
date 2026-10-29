import XCTest

@MainActor
extension XCTestCase {
    func searchControl(in app: XCUIApplication, customButtonIdentifier: String) -> XCUIElement {
        let customButton = app.buttons[customButtonIdentifier]
        if customButton.exists {
            return customButton
        }
        return app.navigationBars.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Search"))
            .firstMatch
    }

    func tapSearch(in app: XCUIApplication, customButtonIdentifier: String) {
        let control = searchControl(in: app, customButtonIdentifier: customButtonIdentifier)
        XCTAssertTrue(control.waitForExistence(timeout: 10),
                      "the native or fallback search control should be visible")
        control.tap()
    }

    func activeSearchField(in app: XCUIApplication, customFieldIdentifier: String) -> XCUIElement {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
            let nativeField = app.searchFields.firstMatch
            XCTAssertTrue(nativeField.waitForExistence(timeout: 5),
                          "iOS 26+ should present the native search field")
            XCTAssertFalse(app.textFields[customFieldIdentifier].exists,
                           "iOS 26+ should not use the fallback search field")
            return nativeField
        }

        let customField = app.textFields[customFieldIdentifier]
        XCTAssertTrue(customField.waitForExistence(timeout: 5),
                      "pre-iOS 26 should insert the fallback search field")
        XCTAssertFalse(app.searchFields.firstMatch.exists,
                       "pre-iOS 26 should use the fallback, not the native search field")
        return customField
    }

    func typeSearchText(_ text: String, in field: XCUIElement) {
        func waitForFocus(_ timeout: TimeInterval) -> Bool {
            let focused = NSPredicate(format: "hasKeyboardFocus == true")
            let expectation = XCTNSPredicateExpectation(predicate: focused, object: field)
            return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
        }

        if !waitForFocus(2) {
            field.tap()
            if !waitForFocus(3) {
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }
        XCTAssertTrue(waitForFocus(5), "the search field should have keyboard focus before typing")
        field.typeText(text)
    }

    func clearSearch(in app: XCUIApplication, customClearIdentifier: String) {
        let customClearButton = app.buttons[customClearIdentifier]
        if customClearButton.waitForExistence(timeout: 1) {
            customClearButton.tap()
            return
        }

        let nativeClearButton = app.navigationBars.descendants(matching: .button)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Clear"))
            .firstMatch
        XCTAssertTrue(nativeClearButton.waitForExistence(timeout: 10),
                      "the native search field should expose a clear control")
        nativeClearButton.tap()
    }

    func cancelSearch(in app: XCUIApplication, customButtonIdentifier: String) {
        let nativeCancelButton = app.navigationBars.descendants(matching: .button)
            .matching(NSPredicate(format: "label CONTAINS[c] 'Cancel' OR label == 'Close'"))
            .firstMatch
        if nativeCancelButton.waitForExistence(timeout: 2) {
            nativeCancelButton.tap()
            return
        }

        let fallbackButton = app.buttons[customButtonIdentifier]
        XCTAssertTrue(fallbackButton.waitForExistence(timeout: 10),
                      "the fallback cancel-search button should be visible")
        fallbackButton.tap()
    }
}
