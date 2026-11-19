//! Waiting on an address, for blocking locks without spinning. `__ulock` is what libc++ and Zig use too.

const std = @import("std");
const c = std.c;

/// Waits while `ptr` holds `expect`, or till `timeout_ms` is up. Can wake early.
pub fn wait(ptr: *const std.atomic.Value(u32), expect: u32, timeout_ms: ?u32) void {
    // In microseconds, where 0 is forever
    const us: u32 = if (timeout_ms) |ms| @max(1, ms *| 1000) else 0;
    _ = c.__ulock_wait(.{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true }, ptr, expect, us);
}

pub fn wake(ptr: *const std.atomic.Value(u32), all: bool) void {
    _ = c.__ulock_wake(.{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true, .WAKE_ALL = all }, ptr, 0);
}
