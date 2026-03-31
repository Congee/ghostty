# Ghostty UI Tests

UI tests for Ghostty on Linux (GTK) and macOS.

- **Linux GTK**: Uses `wtype` (Wayland keystroke injection), `wlrctl` (window focus), and the control socket.
- **macOS**: Uses Appium with XCUITest driver.

## Prerequisites

### Linux (GTK)

- Wayland session
- `wtype` — keystroke injection
- `wlrctl` — window focus control (wlroots compositors)
- Ghostty built: `zig build -Dapp-runtime=gtk`

### macOS

- Appium: `bunx appium`
- XCUITest driver: `bunx appium driver install mac2`
- Ghostty built via Xcode

## Setup

```bash
cd test/ui
bun install
```

## Running

### GTK (Linux)

```bash
bun run test:gtk

# With custom binary:
GHOSTTY=/path/to/ghostty bun run test:gtk
```

### macOS

```bash
# Start Appium server first:
bunx appium &

bun run test:macos
```

## Test Structure

```
test/ui/
├── helpers/
│   └── ghostty.ts              # Shared utilities
├── specs/
│   ├── gtk/
│   │   └── terminal.spec.ts    # GTK tests (wtype + control socket)
│   └── macos/
│       └── terminal.spec.ts    # macOS tests (Appium/XCUITest)
├── wdio.macos.conf.ts          # WebdriverIO config for macOS
└── package.json
```
