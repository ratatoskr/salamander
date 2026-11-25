//! Reading the registry.

const std = @import("std");

const HKEY = *opaque {};
extern "advapi32" fn RegGetValueW(key: HKEY, sub_key: ?[*:0]const u16, value: ?[*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;

pub const Root = enum(usize) {
    current_user = 0x80000001,
    local_machine = 0x80000002,
};

/// Which view of the registry, since 32-bit programs see a different SOFTWARE key.
pub const View = enum { native, bits32, bits64 };

const RRF_RT_REG_SZ = 0x2;
const RRF_SUBKEY_WOW6464KEY = 0x10000;
const RRF_SUBKEY_WOW6432KEY = 0x20000;

/// A string value as UTF-8, or null if it isn't there or isn't a string. Free with `a`.
pub fn string(a: std.mem.Allocator, root: Root, key: []const u8, value: []const u8, view: View) error{OutOfMemory}!?[]u8 {
    const wide_key = std.unicode.wtf8ToWtf16LeAllocZ(a, key) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else null;
    defer a.free(wide_key);
    const wide_value = std.unicode.wtf8ToWtf16LeAllocZ(a, value) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else null;
    defer a.free(wide_value);
    const flags: u32 = RRF_RT_REG_SZ | @as(u32, switch (view) {
        .native => 0,
        .bits32 => RRF_SUBKEY_WOW6432KEY,
        .bits64 => RRF_SUBKEY_WOW6464KEY,
    });
    const hkey: HKEY = @ptrFromInt(@backingInt(root));
    var size: u32 = 0;
    // Asks for the size first, then again if it grew in between
    if (RegGetValueW(hkey, wide_key, wide_value, flags, null, null, &size) != 0) return null;
    while (true) {
        const buf = try a.alloc(u16, size / 2 + 1);
        defer a.free(buf);
        var got: u32 = @intCast(buf.len * 2);
        const err = RegGetValueW(hkey, wide_key, wide_value, flags, null, buf.ptr, &got);
        const ERROR_MORE_DATA = 234;
        if (err == ERROR_MORE_DATA) {
            size = got;
            continue;
        }
        if (err != 0) return null;
        // The size counts the terminating zero
        const text = std.mem.sliceTo(buf[0 .. got / 2], 0);
        return try std.unicode.wtf16LeToWtf8Alloc(a, text);
    }
}

test "reads a string value" {
    const a = std.testing.allocator;
    const got = (try string(a, .local_machine, "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", "SystemRoot", .native)).?;
    defer a.free(got);
    try std.testing.expect(std.ascii.endsWithIgnoreCase(got, "windows"));
    try std.testing.expectEqual(null, try string(a, .local_machine, "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", "NotAValueAtAll", .native));
}
