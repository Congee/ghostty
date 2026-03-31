//! AppExt extends the core App with custom tab/split management.
//!
//! This module contains all our custom additions to App that are not in
//! upstream ghostty. When ghostty becomes a submodule, App.zig stays
//! upstream-clean and this module wraps it.
//!
//! Usage:
//!   const ext = AppExt.from(core_app);  // recover from *App pointer
//!   ext.selectTab(1);
//!   ext.active_tab_index;
//!
//! The AppExt is allocated to contain the App by value. The *App pointer
//! returned to callers points into AppExt.app, and @fieldParentPtr
//! recovers the AppExt.

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const apprt = @import("apprt.zig");

const AppExt = @This();

/// The upstream App, embedded by value.
app: App,

/// The currently active (selected) tab index.
active_tab_index: ?usize = null,

/// The insertion index for the next new tab.
pending_tab_index: ?usize = null,

/// When true, the next addSurface with .split context is treated as .tab.
pending_new_tab: bool = false,

/// The direction for the next split.
pending_split_direction: ?App.SurfaceSplitTree.Split.Direction = null,

pub const NewTabPosition = enum { current, end };
pub const CloseTabResult = enum { closed, needs_confirm };

/// Recover AppExt from a *App pointer (which points to self.app).
pub fn from(core: *App) *AppExt {
    return @fieldParentPtr("app", core);
}

/// Const version.
pub fn fromConst(core: *const App) *const AppExt {
    return @fieldParentPtr("app", core);
}

// ── Tab Management ──

/// Select a tab by index. Returns true if selection changed.
pub fn selectTab(self: *AppExt, index: usize) bool {
    if (index >= self.app.tabs.items.len) return false;
    if (self.active_tab_index == index) return false;
    self.active_tab_index = index;

    const tab = &self.app.tabs.items[index];
    if (tab.representativeSurface()) |surface| {
        self.app.focused_surface = surface;
    }
    self.app.sendTabsUpdate();
    return true;
}

/// Move a tab from one index to another. Returns true if moved.
pub fn moveTab(self: *AppExt, from_idx: usize, to_idx: usize) bool {
    if (from_idx >= self.app.tabs.items.len) return false;
    if (to_idx >= self.app.tabs.items.len) return false;
    if (from_idx == to_idx) return false;

    const tab = self.app.tabs.orderedRemove(from_idx);
    self.app.tabs.insert(self.app.alloc, to_idx, tab) catch return false;

    if (self.active_tab_index) |active| {
        if (active == from_idx) {
            self.active_tab_index = to_idx;
        } else if (from_idx < active and active <= to_idx) {
            self.active_tab_index = active - 1;
        } else if (to_idx <= active and active < from_idx) {
            self.active_tab_index = active + 1;
        }
    }
    self.app.sendTabsUpdate();
    return true;
}

/// Close a tab by index.
pub fn closeTab(self: *AppExt, index: usize) CloseTabResult {
    if (index >= self.app.tabs.items.len) return .closed;
    const tab = &self.app.tabs.items[index];

    var it = tab.surfaceIterator();
    while (it.next()) |rt_surface| {
        const cs = rt_surface.surface.core() orelse continue;
        if (cs.needsConfirmQuit()) return .needs_confirm;
    }

    var surfaces_buf: [64]*apprt.Surface = undefined;
    var count: usize = 0;
    var it2 = tab.surfaceIterator();
    while (it2.next()) |rt_surface| {
        if (count < surfaces_buf.len) {
            surfaces_buf[count] = rt_surface;
            count += 1;
        }
    }
    for (surfaces_buf[0..count]) |rt_surface| {
        self.app.deleteSurface(rt_surface);
    }
    return .closed;
}

/// Close all tabs except the one at the given index.
pub fn closeOtherTabs(self: *AppExt, except: usize) CloseTabResult {
    if (except >= self.app.tabs.items.len) return .closed;

    for (self.app.tabs.items, 0..) |*tab, i| {
        if (i == except) continue;
        var it = tab.surfaceIterator();
        while (it.next()) |rt_surface| {
            const cs = rt_surface.surface.core() orelse continue;
            if (cs.needsConfirmQuit()) return .needs_confirm;
        }
    }

    var i: usize = self.app.tabs.items.len;
    while (i > 0) {
        i -= 1;
        if (i == except) continue;
        _ = self.closeTab(i);
    }
    return .closed;
}

/// Close all tabs after the given index.
pub fn closeTabsAfter(self: *AppExt, after: usize) CloseTabResult {
    if (after >= self.app.tabs.items.len) return .closed;

    for (self.app.tabs.items[after + 1 ..]) |*tab| {
        var it = tab.surfaceIterator();
        while (it.next()) |rt_surface| {
            const cs = rt_surface.surface.core() orelse continue;
            if (cs.needsConfirmQuit()) return .needs_confirm;
        }
    }

    var i: usize = self.app.tabs.items.len;
    while (i > after + 1) {
        i -= 1;
        _ = self.closeTab(i);
    }
    return .closed;
}

/// Compute where a new tab should be inserted.
pub fn resolveNewTabIndex(self: *const AppExt, position: NewTabPosition) usize {
    return switch (position) {
        .current => if (self.active_tab_index) |idx|
            @min(idx + 1, self.app.tabs.items.len)
        else
            self.app.tabs.items.len,
        .end => self.app.tabs.items.len,
    };
}

/// Find a tab by its unique ID.
pub fn tabForId(self: *AppExt, id: u32) ?*App.Tab {
    for (self.app.tabs.items) |*tab| {
        if (tab.id == id) return tab;
    }
    return null;
}

// ── Split Operations ──

/// Resize a split pane by a ratio (-1..1).
pub fn resizeSplit(
    self: *AppExt,
    rt_surface: *apprt.Surface,
    layout: App.SurfaceSplitTree.Split.Layout,
    ratio: f16,
) !bool {
    const tab = self.tabForRtSurface(rt_surface) orelse return false;
    const handle = tab.findHandle(rt_surface) orelse return false;
    const new_tree = try tab.tree.resize(self.app.alloc, handle, layout, ratio);
    tab.tree.deinit();
    tab.tree = new_tree;
    tab.tree_version +%= 1;
    return true;
}

/// Equalize all splits in the tab containing the given surface.
pub fn equalizeSplits(self: *AppExt, rt_surface: *apprt.Surface) !bool {
    const tab = self.tabForRtSurface(rt_surface) orelse return false;
    const new_tree = try tab.tree.equalize(self.app.alloc);
    tab.tree.deinit();
    tab.tree = new_tree;
    tab.tree_version +%= 1;
    return true;
}

/// Toggle zoom on the focused surface within its tab.
pub fn toggleZoom(self: *AppExt, rt_surface: *apprt.Surface) bool {
    const tab = self.tabForRtSurface(rt_surface) orelse return false;
    const handle = tab.findHandle(rt_surface) orelse return false;
    if (tab.tree.zoomed) |z| {
        if (z == handle) {
            tab.tree.zoom(null);
        } else {
            tab.tree.zoom(handle);
        }
    } else {
        tab.tree.zoom(handle);
    }
    tab.tree_version +%= 1;
    return true;
}

/// Update a split ratio in-place (interactive drag resize).
pub fn resizeSplitInPlace(
    self: *AppExt,
    rt_surface: *apprt.Surface,
    handle: App.SurfaceSplitTree.Node.Handle,
    ratio: f16,
) void {
    const tab = self.tabForRtSurface(rt_surface) orelse return;
    tab.tree.resizeInPlace(handle, ratio);
}

/// Find the tab containing the given apprt surface.
fn tabForRtSurface(self: *AppExt, rt_surface: *apprt.Surface) ?*App.Tab {
    for (self.app.tabs.items) |*tab| {
        if (tab.findHandle(rt_surface) != null) return tab;
    }
    return null;
}
