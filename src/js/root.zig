//! QuickJS-ng as a language host. Embedders share the engine through the `quickjs` module.

const std = @import("std");

pub const c = @import("quickjs");
pub const qjs = @import("qjs.zig");
pub const Binder = @import("Binder.zig");
pub const Script = @import("Script.zig");
pub const create = Script.create;

test "the engine runs" {
    const rt = c.JS_NewRuntime() orelse return error.OutOfMemory;
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.OutOfMemory;
    defer c.JS_FreeContext(ctx);
    const code = "[1, 2, 3].map(x => x * 2).reduce((a, b) => a + b)";
    const v = c.JS_Eval(ctx, @ptrCast(code), code.len, @ptrCast("<test>"), c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, v);
    var n: i32 = 0;
    try std.testing.expectEqual(0, c.JS_ToInt32(ctx, &n, v));
    try std.testing.expectEqual(12, n);
}

test {
    _ = @import("tests.zig");
}
