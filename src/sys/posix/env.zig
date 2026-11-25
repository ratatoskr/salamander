//! The process's environment variables. Needs libc.

const std = @import("std");

pub fn get(a: std.mem.Allocator, name: []const u8) error{OutOfMemory}!?[]u8 {
    var buf: [256:0]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const value = std.c.getenv(buf[0..name.len :0].ptr) orelse return null;
    return try a.dupe(u8, std.mem.span(value));
}
