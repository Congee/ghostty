//! Reads output from a session's PTY, parses VT sequences to update the
//! cell grid, and pushes delta updates to the attached client. One PtyReader
//! runs per active session in its own thread.
const PtyReader = @This();

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Protocol = @import("Protocol.zig");
const SessionManager = @import("SessionManager.zig");
const VtParser = @import("VtParser.zig");

const log = std.log.scoped(.pty_reader);

alloc: Allocator,
session_mgr: *SessionManager,
session_id: u32,
thread: ?std.Thread = null,
running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

/// The fd of the currently attached client (for pushing deltas).
/// Null means no client is attached — we still parse output to keep
/// the cell grid current.
client_fd: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

pub fn init(
    alloc: Allocator,
    session_mgr: *SessionManager,
    session_id: u32,
) PtyReader {
    return .{
        .alloc = alloc,
        .session_mgr = session_mgr,
        .session_id = session_id,
    };
}

/// Start the reader thread.
pub fn start(self: *PtyReader) !void {
    self.running.store(true, .release);
    self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
}

/// Stop the reader thread and wait for it to exit.
pub fn stop(self: *PtyReader) void {
    self.running.store(false, .release);
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
}

/// Set the attached client fd for delta pushing. -1 = no client.
pub fn setClientFd(self: *PtyReader, fd: posix.fd_t) void {
    self.client_fd.store(fd, .release);
}

fn readLoop(self: *PtyReader) void {
    log.info("pty reader started for session {}", .{self.session_id});
    defer log.info("pty reader stopped for session {}", .{self.session_id});

    // Get the PTY fd (need lock)
    self.session_mgr.lock();
    const session = self.session_mgr.getSession(self.session_id) orelse {
        self.session_mgr.unlock();
        log.err("session {} not found", .{self.session_id});
        return;
    };
    const pty_fd = session.pty_fd orelse {
        self.session_mgr.unlock();
        log.err("session {} has no pty", .{self.session_id});
        return;
    };
    const rows = session.rows;
    self.session_mgr.unlock();

    var parser = VtParser.init(rows);
    var buf: [4096]u8 = undefined;

    while (self.running.load(.acquire)) {
        // Use poll to check for data with a timeout so we can check running flag
        var pfd = [1]std.posix.pollfd{.{
            .fd = pty_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const poll_result = std.posix.poll(&pfd, 100) catch |err| {
            log.warn("poll error session {}: {}", .{ self.session_id, err });
            break;
        };

        if (poll_result == 0) continue; // Timeout, check running flag

        if (pfd[0].revents & std.posix.POLL.HUP != 0) {
            // PTY closed — child process exited
            self.session_mgr.lock();
            if (self.session_mgr.getSession(self.session_id)) |s| {
                s.child_exited = true;
            }
            self.session_mgr.unlock();
            log.info("pty hangup for session {}", .{self.session_id});
            break;
        }

        if (pfd[0].revents & std.posix.POLL.IN == 0) continue;

        const n = posix.read(pty_fd, &buf) catch |err| {
            if (!self.running.load(.acquire)) break;
            log.warn("pty read error session {}: {}", .{ self.session_id, err });
            break;
        };
        if (n == 0) {
            // EOF
            self.session_mgr.lock();
            if (self.session_mgr.getSession(self.session_id)) |s| {
                s.child_exited = true;
            }
            self.session_mgr.unlock();
            break;
        }

        // Parse VT output under lock, serialize delta, then release lock
        // before doing blocking socket I/O to avoid deadlock.
        var delta_payload: ?[]u8 = null;
        var delta_fd: posix.fd_t = -1;

        self.session_mgr.lock();
        if (self.session_mgr.getSession(self.session_id)) |s| {
            parser.feed(s, buf[0..n]);

            const cfd = self.client_fd.load(.acquire);
            if (cfd >= 0) {
                delta_payload = s.serializeDelta(self.alloc) catch null;
                delta_fd = cfd;
            }
        }
        self.session_mgr.unlock();

        // Send delta outside the lock
        if (delta_payload) |payload| {
            defer self.alloc.free(payload);
            const encoded = Protocol.encode(self.alloc, .delta, payload) catch continue;
            defer self.alloc.free(encoded);
            Protocol.writeMessage(delta_fd, encoded) catch |err| {
                log.warn("delta push failed for session {}: {}", .{ self.session_id, err });
                self.client_fd.store(-1, .release);
            };
        }
    }
}

// ── Tests ──

test "PtyReader init" {
    const alloc = std.testing.allocator;
    var mgr = SessionManager.initTest(alloc);
    defer mgr.deinit();

    _ = try mgr.createSession(80, 24, null);

    var reader = PtyReader.init(alloc, &mgr, 1);
    try std.testing.expectEqual(@as(u32, 1), reader.session_id);
    try std.testing.expect(!reader.running.load(.acquire));
    try std.testing.expect(reader.client_fd.load(.acquire) == -1);
    _ = &reader;
}
