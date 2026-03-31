# Control Socket Protocol: Async IDs, GET-TEXT, Pane Targeting, and CLI

## Context

The control socket uses a simple line-based text protocol (`COMMAND args\n` → `response\n`). We need:
1. Kitty-style async request IDs for race-free testing
2. `GET-TEXT` command to read terminal screen content
3. Pane targeting (specify which surface/pane a command applies to)
4. `ghostty cmd` subcommands to invoke socket commands from the shell

## Prior Art

| | Kitty | Wezterm | Ghostty (current) |
|---|---|---|---|
| **Format** | JSON over escape sequences | Custom binary PDU | Line-based text |
| **Content query** | `get-text --extent screen/all/selection` | `get-text --start-line --end-line` | None |
| **Addressing** | `--match field:query` (title, pid, cwd...) | `--pane-id` from env | Implicit (focused) |
| **Async/race** | Explicit async IDs + streaming | Implicit RPC sequencing | None |
| **CLI** | `kitten @` | `wezterm cli` | None |

We adopt Kitty's async ID approach and keep our line-based text protocol.

## Protocol Changes

### Async Request IDs

Any command can include an `@id` suffix. The response will include the same ID.

```
# Without ID (current behavior, unchanged)
PING
PONG

# With ID
PING @req-1
@req-1 PONG

GET-TEXT @abc123
@abc123 <screen content>

NEW-TAB @t1
@t1 OK
```

Rules:
- `@id` is optional — fully backward compatible
- ID is any string after the last ` @` token in the command line
- Response is prefixed with `@id ` if an ID was provided
- Enables clients to send multiple commands and match responses

### Pane Targeting

Commands that operate on a surface accept `--pane <spec>`:

```
GET-TEXT --pane focused          # default
GET-TEXT --pane 0:0              # tab 0, pane handle 0
GET-TEXT --pane 1:3              # tab 1, pane handle 3
GET-DIMENSIONS --pane 0:0
```

Spec format:
- `focused` (default): the currently focused surface
- `tab_index:pane_handle`: explicit tab and pane within that tab's split tree

### GET-TEXT Command

```
GET-TEXT [--pane <spec>] [--extent screen|all] [@id]
```

- `screen` (default): visible terminal content, one line per row
- `all`: full scrollback + screen

Response: plain text lines of terminal content. With `@id`, response is prefixed.

### Split/Pane Commands (new)

```
NEW-SPLIT <direction> [--pane <spec>] [@id]     → OK
  direction: left|right|up|down
  Creates a split relative to the targeted pane.

CLOSE-PANE [--pane <spec>] [@id]                → OK
  Closes the targeted pane.

RESIZE-SPLIT <direction> <amount> [--pane <spec>] [@id] → OK
  direction: left|right|up|down
  amount: pixels (integer)
  Resizes the split adjacent to the targeted pane.

GOTO-SPLIT <direction> [--pane <spec>] [@id]    → OK
  direction: left|right|up|down|next|previous
  Moves focus to the pane in the given direction.

EQUALIZE-SPLITS [--pane <spec>] [@id]           → OK
  Equalizes all splits in the tab containing the targeted pane.

TOGGLE-ZOOM [--pane <spec>] [@id]               → OK
  Toggles zoom on the targeted pane.

LIST-PANES [--tab <index>] [@id]                → JSON
  Lists all panes in a tab with handle, dimensions, active flag.
```

### Existing Commands (unchanged, gain @id and --pane support)

```
PING [@id]                              → PONG
LIST-TABS [@id]                         → JSON array
GET-FOCUSED [@id]                       → JSON
GET-DIMENSIONS [--pane <spec>] [@id]    → JSON {rows, cols}
GET-STATUS-BAR [@id]                    → status text
NEW-TAB [@id]                           → OK
CLOSE-TAB [@id]                         → OK
GOTO-TAB <next|previous|N> [@id]        → OK
SET-STATUS-LEFT <text> [@id]            → OK
SET-STATUS-RIGHT <text> [@id]           → OK
RENAME-TAB <name> [@id]                 → OK
```

## CLI: `ghostty cmd`

```bash
# Terminal content
ghostty cmd get-text                          # focused pane screen
ghostty cmd get-text --pane 1:0 --extent all  # specific pane, full scrollback

# Tab management
ghostty cmd list-tabs
ghostty cmd new-tab
ghostty cmd goto-tab next
ghostty cmd close-tab

# Split/pane management
ghostty cmd list-panes --tab 0
ghostty cmd new-split right
ghostty cmd new-split down --pane 0:0
ghostty cmd close-pane --pane 0:1
ghostty cmd resize-split right 50 --pane 0:0
ghostty cmd goto-split left
ghostty cmd equalize-splits
ghostty cmd toggle-zoom

# Info
ghostty cmd ping
ghostty cmd get-dimensions --pane 0:0
ghostty cmd get-focused
```

- Reads socket path from `$GHOSTTY_SOCKET` or `--socket` flag
- Connects to control socket, sends command, prints response, exits
- Translates CLI flags to protocol commands

## Implementation

### ControlSocket.zig

1. **Parse `@id`**: extract from end of command line before dispatching
2. **Parse `--pane`**: extract pane spec, resolve to `*Surface` via `App.tabs`
3. **Add `GET-TEXT` handler**: lock `renderer_state.mutex`, read terminal rows via `Terminal.plainString()` or `Screen.dumpString`
4. **Prepend `@id`** to all responses if present

### Terminal text extraction

Use existing `Terminal.plainString(alloc)` or `Screen.dumpStringAlloc(alloc)` which iterate screen rows and extract cell text.

### ghostty cmd

New subcommand in `src/main_ghostty.zig` (or `src/cli/cmd.zig`):
- Parse subcommand and flags
- Connect to Unix socket
- Send protocol command
- Print response to stdout

## Race Condition Handling

The control socket handler runs on the main thread (GTK event loop), so terminal state reads are serialized with rendering. No data races.

For logical races (test sends command, then reads screen before shell processes it), the recommended pattern is **client-side polling**:

```typescript
async function waitForScreen(needle: string, timeout = 5000) {
  const start = Date.now()
  while (Date.now() - start < timeout) {
    const screen = await socketCmd('GET-TEXT')
    if (screen.includes(needle)) return screen
    await sleep(100)
  }
  throw new Error(`"${needle}" not found on screen within ${timeout}ms`)
}
```

The `@id` mechanism enables a more advanced pattern: send a command and a GET-TEXT with the same batch, match by ID to know which response is which.

## Test Integration

With GET-TEXT, all UI tests become pure socket tests:

```typescript
// Launch ghostty
// Send: echo hello
// Poll: GET-TEXT until "hello" appears
// Assert: screen contains "hello"
```

No AT-SPI, no wtype, no Appium needed. Same test works on GTK and macOS.
