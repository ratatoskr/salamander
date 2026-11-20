//! A little Zig on top of Lua's C API. Many of Lua's helpers are macros translate-c can't see.

const std = @import("std");

pub const c = @import("lua");

pub const State = c.lua_State;
pub const CFunction = *const fn (l: ?*State) callconv(.c) c_int;

pub const registry: c_int = c.LUA_REGISTRYINDEX;
pub const ok = c.LUA_OK;
pub const noref = c.LUA_NOREF;

pub fn upvalue(i: c_int) c_int {
    return registry - i;
}

pub fn cstr(s: [:0]const u8) [*c]const u8 {
    return @ptrCast(s.ptr);
}

pub fn pop(l: *State, n: c_int) void {
    c.lua_settop(l, -n - 1);
}

pub fn top(l: *State) c_int {
    return c.lua_gettop(l);
}

pub fn isNil(l: *State, idx: c_int) bool {
    return c.lua_type(l, idx) <= c.LUA_TNIL;
}

pub fn typeOf(l: *State, idx: c_int) c_int {
    return c.lua_type(l, idx);
}

/// Takes `idx` out, moving what's above it down.
pub fn remove(l: *State, idx: c_int) void {
    c.lua_rotate(l, idx, -1);
    pop(l, 1);
}

/// Moves the top to `idx`, moving what's there up.
pub fn insert(l: *State, idx: c_int) void {
    c.lua_rotate(l, idx, 1);
}

pub fn pushString(l: *State, s: []const u8) void {
    _ = c.lua_pushlstring(l, @ptrCast(s.ptr), s.len);
}

pub fn pushClosure(l: *State, f: CFunction, n: c_int) void {
    c.lua_pushcclosure(l, f, n);
}

pub fn newTable(l: *State) void {
    c.lua_createtable(l, 0, 0);
}

/// `t[name] = top` without metamethods, popping it. `t` must be absolute.
pub fn rawSet(l: *State, t: c_int, name: []const u8) void {
    pushString(l, name);
    insert(l, -2);
    c.lua_rawset(l, t);
}

/// `t[name]` without metamethods, pushed. `t` must be absolute. Gives its type.
pub fn rawGet(l: *State, t: c_int, name: []const u8) c_int {
    pushString(l, name);
    return c.lua_rawget(l, t);
}

/// Only actual strings, borrowed for as long as the value's on the stack.
pub fn toString(l: *State, idx: c_int) ?[]const u8 {
    if (c.lua_type(l, idx) != c.LUA_TSTRING) return null;
    var len: usize = 0;
    const p = c.lua_tolstring(l, idx, &len) orelse return null;
    return @as([*]const u8, @ptrCast(p))[0..len];
}

pub fn pcall(l: *State, nargs: c_int, nresults: c_int, msgh: c_int) c_int {
    return c.lua_pcallk(l, nargs, nresults, msgh, 0, null);
}

/// Loads `source` as a text chunk named `name`, like `"@main.lua"`.
pub fn load(l: *State, source: []const u8, name: [:0]const u8) c_int {
    return c.luaL_loadbufferx(l, @ptrCast(source.ptr), source.len, cstr(name), cstr("t"));
}

/// Pushes what `ref` holds in the registry.
pub fn pushRef(l: *State, r: c_int) void {
    _ = c.lua_rawgeti(l, registry, r);
}

/// Pops the top into the registry.
pub fn ref(l: *State) c_int {
    return c.luaL_ref(l, registry);
}

pub fn unref(l: *State, r: c_int) void {
    if (r != noref) c.luaL_unref(l, registry, r);
}
