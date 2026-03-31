/**
 * Shared helpers for Ghostty UI tests.
 * Works across GTK (AT-SPI) and macOS (XCUITest) drivers.
 */

/** Wait for the terminal surface to be ready (has focus and accepts input). */
export async function waitForTerminal(timeout = 10000) {
  await browser.pause(2000) // Give Ghostty time to initialize
  // The terminal surface should be the focused element
  const active = await browser.getActiveElement()
  expect(active).toBeTruthy()
}

/** Type text into the terminal by sending keystrokes. */
export async function typeText(text: string) {
  for (const char of text) {
    await browser.keys(char)
    await browser.pause(20) // Small delay between keystrokes
  }
}

/** Type text and press Enter. */
export async function typeCommand(cmd: string) {
  await typeText(cmd)
  await browser.keys('Enter')
}

/** Press a key combination (e.g., ['Control', 'Shift', 'd'] for split). */
export async function pressKeys(keys: string[]) {
  await browser.keys(keys)
}

/** Wait for the window to close (Ghostty process exits). */
export async function waitForWindowClose(timeout = 5000) {
  const start = Date.now()
  while (Date.now() - start < timeout) {
    try {
      // Try to get window handle — if it fails, window is closed
      await browser.getWindowHandle()
      await browser.pause(200)
    } catch {
      return // Window closed
    }
  }
  throw new Error(`Window did not close within ${timeout}ms`)
}

/**
 * Send a command to Ghostty's control socket and get the response.
 * Only works if Ghostty was started with --control-socket.
 */
export async function controlSocketCommand(socketPath: string, command: string): Promise<string> {
  // Use Node's net module via browser.execute or a helper script
  // For now, this is a placeholder — actual implementation depends on
  // whether we can access Node APIs from the test context.
  throw new Error('Control socket helper not yet implemented')
}
