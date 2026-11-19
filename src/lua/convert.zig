//! Memory laid out like `rt.Abi` to Lua values and back, going by the schema.
//! Arrays and slices are sequences from 1, `u8[N]` and `u16[N]` text are strings, u64 keeps its bits.
//! Tables are read and written raw, so no metamethod can raise mid-conversion.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const script = @import("salamander_script");
const rt = @import("salamander_runtime");

const lua = @import("lua.zig");
const Binder = @import("Binder.zig");

const c = lua.c;
const memory = script.memory;
const views = script.views;
const State = lua.State;
const Schema = salamander_schema.Schema;
const Ref = Schema.Ref;

pub const Error = Binder.Error;

// Blobs, as userdata holding a count till they're collected

const blob_name = "salamander.blob";

/// Once per state, before any blob's pushed.
pub fn registerBlob(l: *State) void {
    _ = c.luaL_newmetatable(l, lua.cstr(blob_name));
    const mt = lua.top(l);
    lua.pushClosure(l, blobGc, 0);
    lua.rawSet(l, mt, "__gc");
    lua.pushClosure(l, blobLen, 0);
    lua.rawSet(l, mt, "__len");
    lua.pushClosure(l, blobToString, 0);
    lua.rawSet(l, mt, "__tostring");
    lua.newTable(l);
    const methods = lua.top(l);
    lua.pushClosure(l, blobByte, 0);
    lua.rawSet(l, methods, "byte");
    lua.pushClosure(l, blobSub, 0);
    lua.rawSet(l, methods, "sub");
    lua.pushClosure(l, blobString, 0);
    lua.rawSet(l, methods, "string");
    lua.rawSet(l, mt, "__index");
    lua.pop(l, 1);
}

fn pushBlob(l: *State, blob: rt.Blob) void {
    if (blob.table == null) return c.lua_pushnil(l);
    blob.retain();
    const at: *rt.Blob = @ptrCast(@alignCast(c.lua_newuserdatauv(l, @sizeOf(rt.Blob), 0)));
    at.* = blob;
    c.luaL_setmetatable(l, lua.cstr(blob_name));
}

fn blobAt(l: *State, idx: c_int) ?*rt.Blob {
    return @ptrCast(@alignCast(c.luaL_testudata(l, idx, lua.cstr(blob_name))));
}

/// One count for whoever gets it. The same blob for one of ours, else a copy of a string.
fn blobFromLua(b: *Binder, l: *State, idx: c_int) Error!rt.Blob {
    if (lua.typeOf(l, idx) == c.LUA_TNIL) return .{};
    if (blobAt(l, idx)) |held| {
        if (held.table == null) return .{};
        held.retain();
        return held.*;
    }
    const text = lua.toString(l, idx) orelse return b.fail(l, "expected a blob or a string for a blob", .{});
    const made = b.core.host.raw().blob(text.len);
    if (made.table == null) return error.OutOfMemory;
    @memcpy(@constCast(made.bytes())[0..text.len], text);
    return made;
}

fn bytesOf(l: *State) []const u8 {
    const held = blobAt(l, 1) orelse return "";
    if (held.table == null) return "";
    return held.bytes();
}

fn blobGc(l_: ?*State) callconv(.c) c_int {
    const held = blobAt(l_.?, 1) orelse return 0;
    if (held.table != null) held.release();
    held.* = .{};
    return 0;
}

fn blobLen(l_: ?*State) callconv(.c) c_int {
    c.lua_pushinteger(l_.?, @intCast(bytesOf(l_.?).len));
    return 1;
}

fn blobToString(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    var buf: [48]u8 = undefined;
    lua.pushString(l, std.fmt.bufPrint(&buf, "blob: {d} bytes", .{bytesOf(l).len}) catch "blob");
    return 1;
}

/// The byte at `i`, from 1, or nil past either end.
fn blobByte(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const bytes = bytesOf(l);
    const i = c.luaL_optinteger(l, 2, 1);
    if (i < 1 or i > bytes.len) {
        c.lua_pushnil(l);
        return 1;
    }
    c.lua_pushinteger(l, bytes[@intCast(i - 1)]);
    return 1;
}

/// Bytes `i` to `j` as a string, like `string.sub`.
fn blobSub(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const bytes = bytesOf(l);
    const len: i64 = @intCast(bytes.len);
    var i: i64 = c.luaL_optinteger(l, 2, 1);
    var j: i64 = c.luaL_optinteger(l, 3, -1);
    if (i < 0) i = @max(len + i + 1, 1) else if (i == 0) i = 1;
    if (j < 0) j = len + j + 1 else if (j > len) j = len;
    if (i > j) {
        lua.pushString(l, "");
        return 1;
    }
    lua.pushString(l, bytes[@intCast(i - 1)..@intCast(j)]);
    return 1;
}

fn blobString(l_: ?*State) callconv(.c) c_int {
    lua.pushString(l_.?, bytesOf(l_.?));
    return 1;
}

fn room(b: *Binder, l: *State) Error!void {
    if (c.lua_checkstack(l, 8) == 0) return b.fail(l, "too deeply nested", .{});
}

/// Pushes the value at `mem`. Borrowed things like strings are copied.
pub fn toLua(b: *Binder, l: *State, s: Schema, r: Ref, mem: [*]const u8) Error!void {
    try room(b, l);
    switch (r) {
        .prim => |p| switch (p) {
            .f32, .f64 => c.lua_pushnumber(l, memory.float(mem, p)),
            .bool => c.lua_pushboolean(l, @intFromBool(mem[0] != 0)),
            .string => lua.pushString(l, memory.slice(mem).get()),
            .cstring => {
                const at: ?[*:0]const u8 = @ptrFromInt(@as(usize, @intCast(memory.bits(mem, s.pointer_size))));
                if (at) |text| lua.pushString(l, std.mem.span(text)) else c.lua_pushnil(l);
            },
            .object => try b.wrapAny(l, memory.object(mem)),
            .blob => pushBlob(l, memory.blob(mem)),
            .void => c.lua_pushnil(l),
            else => int(l, mem, p, s.pointer_size),
        },
        .named => |n| {
            if (s.findTrait(n)) |t| return b.wrap(l, try b.traitOf(l, s, t), memory.object(mem));
            const t = s.findType(n).?;
            switch (t.kind) {
                .@"struct", .@"union" => {
                    c.lua_createtable(l, 0, 4);
                    const at = lua.top(l);
                    var it = memory.fields(s, t);
                    while (it.next()) |f| {
                        try toLua(b, l, s, f.type, mem + f.offset);
                        lua.rawSet(l, at, f.name);
                    }
                },
                .@"enum" => |e| int(l, mem, e.backing, s.pointer_size),
                .bitfield => |bf| int(l, mem, bf.backing, s.pointer_size),
                .func => |*sig| try b.wrapFn(l, try b.fnOf(l, s, sig), memory.object(mem)),
                .@"error", .@"opaque" => unreachable,
            }
        },
        .pointer => {
            const v = memory.bits(mem, s.pointer_size);
            if (v == 0) return c.lua_pushnil(l);
            // Structs and text behind pointers are live, once something can read memory
            if (b.core.locator != null) switch (views.place(s, r, 0)) {
                .pointer => return Binder.views.push(b, l, views.pointee(s, r, @intCast(v))),
                .text => {
                    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
                    defer arena.deinit();
                    const text = b.core.readText(r.pointer.prim, @intCast(v), arena.allocator()) catch |e| return b.locateFailed(l, "text", e);
                    return lua.pushString(l, text);
                },
                else => {},
            };
            c.lua_pushinteger(l, @bitCast(v));
        },
        .array => |a| {
            if (memory.isText(a)) |kind| {
                if (kind == .utf8) return lua.pushString(l, memory.utf8Text(mem, a.len));
                var buf: [1024]u8 = undefined;
                return lua.pushString(l, memory.utf16Text(mem, a.len, &buf));
            }
            try array(b, l, s, a.child.*, mem, a.len);
        },
        .slice => |child| {
            const sl = memory.slice(mem);
            try array(b, l, s, child.*, if (sl.ptr) |p| p else mem, sl.len);
        },
        .optional => |child| {
            if (memory.someFlag(s, child.*)) |at| if (mem[at] == 0) return c.lua_pushnil(l);
            try toLua(b, l, s, child.*, mem);
        },
        .func => |sig| try b.wrapFn(l, try b.fnOf(l, s, sig), memory.object(mem)),
        .result => unreachable,
    }
}

fn int(l: *State, mem: [*]const u8, p: Schema.Prim, ps: u8) void {
    switch (memory.int(mem, p, ps)) {
        .signed => |v| c.lua_pushinteger(l, v),
        .unsigned => |v| c.lua_pushinteger(l, @bitCast(v)),
    }
}

fn array(b: *Binder, l: *State, s: Schema, child: Ref, mem: [*]const u8, len: usize) Error!void {
    c.lua_createtable(l, @intCast(@min(len, std.math.maxInt(c_int))), 0);
    const at = lua.top(l);
    const size = memory.shapeOf(s, child).size;
    for (0..len) |i| {
        try toLua(b, l, s, child, mem + i * size);
        c.lua_rawseti(l, at, @intCast(i + 1));
    }
}

/// Writes the value at absolute `idx` to `mem`, which is zeroed. Copies of strings and slices go in `a`.
pub fn fromLua(b: *Binder, l: *State, s: Schema, r: Ref, idx: c_int, mem: [*]u8, a: std.mem.Allocator) Error!void {
    try room(b, l);
    switch (r) {
        .prim => |p| switch (p) {
            .f32, .f64 => {
                var is: c_int = 0;
                const f = c.lua_tonumberx(l, idx, &is);
                if (is == 0 or lua.typeOf(l, idx) != c.LUA_TNUMBER) return b.fail(l, "expected a number", .{});
                memory.putFloat(mem, p, f);
            },
            .bool => mem[0] = @intFromBool(c.lua_toboolean(l, idx) != 0),
            .string => {
                const text = lua.toString(l, idx) orelse return b.fail(l, "expected a string", .{});
                const copy = try a.dupe(u8, text);
                memory.putSlice(mem, copy.ptr, copy.len);
            },
            .cstring => if (!lua.isNil(l, idx)) {
                const text = lua.toString(l, idx) orelse return b.fail(l, "expected a string", .{});
                const z = try a.allocSentinel(u8, text.len, 0);
                @memcpy(z, text);
                memory.put(mem, s.pointer_size, @intFromPtr(z.ptr));
            },
            .object => memory.putObject(mem, try b.unwrapAny(l, idx)),
            .blob => {
                const made = try blobFromLua(b, l, idx);
                memory.putObject(mem, .{ .data = made.data, .table = made.table });
            },
            .void => {},
            else => memory.put(mem, p.size(s.pointer_size), try intBits(b, l, idx)),
        },
        .named => |n| {
            if (s.findTrait(n)) |t| return memory.putObject(mem, try b.unwrap(l, try b.traitOf(l, s, t), idx));
            const t = s.findType(n).?;
            switch (t.kind) {
                .@"struct", .@"union" => {
                    if (lua.typeOf(l, idx) != c.LUA_TTABLE) return b.fail(l, "expected a table for {s}", .{t.name});
                    var u: memory.UnionWrite = try .init(s, r, t, mem, a);
                    var it = memory.fields(s, t);
                    while (it.next()) |f| {
                        _ = lua.rawGet(l, idx, f.name);
                        defer lua.pop(l, 1);
                        if (lua.isNil(l, -1)) continue;
                        try fromLua(b, l, s, f.type, lua.top(l), u.at(mem, f.offset), a);
                        u.done(mem);
                    }
                },
                .@"enum" => |e| {
                    const size = e.backing.size(s.pointer_size);
                    if (lua.toString(l, idx)) |name| {
                        const bits = memory.enumValue(e, name) orelse return b.fail(l, "{s} has no {s}", .{ t.name, name });
                        return memory.put(mem, size, bits);
                    }
                    memory.put(mem, size, try intBits(b, l, idx));
                },
                .bitfield => |bf| memory.put(mem, bf.backing.size(s.pointer_size), try intBits(b, l, idx)),
                .func => |*sig| memory.putObject(mem, try b.unwrapFn(l, try b.fnOf(l, s, sig), idx)),
                .@"error", .@"opaque" => unreachable,
            }
        },
        .pointer => if (Binder.views.at(l, idx)) |view| {
            memory.put(mem, s.pointer_size, view.address);
        } else if (!lua.isNil(l, idx)) memory.put(mem, s.pointer_size, try intBits(b, l, idx)),
        .array => |arr| {
            if (memory.isText(arr)) |kind| if (lua.toString(l, idx)) |text| {
                return memory.putText(mem, kind, arr.len, text) catch b.fail(l, "bad UTF-8", .{});
            };
            const len = try length(b, l, idx);
            const size = memory.shapeOf(s, arr.child.*).size;
            for (0..@min(len, arr.len)) |i| try element(b, l, s, arr.child.*, idx, i, mem + i * size, a);
        },
        .slice => |child| {
            // Bytes take strings and blobs too, copied
            if (child.* == .prim and child.prim == .u8) {
                const bytes: ?[]const u8 = if (blobAt(l, idx)) |held| (if (held.table != null) held.bytes() else "") else if (lua.typeOf(l, idx) == c.LUA_TSTRING) lua.toString(l, idx) else null;
                if (bytes) |got| {
                    const copy = try a.dupe(u8, got);
                    return memory.putSlice(mem, copy.ptr, copy.len);
                }
            }
            const len = try length(b, l, idx);
            const shape = memory.shapeOf(s, child.*);
            const items = try memory.alloc(a, .{ .size = shape.size * len, .alignment = shape.alignment });
            for (0..len) |i| try element(b, l, s, child.*, idx, i, items + i * shape.size, a);
            memory.putSlice(mem, items, len);
        },
        .optional => |child| {
            if (lua.isNil(l, idx)) return;
            try fromLua(b, l, s, child.*, idx, mem, a);
            if (memory.someFlag(s, child.*)) |at| mem[at] = 1;
        },
        .func => |sig| memory.putObject(mem, try b.unwrapFn(l, try b.fnOf(l, s, sig), idx)),
        .result => unreachable,
    }
}

fn element(b: *Binder, l: *State, s: Schema, child: Ref, idx: c_int, i: usize, mem: [*]u8, a: std.mem.Allocator) Error!void {
    _ = c.lua_rawgeti(l, idx, @intCast(i + 1));
    defer lua.pop(l, 1);
    try fromLua(b, l, s, child, lua.top(l), mem, a);
}

fn length(b: *Binder, l: *State, idx: c_int) Error!usize {
    if (lua.typeOf(l, idx) != c.LUA_TTABLE) return b.fail(l, "expected a table", .{});
    return @intCast(c.lua_rawlen(l, idx));
}

/// Integers as their bits. Floats only when they're whole.
fn intBits(b: *Binder, l: *State, idx: c_int) Error!u64 {
    switch (lua.typeOf(l, idx)) {
        c.LUA_TNUMBER => {
            var is: c_int = 0;
            const n = c.lua_tointegerx(l, idx, &is);
            if (is == 0) return b.fail(l, "expected an integer", .{});
            return @bitCast(n);
        },
        c.LUA_TBOOLEAN => return @intFromBool(c.lua_toboolean(l, idx) != 0),
        else => return b.fail(l, "expected an integer", .{}),
    }
}
