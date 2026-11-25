//! Loading shared libraries and finding what they export. Needs libc for dlopen.

const std = @import("std");

pub fn find(name: []const u8) ?*anyopaque {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const z = toZ(&buf, name) orelse return null;
    return std.c.dlopen(z, .{ .LAZY = true, .NOLOAD = true });
}

pub fn load(path: []const u8) error{LoadFailed}!*anyopaque {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const z = toZ(&buf, path) orelse return error.LoadFailed;
    return std.c.dlopen(z, .{ .LAZY = true }) orelse error.LoadFailed;
}

pub fn symbol(lib: *anyopaque, name: [*:0]const u8) ?*anyopaque {
    return std.c.dlsym(lib, name);
}

fn toZ(buf: [:0]u8, text: []const u8) ?[*:0]const u8 {
    if (text.len >= buf.len) return null;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    return buf[0..text.len :0].ptr;
}
