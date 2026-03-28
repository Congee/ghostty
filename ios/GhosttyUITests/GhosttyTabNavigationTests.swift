import XCTest

final class GhosttyTabNavigationTests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
    }

    func testTabBarVisible() {
        let sessionsTab = app.buttons["tab-sessions"]
        let historyTab = app.buttons["tab-history"]
        let settingsTab = app.buttons["tab-settings"]

        XCTAssertTrue(sessionsTab.waitForExistence(timeout: 3))
        XCTAssertTrue(historyTab.exists)
        XCTAssertTrue(settingsTab.exists)
    }

    func testSwitchToHistoryTab() {
        let historyTab = app.buttons["tab-history"]
        XCTAssertTrue(historyTab.waitForExistence(timeout: 3))

        historyTab.tap()

        let historyTitle = app.staticTexts["History"]
        XCTAssertTrue(historyTitle.waitForExistence(timeout: 2))
    }

    func testSwitchToSettingsTab() {
        let settingsTab = app.buttons["tab-settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 3))

        settingsTab.tap()

        // Settings screen should show its hero title
        let settingsTitle = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'Settings'")
        ).firstMatch
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 2))
    }

    func testSwitchBackToSessions() {
        let historyTab = app.buttons["tab-history"]
        let sessionsTab = app.buttons["tab-sessions"]
        XCTAssertTrue(historyTab.waitForExistence(timeout: 3))

        // Go to history
        historyTab.tap()
        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 2))

        // Go back to sessions
        sessionsTab.tap()
        let connectTitle = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'Connect'")
        ).firstMatch
        XCTAssertTrue(connectTitle.waitForExistence(timeout: 2))
    }
}
