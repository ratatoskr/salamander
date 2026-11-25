//! Loading DLLs and finding what they export.

const std = @import("std");
const windows = std.os.windows;

extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn LoadLibraryExW(path: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

// Looks for its own dependencies next to it first
const LOAD_WITH_ALTERED_SEARCH_PATH = 0x8;

pub fn find(name: []const u8) ?*anyopaque {
    var buf: [windows.MAX_PATH:0]u16 = undefined;
    const wide = toWide(&buf, name) orelse return null;
    return GetModuleHandleW(wide);
}

pub fn load(path: []const u8) error{LoadFailed}!*anyopaque {
    var buf: [windows.PATH_MAX_WIDE:0]u16 = undefined;
    const wide = toWide(&buf, path) orelse return error.LoadFailed;
    return LoadLibraryExW(wide, null, LOAD_WITH_ALTERED_SEARCH_PATH) orelse error.LoadFailed;
}

pub fn symbol(lib: *anyopaque, name: [*:0]const u8) ?*anyopaque {
    return GetProcAddress(lib, name);
}

fn toWide(buf: [:0]u16, text: []const u8) ?[*:0]const u16 {
    if (text.len >= buf.len) return null;
    const n = std.unicode.wtf8ToWtf16Le(buf, text) catch return null;
    buf[n] = 0;
    return buf[0..n :0].ptr;
}
