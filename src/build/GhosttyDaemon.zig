/// Build configuration for the ghostty-daemon standalone executable.
/// The daemon is intentionally lightweight — it only needs libc for
/// PTY operations and does not depend on SharedDeps (no fonts, renderers, etc.).
const GhosttyDaemon = @This();

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("Config.zig");

/// The daemon executable.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config) !GhosttyDaemon {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "ghostty-daemon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon/main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
            .omit_frame_pointer = cfg.strip,
            .unwind_tables = if (cfg.strip) .none else .sync,
        }),
        .use_llvm = true,
    });

    // The daemon needs libc for PTY operations (openpty, fork, execve, etc.)
    exe.linkLibC();

    // On macOS/Darwin, add Apple SDK paths for system headers (util.h, etc.)
    if (cfg.target.result.os.tag.isDarwin()) {
        try @import("apple_sdk").addPaths(b, exe);
    }

    const install_step = b.addInstallArtifact(exe, .{});

    return .{
        .exe = exe,
        .install_step = install_step,
    };
}

/// Add the daemon to the default install target.
pub fn install(self: *const GhosttyDaemon) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}
