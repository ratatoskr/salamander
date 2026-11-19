//! Waiting on an address, for blocking locks without spinning.

const std = @import("std");
const linux = std.os.linux;

/// Waits while `ptr` holds `expect`, or till `timeout_ms` is up. Can wake early.
pub fn wait(ptr: *const std.atomic.Value(u32), expect: u32, timeout_ms: ?u32) void {
    var ts: linux.timespec = undefined;
    if (timeout_ms) |ms| ts = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms) };
    _ = linux.futex_4arg(ptr, .{ .cmd = .WAIT, .private = true }, expect, if (timeout_ms != null) &ts else null);
}

pub fn wake(ptr: *const std.atomic.Value(u32), all: bool) void {
    _ = linux.futex_3arg(ptr, .{ .cmd = .WAKE, .private = true }, if (all) std.math.maxInt(i32) else 1);
}
