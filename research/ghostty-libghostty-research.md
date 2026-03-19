# Ghostty & libghostty Research Summary

## 1. What is libghostty?

**libghostty** is Ghostty's C-compatible library for embedding terminal emulation. It exists in two forms:

### libghostty (full embedding API)
- Exposes a **C API** via `include/ghostty.h` with opaque types: `ghostty_app_t`, `ghostty_config_t`, `ghostty_surface_t`
- Functions include: `ghostty_app_new`, `ghostty_app_tick`, `ghostty_surface_new`, `ghostty_surface_draw`, `ghostty_surface_key`, config management, etc.
- **Currently NOT a general-purpose embedding API.** The header literally says: *"This currently isn't supported as a general purpose embedding API. This is currently used only to embed ghostty within a macOS app."*
- The macOS Ghostty app is a real consumer: it's a native Swift/SwiftUI app that links to libghostty and uses the C API.
- The embedded apprt (`src/apprt/embedded.zig`) uses a callback-based architecture: the host app provides function pointers for `wakeup`, `action`, `read_clipboard`, `write_clipboard`, `close_surface`, etc.

### libghostty-vt (new, modular library)
- Announced September 2025 via [blog post](https://mitchellh.com/writing/libghostty-is-coming)
- **Zero-dependency** (not even libc), provides VT parsing + terminal state management
- C headers at `include/ghostty/vt.h`, `include/ghostty/vt/terminal.h`, etc.
- API: `ghostty_terminal_new`, `ghostty_terminal_free`, scroll, formatters (plain text/HTML/VT), key/mouse encoding, SGR/OSC parsing
- Available for Zig and C; targets macOS, Linux, Windows, WebAssembly
- **API is NOT stable yet** -- no official release tagged
- Designed for embedding in editors, multiplexers, web apps, CI log viewers, etc.

### Stability Assessment
- The full libghostty is **internal-only** in practice (macOS app consumer)
- libghostty-vt is **early-stage public** but unstable API
- Mitchell explicitly noted RenderState "can be used to create your own renderers... even useful for text like a tmux clone"

---

## 2. Ghostty Architecture

**Language:** Zig (47.5k stars, MIT license)

### Core/Shell Split
Ghostty has a clean separation between the **core engine** (Zig) and **platform GUI shells**:

- **Core** (`src/`): Terminal emulation, VT parsing, font rendering, GPU renderer, config, pty management
  - `src/Surface.zig` -- A terminal "surface" (widget). Doesn't know if it's a window, tab, or split pane. Owns a pty session.
  - `src/App.zig` -- Application-level state
  - `src/terminal/` -- VT emulator, screen, scrollback
  - `src/font/` -- Font discovery, shaping, atlas
  - `src/renderer/` -- GPU rendering (Metal, OpenGL)

- **Application Runtimes** (`src/apprt/`):
  - `embedded.zig` -- For macOS (Swift host calls into C API)
  - `gtk.zig` -- Linux native GTK app
  - `browser.zig` -- WebAssembly/browser
  - `none.zig` -- Headless/testing

- **Platform GUI shells**:
  - macOS: Native Swift/SwiftUI app in `macos/` directory, uses Metal renderer
  - Linux: GTK-based, built directly from Zig
  - The `apprt.Action` union defines all actions (quit, new_window, new_tab, new_split, close_tab, toggle_fullscreen, etc.) with C ABI compatibility

### Key Architectural Insight
The `Surface` abstraction is deliberately agnostic about windowing. The comment says: *"The word 'surface' is used because it is left to the higher level application runtime to determine if the surface is a window, a tab, a split, a preview pane in a larger window, etc."*

---

## 3. Multiplexer / Session Persistence

### Current State: NO built-in multiplexer or session persistence

- **No issues or discussions** about built-in session persistence/detach functionality
- Ghostty has **no session restore** (sessions die with the terminal process)
- There is **no detach/reattach** mechanism

### Related Community Activity
- **Discussion #11234** -- Someone is building a terminal multiplexer using libghostty-vt as the VT engine (server-side headless Terminals, transmitting cell data to clients via Unix socket/SSH). Mitchell confirmed the approach is viable using Zig's lack of access boundaries.
- **Discussion #10267** -- "Native SSH Session Inheritance" -- users want new splits to inherit SSH sessions. Not implemented.
- **Discussion #11479** -- "Ghostty, tmux and agents" -- Users note that tmux provides session-level programmability that Ghostty lacks. Mitchell posted on X about users confounding Ghostty and tmux.
- **Discussion #10576** -- "Detach a split into a new window?" -- basic split-to-window requested

### Mitchell's Position
Based on discussions, Mitchell views Ghostty as a terminal emulator (not a multiplexer). The tmux/mux functionality is explicitly out of scope for Ghostty itself. The approach is to make libghostty good enough that others can build multiplexers on top.

---

## 4. Plugin / Extension System

### Current State: NO plugin system exists

- **Discussion #2353** -- "Scripting API for Ghostty" is the central discussion
  - Mitchell is leaning toward a **single-line text protocol** (memcached/redis style) over Unix sockets or TCP
  - Benefits: easy to debug (telnet), easy API clients, supports TLS
  - Community also proposed HTTP+JSON over Unix sockets
  - **Not yet implemented** -- Mitchell said "I'm not ready to commit to working on these yet"
- **Issue #1358** -- Proposal for dynamically linked plugins (referenced by Mitchell in #2353)
- **Discussion #2421** -- "Statusbar widget" -- Mitchell commented: *"For future note when we support a plugin system, 'status bar widget' is also a great place for plugins to expose themselves."*
- **Discussion #11603** -- "Semantic OSC exposed to C API" -- requests for more API surface

### Summary
No plugin system exists. A scripting/control API is planned but not started. The direction will likely be a text protocol over sockets, not an in-process plugin system.

---

## 5. Tabs / Splits Implementation

### Current State: Fully implemented

Ghostty supports **multi-window, tabs, and splits** on both macOS and Linux (GTK).

- **SplitTree** (`src/datastruct/split_tree.zig`) -- An immutable tree data structure for splits
  - Supports arbitrary horizontal/vertical splitting
  - Immutable structure with history for undo/redo
  - Views implement reference counting
  - Supports "zoomed" nodes (fullscreen a single pane)

- **Actions available** (from `src/apprt/action.zig`):
  - `new_window`, `new_tab`, `close_tab`
  - `new_split` (with direction: left/right/up/down)
  - `toggle_tab_overview`
  - `toggle_maximize`, `toggle_fullscreen`
  - Split navigation, resizing, equalization

- Tabs and splits are managed by the **apprt layer** (GTK or macOS Swift), not the core

---

## 6. Status Bar

### Current State: NO status bar exists

- **Discussion #2421** -- "Statusbar widget" is the primary discussion
  - Proposed widgets: pending key, date/time, terminal size, cursor position, modifier state, CPU/memory usage
  - Proposed config: `status-bar = on/off`, `status-bar-widgets = ...`, `status-bar-location = top/bottom`
  - Mitchell acknowledged it as a good candidate for the future plugin system
  - **Not implemented**

---

## 7. Decision Analysis: Fork vs. Build on libghostty

### Option A: Fork Ghostty Entirely

**Pros:**
- Get the full terminal emulator for free (VT, rendering, font, config, tabs/splits)
- MIT license allows full forking
- Mature, battle-tested codebase (47k+ stars)
- Already has the Surface abstraction and SplitTree

**Cons:**
- Must maintain a fork against an active upstream (significant ongoing burden)
- Ghostty is written in Zig -- requires Zig expertise for all modifications
- Adding session persistence requires deep changes to Surface/pty lifecycle
- Adding a status bar requires modifying platform-specific apprt code (Swift for macOS, GTK for Linux)
- The macOS app is built with Xcode/Swift -- need Swift + Zig expertise
- Risk of diverging too far from upstream to merge back

### Option B: Build New Terminal Using libghostty-vt as Core Engine

**Pros:**
- Clean architecture from the start, designed for your specific needs
- libghostty-vt is explicitly designed for this use case (Mitchell encourages it)
- Someone is already building a multiplexer this way (Discussion #11234)
- Can choose your own GUI toolkit (Swift, Rust+winit, Electron, etc.)
- Session persistence can be designed in from day one (server/client architecture)
- Status bar is just another UI component you control
- Smaller dependency surface -- just the VT library

**Cons:**
- libghostty-vt API is unstable and incomplete
- You must build: GPU renderer, font stack, pty management, config system, window management, tabs/splits UI
- The full libghostty (not just -vt) could help but it's not a public API
- Significant development effort to reach feature parity with a real terminal

### Option C: Build on Full libghostty (embedded apprt)

**Pros:**
- Get rendering, font, pty, config for free via the C API
- The macOS app already proves this works (Swift host + libghostty)
- You write the GUI shell and add session persistence + status bar at the shell level
- Can use the existing embedded.zig apprt callbacks

**Cons:**
- The full C API is explicitly "not a general purpose embedding API" yet
- API surface is oriented toward macOS Swift app needs
- Would need to track Ghostty's internal API changes (no stability guarantees)
- Still requires understanding Ghostty internals deeply

### Recommendation

**Option C (build on full libghostty embedded API) is the most promising path**, with a fallback to a shallow fork if the API proves too limiting. Rationale:

1. The macOS app already validates this architecture (Swift app consuming libghostty via C API)
2. Session persistence is fundamentally a shell-level concern (managing pty lifecycles, serializing state) -- it belongs in the host app, not the core
3. A status bar is purely UI -- it belongs in the host app
4. You avoid maintaining a full fork while getting the hard parts (VT emulation, rendering, fonts) for free
5. If the C API gaps are too large, you can selectively patch libghostty (much smaller diff than a full fork)

The main risk is API instability. Mitigate by: pinning to a specific Ghostty commit, wrapping the C API in your own abstraction layer, and engaging with the Ghostty community on API needs.

---

## Key GitHub References

| Topic | URL |
|-------|-----|
| Scripting API discussion | https://github.com/ghostty-org/ghostty/discussions/2353 |
| Statusbar widget | https://github.com/ghostty-org/ghostty/discussions/2421 |
| RenderState export/import (mux builder) | https://github.com/ghostty-org/ghostty/discussions/11234 |
| Native SSH session inheritance | https://github.com/ghostty-org/ghostty/discussions/10267 |
| Ghostty + tmux + agents | https://github.com/ghostty-org/ghostty/discussions/11479 |
| libghostty-vt C API discussion | https://github.com/ghostty-org/ghostty/discussions/11348 |
| Detach split into window | https://github.com/ghostty-org/ghostty/discussions/10576 |
| Dynamic plugins proposal | https://github.com/ghostty-org/ghostty/issues/1358 |
| libghostty blog post | https://mitchellh.com/writing/libghostty-is-coming |
| Embedded apprt (C API impl) | `src/apprt/embedded.zig` |
| C header | `include/ghostty.h` |
| VT library headers | `include/ghostty/vt/*.h` |
| SplitTree data structure | `src/datastruct/split_tree.zig` |
| Surface (terminal widget) | `src/Surface.zig` |
| Action definitions | `src/apprt/action.zig` |
