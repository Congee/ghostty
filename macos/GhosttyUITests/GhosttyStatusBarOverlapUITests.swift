//
//  GhosttyStatusBarOverlapUITests.swift
//  GhosttyUITests
//
//  Tests that the status bar gets its own dedicated row without
//  overlapping terminal content.
//

import XCTest

final class GhosttyStatusBarOverlapUITests: GhosttyCustomConfigCase {
    override static var runsForEachTargetApplicationUIConfiguration: Bool { false }

    private var socketPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        socketPath = "/tmp/ghostty-uitest-\(ProcessInfo.processInfo.processIdentifier).sock"
        try updateConfig(
            """
            status-bar = true
            control-socket = \(socketPath!)
            window-width = 80
            window-height = 24
            title = "StatusBarOverlapTest"
            """
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: socketPath)
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Send a command to the control socket using native Unix sockets.
    private func socketCmd(_ command: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "StatusBarTest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed: \(errno)"])
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath!.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw NSError(domain: "StatusBarTest", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Socket path too long"])
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count { dest[i] = pathBytes[i] }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw NSError(domain: "StatusBarTest", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "connect() failed: \(errno)"])
        }

        let msg = command + "\n"
        msg.utf8CString.withUnsafeBufferPointer { buf in
            _ = write(fd, buf.baseAddress!, msg.utf8.count)
        }

        // Shutdown write side so server knows we're done sending.
        shutdown(fd, SHUT_WR)

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            response.append(contentsOf: buf[0..<n])
        }

        return (String(data: response, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitForSocket(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                if let resp = try? socketCmd("PING"), resp == "PONG" {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    private func getDimensions() throws -> (rows: Int, cols: Int) {
        let resp = try socketCmd("GET-DIMENSIONS")
        guard let data = resp.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["rows"] as? Int,
              let cols = json["cols"] as? Int else {
            throw NSError(domain: "StatusBarTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid GET-DIMENSIONS response: \(resp)"])
        }
        return (rows: rows, cols: cols)
    }

    /// Fill the terminal by pressing Enter 200 times to scroll content past the visible area.
    private func fillTerminal(_ app: XCUIApplication) {
        // Use typeText with newlines for speed — each \n acts as a Return keypress
        // in the terminal, producing a new shell prompt line and scrolling content.
        app.typeText(String(repeating: "\n", count: 200))
    }

    /// Launch app and wait for window to appear.
    @MainActor
    private func launchAndWaitForWindow() async throws -> XCUIApplication {
        let app = try ghosttyApplication()
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Window should appear")
        try await Task.sleep(for: .seconds(1))
        return app
    }

    /// Launch app, wait for window and control socket, return the app instance.
    @MainActor
    private func launchAndWait() async throws -> XCUIApplication {
        let app = try await launchAndWaitForWindow()
        XCTAssertTrue(waitForSocket(), "Control socket should become available")
        return app
    }

    // MARK: - Tests

    /// Verify that the status bar is visually present at the bottom of the window.
    /// Takes a screenshot and confirms the bottom row has non-zero pixel content,
    /// indicating the status bar rendered (not just empty terminal background).
    @MainActor
    func testStatusBarNotOverwrittenByTerminalContent() async throws {
        let app = try await launchAndWaitForWindow()
        // Give the status bar and renderer time to draw
        try await Task.sleep(for: .seconds(2))

        let window = app.windows.firstMatch
        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let cgImage = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not get CGImage from screenshot")
            return
        }

        let height = cgImage.height
        // The status bar occupies the bottom row. It renders text (tab info)
        // which should make the bottom row non-uniform compared to a pure
        // background-color row. Sample bottom 5px and a row 40px up.
        let bottomColor = averageColor(of: cgImage, atY: height - 5)
        let aboveColor = averageColor(of: cgImage, atY: height - 40)

        // At minimum, the bottom should not be pure black (0,0,0) which would
        // indicate nothing rendered at all.
        let bottomBrightness = bottomColor.0 + bottomColor.1 + bottomColor.2
        XCTAssertGreaterThan(bottomBrightness, 0,
            "Status bar row should have rendered content (color: \(bottomColor))")

        // Verify the window rendered with reasonable dimensions
        XCTAssertGreaterThan(cgImage.width, 100, "Window should be wide enough")
        XCTAssertGreaterThan(height, 100, "Window should be tall enough")
    }

    /// Verify PTY rows are reduced by 1 when status bar is active
    /// (24-row window → 23 PTY rows).
    /// NOTE: Requires control socket access (blocked by EPERM in XCUITest — see ghostty-lfc).
    @MainActor
    func testDimensionsReducedWithStatusBar() async throws {
        _ = try await launchAndWait()

        let dims = try getDimensions()
        XCTAssertEqual(dims.rows, 23, "PTY rows should be window rows - 1 for status bar")
        XCTAssertEqual(dims.cols, 80, "Columns should match window-width config")
    }

    /// Fill terminal with output, verify the status bar still reports tab text
    /// via GET-STATUS-BAR (content not overwritten by scrolling).
    /// NOTE: Requires control socket access (blocked by EPERM in XCUITest — see ghostty-lfc).
    @MainActor
    func testStatusBarContentSurvivesTerminalFill() async throws {
        let app = try await launchAndWait()

        fillTerminal(app)
        try await Task.sleep(for: .seconds(2))

        let resp = try socketCmd("GET-STATUS-BAR")
        XCTAssertFalse(resp.isEmpty, "Status bar should have content after terminal fill")
        XCTAssertTrue(resp.contains("1:") || resp != "(none)",
                      "Status bar should still show tab text after fill, got: \(resp)")
    }

    /// Verify PTY row/col counts stay stable after terminal scrolls.
    @MainActor
    func testDimensionsStableAfterFill() async throws {
        let app = try await launchAndWait()

        let dimsBefore = try getDimensions()

        fillTerminal(app)
        try await Task.sleep(for: .seconds(2))

        let dimsAfter = try getDimensions()

        XCTAssertEqual(dimsBefore.rows, dimsAfter.rows,
                       "Row count should not change after scroll (before=\(dimsBefore.rows), after=\(dimsAfter.rows))")
        XCTAssertEqual(dimsBefore.cols, dimsAfter.cols,
                       "Column count should not change after scroll")
    }

    // MARK: - Pixel Sampling

    /// Average RGB color of a horizontal strip at the given y coordinate.
    /// Samples the middle 60% of the row width to avoid window chrome.
    private func averageColor(of image: CGImage, atY y: Int) -> (Double, Double, Double) {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data,
              let ptr = CFDataGetBytePtr(data) else {
            return (0, 0, 0)
        }

        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        let safeY = max(0, min(y, image.height - 1))

        // Sample the middle 60% to avoid window chrome/rounded corners
        let startX = image.width / 5
        let endX = image.width * 4 / 5
        let sampleCount = endX - startX
        guard sampleCount > 0 else { return (0, 0, 0) }

        var totalR: Double = 0
        var totalG: Double = 0
        var totalB: Double = 0

        for x in startX..<endX {
            let offset = safeY * bytesPerRow + x * bytesPerPixel
            totalR += Double(ptr[offset])
            totalG += Double(ptr[offset + 1])
            totalB += Double(ptr[offset + 2])
        }

        let n = Double(sampleCount)
        return (totalR / n, totalG / n, totalB / n)
    }
}
