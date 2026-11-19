//! Waiting on an address, for blocking locks without spinning.

const std = @import("std");
const windows = std.os.windows;

/// Waits while `ptr` holds `expect`, or till `timeout_ms` is up. Can wake early.
pub fn wait(ptr: *const std.atomic.Value(u32), expect: u32, timeout_ms: ?u32) void {
    var timeout: windows.LARGE_INTEGER = 0;
    // Relative, in 100ns units
    if (timeout_ms) |ms| timeout = -@as(windows.LARGE_INTEGER, ms) * 10_000;
    _ = windows.ntdll.RtlWaitOnAddress(ptr, &expect, @sizeOf(u32), if (timeout_ms != null) &timeout else null);
}

pub fn wake(ptr: *const std.atomic.Value(u32), all: bool) void {
    if (all) windows.ntdll.RtlWakeAddressAll(ptr) else windows.ntdll.RtlWakeAddressSingle(ptr);
}
