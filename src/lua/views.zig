//! Live views as Lua userdata. Fields read and write memory when used, methods are `view:method()`.
//! Arrays are 0-based like the memory they're in.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const script = @import("salamander_script");

const lua = @import("lua.zig");
const convert = @import("convert.zig");
const Binder = @import("Binder.zig");

const c = lua.c;
const State = lua.State;
const Schema = salamander_schema.Schema;
const views = script.views;
const memory = script.memory;
const View = views.View;
const Error = Binder.Error;

const view_name = "salamander.view";

/// Once per state, before any view's pushed.
pub fn register(l: *State) void {
    _ = c.luaL_newmetatable(l, lua.cstr(view_name));
    const mt = lua.top(l);
    lua.pushClosure(l, indexC, 0);
    lua.rawSet(l, mt, "__index");
    lua.pushClosure(l, newIndexC, 0);
    lua.rawSet(l, mt, "__newindex");
    lua.pushClosure(l, lenC, 0);
    lua.rawSet(l, mt, "__len");
    lua.pushClosure(l, tostringC, 0);
    lua.rawSet(l, mt, "__tostring");
    lua.pushClosure(l, eqC, 0);
    lua.rawSet(l, mt, "__eq");
    lua.pushClosure(l, pairsC, 0);
    lua.rawSet(l, mt, "__pairs");
    lua.pop(l, 1);
}

const Box = struct {
    binder: *Binder,
    view: View,
};

pub fn push(b: *Binder, l: *State, unsized: View) void {
    const v = b.core.sized(unsized);
    const box: *Box = @ptrCast(@alignCast(c.lua_newuserdatauv(l, @sizeOf(Box), 0).?));
    box.* = .{ .binder = b, .view = v };
    _ = c.luaL_setmetatable(l, lua.cstr(view_name));
}

/// The view at `idx`, if it's one.
pub fn at(l: *State, idx: c_int) ?View {
    const box: *Box = @ptrCast(@alignCast(c.luaL_testudata(l, idx, lua.cstr(view_name)) orelse return null));
    return box.view;
}

fn boxAt(l: *State, idx: c_int) *Box {
    return @ptrCast(@alignCast(c.luaL_checkudata(l, idx, lua.cstr(view_name))));
}

/// A key as a member name. Numbers are indices.
fn keyName(l: *State, idx: c_int, buf: []u8) ?[]const u8 {
    if (c.lua_type(l, idx) == c.LUA_TNUMBER) {
        var is: c_int = 0;
        const i = c.lua_tointegerx(l, idx, &is);
        if (is == 0 or i < 0) return null;
        return std.fmt.bufPrint(buf, "{d}", .{i}) catch null;
    }
    if (c.lua_type(l, idx) != c.LUA_TSTRING) return null;
    return lua.toString(l, idx);
}

fn indexC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const box = boxAt(l, 1);
    const b = box.binder;
    var buf: [32]u8 = undefined;
    const name = keyName(l, 2, &buf) orelse return 0;
    const m = views.member(box.view, name) orelse return 0;
    read(b, l, box.view.schema, m) catch |e| return b.raise(l, e);
    return 1;
}

fn newIndexC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const box = boxAt(l, 1);
    const b = box.binder;
    var buf: [32]u8 = undefined;
    const name = keyName(l, 2, &buf) orelse return b.raise(l, b.fail(l, "a view's keys are names and indices", .{}));
    var tbuf: [128]u8 = undefined;
    const m = views.member(box.view, name) orelse
        return b.raise(l, b.fail(l, "{s} has no {s}", .{ std.fmt.bufPrint(&tbuf, "{f}", .{box.view.type}) catch "it", name }));
    write(b, l, box.view.schema, m, 3) catch |e| return b.raise(l, e);
    return 0;
}

fn lenC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const v = boxAt(l, 1).view;
    c.lua_pushinteger(l, switch (v.type) {
        .array => |a| @intCast(a.len),
        else => 0,
    });
    return 1;
}

fn tostringC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const v = boxAt(l, 1).view;
    var buf: [192]u8 = undefined;
    lua.pushString(l, std.fmt.bufPrint(&buf, "{f} @ 0x{x}", .{ v.type, v.address }) catch "view");
    return 1;
}

fn eqC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const a = at(l, 1) orelse return 0;
    const b = at(l, 2) orelse return 0;
    c.lua_pushboolean(l, @intFromBool(a.address == b.address and a.type.eql(b.type)));
    return 1;
}

/// `pairs(view)` goes through its fields, or its elements from 0.
fn pairsC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    _ = boxAt(l, 1);
    lua.pushClosure(l, nextC, 0);
    c.lua_pushvalue(l, 1);
    c.lua_pushnil(l);
    return 3;
}

fn nextC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const box = boxAt(l, 1);
    const b = box.binder;
    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
    defer arena.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    views.names(box.view, arena.allocator(), &list) catch return b.raise(l, error.OutOfMemory);
    var buf: [32]u8 = undefined;
    const i: usize = if (lua.isNil(l, 2)) 0 else blk: {
        const prev = keyName(l, 2, &buf) orelse return 0;
        for (list.items, 0..) |n, i| if (std.mem.eql(u8, n, prev)) break :blk i + 1;
        return 0;
    };
    if (i >= list.items.len) return 0;
    const name = list.items[i];
    if (box.view.type == .array) c.lua_pushinteger(l, @intCast(i)) else lua.pushString(l, name);
    const m = views.member(box.view, name).?;
    read(b, l, box.view.schema, m) catch |e| return b.raise(l, e);
    return 2;
}

fn located(b: *Binder, l: *State, e: anyerror) Error {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    return b.locateFailed(l, "memory", e);
}

/// Pushes a member's value now. Methods come as functions taking the view as `self`.
pub fn read(b: *Binder, l: *State, s: Schema, m: views.Member) Error!void {
    if (c.lua_checkstack(l, 4) == 0) return error.OutOfMemory;
    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    switch (m) {
        .value => |p| {
            const mem = b.core.readPlace(s, p, a) catch |e| return located(b, l, e);
            try convert.toLua(b, l, s, p.type, mem);
        },
        .pointer => |p| {
            const to = b.core.readPointer(p.address) catch |e| return located(b, l, e);
            if (to == 0) return c.lua_pushnil(l);
            push(b, l, views.pointee(s, p.type, to));
        },
        .text => |p| {
            const to = b.core.readPointer(p.address) catch |e| return located(b, l, e);
            if (to == 0) return c.lua_pushnil(l);
            const text = b.core.readText(p.type.pointer.prim, to, a) catch |e| return located(b, l, e);
            lua.pushString(l, text);
        },
        .bits => |bits| {
            var word: u64 = 0;
            b.core.readMemory(bits.address, std.mem.asBytes(&word)[0..bits.backing.size(s.pointer_size)]) catch |e| return located(b, l, e);
            const v = views.readBits(bits, word);
            switch (bits.member) {
                .bool => c.lua_pushboolean(l, @intFromBool(v != 0)),
                else => c.lua_pushinteger(l, @bitCast(v)),
            }
        },
        .view => |v| push(b, l, v),
        .method => |f| try b.pushMethod(l, f),
        .length => |n| c.lua_pushinteger(l, @intCast(n)),
    }
}

pub fn write(b: *Binder, l: *State, s: Schema, m: views.Member, idx: c_int) Error!void {
    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    switch (m) {
        .value, .pointer => |p| {
            const shape = memory.shapeOf(s, p.type);
            const mem = try memory.alloc(a, shape);
            try convert.fromLua(b, l, s, p.type, idx, mem, a);
            b.core.writeMemory(p.address, mem[0..shape.size]) catch |e| return located(b, l, e);
        },
        .bits => |bits| {
            const n = bits.backing.size(s.pointer_size);
            var word: u64 = 0;
            b.core.readMemory(bits.address, std.mem.asBytes(&word)[0..n]) catch |e| return located(b, l, e);
            const value: u64 = if (c.lua_type(l, idx) == c.LUA_TBOOLEAN)
                @intFromBool(c.lua_toboolean(l, idx) != 0)
            else blk: {
                var is: c_int = 0;
                const v = c.lua_tointegerx(l, idx, &is);
                if (is == 0) return b.fail(l, "bits take a bool or an integer", .{});
                break :blk @bitCast(v);
            };
            word = views.writeBits(bits, word, value);
            b.core.writeMemory(bits.address, std.mem.asBytes(&word)[0..n]) catch |e| return located(b, l, e);
        },
        .text => return b.fail(l, "text behind a pointer can't be set, only the pointer", .{}),
        .view => return b.fail(l, "set its fields instead", .{}),
        .method => return b.fail(l, "a method can't be set", .{}),
        .length => return b.fail(l, "length can't be set", .{}),
    }
}

// Snapshots are plain copies read once, changed like any table, then saved back

const copy_name = "salamander.copy";

/// Registry ref of a weak-keyed table from each snapshot to what it was copied from. Once per state.
pub fn registerCopies(l: *State) c_int {
    _ = c.luaL_newmetatable(l, lua.cstr(copy_name));
    lua.pushClosure(l, copyGcC, 0);
    lua.rawSet(l, lua.top(l) - 1, "__gc");
    lua.pop(l, 1);
    lua.newTable(l);
    lua.newTable(l);
    lua.pushString(l, "k");
    lua.rawSet(l, lua.top(l) - 1, "__mode");
    _ = c.lua_setmetatable(l, -2);
    return lua.ref(l);
}

fn copyGcC(l_: ?*State) callconv(.c) c_int {
    const p: *?*views.Copy = @ptrCast(@alignCast(c.lua_touserdata(l_.?, 1) orelse return 0));
    if (p.*) |taken| taken.destroy();
    p.* = null;
    return 0;
}

/// Pushes a plain copy of what's at `v`. Pointers in it stay live views.
fn pushCopy(b: *Binder, l: *State, v: View, depth: usize) Error!void {
    if (c.lua_checkstack(l, 6) == 0) return error.OutOfMemory;
    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
    defer arena.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    try views.names(v, arena.allocator(), &list);
    lua.newTable(l);
    const t = lua.top(l);
    for (list.items, 0..) |name, i| {
        const m = views.member(v, name) orelse continue;
        switch (m) {
            .view => |inner| if (depth < views.max_depth) try pushCopy(b, l, inner, depth + 1) else c.lua_pushnil(l),
            else => try read(b, l, v.schema, m),
        }
        if (v.type == .array) c.lua_rawseti(l, t, @intCast(i + 1)) else lua.rawSet(l, t, name);
    }
}

/// Pushes a plain table read in one go. `save` it to write back what changed.
pub fn snapshot(b: *Binder, l: *State, v: View) Error!void {
    const taken = b.core.takeCopy(v) catch |e| return located(b, l, e);
    pushCopy(b, l, taken.local(), 0) catch |e| {
        taken.destroy();
        return e;
    };
    const t = lua.top(l);
    lua.pushRef(l, b.copies);
    c.lua_pushvalue(l, t);
    const p: *?*views.Copy = @ptrCast(@alignCast(c.lua_newuserdatauv(l, @sizeOf(?*views.Copy), 0).?));
    p.* = taken;
    _ = c.luaL_setmetatable(l, lua.cstr(copy_name));
    c.lua_rawset(l, -3);
    lua.pop(l, 1);
}

/// Writes back what changed in the snapshot at `idx` and gives how many parts.
pub fn save(b: *Binder, l: *State, idx: c_int) Error!usize {
    const where = c.lua_absindex(l, idx);
    lua.pushRef(l, b.copies);
    c.lua_pushvalue(l, where);
    _ = c.lua_rawget(l, -2);
    const p: ?*?*views.Copy = @ptrCast(@alignCast(c.luaL_testudata(l, -1, lua.cstr(copy_name))));
    lua.pop(l, 2);
    const taken = (if (p) |q| q.* else null) orelse return b.fail(l, "that isn't from snapshot", .{});
    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
    defer arena.deinit();
    const lang: Lang = .{ .b = b, .l = l, .a = arena.allocator() };
    return views.save(Lang, lang, b.core.gpa, taken, where, &b.core) catch |e| switch (e) {
        error.Raise => error.Raise,
        error.OutOfMemory => error.OutOfMemory,
        else => located(b, l, e),
    };
}

/// A snapshot's parts on the stack, for `views.save`. Each part's pushed, then popped once done.
const Lang = struct {
    b: *Binder,
    l: *State,
    a: std.mem.Allocator,

    pub const Item = c_int;

    fn present(self: Lang) ?c_int {
        if (lua.isNil(self.l, -1)) {
            lua.pop(self.l, 1);
            return null;
        }
        return lua.top(self.l);
    }

    pub fn child(self: Lang, item: c_int, name: []const u8) ?c_int {
        if (lua.typeOf(self.l, item) != c.LUA_TTABLE or c.lua_checkstack(self.l, 2) == 0) return null;
        _ = lua.rawGet(self.l, item, name);
        return self.present();
    }

    pub fn element(self: Lang, item: c_int, i: usize) ?c_int {
        if (lua.typeOf(self.l, item) != c.LUA_TTABLE or c.lua_checkstack(self.l, 2) == 0) return null;
        _ = c.lua_rawgeti(self.l, item, @intCast(i + 1));
        return self.present();
    }

    pub fn release(self: Lang, _: c_int) void {
        lua.pop(self.l, 1);
    }

    pub fn put(self: Lang, s: Schema, r: Schema.Ref, item: c_int, mem: [*]u8) Error!void {
        return convert.fromLua(self.b, self.l, s, r, item, mem, self.a);
    }

    pub fn bitsOf(self: Lang, item: c_int) Error!u64 {
        if (lua.typeOf(self.l, item) == c.LUA_TBOOLEAN) return @intFromBool(c.lua_toboolean(self.l, item) != 0);
        var is: c_int = 0;
        const v = c.lua_tointegerx(self.l, item, &is);
        if (is == 0) return self.b.fail(self.l, "bits take a bool or an integer", .{});
        return @bitCast(v);
    }
};
