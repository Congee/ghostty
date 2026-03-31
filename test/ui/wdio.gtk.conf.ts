// GTK UI tests use AT-SPI + wtype directly (no Appium).
// See specs/gtk/ for the test scripts.
// Run: bun run test:gtk
//
// Appium does not have a well-supported Linux/GTK driver.
// Instead, we use:
// - wtype (Wayland) for keystroke injection
// - AT-SPI2 / busctl for accessibility tree inspection
// - ghostty control socket for state verification
export {}
