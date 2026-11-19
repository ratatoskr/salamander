//! A little Zig on top of QuickJS's C API.

const std = @import("std");

pub const c = @import("quickjs");

pub const Value = c.JSValue;
pub const Context = c.JSContext;

pub const undefined_value: Value = special(c.JS_TAG_UNDEFINED);
pub const null_value: Value = special(c.JS_TAG_NULL);
pub const exception: Value = special(c.JS_TAG_EXCEPTION);

// translate-c can't evaluate these when the value is a struct, as on x64
fn special(tag: c_int) Value {
    if (@typeInfo(Value) == .@"struct") return .{ .u = .{ .uint64 = 0 }, .tag = tag };
    return @as(u64, @as(u32, @bitCast(tag))) << 32;
}

pub fn cstr(s: [:0]const u8) [*c]const c_char {
    return @ptrCast(s.ptr);
}

pub fn chars(s: []const u8) [*c]const c_char {
    return @ptrCast(s.ptr);
}

pub fn string(ctx: *Context, s: []const u8) Value {
    return c.JS_NewStringLen(ctx, chars(s), s.len);
}

/// Borrowed from QuickJS until `free`.
pub const String = struct {
    ctx: *Context,
    ptr: [*c]const c_char,
    len: usize,

    pub fn slice(self: String) []const u8 {
        return @as([*]const u8, @ptrCast(self.ptr))[0..self.len];
    }

    pub fn free(self: String) void {
        c.JS_FreeCString(self.ctx, self.ptr);
    }
};

/// Null if that threw.
pub fn toString(ctx: *Context, v: Value) ?String {
    var len: usize = 0;
    const ptr = c.JS_ToCStringLen2(ctx, &len, v, false);
    if (ptr == null) return null;
    return .{ .ctx = ctx, .ptr = ptr, .len = len };
}

/// The exception, for a JS function to return.
pub fn throw(ctx: *Context, comptime fmt: []const u8, args: anytype) Value {
    var buf: [256:0]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch buf[0..0 :0];
    return c.JS_ThrowTypeError(ctx, cstr("%s"), msg.ptr);
}

pub fn isNullish(v: Value) bool {
    return c.JS_IsUndefined(v) or c.JS_IsNull(v);
}

/// Caller frees it.
pub fn get(ctx: *Context, obj: Value, name: []const u8) Value {
    var buf: [256:0]u8 = undefined;
    const n = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return undefined_value;
    return c.JS_GetPropertyStr(ctx, obj, cstr(n));
}

/// Takes `v`.
pub fn set(ctx: *Context, obj: Value, name: []const u8, v: Value) void {
    var buf: [256:0]u8 = undefined;
    const n = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return c.JS_FreeValue(ctx, v);
    _ = c.JS_SetPropertyStr(ctx, obj, cstr(n), v);
}
