import XCTest

final class GhosttySettingsTests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        // Navigate to Settings tab
        let settingsTab = app.buttons["tab-settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 3))
        settingsTab.tap()
    }

    func testSettingsScreenSections() {
        // Section labels
        XCTAssertTrue(app.staticTexts["SAVED NODES"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["SECURITY & PREFERENCES"].exists)
        XCTAssertTrue(app.staticTexts["SYSTEM CONTROL"].exists)
    }

    func testSettingsSecurityRows() {
        XCTAssertTrue(app.staticTexts["SSH Key Management"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Appearance"].exists)
        XCTAssertTrue(app.staticTexts["Notifications"].exists)
    }

    func testAddNodeSheetPresents() {
        let addButton = app.buttons["add-node-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 2))

        addButton.tap()

        // Sheet should appear with input fields
        let nodeNameField = app.textFields.matching(
            NSPredicate(format: "placeholderValue CONTAINS[c] 'Node name'")
        ).firstMatch
        XCTAssertTrue(nodeNameField.waitForExistence(timeout: 2))
    }

    func testAddNodeSheetDismisses() {
        let addButton = app.buttons["add-node-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 2))

        addButton.tap()

        // Wait for sheet
        let nodeNameField = app.textFields.matching(
            NSPredicate(format: "placeholderValue CONTAINS[c] 'Node name'")
        ).firstMatch
        XCTAssertTrue(nodeNameField.waitForExistence(timeout: 2))

        // Tap Cancel
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists)
        cancelButton.tap()

        // Sheet should dismiss — node name field gone
        XCTAssertTrue(nodeNameField.waitForNonExistence(timeout: 2))
    }

    func testFlushTokensButtonExists() {
        let flushButton = app.buttons["flush-tokens-button"]
        XCTAssertTrue(flushButton.waitForExistence(timeout: 2))
    }

    func testSignOutButtonExists() {
        let signOutButton = app.buttons["sign-out-button"]
        XCTAssertTrue(signOutButton.waitForExistence(timeout: 2))
    }
}
