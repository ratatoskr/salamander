//! The process's environment variables.

const std = @import("std");

extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, size: u32) callconv(.winapi) u32;

pub fn get(a: std.mem.Allocator, name: []const u8) error{OutOfMemory}!?[]u8 {
    var name_buf: [256:0]u16 = undefined;
    if (name.len >= name_buf.len) return null;
    const n = std.unicode.wtf8ToWtf16Le(&name_buf, name) catch return null;
    name_buf[n] = 0;
    const wide_name = name_buf[0..n :0].ptr;
    // Asks for the size first, then again if it grew in between
    var size = GetEnvironmentVariableW(wide_name, null, 0);
    while (size != 0) {
        const buf = try a.alloc(u16, size);
        defer a.free(buf);
        const got = GetEnvironmentVariableW(wide_name, buf.ptr, size);
        if (got == 0) return null;
        if (got < size) return try std.unicode.wtf16LeToWtf8Alloc(a, buf[0..got]);
        size = got;
    }
    return null;
}
