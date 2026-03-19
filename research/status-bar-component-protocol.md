# Status Bar Component Protocol — Design Proposal

## Prior Art Summary

### tmux: Inline Style Directives
tmux embeds styles in format strings using `#[fg=colour,bg=colour,bold]`.
Key features:
- **Clickable ranges**: `#[range=user|myid]text#[norange]` — defines a clickable region with a user-defined ID. Clicks fire the `Status` mouse key with `mouse_status_range=myid`.
- **Tab list layout**: `#[list=on]` marks where the window list starts; `#[list=focus]` marks the focused window for scroll-into-view; `#[list=left-marker]`/`#[list=right-marker]` define overflow indicators.
- **Alignment**: `#[align=left]`, `#[align=centre]`, `#[align=right]`.
- **Colors**: named (`red`), 256-palette (`colour123`), hex (`#ffffff`).
- **Attributes**: `bold`, `dim`, `underscore`, `blink`, `reverse`, `italics`.
- **Style stacking**: `push-default`/`pop-default` for saving/restoring.

### wezterm: Structured FormatItems + User Variables
wezterm uses a Lua array of typed FormatItem objects:
```lua
wezterm.format {
  { Foreground = { Color = "#ff0000" } },
  { Background = { Color = "blue" } },
  { Attribute = { Intensity = "Bold" } },
  { Attribute = { Italic = true } },
  { Text = "hello" },
  "ResetAttributes",
}
```
- `window:set_left_status(string)` / `window:set_right_status(string)` accept pre-formatted escape strings.
- Programs push status via **OSC 1337 SetUserVar**: `\x1b]1337;SetUserVar=name=<base64-value>\a`. wezterm fires a `user-var-changed` Lua callback, which can then call `set_left_status`.
- **No built-in click handling** in status bar — wezterm's status bar is display-only text.

### Your wezterm_bar.lua: How Neovim Pushes Status Today
Your existing code:
1. Evaluates neovim's statusline via `nvim_eval_statusline(vim.o.stl, { highlights = true })`.
2. Gets back `{ str, width, highlights: [{ group, start }] }` — plain text + highlight group spans at byte offsets.
3. Resolves each highlight group to actual `{ fg, bg, bold, italic, ... }` via `nvim_get_hl()`.
4. JSON-encodes `{ pid, statusline: { str, width, highlights } }` and sends via OSC 1337 SetUserVar.

### kitty: Remote Control Protocol
kitty uses `\x1bP@kitty-cmd<JSON>\x1b\\` for structured commands. Your wezterm_bar.lua already has (disabled) code for this. kitty also supports user vars via its remote control protocol but does not have a status bar API.

### Heirline (neovim): Component Model with Click Handlers
Heirline components have:
- `provider` — text content
- `hl` — `{ fg, bg, bold, italic }`
- `on_click` — `{ callback, name }` with encoded payload via `minwid`

---

## Design Questions Answered

### 1. Wire Format: OSC vs Control Socket vs Hybrid?

**Recommendation: Control socket with JSON (extend existing protocol).**

Rationale:
- OSC 1337 SetUserVar is limited: it's one-way (app → terminal), requires base64 encoding, passes through tmux/SSH poorly, and provides no acknowledgment.
- The control socket already exists with a command protocol. Extending it is natural.
- JSON gives us structured data, extensibility, and easy parsing in Zig.
- The control socket allows **bidirectional** communication (critical for click callbacks).

### 2. Click Event Routing

**Recommendation: Named click regions with callback via control socket notification.**

Each component segment gets an `id` field. When the user clicks a region, Ghostty:
1. Hit-tests to find which segment was clicked.
2. Sends a notification to the originating program's registered callback channel.

Two callback mechanisms (program chooses one at registration time):
- **Control socket push**: If the program holds a persistent connection, Ghostty writes `CLICK <component-id> <segment-id>\n` to it.
- **OSC reply**: Ghostty writes `\x1b]1337;GhosttyClick=<component-id>;<segment-id>\a` to the PTY (the program's stdin). Programs that understand this can react.
- **Shell command**: The component specifies an `action` that is a ghostty keybind action or shell command.

### 3. Simplest Protocol Supporting Text + Styles + Clicks

**Recommendation: JSON segments array over control socket.**

---

## Concrete Protocol Proposal

### New Control Socket Commands

#### `SET-COMPONENTS <JSON>`

Replaces the current status bar content for a given zone. The JSON payload:

```json
{
  "zone": "left" | "right",
  "source": "nvim-1234",
  "components": [
    {
      "text": " N ",
      "style": { "fg": "#e06c75", "bg": "#282c34", "bold": true },
      "click": { "id": "mode", "action": "notify" }
    },
    {
      "text": " main ",
      "style": { "fg": "#98c379", "bg": "#3e4452" },
      "click": { "id": "git-branch", "action": "notify" }
    },
    {
      "text": "  statusline.lua ",
      "style": { "fg": "#abb2bf" },
      "click": { "id": "filename", "action": "notify" }
    },
    {
      "text": " 73% ",
      "style": { "fg": "#61afef", "italic": true }
    }
  ]
}
```

#### Style Object

```
style: {
  fg?: string,       // "#rrggbb" | named color | "palette:N" (0-255)
  bg?: string,       // same as fg
  bold?: bool,
  italic?: bool,
  underline?: "none" | "single" | "double" | "curly",
  strikethrough?: bool
}
```

#### Click Object

```
click: {
  id: string,                // unique within this source, max 32 bytes
  action: "notify"           // send CLICK event back to the source
         | "key:<binding>"   // execute a ghostty keybind (e.g., "key:goto_tab:1")
         | "cmd:<command>"   // run a shell command
}
```

#### `SUBSCRIBE-CLICKS <source-id>`

Registers the current connection to receive click notifications for components with `action: "notify"` from the given source. The connection stays open and Ghostty writes lines:

```
CLICK <segment-click-id> <mouse-button> <x-offset>\n
```

This allows a long-running program (like a neovim plugin) to:
1. Connect, send `SUBSCRIBE-CLICKS nvim-1234`.
2. Send `SET-COMPONENTS {...}` periodically to update status.
3. Read lines to receive click events.

#### `CLEAR-COMPONENTS <source-id>`

Removes all components from a given source.

### Zone Layout Model

```
┌──────────────────────────────────────────────────────────────┐
│ [external:left]  [  tabs (ghostty-native)  ]  [external:right] │
└──────────────────────────────────────────────────────────────┘
```

- Ghostty always renders tabs in the center (native rendering with native click handling).
- External components occupy the left and right zones.
- If multiple sources set the same zone, they are concatenated in registration order.
- If external content overflows, it is clipped (left-side clips from left, right-side clips from right).

### OSC Alternative (for programs that can't use the control socket)

For simpler integration (e.g., shell prompts, programs without socket access):

```
\x1b]1337;SetUserVar=ghostty_status_left=<base64-json>\a
\x1b]1337;SetUserVar=ghostty_status_right=<base64-json>\a
```

Where the base64 payload is the same JSON components array. This is **one-way only** — no click callbacks. Ghostty would decode this as a simplified `SET-COMPONENTS` from the focused pane's process.

### Neovim Integration Example

```lua
-- In neovim plugin (extends your existing wezterm_bar.lua pattern)
local socket = vim.uv.new_pipe(false)
socket:connect(os.getenv("GHOSTTY_CONTROL_SOCKET"))

-- Subscribe to clicks
socket:write("SUBSCRIBE-CLICKS nvim-" .. vim.fn.getpid() .. "\n")

-- Push status updates
local function update_status()
  local components = {
    zone = "left",
    source = "nvim-" .. vim.fn.getpid(),
    components = build_components_from_heirline()
  }
  socket:write("SET-COMPONENTS " .. vim.fn.json_encode(components) .. "\n")
end

-- Handle click events
socket:read_start(function(err, data)
  if data and data:match("^CLICK ") then
    local id = data:match("^CLICK (%S+)")
    handle_click(id)
  end
end)
```

### Translation from Heirline Highlights

Your `wezterm_bar.lua` already extracts `{ str, width, highlights: [{ group: {fg,bg,...}, start }] }`. The translation to the component protocol is:

```lua
local function highlights_to_components(stl)
  local components = {}
  for i, hi in ipairs(stl.highlights) do
    local next_start = (stl.highlights[i+1] and stl.highlights[i+1].start) or #stl.str
    local text = stl.str:sub(hi.start + 1, next_start)
    if #text > 0 then
      local style = {}
      local g = hi.group
      if g.fg then style.fg = string.format("#%06x", g.fg) end
      if g.bg then style.bg = string.format("#%06x", g.bg) end
      if g.bold then style.bold = true end
      if g.italic then style.italic = true end
      table.insert(components, { text = text, style = style })
    end
  end
  return components
end
```

---

## Comparison Matrix

| Feature | tmux | wezterm | This proposal |
|---|---|---|---|
| Wire format | Inline `#[style]` in strings | Lua FormatItem arrays | JSON over socket |
| Color support | named, 256, hex | named, hex, AnsiColor | named, hex, palette index |
| Click regions | `range=user\|id` | None | `click.id` per segment |
| Click routing | Mouse key binding | N/A | CLICK notification on socket |
| Bidirectional | No (set only) | No (set only) | Yes (socket is bidirectional) |
| Tab integration | Native `list=on` | Native (Lua config) | Native center zone |
| Multiple sources | No | No | Yes (source ID) |
| Transport | Format string in config | Lua callback | Unix socket + optional OSC |

## Implementation Notes for Ghostty (Zig)

1. **Extend `ControlSocket.zig`**: Add `SET-COMPONENTS`, `CLEAR-COMPONENTS`, `SUBSCRIBE-CLICKS` handlers. Persistent connections need a connection registry (small ArrayList of fds + source IDs).

2. **Extend `StatusBarWidget.zig`**: Add a `components: ?[]Component` field per zone (left/right). When external components are present, render them instead of (or alongside) the template format string. The `Component` struct holds pre-parsed style info.

3. **Renderer integration**: The renderer needs to map pixel coordinates to component segments for hit testing. Store a `[]ClickRegion` array with `{ x_start, x_end, click_id, source_id }` computed during the last render pass.

4. **Click dispatch**: On mouse click in the status bar zone, walk `ClickRegion` array. For `action: "notify"`, write to the subscribed socket fd. For `action: "key:..."`, dispatch as a keybind. For `action: "cmd:..."`, spawn a subprocess.
