# Restructure: Ghostty as Submodule, Our Code Separate

## Context

We modified upstream `App.zig` with +443 lines. Rebasing is painful. Goal: upstream ghostty as a git submodule (unmodified), our custom code in separate directories.

## Repo Structure

```
Congee/ghostty/                    ← our repo (keep)
├── ghostty/                       ← git submodule (upstream ghostty-org/ghostty)
├── src/                           ← our code (AppExt, ControlSocket, CLI)
│   ├── AppExt.zig                 ← tab/split management wrapping upstream App
│   ├── ControlSocket.zig          ← our control socket (moved from ghostty/src/)
│   └── cli/
│       └── cmd.zig                ← ghostty +cmd CLI
├── apprt/
│   └── gtk/                       ← our GTK apprt (moved from ghostty/src/apprt/gtk/)
│       ├── class/
│       │   ├── split_tree.zig
│       │   ├── application.zig
│       │   └── window.zig
│       └── ui/
│           └── 1.5/
│               ├── split-tree.blp
│               └── window.blp
├── macos/                         ← our macOS code (Swift)
├── test/                          ← our tests
├── research/                      ← design docs
└── build.zig                      ← our build that imports ghostty's build
```

## Key Design Decision: AppExt via `@fieldParentPtr`

Zig has no inheritance. Callers access upstream `App` fields directly (`app.tabs`, `app.alloc`). We can't transparently replace `App`.

**Solution**: Allocate `AppExt` which contains the upstream `App` as a field. Return `&self.app` to callers. When our code needs the extension, recover it via `@fieldParentPtr`:

```zig
// src/AppExt.zig
const AppExt = @This();
const CoreApp = @import("ghostty").App;

app: CoreApp,  // upstream App embedded by value

// Our extra state
active_tab_index: ?usize = null,
pending_tab_index: ?usize = null,
pending_new_tab: bool = false,
pending_split_direction: ?CoreApp.SurfaceSplitTree.Split.Direction = null,

/// Recover AppExt from a *CoreApp pointer
pub fn from(core: *CoreApp) *AppExt {
    return @fieldParentPtr("app", core);
}

/// Our custom methods
pub fn selectTab(self: *AppExt, index: usize) bool { ... }
pub fn moveTab(self: *AppExt, from: usize, to: usize) bool { ... }
pub fn closeTab(self: *AppExt, index: usize) CloseTabResult { ... }
// ... etc
```

**Caller pattern**:
```zig
// For upstream methods — use *App directly (no change needed)
const app = Application.default().core();  // returns *CoreApp
app.focusSurface(surface);

// For our methods — recover AppExt
const ext = AppExt.from(app);
ext.selectTab(1);
ext.active_tab_index;
```

**main_ghostty.zig**:
```zig
// Allocate AppExt (which contains CoreApp)
const ext = try alloc.create(AppExt);
try ext.app.init(alloc);  // init the upstream App inside
const app: *CoreApp = &ext.app;
try app_runtime.init(app, .{});
```

## What Moves Where

| Current location | New location | Notes |
|---|---|---|
| `src/App.zig` additions | `src/AppExt.zig` | 4 fields, 17 methods |
| `src/App.zig` (upstream) | `ghostty/src/App.zig` | Unmodified, in submodule |
| `src/Surface.zig` fix | Patch file or keep in-tree | 1-line UAF fix |
| `src/ControlSocket.zig` | `src/ControlSocket.zig` | Uses `AppExt.from(app)` |
| `src/cli/cmd.zig` | `src/cli/cmd.zig` | No change |
| `src/apprt/gtk/class/*.zig` | `apprt/gtk/class/*.zig` | Uses `AppExt.from(core_app)` for custom methods |
| `macos/` | `macos/` | No change |

## Migration Steps

### Step 1: Add ghostty as submodule
```bash
git submodule add https://github.com/ghostty-org/ghostty.git ghostty
cd ghostty && git checkout <pinned-tag>
```

### Step 2: Clean up — delete upstream files from our repo
Remove everything that now lives in the submodule:
- `src/` — all upstream Zig source (Surface.zig, terminal/, renderer/, font/, etc.)
- `include/` — C headers
- `pkg/`, `nix/`, `.github/` — upstream build/CI
- Keep ONLY our custom files (ControlSocket.zig, cli/cmd.zig, apprt/gtk changes)
- Move our custom files to top-level `src/` (not under ghostty/)

### Step 3: Create AppExt.zig
- Move 4 fields and 17 methods from App.zig
- Add `from(*CoreApp) *AppExt` using `@fieldParentPtr`
- Wrap `addSurface` to handle `pending_new_tab` override

### Step 3: Create our build.zig
- Import ghostty's build system as a dependency
- Add our source files to the compilation
- Link against libghostty from the submodule

### Step 4: Update callers
- `core_app.selectTab()` → `AppExt.from(core_app).selectTab()`
- `core_app.active_tab_index` → `AppExt.from(core_app).active_tab_index`
- Direct `app.tabs`, `app.alloc` etc. stay unchanged (upstream fields)

### Step 5: Revert upstream modifications
- Remove our changes from `ghostty/src/App.zig`
- Remove our changes from `ghostty/src/Surface.zig` (keep as patch)
- Remove our GTK apprt changes from `ghostty/src/apprt/gtk/`

### Step 6: Wire main_ghostty.zig
- Allocate `AppExt` instead of `App`
- Pass `&ext.app` to the apprt

## What Stays Patched in Submodule

- `Surface.zig`: 1-line title UAF fix (apply as patch on submodule update)
- Nothing else

## Build System

```zig
// build.zig (ours)
const ghostty_dep = b.dependency("ghostty", .{});
// Import ghostty's Zig modules
// Link our code + ghostty's libghostty
// Produce our binary
```

Details TBD — need to study ghostty's build.zig export structure.

## Verification

1. `zig build -Dapp-runtime=gtk` compiles with submodule
2. Launch ghostty, shell works, type exit → window closes
3. `ghostty +cmd ping` → PONG
4. `ghostty +cmd get-text` → screen content
5. Tab operations work via control socket
6. `git diff ghostty/` shows zero modifications to submodule
7. `zig build test` passes
