# WezTerm Feature Analysis & Comparison with Ghostty Fork

## 1. Multiplexing Architecture

### WezTerm's Approach
- **Domain-based model**: All multiplexing is organized around "domains" — distinct sets of windows/tabs
- **Default local domain**: Created automatically on startup for in-process tab/window management
- **Three remote domain types**:
  - **Unix Domains** — local mux server via unix socket (tmux/screen replacement)
  - **SSH Domains** — remote mux server reached over SSH (auto-spawns wezterm daemon on remote)
  - **TLS Domains** — remote mux server over TCP/TLS (for direct network connections)
- **Mux server is a separate process** (`wezterm-mux-server`), GUI connects to it as a client
- **Auto-start**: Server is spawned automatically on `wezterm connect <domain>` if not already running (`no_serve_automatically = false` by default)
- **Native UI attachment**: Remote tabs/panes are attached to native GUI, giving full mouse, clipboard, and scrollback support (not a raw terminal-in-terminal like tmux)

### Unix Domain Configuration
```lua
config.unix_domains = {
  {
    name = 'unix',
    -- socket_path = "/some/path",       -- default is computed
    -- no_serve_automatically = false,    -- auto-start server
    -- skip_permissions_check = false,    -- security check on socket
    -- proxy_command = { 'nc', '-U', '/path/to/sock' },  -- optional proxy
    -- local_echo_threshold_ms = N,       -- latency threshold for local echo
  },
}
-- Auto-connect on startup:
config.default_gui_startup_args = { 'connect', 'unix' }
```

### SSH Domain Configuration
```lua
config.ssh_domains = {
  {
    name = 'my.server',
    remote_address = '192.168.1.1',
    username = 'wez',
  },
}
-- Auto-populates from ~/.ssh/config with SSH: and SSHMUX: prefixes
-- Connect: wezterm connect my.server
-- Or: wezterm cli spawn --domain-name SSHMUX:my.server
```

### Comparison with Our Ghostty Fork
| Aspect | WezTerm | Ghostty Fork |
|--------|---------|--------------|
| Session persistence | Mux server process survives GUI close | Session.zig manages persistent PTY state |
| Socket protocol | Custom binary mux protocol over unix/TCP/SSH | JSON-based control socket protocol |
| Connection model | GUI is a client to mux server | Embedded apprt with direct session ownership |
| Remote support | SSH domains, TLS domains (full remote mux) | Local only (no remote multiplexing yet) |
| Auto-start | Server auto-spawns on connect | Daemon not yet separate from GUI process |
| Multiple clients | Multiple GUIs can attach to same mux server | Single GUI per session currently |

## 2. Tab/Pane Management

### WezTerm
- **Tabs**: `Super-T` new tab, `Super-Shift-[/]` prev/next, `Super-[1-9]` go-to
- **Panes/Splits**: `Ctrl-Shift-Alt-%` horizontal, `Ctrl-Shift-Alt-"` vertical
- **Pane navigation**: `Ctrl-Shift-ArrowKey` to move between panes
- **Pane zoom**: Toggle zoom on a single pane
- **Move pane to new tab**: CLI and keybinding support
- **Workspaces**: Named workspace groupings (like tmux sessions)
- **Rename workspace**: `wezterm cli rename-workspace`

### CLI Pane/Tab Commands
```
wezterm cli activate-pane-direction
wezterm cli activate-pane
wezterm cli activate-tab
wezterm cli adjust-pane-size
wezterm cli get-pane-direction
wezterm cli get-text
wezterm cli kill-pane
wezterm cli list-clients
wezterm cli list
wezterm cli move-pane-to-new-tab
wezterm cli rename-workspace
wezterm cli send-text
wezterm cli set-tab-title
wezterm cli set-window-title
wezterm cli spawn
wezterm cli split-pane
wezterm cli zoom-pane
```

### Comparison with Our Ghostty Fork
| Aspect | WezTerm | Ghostty Fork |
|--------|---------|--------------|
| Tab management | Full GUI tabs + CLI control | Control socket: LIST-TABS, GET-FOCUSED, RENAME-TAB |
| Splits/Panes | Built-in split support with resize | Not yet implemented |
| Workspaces | Named workspace groupings | Not yet implemented |
| CLI breadth | 17 subcommands for full control | Narrower control socket command set |
| Pane text extraction | `wezterm cli get-text` | Not yet implemented |

## 3. Status Bar / Tab Bar Customization

### WezTerm
- **Lua-scriptable**: Full Lua API for customization
- **Tab bar position**: `tab_bar_at_bottom = true/false`
- **Fancy tab bar**: `use_fancy_tab_bar` (native-looking vs retro)
- **Enable/disable**: `enable_tab_bar`
- **Status bar via events**:
  - `update-status` event fires periodically (configurable interval via `status_update_interval`)
  - `window:set_left_status(formatted_string)` — left side of tab bar
  - `window:set_right_status(formatted_string)` — right side of tab bar
  - `format-tab-title` event — customize individual tab titles
  - `format-window-title` event — customize window title
- **Rich formatting**: `wezterm.format {}` for colors, fonts, icons in status

### Comparison with Our Ghostty Fork
| Aspect | WezTerm | Ghostty Fork |
|--------|---------|--------------|
| Customization language | Full Lua scripting | Template-based config strings |
| Status bar content | Arbitrary Lua-generated content | StatusBarWidget with template variables |
| Update mechanism | Event-driven with configurable interval | Renderer state polling |
| Tab title customization | Lua event handler per tab | RENAME-TAB control socket command |
| Positioning | Top or bottom | Configurable via `status-bar` config |

## 4. Key Bindings & Leader Key

### WezTerm
- **Leader key**: `config.leader = { key = 'Space', mods = 'CTRL|SHIFT', timeout_milliseconds = 1000 }`
- **LEADER modifier**: Use `mods = 'LEADER'` in key bindings for leader-prefixed keys
- **Key Tables (modal keybindings)**:
  - Named tables activated via `ActivateKeyTable { name = 'resize_pane', one_shot = false }`
  - `one_shot = true` — table deactivates after one key press
  - `one_shot = false` — stays in mode until Escape/timeout
  - `timeout_milliseconds` — auto-deactivate after timeout
  - Can show active table in status bar via `window:active_key_table()`
- **Modifier labels**: SUPER/CMD/WIN, CTRL, SHIFT, ALT/OPT/META, LEADER, VoidSymbol
- **Physical vs Mapped**: Support for both physical key position and logical key assignments
- **Key assignment actions**: SpawnTab, SplitHorizontal, SplitVertical, ActivateTabRelative, AdjustPaneSize, and many more

### Comparison with Our Ghostty Fork
| Aspect | WezTerm | Ghostty Fork |
|--------|---------|--------------|
| Leader/prefix key | `config.leader` with timeout | `prefix-key` config option |
| Modal key tables | ActivateKeyTable with one_shot/timeout | Not yet implemented |
| Key actions | ~50+ built-in actions | Ghostty's action system + custom commands |
| Status indicator | `window:active_key_table()` in status | Leader active state not yet exposed |

## 5. Full Feature List (WezTerm)

From the features page:
- Cross-platform: Linux, macOS, Windows 10, FreeBSD, NetBSD
- Multiplex panes, tabs, windows on local and remote hosts with native mouse/scrollback
- Ligatures, Color Emoji, font fallback, true color, dynamic color schemes
- Hyperlinks (OSC 8)
- Searchable Scrollback (Ctrl-Shift-F)
- xterm-style mouse selection, bracketed paste
- SGR mouse reporting
- Rich text rendering: underline, double-underline, italic, bold, strikethrough
- Hot-reloading configuration file
- Multiple windows, tabs, splits/panes
- SSH client with native tabs
- Serial port connections
- Unix domain socket multiplexer
- TLS over TCP/IP remote multiplexer
- iTerm2 image protocol
- Kitty graphics protocol
- Sixel graphics (experimental)
- Copy Mode (vim-like selection)
- Shell Integration
- Command Palette
- Plugin system

## 6. Recommendations for Ghostty Daemon Architecture

Based on wezterm's design, consider these for the ghostty fork:

### High Priority
1. **Separate daemon process**: Like `wezterm-mux-server`, split session management into a standalone daemon that survives GUI restarts. Currently our Session.zig is in-process.
2. **Multiple GUI client support**: Allow multiple GUI windows to connect to the same daemon, each attaching to different sessions/tabs.
3. **Richer CLI command set**: Expand control socket beyond LIST-TABS/GET-FOCUSED/RENAME-TAB to match wezterm's 17 CLI subcommands (spawn, split-pane, send-text, get-text, etc.).

### Medium Priority
4. **Workspaces**: Named session groupings (wezterm calls them workspaces) for organizing related tabs.
5. **Pane splits**: In-terminal splits managed by the daemon, not just tabs.
6. **Modal key tables**: Support for ActivateKeyTable-style modal keybinding modes beyond just leader key.
7. **Leader key state in status bar**: Expose whether leader/prefix key is active for status bar display.

### Lower Priority / Future
8. **Remote multiplexing**: SSH domains and TLS domains for remote session attachment.
9. **Proxy command support**: For connecting through WSL or custom transports.
10. **Local echo optimization**: `local_echo_threshold_ms` for reducing perceived latency on slow connections.
11. **Plugin system**: Lua or similar scripting for extensibility.

### Architecture Differences to Preserve
- Our JSON-based control socket protocol is simpler and more debuggable than wezterm's binary mux protocol
- Template-based status bar config is more accessible than requiring Lua scripting
- Ghostty's GPU-accelerated rendering is a significant advantage to maintain
- Keep the embedded apprt pattern but add a daemon mode that the apprt can connect to
