//! Bonjour (DNS-SD) service registration for the daemon. Advertises the
//! ghostty-daemon TCP service on the local network so iOS clients can
//! discover it automatically without entering an IP address.
//!
//! Service type: _ghostty._tcp
//!
//! Uses `dns-sd` CLI tool as a subprocess for maximum compatibility
//! (works in Nix environments where direct dns_sd.h calls fail).
const Bonjour = @This();

const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.bonjour);

/// The dns-sd subprocess PID.
child_pid: ?std.c.pid_t = null,

/// Register the ghostty-daemon service on the given port.
/// Spawns `dns-sd -R` as a background subprocess.
pub fn register(self: *Bonjour, port: u16) void {
    var port_buf: [6]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{}", .{port}) catch return;
    // Null-terminate
    var port_z: [6:0]u8 = .{ 0, 0, 0, 0, 0, 0 };
    @memcpy(port_z[0..port_str.len], port_str);

    const pid = std.c.fork();
    if (pid < 0) {
        log.warn("Bonjour: fork failed", .{});
        return;
    }
    if (pid == 0) {
        // Child: exec dns-sd
        const argv = [_:null]?[*:0]const u8{
            "dns-sd",
            "-R",
            "ghostty-daemon",
            "_ghostty._tcp",
            "local",
            &port_z,
        };
        _ = std.c.execve("/usr/bin/dns-sd", &argv, std.c.environ);
        std.c.exit(1);
    }

    self.child_pid = pid;
    log.info("Bonjour: registered _ghostty._tcp on port {} (pid={})", .{ port, pid });
}

/// Unregister the service by killing the dns-sd subprocess.
pub fn unregister(self: *Bonjour) void {
    if (self.child_pid) |pid| {
        _ = std.c.kill(pid, std.c.SIG.TERM);
        _ = std.c.waitpid(pid, null, 0);
        self.child_pid = null;
        log.info("Bonjour: unregistered", .{});
    }
}

// ── Tests ──

test "Bonjour struct init" {
    var b: Bonjour = .{};
    try std.testing.expect(b.child_pid == null);
    _ = &b;
}
