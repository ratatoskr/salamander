//! Lua 5.5 as a language host. Embedders share the engine through the `lua` module.

const std = @import("std");

/// No `linit.c`, so hosts open the libraries they want.
pub const c = @import("lua");
pub const lua = @import("lua.zig");
pub const Binder = @import("Binder.zig");
pub const Script = @import("Script.zig");
pub const create = Script.create;

test "the engine runs" {
    const L = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(L);
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(L, @ptrCast("local t = 0 for i = 1, 4 do t = t + i end return t")));
    try std.testing.expectEqual(c.LUA_OK, c.lua_pcallk(L, 0, 1, 0, 0, null));
    try std.testing.expectEqual(10, c.lua_tointegerx(L, -1, null));
}

test {
    _ = @import("tests.zig");
}
