/// Build configuration for the ghostty-daemon standalone executable.
/// Uses the pre-built vt module from GhosttyZig for terminal emulation.
const GhosttyDaemon = @This();

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("Config.zig");

/// The daemon executable.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

pub fn init(
    b: *std.Build,
    cfg: *const Config,
    vt_mod: *std.Build.Module,
    gsp_mod: *std.Build.Module,
) !GhosttyDaemon {
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

    // Add the pre-built terminal module for full VT emulation
    exe.root_module.addImport("vt", vt_mod);

    // Add the GSP protocol module (shared with main exe CLI)
    exe.root_module.addImport("gsp", gsp_mod);

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
