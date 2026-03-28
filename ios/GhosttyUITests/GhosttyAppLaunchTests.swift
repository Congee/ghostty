import XCTest

final class GhosttyAppLaunchTests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
    }

    func testAppLaunches() {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    func testConnectScreenHeroHeader() {
        let title = app.staticTexts["hero-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertTrue(title.label.contains("Connect"))
    }

    func testConnectScreenElements() {
        // Host input
        let hostInput = app.textFields["connect-host-input"]
        XCTAssertTrue(hostInput.waitForExistence(timeout: 3))

        // Connect button
        let connectButton = app.buttons["connect-button"]
        XCTAssertTrue(connectButton.exists)

        // Settings button
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.exists)

        // Feature cards — check by text content
        XCTAssertTrue(app.staticTexts["Encrypted Tunnel"].exists)
        XCTAssertTrue(app.staticTexts["Low Latency"].exists)
    }

    func testConnectButtonDisabledWhenEmpty() {
        let connectButton = app.buttons["connect-button"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 3))
        XCTAssertFalse(connectButton.isEnabled)
    }

    func testHostInputAcceptsText() {
        let hostInput = app.textFields["connect-host-input"]
        XCTAssertTrue(hostInput.waitForExistence(timeout: 3))

        hostInput.tap()
        hostInput.typeText("192.168.1.100")

        XCTAssertEqual(hostInput.value as? String, "192.168.1.100")

        // Connect button should now be enabled
        let connectButton = app.buttons["connect-button"]
        XCTAssertTrue(connectButton.isEnabled)
    }
}
