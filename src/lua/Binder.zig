//! Traits in a Lua state, one per state. Any thread can call in, one at a time, through the core's gate.
//! Errors are tables with `name`, `code` and `message`. Poll `queue`, then call `runJobs`.
//! Needs the base and coroutine libraries. Objects lent for a borrowed parameter die with the call.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const rt = @import("salamander_runtime");
const bind = @import("salamander_bind");
const script = @import("salamander_script");

const lua = @import("lua.zig");
const convert = @import("convert.zig");
pub const views = @import("views.zig");

const c = lua.c;
const memory = script.memory;
const State = lua.State;
const Schema = salamander_schema.Schema;
const Allocator = std.mem.Allocator;

const Binder = @This();

/// A registry ref.
pub const Value = c_int;
pub const Core = script.Core(Binder);
pub const Trait = Core.Trait;
pub const Scope = Core.Scope;
pub const Impl = Core.Impl;
pub const Module = script.Module;

pub const TraitData = struct {
    /// A table of the trait's methods, by registry ref.
    methods: c_int = lua.noref,
};

/// `error.Raise` leaves what to raise pending, for `raise`.
pub const Error = error{ Raise, OutOfMemory };

core: Core,
main: *State,
/// The thread running now, so calls into the script land on it. `main` outside any call.
cur: *State,
/// Gets errors nobody else will see, like ones raised by a method that has no result.
report: ?*const fn (b: *Binder, message: []const u8) void,
/// For whoever made the binder.
user: ?*anyopaque = null,
prelude: Prelude = .{},
/// Native objects kept for Lua values, by those values. Weak keys.
cache: c_int = lua.noref,
/// What to raise, by registry ref.
err: c_int = lua.noref,
/// Each snapshot's copy, by registry ref. Weak keys.
copies: c_int = lua.noref,
/// Where the last error came from, from the message handler.
trace: ?[]u8 = null,
/// Set while converting a borrowed argument for the script, to boxes that stop working after.
lent_boxes: ?*std.ArrayList(c_int) = null,
awaits: std.ArrayList(*Await) = .empty,

pub const Options = struct {
    host: ?rt.Host = null,
    queue: rt.Queue,
    report: ?*const fn (b: *Binder, message: []const u8) void = null,
};

/// From `prelude.lua`, by registry ref.
const Prelude = struct {
    start: c_int = lua.noref,
    new_promise: c_int = lua.noref,
    settle: c_int = lua.noref,
    drain: c_int = lua.noref,
    watch: c_int = lua.noref,
    promise_mt: c_int = lua.noref,
    error_mt: c_int = lua.noref,
    task: c_int = lua.noref,
};

const box_name = "salamander.object";

/// What a userdata of ours holds.
const Box = union(enum) {
    /// A native object. No trait for `object`. No table once it's gone.
    object: struct { binder: *Binder, trait: ?*Trait, obj: rt.AnyObject },
    /// A script settling an async method's promise.
    settle: Settle,
};

const Settle = struct {
    binder: *Binder,
    resolver: rt.core.Resolver,
    trait: *Trait,
    slot: usize,
    done: bool = false,
};

/// A native promise a script's waiting on.
const Await = struct {
    gpa: Allocator,
    binder: ?*Binder,
    promise: rt.core.Promise,
    /// The prelude's promise, by registry ref.
    lua_promise: c_int,
    trait: *Trait,
    slot: usize,
};

pub fn init(gpa: Allocator, l: *State, options: Options) !*Binder {
    const b = try gpa.create(Binder);
    errdefer gpa.destroy(b);
    b.* = .{ .core = undefined, .main = l, .cur = l, .report = options.report };
    const base = lua.top(l);
    defer c.lua_settop(l, base);
    if (c.lua_checkstack(l, 8) == 0) return error.OutOfMemory;

    convert.registerBlob(l);
    views.register(l);
    b.copies = views.registerCopies(l);
    _ = c.luaL_newmetatable(l, lua.cstr(fn_name));
    lua.pushClosure(l, fnCallC, 0);
    lua.rawSet(l, lua.top(l) - 1, "__call");
    lua.pop(l, 1);
    _ = c.luaL_newmetatable(l, lua.cstr(box_name));
    const mt = lua.top(l);
    lua.pushClosure(l, indexC, 0);
    lua.rawSet(l, mt, "__index");
    lua.pushClosure(l, gcC, 0);
    lua.rawSet(l, mt, "__gc");

    lua.newTable(l);
    lua.newTable(l);
    lua.pushString(l, "k");
    lua.rawSet(l, lua.top(l) - 1, "__mode");
    _ = c.lua_setmetatable(l, -2);
    b.cache = lua.ref(l);
    errdefer lua.unref(l, b.cache);

    const prelude = @embedFile("prelude.lua");
    if (lua.load(l, prelude, "=salamander") != lua.ok) return error.PreludeFailed;
    c.lua_pushlightuserdata(l, b);
    lua.pushClosure(l, reportC, 1);
    lua.pushClosure(l, tracebackC, 0);
    if (lua.pcall(l, 2, 1, 0) != lua.ok) return error.PreludeFailed;
    const t = lua.top(l);
    inline for (comptime std.meta.fieldNames(Prelude)) |name| {
        const key = comptime if (std.mem.eql(u8, name, "promise_mt")) "Promise" else if (std.mem.eql(u8, name, "error_mt")) "Error" else name;
        _ = lua.rawGet(l, t, key);
        @field(b.prelude, name) = lua.ref(l);
    }
    errdefer b.unrefPrelude();
    try b.core.init(gpa, options.host orelse rt.host(), options.queue);
    return b;
}

fn unrefPrelude(b: *Binder) void {
    inline for (comptime std.meta.fieldNames(Prelude)) |name| lua.unref(b.main, @field(b.prelude, name));
}

/// Stops calls into what the script made and lets it all go. Close the state after.
pub fn deinit(b: *Binder) void {
    const gpa = b.core.gpa;
    b.cur = b.main;
    b.core.deinit();
    for (b.awaits.items) |a| {
        a.binder = null;
        lua.unref(b.main, a.lua_promise);
    }
    b.awaits.deinit(gpa);
    b.unrefPrelude();
    lua.unref(b.main, b.cache);
    lua.unref(b.main, b.err);
    if (b.trace) |t| gpa.free(t);
    gpa.destroy(b);
}

/// Parses a `.sal` and keeps it.
pub fn load(b: *Binder, source: []const u8, diagnostic: ?*Schema.Diagnostic) !*Module {
    return b.core.load(source, diagnostic);
}

pub fn trait(b: *Binder, m: *const Module, name: []const u8) script.TraitError!*Trait {
    return b.core.trait(m, name);
}

pub fn traitOf(b: *Binder, l: *State, s: Schema, decl: *const Schema.Trait) Error!*Trait {
    return b.core.traitOf(s, decl) catch |e| b.traitFailed(l, e, decl.name);
}

pub fn fnOf(b: *Binder, l: *State, s: Schema, sig: *const Schema.Signature) Error!*Trait {
    return b.core.fnOf(s, sig) catch |e| b.traitFailed(l, e, "fn");
}

fn traitFailed(b: *Binder, l: *State, e: script.TraitError, name: []const u8) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.NoSuchTrait => b.fail(l, "no trait {s}", .{name}),
        error.TooManyMethods => b.fail(l, "{s} has too many methods", .{name}),
    };
}

pub fn openScope(b: *Binder, name: []const u8) error{OutOfMemory}!*Scope {
    return b.core.openScope(name);
}

pub fn closeScope(b: *Binder, s: *Scope) void {
    b.core.closeScope(s);
}

/// Pushes the `task` table, with `spawn(f, ...)` and `yield()`.
pub fn pushTask(b: *Binder, l: *State) void {
    lua.pushRef(l, b.prelude.task);
}

/// Resumes tasks whose promises settled and reports rejections nobody waited for. Call after polling the queue.
pub fn runJobs(b: *Binder) void {
    const l = b.main;
    const base = lua.top(l);
    defer c.lua_settop(l, base);
    lua.pushRef(l, b.prelude.drain);
    c.lua_pushboolean(l, 1);
    if (lua.pcall(l, 1, 0, 0) != lua.ok) b.reportTop(l);
}

/// Runs the function under `nargs` args as a task so it can await, and leaves its promise. False with
/// nil left if it failed before it first waited, the error pending for `takeError`.
pub fn startTask(b: *Binder, l: *State, nargs: c_int) bool {
    lua.pushRef(l, b.prelude.start);
    lua.insert(l, -nargs - 2);
    if (lua.pcall(l, nargs + 1, 3, 0) != lua.ok) {
        b.keepError(l);
        c.lua_pushnil(l);
        return false;
    }
    if (c.lua_toboolean(l, -3) != 0) {
        c.lua_copy(l, -2, -3);
        lua.pop(l, 2);
        return true;
    }
    if (b.trace) |t| b.core.gpa.free(t);
    b.trace = if (lua.toString(l, -1)) |t| b.core.gpa.dupe(u8, t) catch null else null;
    lua.pop(l, 1);
    b.keepError(l);
    lua.pop(l, 1);
    c.lua_pushnil(l);
    return false;
}

/// Writes what's pending, with where it came from, and clears it.
pub fn takeError(b: *Binder, l: *State, w: *std.Io.Writer) void {
    lua.pushRef(l, b.err);
    describe(l, -1, w);
    lua.pop(l, 1);
    lua.unref(l, b.err);
    b.err = lua.noref;
    if (b.trace) |t| {
        w.print("\n{s}", .{t}) catch {};
        b.core.gpa.free(t);
        b.trace = null;
    }
}

/// Calls the function under `nargs` args, leaving one result, with what it raised pending if it did.
pub fn protectedCall(b: *Binder, l: *State, nargs: c_int) bool {
    const f = lua.top(l) - nargs;
    c.lua_pushlightuserdata(l, b);
    lua.pushClosure(l, onErrorC, 1);
    lua.insert(l, f);
    const status = lua.pcall(l, nargs, 1, f);
    lua.remove(l, f);
    if (status == lua.ok) return true;
    b.keepError(l);
    c.lua_pushnil(l);
    return false;
}

// What the core needs

pub fn initTrait(b: *Binder, t: *Trait) error{OutOfMemory}!void {
    if (t.sig != null) return;
    const l = b.main;
    if (c.lua_checkstack(l, 4) == 0) return error.OutOfMemory;
    c.lua_createtable(l, 0, @intCast(t.methods.len));
    const at = lua.top(l);
    for (t.methods, 0..) |m, i| {
        if (t.bound.methods[i] == null) continue;
        c.lua_pushlightuserdata(l, b);
        c.lua_pushinteger(l, @intCast(i));
        lua.pushClosure(l, callMethodC, 2);
        lua.rawSet(l, at, m.name);
    }
    t.lang.methods = lua.ref(l);
}

pub fn deinitTrait(b: *Binder, t: *Trait) void {
    lua.unref(b.main, t.lang.methods);
}

/// Lets go of an impl's Lua value, and of the value's link to it.
pub fn forget(b: *Binder, impl: *Impl) void {
    const l = b.cur;
    if (c.lua_checkstack(l, 4) != 0) {
        const base = lua.top(l);
        defer c.lua_settop(l, base);
        lua.pushRef(l, b.cache);
        lua.pushRef(l, impl.value);
        _ = c.lua_rawget(l, base + 1);
        if (b.boxAt(l, -1)) |box| switch (box.*) {
            .object => |*o| if (o.obj.data == @intFromPtr(&impl.record)) {
                o.obj = .{};
                lua.pushRef(l, impl.value);
                c.lua_pushnil(l);
                c.lua_rawset(l, base + 1);
            },
            .settle => {},
        };
    }
    lua.unref(l, impl.value);
    impl.value = lua.noref;
}

// Userdata for native objects

fn newBox(l: *State, box: Box) void {
    const p: *Box = @ptrCast(@alignCast(c.lua_newuserdatauv(l, @sizeOf(Box), 0).?));
    p.* = box;
    _ = c.lua_getfield(l, lua.registry, lua.cstr(box_name));
    _ = c.lua_setmetatable(l, -2);
}

fn boxAt(_: *Binder, l: *State, idx: c_int) ?*Box {
    return @ptrCast(@alignCast(c.luaL_testudata(l, idx, lua.cstr(box_name))));
}

fn indexC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const box: *Box = @ptrCast(@alignCast(c.luaL_testudata(l, 1, lua.cstr(box_name)) orelse return 0));
    switch (box.*) {
        .object => |o| {
            const t = o.trait orelse return 0;
            if (t.sig != null) return 0;
            lua.pushRef(l, t.lang.methods);
            c.lua_pushvalue(l, 2);
            _ = c.lua_rawget(l, -2);
            return 1;
        },
        .settle => return 0,
    }
}

fn gcC(l_: ?*State) callconv(.c) c_int {
    const box: *Box = @ptrCast(@alignCast(c.lua_touserdata(l_.?, 1) orelse return 0));
    switch (box.*) {
        // Never going to settle, so whoever waits gets Gone
        .settle => |*s| if (!s.done) s.resolver.drop(),
        .object => {},
    }
    return 0;
}

/// Pushes `obj` as a userdata with `t`'s methods, or the value it came from if it's ours.
pub fn wrap(b: *Binder, l: *State, t: *Trait, obj: rt.AnyObject) Error!void {
    if (obj.table == null) return c.lua_pushnil(l);
    if (b.core.ourImpl(obj)) |impl| return lua.pushRef(l, impl.value);
    newBox(l, .{ .object = .{ .binder = b, .trait = t, .obj = obj } });
    try b.lend(l);
}

/// Any object, which scripts can only hand back.
pub fn wrapAny(b: *Binder, l: *State, obj: rt.AnyObject) Error!void {
    if (obj.table == null) return c.lua_pushnil(l);
    if (b.core.ourImpl(obj)) |impl| return lua.pushRef(l, impl.value);
    newBox(l, .{ .object = .{ .binder = b, .trait = null, .obj = obj } });
    try b.lend(l);
}

pub fn wrapFn(b: *Binder, l: *State, t: *Trait, obj: rt.AnyObject) Error!void {
    if (obj.table == null) return c.lua_pushnil(l);
    if (b.core.ourImpl(obj)) |impl| return lua.pushRef(l, impl.value);
    c.lua_pushlightuserdata(l, b);
    newBox(l, .{ .object = .{ .binder = b, .trait = t, .obj = obj } });
    try b.lend(l);
    lua.pushClosure(l, callFnC, 2);
}

/// Notes the box on top, made for a borrowed argument, so it can stop working after the call.
fn lend(b: *Binder, l: *State) Error!void {
    const list = b.lent_boxes orelse return;
    c.lua_pushvalue(l, -1);
    const r = lua.ref(l);
    list.append(b.core.gpa, r) catch {
        lua.unref(l, r);
        return error.OutOfMemory;
    };
}

fn stopLent(b: *Binder, l: *State, lent: *std.ArrayList(c_int)) void {
    for (lent.items) |r| {
        lua.pushRef(l, r);
        if (b.boxAt(l, -1)) |box| switch (box.*) {
            .object => |*o| o.obj = .{},
            .settle => {},
        };
        lua.pop(l, 1);
        lua.unref(l, r);
    }
    lent.deinit(b.core.gpa);
}

/// The native object a wrapped one holds, or the value at `idx` as a `t`.
pub fn unwrap(b: *Binder, l: *State, t: *Trait, idx: c_int) Error!rt.AnyObject {
    if (lua.isNil(l, idx)) return .{};
    if (b.boxAt(l, idx)) |box| switch (box.*) {
        .object => |o| {
            if (o.obj.table == null) return b.gone(l);
            if (o.trait == t) return o.obj;
            // Another version, or another schema's copy of it
            const adapted = b.core.host.raw().adapt(o.obj, @ptrCast(@constCast(t.bound.info)));
            if (adapted.table == null) return b.fail(l, "that isn't a {s}", .{t.decl.name});
            return adapted;
        },
        .settle => return b.fail(l, "that isn't a {s}", .{t.decl.name}),
    };
    if (lua.typeOf(l, idx) != c.LUA_TTABLE) return b.fail(l, "expected a table for {s}", .{t.decl.name});
    return b.implement(l, t, idx);
}

pub fn unwrapAny(b: *Binder, l: *State, idx: c_int) Error!rt.AnyObject {
    if (lua.isNil(l, idx)) return .{};
    // A function `salamander.fn` gave a type
    if (typedFn(l, idx)) |t| {
        const at = c.lua_absindex(l, idx);
        _ = c.lua_rawgeti(l, at, 1);
        defer lua.pop(l, 1);
        return b.implement(l, t, lua.top(l));
    }
    if (b.boxAt(l, idx)) |box| switch (box.*) {
        .object => |o| return if (o.obj.table == null) b.gone(l) else o.obj,
        .settle => {},
    };
    return b.fail(l, "expected a salamander object", .{});
}

// The `salamander` module scripts require, for types they write while running

pub const builtin_module = "salamander";
const fn_name = "salamander.fn";

/// Pushes the `salamander` module.
pub fn pushBuiltin(b: *Binder, l: *State) void {
    const list = [_]struct { []const u8, lua.CFunction }{
        .{ "fn", builtinFnC },
        .{ "native", builtinNativeC },
        .{ "at", builtinAtC },
        .{ "addressOf", builtinAddressOfC },
        .{ "typeOf", builtinTypeOfC },
        .{ "sizeOf", builtinSizeOfC },
        .{ "snapshot", builtinSnapshotC },
        .{ "save", builtinSaveC },
        .{ "edit", builtinEditC },
        .{ "load", builtinLoadC },
    };
    c.lua_createtable(l, 0, list.len);
    const t = lua.top(l);
    for (list) |e| {
        c.lua_pushlightuserdata(l, b);
        lua.pushClosure(l, e[1], 1);
        lua.rawSet(l, t, e[0]);
    }
}

fn upBinder(l: *State) *Binder {
    return @ptrCast(@alignCast(c.lua_touserdata(l, lua.upvalue(1))));
}

/// `at(type, address)`, a live view of `type` like `Player` or `u32[4]`. Nil at 0.
fn builtinAtC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b = upBinder(l);
    const text = lua.toString(l, 1) orelse return b.raise(l, b.fail(l, "at takes a type and an address", .{}));
    return b.viewAt(l, text, 2) catch |e| b.raise(l, e);
}

/// A view of `type_text` at the address at `idx`, or nil at 0.
fn viewAt(b: *Binder, l: *State, type_text: []const u8, idx: c_int) Error!c_int {
    const address: usize = if (views.at(l, idx)) |v| v.address else blk: {
        var is: c_int = 0;
        const n = c.lua_tointegerx(l, idx, &is);
        if (is == 0) return b.fail(l, "expected an address", .{});
        break :blk @bitCast(@as(isize, @truncate(n)));
    };
    if (address == 0) {
        c.lua_pushnil(l);
        return 1;
    }
    var diag: Schema.Diagnostic = .{};
    const s, const r = b.core.typeOf(type_text, &diag) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => b.fail(l, "{s}: {s}", .{ type_text, if (diag.message().len > 0) diag.message() else @errorName(e) }),
    };
    switch (script.views.place(s, r, address)) {
        .view => |v| views.push(b, l, v),
        else => return b.fail(l, "{s} isn't a struct, union, bitfield or array", .{type_text}),
    }
    return 1;
}

/// `addressOf(view)`, where it is.
fn builtinAddressOfC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b = upBinder(l);
    const v = views.at(l, 1) orelse return b.raise(l, b.fail(l, "addressOf takes a view", .{}));
    c.lua_pushinteger(l, @bitCast(@as(u64, v.address)));
    return 1;
}

/// `typeOf(view)`, its type like `Player` or `u32[4]`.
fn builtinTypeOfC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b = upBinder(l);
    const v = views.at(l, 1) orelse return b.raise(l, b.fail(l, "typeOf takes a view", .{}));
    var buf: [256]u8 = undefined;
    lua.pushString(l, std.fmt.bufPrint(&buf, "{f}", .{v.type}) catch "?");
    return 1;
}

/// `load(name, text)` loads a `.sal` written while running, in place of what was loaded as `name`.
/// Gives what it declares, like the `schema` module.
fn builtinLoadC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b = upBinder(l);
    const name = lua.toString(l, 1) orelse return b.raise(l, b.fail(l, "load takes a name and a schema's text", .{}));
    const text = lua.toString(l, 2) orelse return b.raise(l, b.fail(l, "load takes a name and a schema's text", .{}));
    var diag: Schema.Diagnostic = .{};
    const m = b.core.loadNamed(name, text, &diag) catch |e| return b.raise(l, switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => b.fail(l, "{s}", .{if (diag.message().len > 0) diag.message() else @errorName(e)}),
    });
    lua.newTable(l);
    const t = lua.top(l);
    b.fillSchema(l, t, m.schema()) catch |e| return b.raise(l, e);
    // Statics read and write through its metatable, like the `schema` module's
    b.pushStatics(l, "");
    _ = c.lua_setmetatable(l, t);
    return 1;
}

/// `snapshot(view)`, a plain table to change and `save`.
fn builtinSnapshotC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b = upBinder(l);
    const v = views.at(l, 1) orelse return b.raise(l, b.fail(l, "snapshot takes a view", .{}));
    views.snapshot(b, l, v) catch |e| return b.raise(l, e);
    return 1;
}

/// `save(copy)` writes back what changed in a snapshot and gives how many parts.
fn builtinSaveC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b = upBinder(l);
    const n = views.save(b, l, 1) catch |e| return b.raise(l, e);
    c.lua_pushinteger(l, @intCast(n));
    return 1;
}

/// `edit(view, fn)` calls `fn` with a snapshot, then saves it. Nothing's saved if it raises.
fn builtinEditC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b = upBinder(l);
    const v = views.at(l, 1) orelse return b.raise(l, b.fail(l, "edit takes a view and a function", .{}));
    if (lua.typeOf(l, 2) != c.LUA_TFUNCTION) return b.raise(l, b.fail(l, "edit takes a view and a function", .{}));
    c.lua_settop(l, 2);
    views.snapshot(b, l, v) catch |e| return b.raise(l, e);
    c.lua_pushvalue(l, 2);
    c.lua_pushvalue(l, 3);
    c.lua_callk(l, 1, 1, 0, null);
    _ = views.save(b, l, 3) catch |e| return b.raise(l, e);
    return 1;
}

/// `sizeOf(type)`, how many bytes a type or a view takes.
fn builtinSizeOfC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b = upBinder(l);
    if (views.at(l, 1)) |v| {
        c.lua_pushinteger(l, @intCast(v.size()));
        return 1;
    }
    const text = lua.toString(l, 1) orelse return b.raise(l, b.fail(l, "sizeOf takes a type or a view", .{}));
    var diag: Schema.Diagnostic = .{};
    const s, const r = b.core.typeOf(text, &diag) catch |e| return b.raise(l, switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => b.fail(l, "{s}: {s}", .{ text, if (diag.message().len > 0) diag.message() else @errorName(e) }),
    });
    c.lua_pushinteger(l, @intCast(memory.shapeOf(s, r).size));
    return 1;
}

/// The trait of a callable table `fn` made, if that's what's at `idx`.
fn typedFn(l: *State, idx: c_int) ?*Trait {
    if (lua.typeOf(l, idx) != c.LUA_TTABLE) return null;
    const at = c.lua_absindex(l, idx);
    if (c.lua_getmetatable(l, at) == 0) return null;
    _ = c.luaL_getmetatable(l, lua.cstr(fn_name));
    const same = c.lua_rawequal(l, -1, -2) != 0;
    lua.pop(l, 2);
    if (!same) return null;
    _ = c.lua_rawgeti(l, at, 2);
    defer lua.pop(l, 1);
    return @ptrCast(@alignCast(c.lua_touserdata(l, -1)));
}

/// Calls the function a typed one holds.
fn fnCallC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    _ = c.lua_rawgeti(l, 1, 1);
    c.lua_replace(l, 1);
    c.lua_callk(l, lua.top(l) - 1, c.LUA_MULTRET, 0, null);
    return lua.top(l);
}

fn signatureArg(b: *Binder, l: *State, idx: c_int) Error!script.Core(Binder).Signature {
    const text = lua.toString(l, idx) orelse return b.fail(l, "expected a signature, like `fn i32 (u32 a)`", .{});
    var diag: Schema.Diagnostic = .{};
    return b.core.signature(text, &diag) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSchema => b.fail(l, "{s}", .{diag.message()}),
        error.NotASignature => b.fail(l, "a signature looks like `fn i32 (u32 a)`, not `{s}`", .{text}),
        else => b.fail(l, "can't use `{s}`: {t}", .{ text, e }),
    };
}

fn builtinFnC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b: *Binder = @ptrCast(@alignCast(c.lua_touserdata(l, lua.upvalue(1))));
    return b.builtinFn(l) catch |e| b.raise(l, e);
}

/// `fn(signature, f)` types `f`, so native code taking an object gets a function value of that type.
fn builtinFn(b: *Binder, l: *State) Error!c_int {
    if (lua.typeOf(l, 2) != c.LUA_TFUNCTION) return b.fail(l, "fn takes a signature and a function", .{});
    const sig = try b.signatureArg(l, 1);
    c.lua_createtable(l, 2, 0);
    c.lua_pushvalue(l, 2);
    c.lua_rawseti(l, -2, 1);
    c.lua_pushlightuserdata(l, sig.trait);
    c.lua_rawseti(l, -2, 2);
    c.luaL_setmetatable(l, lua.cstr(fn_name));
    return 1;
}

fn builtinNativeC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b: *Binder = @ptrCast(@alignCast(c.lua_touserdata(l, lua.upvalue(1))));
    return b.builtinNative(l) catch |e| b.raise(l, e);
}

/// `native(signature, address)`, the native function at `address`.
fn builtinNative(b: *Binder, l: *State) Error!c_int {
    const sig = try b.signatureArg(l, 1);
    var is: c_int = 0;
    const address = c.lua_tointegerx(l, 2, &is);
    if (is == 0 or address == 0) return b.fail(l, "native needs an address that isn't 0", .{});
    c.lua_pushlightuserdata(l, b);
    c.lua_pushinteger(l, address);
    c.lua_pushlightuserdata(l, sig.trait);
    c.lua_pushlightuserdata(l, @constCast(sig.function));
    lua.pushClosure(l, callNativeC, 4);
    return 1;
}

fn callNativeC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b: *Binder = @ptrCast(@alignCast(c.lua_touserdata(l, lua.upvalue(1))));
    return b.callNative(l) catch |e| b.raise(l, e);
}

fn callNative(b: *Binder, l: *State) Error!c_int {
    const address: usize = @bitCast(@as(isize, @truncate(c.lua_tointegerx(l, lua.upvalue(2), null))));
    const t: *Trait = @ptrCast(@alignCast(c.lua_touserdata(l, lua.upvalue(3))));
    const function: *const bind.Function = @ptrCast(@alignCast(c.lua_touserdata(l, lua.upvalue(4))));
    return b.callAt(l, t, function, .{ .address = address }, 1);
}

const Where = union(enum) {
    address: usize,
    /// Found by the core's locator, through its vtable for a [Virtual(n)] one.
    declared: struct { name: []const u8, found: Schema.Function },
};

/// Arguments start at `first`. Pushes what it gives back.
fn callAt(b: *Binder, l: *State, t: *Trait, function: *const bind.Function, where: Where, first: c_int) Error!c_int {
    const sig = t.sig.?;
    const s = t.schema;
    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var ptrs: [bind.abi.max_args][*]const u8 = undefined;
    for (sig.params, 0..) |p, i| {
        const mem = try memory.alloc(a, memory.shapeOf(s, p.type));
        try convert.fromLua(b, l, s, p.type, first + @as(c_int, @intCast(i)), mem, a);
        ptrs[i] = mem;
    }
    const address = switch (where) {
        .address => |at| at,
        .declared => |d| blk: {
            const this: usize = if (d.found.hasThis() and sig.params.len > 0) @intCast(memory.bits(ptrs[0], s.pointer_size)) else 0;
            break :blk b.core.declaredAddress(d.name, d.found, this) catch |e| return b.locateFailed(l, d.name, e);
        },
    };
    const value = try memory.alloc(a, function.lowered.value);
    const code = bind.callAt(function, address, ptrs[0..sig.params.len], value);
    for (sig.params, 0..) |p, i| if (!p.keep) memory.releaseBlobs(s, p.type, ptrs[i]);
    const ret = switch (sig.ret) {
        .result => |res| blk: {
            if (code != 0) return b.failError(l, s, res.err, code);
            break :blk res.ok.*;
        },
        else => sig.ret,
    };
    if (ret == .prim and ret.prim == .void) return 0;
    try convert.toLua(b, l, s, ret, value);
    return 1;
}

pub fn locateFailed(b: *Binder, l: *State, name: []const u8, e: anyerror) Error {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    if (e == error.NoLocator) return b.fail(l, "{s}: nothing here finds the code schemas declare", .{name});
    return b.fail(l, "{s}: {s}", .{ name, script.withExplanation(b.core.host, @errorName(e)) });
}

/// Calls the declared function `name` with the arguments from `first` on. A method that takes `this`
/// gets it from the first.
fn callDeclared(b: *Binder, l: *State, name: []const u8, first: c_int) Error!c_int {
    const found = b.core.declared(name) orelse return b.fail(l, "{s} isn't declared", .{name});
    const f = switch (found) {
        .function => |f| f.found,
        .static => return b.fail(l, "{s} isn't a function", .{name}),
    };
    var diag: Schema.Diagnostic = .{};
    const sig = b.core.signature(name, &diag) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => b.fail(l, "{s}: {s}", .{ name, if (diag.message().len > 0) diag.message() else @errorName(e) }),
    };
    // A static method called as `view:method()` skips the view
    const from = if (!f.hasThis() and f.in != null and first == 1 and views.at(l, 1) != null) first + 1 else first;
    return b.callAt(l, sig.trait, sig.function, .{ .declared = .{ .name = name, .found = f } }, from);
}

// The `schema` module, for code that already exists like a game's. Structs are classes. Statics read
// memory each time, methods take `this` first and `at(address)` gives a view.

pub const schema_module = "schema";

/// Pushes a method of a view, which takes the view as `self`.
pub fn pushMethod(b: *Binder, l: *State, f: Schema.Function) Error!void {
    var buf: [256]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}.{s}", .{ f.in.?.name, f.method.name }) catch return error.OutOfMemory;
    b.pushDeclared(l, full);
}

/// A declared function, called with its arguments as they are.
fn pushDeclared(b: *Binder, l: *State, name: []const u8) void {
    c.lua_pushlightuserdata(l, b);
    lua.pushString(l, name);
    lua.pushClosure(l, callDeclaredC, 2);
}

fn callDeclaredC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b = upBinder(l);
    const name = lua.toString(l, lua.upvalue(2)).?;
    return b.callDeclared(l, name, 1) catch |e| b.raise(l, e);
}

pub fn pushSchema(b: *Binder, l: *State) Error!void {
    if (c.lua_checkstack(l, 8) == 0) return error.OutOfMemory;
    lua.newTable(l);
    const all = lua.top(l);
    var it = b.core.declaring();
    while (it.next()) |s| try b.fillSchema(l, all, s);
    b.pushStatics(l, "");
    _ = c.lua_setmetatable(l, all);
}

/// Puts classes for structs, functions and enums on the table at `all`.
fn fillSchema(b: *Binder, l: *State, all: c_int, s: Schema) Error!void {
    if (c.lua_checkstack(l, 8) == 0) return error.OutOfMemory;
    var buf: [256]u8 = undefined;
    for (s.types) |*t| {
        if (t.kind == .@"enum" and !t.nested) {
            // Its values by name, to combine flags
            lua.newTable(l);
            for (t.kind.@"enum".values) |v| {
                c.lua_pushinteger(l, @intCast(v.value));
                lua.rawSet(l, lua.top(l) - 1, v.name);
            }
            lua.rawSet(l, all, t.name);
            continue;
        }
        if (t.kind != .@"struct" or t.nested) continue;
        lua.newTable(l);
        const class = lua.top(l);
        var at: ?*const Schema.Type = t;
        var depth: usize = 0;
        while (at) |cur| : (at = s.baseOf(cur)) {
            depth += 1;
            if (depth > 32) break;
            for (cur.kind.@"struct".methods) |m| {
                if (lua.rawGet(l, class, m.name) != c.LUA_TNIL) {
                    lua.pop(l, 1);
                    continue;
                }
                lua.pop(l, 1);
                const full = std.fmt.bufPrint(&buf, "{s}.{s}", .{ t.name, m.name }) catch continue;
                b.pushDeclared(l, full);
                lua.rawSet(l, class, m.name);
            }
        }
        if (lua.rawGet(l, class, "at") == c.LUA_TNIL) {
            lua.pop(l, 1);
            c.lua_pushlightuserdata(l, b);
            lua.pushString(l, t.name);
            lua.pushClosure(l, classAtC, 2);
            lua.rawSet(l, class, "at");
        } else lua.pop(l, 1);
        b.pushStatics(l, t.name);
        _ = c.lua_setmetatable(l, class);
        lua.rawSet(l, all, t.name);
    }
    for (s.functions) |f| {
        b.pushDeclared(l, f.name);
        lua.rawSet(l, all, f.name);
    }
}

/// A metatable whose `__index` and `__newindex` read and write the statics of `owner`, or the
/// top-level ones for "".
fn pushStatics(b: *Binder, l: *State, owner: []const u8) void {
    c.lua_createtable(l, 0, 2);
    const mt = lua.top(l);
    c.lua_pushlightuserdata(l, b);
    lua.pushString(l, owner);
    lua.pushClosure(l, staticGetC, 2);
    lua.rawSet(l, mt, "__index");
    c.lua_pushlightuserdata(l, b);
    lua.pushString(l, owner);
    lua.pushClosure(l, staticSetC, 2);
    lua.rawSet(l, mt, "__newindex");
}

/// The static `key` of the owner in upvalue 2, if it's one.
fn staticAt(b: *Binder, l: *State, buf: []u8) Error!?struct { Schema, script.views.Member } {
    const owner = lua.toString(l, lua.upvalue(2)).?;
    const key = (if (c.lua_type(l, 2) == c.LUA_TSTRING) lua.toString(l, 2) else null) orelse return null;
    const name = if (owner.len == 0) key else std.fmt.bufPrint(buf, "{s}.{s}", .{ owner, key }) catch return null;
    const found = b.core.declared(name) orelse return null;
    const v = switch (found) {
        .static => |v| v,
        .function => return null,
    };
    const m = b.core.staticMember(name, v.schema, v.found.static) catch |e| return b.locateFailed(l, name, e);
    return .{ v.schema, m };
}

fn staticGetC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b = upBinder(l);
    var buf: [256]u8 = undefined;
    const found = (b.staticAt(l, &buf) catch |e| return b.raise(l, e)) orelse return 0;
    views.read(b, l, found[0], found[1]) catch |e| return b.raise(l, e);
    return 1;
}

fn staticSetC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b = upBinder(l);
    var buf: [256]u8 = undefined;
    const found = (b.staticAt(l, &buf) catch |e| return b.raise(l, e)) orelse {
        c.lua_rawset(l, 1);
        return 0;
    };
    views.write(b, l, found[0], found[1], 3) catch |e| return b.raise(l, e);
    return 0;
}

fn classAtC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b = upBinder(l);
    const name = lua.toString(l, lua.upvalue(2)).?;
    return b.viewAt(l, name, 1) catch |e| b.raise(l, e);
}

pub fn unwrapFn(b: *Binder, l: *State, t: *Trait, idx: c_int) Error!rt.AnyObject {
    if (lua.isNil(l, idx)) return .{};
    if (lua.typeOf(l, idx) != c.LUA_TFUNCTION) return b.fail(l, "expected a function", .{});
    return b.implement(l, t, idx);
}

/// A borrowed one while converting a borrowed argument. Otherwise kept once per Lua value.
fn implement(b: *Binder, l: *State, t: *Trait, idx: c_int) Error!rt.AnyObject {
    const base = lua.top(l);
    defer c.lua_settop(l, base);
    lua.pushRef(l, b.cache);
    c.lua_pushvalue(l, idx);
    _ = c.lua_rawget(l, base + 1);
    if (b.boxAt(l, -1)) |box| switch (box.*) {
        .object => |o| if (o.trait == t and o.obj.table != null) {
            if (b.core.ourImpl(o.obj)) |impl| b.core.hold(impl);
            return o.obj;
        },
        .settle => {},
    };
    c.lua_pushvalue(l, idx);
    const made = try b.core.make(t, lua.ref(l));
    if (made.kept) {
        c.lua_pushvalue(l, idx);
        newBox(l, .{ .object = .{ .binder = b, .trait = t, .obj = made.obj } });
        c.lua_rawset(l, base + 1);
    }
    return made.obj;
}

// Errors

/// Always `error.Raise`, with the message pending.
pub fn fail(b: *Binder, l: *State, comptime fmt: []const u8, args: anytype) error{Raise} {
    var buf: [256]u8 = undefined;
    lua.pushString(l, std.fmt.bufPrint(&buf, fmt, args) catch &buf);
    b.keepError(l);
    return error.Raise;
}

/// Pops the top into the pending error.
pub fn keepError(b: *Binder, l: *State) void {
    lua.unref(l, b.err);
    b.err = lua.ref(l);
}

/// Raises what's pending. Only with nothing left to clean up, since it longjmps.
pub fn raise(b: *Binder, l: *State, e: Error) c_int {
    switch (e) {
        error.OutOfMemory => lua.pushString(l, "out of memory"),
        error.Raise => {
            lua.pushRef(l, b.err);
            lua.unref(l, b.err);
            b.err = lua.noref;
        },
    }
    return c.lua_error(l);
}

/// Pushes an error named after `code` in `errors`, with `code` and `message`.
fn pushError(b: *Binder, l: *State, s: ?Schema, errors: []const u8, code: u32) void {
    const name = script.errorName(s, errors, code);
    c.lua_createtable(l, 0, 3);
    const at = lua.top(l);
    lua.pushString(l, name);
    lua.rawSet(l, at, "name");
    lua.pushString(l, script.withExplanation(b.core.host, name));
    lua.rawSet(l, at, "message");
    c.lua_pushinteger(l, code);
    lua.rawSet(l, at, "code");
    lua.pushRef(l, b.prelude.error_mt);
    _ = c.lua_setmetatable(l, at);
}

fn failError(b: *Binder, l: *State, s: ?Schema, errors: []const u8, code: u32) error{Raise} {
    b.pushError(l, s, errors, code);
    b.keepError(l);
    return error.Raise;
}

fn gone(b: *Binder, l: *State) error{Raise} {
    return b.failError(l, null, "", rt.gone_code);
}

/// The code for what a script raised, explained with its message for whoever gets the error.
fn errorCode(b: *Binder, l: *State, s: Schema, errors: ?[]const u8, idx: c_int) u32 {
    const at = c.lua_absindex(l, idx);
    const code = codeOf(l, s, errors, at);
    if (lua.toString(l, at)) |text| {
        script.explainThrown(b.core.host, s, errors, code, text);
    } else if (lua.typeOf(l, at) == c.LUA_TTABLE) {
        _ = lua.rawGet(l, at, "message");
        defer lua.pop(l, 1);
        if (lua.toString(l, -1)) |text| script.explainThrown(b.core.host, s, errors, code, text);
    }
    return code;
}

/// A table's `code` or `name`, or a string that's a name.
fn codeOf(l: *State, s: Schema, errors: ?[]const u8, at: c_int) u32 {
    if (lua.toString(l, at)) |name| return script.errorCode(s, errors, name);
    if (lua.typeOf(l, at) != c.LUA_TTABLE) return rt.unsupported_code;
    _ = lua.rawGet(l, at, "code");
    var is: c_int = 0;
    const n = c.lua_tointegerx(l, -1, &is);
    lua.pop(l, 1);
    if (is != 0 and n > 0 and n <= std.math.maxInt(u32)) return @intCast(n);
    _ = lua.rawGet(l, at, "name");
    defer lua.pop(l, 1);
    const name = lua.toString(l, -1) orelse return rt.unsupported_code;
    return script.errorCode(s, errors, name);
}

/// The code for what's pending, cleared.
fn pendingCode(b: *Binder, l: *State, s: Schema, errors: ?[]const u8) u32 {
    lua.pushRef(l, b.err);
    defer lua.pop(l, 1);
    lua.unref(l, b.err);
    b.err = lua.noref;
    return b.errorCode(l, s, errors, -1);
}

fn reportTop(b: *Binder, l: *State) void {
    b.reportWith(l, -1, null);
}

fn reportWith(b: *Binder, l: *State, idx: c_int, trace: ?[]const u8) void {
    const f = b.report orelse return;
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    describe(l, idx, &w);
    if (trace) |t| w.print("\n{s}", .{t}) catch {};
    f(b, w.buffered());
}

/// Text for an error, without calling into Lua.
pub fn describe(l: *State, idx: c_int, w: *std.Io.Writer) void {
    const at = c.lua_absindex(l, idx);
    if (lua.toString(l, at)) |s| return w.writeAll(s) catch {};
    if (lua.typeOf(l, at) == c.LUA_TTABLE) {
        inline for (.{ "message", "name" }) |key| {
            _ = lua.rawGet(l, at, key);
            defer lua.pop(l, 1);
            if (lua.toString(l, -1)) |s| return w.writeAll(s) catch {};
        }
    }
    w.print("(a {s})", .{std.mem.span(@as([*:0]const u8, @ptrCast(c.lua_typename(l, lua.typeOf(l, at)))))}) catch {};
}

fn reportC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b: *Binder = @ptrCast(@alignCast(c.lua_touserdata(l, lua.upvalue(1))));
    if (b.report) |f| f(b, lua.toString(l, 1) orelse "?");
    return 0;
}

fn tracebackC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    c.luaL_traceback(l, c.lua_tothread(l, 1), null, 0);
    return 1;
}

/// For `lua_pcall`, noting where the error came from and leaving it as it is.
fn onErrorC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b: *Binder = @ptrCast(@alignCast(c.lua_touserdata(l, lua.upvalue(1))));
    c.lua_settop(l, 1);
    c.luaL_traceback(l, l, null, 1);
    if (b.trace) |t| b.core.gpa.free(t);
    b.trace = if (lua.toString(l, -1)) |t| b.core.gpa.dupe(u8, t) catch null else null;
    lua.pop(l, 1);
    return 1;
}

// Scripts calling native objects

fn callMethodC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b: *Binder = @ptrCast(@alignCast(c.lua_touserdata(l, lua.upvalue(1))));
    const slot: usize = @intCast(c.lua_tointegerx(l, lua.upvalue(2), null));
    return b.callMethod(l, slot) catch |e| b.raise(l, e);
}

fn callMethod(b: *Binder, l: *State, slot: usize) Error!c_int {
    const box = b.boxAt(l, 1) orelse return b.fail(l, "call methods with ':', like obj:method()", .{});
    const o = switch (box.*) {
        .object => |o| o,
        .settle => return b.fail(l, "call methods with ':', like obj:method()", .{}),
    };
    if (o.obj.table == null) return b.gone(l);
    return b.invoke(l, o.trait.?, o.obj, slot, 2);
}

fn callFnC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b: *Binder = @ptrCast(@alignCast(c.lua_touserdata(l, lua.upvalue(1))));
    const box: *Box = @ptrCast(@alignCast(c.lua_touserdata(l, lua.upvalue(2))));
    const o = box.object;
    if (o.obj.table == null) return b.raise(l, b.gone(l));
    return b.invoke(l, o.trait.?, o.obj, 0, 1) catch |e| b.raise(l, e);
}

/// Arguments start at `first`. Leaves what it gives.
fn invoke(b: *Binder, l: *State, t: *Trait, obj: rt.AnyObject, slot: usize, first: c_int) Error!c_int {
    const was = b.cur;
    b.cur = l;
    defer b.cur = was;
    const m = t.methods[slot];
    const lowered = &(t.bound.methods[slot] orelse return b.fail(l, "{s} can't be called from script", .{m.name}));
    const s = t.schema;
    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Objects made for borrowed arguments, given back once the call's over
    var lent: std.ArrayList(*Impl) = .empty;
    defer b.core.giveBack(&lent);
    var ptrs: [bind.abi.max_args][*]const u8 = undefined;
    // What `inout` ones point at, written back after
    var targets: [bind.abi.max_args]?[*]u8 = @splat(null);
    for (m.signature.params, 0..) |p, i| {
        const mem = try memory.alloc(a, lowered.shapes[i]);
        const at = first + @as(c_int, @intCast(i));
        ptrs[i] = mem;
        if (p.inoutType()) |child| {
            const boxed = script.inoutBoxed(s, child);
            // Memory's already null
            if (p.nullable() and lua.isNil(l, at)) continue;
            if (lua.typeOf(l, at) != c.LUA_TTABLE) return b.fail(l, "{s} is inout, so it takes {s}", .{ p.name, if (boxed) "a { value = ... } box" else "a table" });
            const target = try memory.alloc(a, memory.shapeOf(s, child));
            if (boxed) {
                _ = lua.rawGet(l, at, "value");
                defer lua.pop(l, 1);
                try convert.fromLua(b, l, s, child, lua.top(l), target, a);
            } else try convert.fromLua(b, l, s, child, at, target, a);
            memory.put(mem, s.pointer_size, @intFromPtr(target));
            targets[i] = target;
            continue;
        }
        const was_lent = b.core.lending(if (p.keep) null else &lent);
        defer _ = b.core.lending(was_lent);
        try convert.fromLua(b, l, s, p.type, at, mem, a);
    }
    const value = try memory.alloc(a, lowered.value);
    const code = bind.call(t.bound, obj, slot, ptrs[0..m.signature.params.len], value);
    // Blobs made for borrowed arguments are ours to let go
    for (m.signature.params, 0..) |p, i| if (!p.keep and !p.inout) memory.releaseBlobs(s, p.type, ptrs[i]);
    for (m.signature.params, 0..) |p, i| {
        const target = targets[i] orelse continue;
        const at = c.lua_absindex(l, first + @as(c_int, @intCast(i)));
        const child = p.inoutType().?;
        try convert.toLua(b, l, s, child, target);
        if (script.inoutBoxed(s, child)) {
            lua.rawSet(l, at, "value");
        } else {
            assign(l, at, lua.top(l));
            lua.pop(l, 1);
        }
    }
    if (m.async) {
        try b.awaitPromise(l, t, slot, memory.object(value));
        return 1;
    }
    const ok, const errors = script.payload(m);
    if (script.isResult(m) and code != 0) return b.failError(l, s, errors.?, code);
    if (script.isVoid(ok)) return 0;
    // The script holds its own counts of blobs it was given
    defer memory.releaseBlobs(s, ok, value);
    try convert.toLua(b, l, s, ok, value);
    return 1;
}

/// Copies `src`'s fields into `dst`, like JS's `Object.assign`. Both absolute.
fn assign(l: *State, dst: c_int, src: c_int) void {
    c.lua_pushnil(l);
    while (c.lua_next(l, src) != 0) {
        // key, value, then key again under it for `next`
        c.lua_pushvalue(l, -2);
        lua.insert(l, -2);
        c.lua_rawset(l, dst);
    }
}

/// Pushes a prelude promise for a native one.
fn awaitPromise(b: *Binder, l: *State, t: *Trait, slot: usize, any: rt.AnyObject) Error!void {
    const promise: rt.core.Promise = .{ .data = any.data, .table = any.table };
    if (promise.table == null) return b.gone(l);
    const gpa = b.core.gpa;
    lua.pushRef(l, b.prelude.new_promise);
    if (lua.pcall(l, 0, 1, 0) != lua.ok) {
        promise.release();
        b.keepError(l);
        return error.Raise;
    }
    c.lua_pushvalue(l, -1);
    const lp = lua.ref(l);
    const a = gpa.create(Await) catch {
        promise.release();
        lua.unref(l, lp);
        return error.OutOfMemory;
    };
    a.* = .{ .gpa = gpa, .binder = b, .promise = promise, .lua_promise = lp, .trait = t, .slot = slot };
    b.awaits.append(gpa, a) catch {
        promise.release();
        lua.unref(l, lp);
        gpa.destroy(a);
        return error.OutOfMemory;
    };
    promise.then(rt.Task.init(a, settled), b.core.queue.raw());
}

/// Back on the script's thread with a native promise settled. Tasks waiting on it run at `runJobs`.
fn settled(a: *Await) void {
    defer a.gpa.destroy(a);
    const b = a.binder orelse {
        // The binder's gone, so nobody's waiting
        a.promise.release();
        return;
    };
    defer a.promise.release();
    if (std.mem.indexOfScalar(*Await, b.awaits.items, a)) |i| _ = b.awaits.swapRemove(i);
    const l = b.cur;
    const base = lua.top(l);
    defer c.lua_settop(l, base);
    defer lua.unref(l, a.lua_promise);
    if (c.lua_checkstack(l, 8) == 0) return;
    const s = a.trait.schema;
    const ok, const errors = script.payload(a.trait.methods[a.slot]);
    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
    defer arena.deinit();
    const shape: bind.abi.Shape = if (script.isVoid(ok)) .{ .size = 1, .alignment = 1 } else memory.shapeOf(s, ok);
    lua.pushRef(l, b.prelude.settle);
    lua.pushRef(l, a.lua_promise);
    const mem = memory.alloc(arena.allocator(), shape) catch return;
    const code = a.promise.take(mem);
    defer if (code == 0 and !script.isVoid(ok)) memory.releaseBlobs(s, ok, mem);
    if (code != 0) {
        c.lua_pushboolean(l, 0);
        b.pushError(l, s, errors orelse "", code);
    } else {
        c.lua_pushboolean(l, 1);
        convert.toLua(b, l, s, ok, mem) catch |e| {
            lua.pop(l, 1);
            c.lua_pushboolean(l, 0);
            if (e == error.Raise) lua.pushRef(l, b.err) else lua.pushString(l, "out of memory");
        };
    }
    if (lua.pcall(l, 3, 0, 0) != lua.ok) b.reportTop(l);
}

// Native code calling scripts

/// Native code calling a method a script implements. The core's checked it can.
pub fn dispatch(b: *Binder, impl: *Impl, method: u32, args: []const [*]u8, value: [*]u8) u32 {
    const l = b.cur;
    const base = lua.top(l);
    defer c.lua_settop(l, base);
    const t = impl.trait;
    const s = t.schema;
    const m = t.methods[method];
    const ok, const errors = script.payload(m);
    const is_result = script.isResult(m);
    if (c.lua_checkstack(l, @intCast(args.len + 8)) == 0) return if (is_result) rt.unsupported_code else 0;

    // Async ones run as tasks so they can await, others get a handler noting where errors came from
    if (m.async) {
        lua.pushRef(l, b.prelude.start);
    } else {
        c.lua_pushlightuserdata(l, b);
        lua.pushClosure(l, onErrorC, 1);
    }
    const handler = lua.top(l);
    lua.pushRef(l, impl.value);
    var nargs: c_int = 0;
    if (t.sig == null) {
        _ = lua.rawGet(l, handler + 1, m.name);
        if (lua.typeOf(l, -1) != c.LUA_TFUNCTION) return if (is_result) rt.unsupported_code else 0;
        // The function, then the table as `self`
        lua.insert(l, -2);
        nargs = 1;
    }

    // Native objects handed over for the call only, which stop working after
    var lent: std.ArrayList(c_int) = .empty;
    defer b.stopLent(l, &lent);
    // `inout` tables by registry ref and what they point at, read back after
    var inouts: [bind.abi.max_args]?struct { ref: c_int, target: [*]u8 } = @splat(null);
    defer for (inouts) |io| if (io) |x| lua.unref(l, x.ref);
    for (m.signature.params, args, 0..) |p, mem, i| {
        if (p.inoutType()) |child| {
            const target: ?[*]u8 = @ptrFromInt(@as(usize, @intCast(memory.bits(mem, s.pointer_size))));
            if (target) |at| {
                const boxed = script.inoutBoxed(s, child);
                if (boxed) c.lua_createtable(l, 0, 1);
                const box = lua.top(l);
                convert.toLua(b, l, s, child, at) catch {
                    if (is_result) return b.pendingCode(l, s, errors);
                    lua.pushRef(l, b.err);
                    b.reportTop(l);
                    return 0;
                };
                if (boxed) lua.rawSet(l, box, "value");
                c.lua_pushvalue(l, -1);
                inouts[i] = .{ .ref = lua.ref(l), .target = at };
            } else c.lua_pushnil(l);
            nargs += 1;
            continue;
        }
        const saved = b.lent_boxes;
        b.lent_boxes = if (p.keep) null else &lent;
        defer b.lent_boxes = saved;
        convert.toLua(b, l, s, p.type, mem) catch {
            if (is_result) return b.pendingCode(l, s, errors);
            lua.pushRef(l, b.err);
            b.reportTop(l);
            return 0;
        };
        nargs += 1;
    }

    if (m.async) {
        if (lua.pcall(l, nargs + 1, 3, 0) != lua.ok) {
            b.reportTop(l);
            return 0;
        }
        if (c.lua_toboolean(l, -3) != 0) return b.settledPromise(l, t, method, value, -2);
        return b.rejectedPromise(l, t, method, value, -2);
    }
    if (lua.pcall(l, nargs, 1, handler) != lua.ok) {
        if (is_result) return b.errorCode(l, s, errors, -1);
        b.reportWith(l, -1, b.trace);
        return 0;
    }
    for (m.signature.params, inouts[0..m.signature.params.len]) |p, io| {
        const x = io orelse continue;
        const child = p.inoutType().?;
        lua.pushRef(l, x.ref);
        defer lua.pop(l, 1);
        if (script.inoutBoxed(s, child)) {
            _ = lua.rawGet(l, lua.top(l), "value");
            defer lua.pop(l, 1);
            convert.fromLua(b, l, s, child, lua.top(l), x.target, b.core.returned()) catch return if (is_result) b.pendingCode(l, s, errors) else 0;
        } else convert.fromLua(b, l, s, child, lua.top(l), x.target, b.core.returned()) catch return if (is_result) b.pendingCode(l, s, errors) else 0;
    }
    const ret = if (is_result) ok else m.signature.ret;
    if (script.isVoid(ret)) return 0;
    convert.fromLua(b, l, s, ret, lua.top(l), value, b.core.returned()) catch {
        if (is_result) return b.pendingCode(l, s, errors);
        lua.pushRef(l, b.err);
        b.reportTop(l);
        return 0;
    };
    return 0;
}

/// Writes a native promise for the task promise at `idx` to `value`.
fn settledPromise(b: *Binder, l: *State, t: *Trait, slot: u32, value: [*]u8, idx: c_int) u32 {
    const p = c.lua_absindex(l, idx);
    const resolver = b.newPromise(t, slot, value) orelse return 0;
    lua.pushRef(l, b.prelude.watch);
    c.lua_pushvalue(l, p);
    c.lua_pushlightuserdata(l, b);
    newBox(l, .{ .settle = .{ .binder = b, .resolver = resolver, .trait = t, .slot = slot } });
    lua.pushClosure(l, onSettleC, 2);
    if (lua.pcall(l, 2, 0, 0) != lua.ok) b.reportTop(l);
    return 0;
}

fn rejectedPromise(b: *Binder, l: *State, t: *Trait, slot: u32, value: [*]u8, idx: c_int) u32 {
    const resolver = b.newPromise(t, slot, value) orelse return 0;
    _, const errors = script.payload(t.methods[slot]);
    resolver.reject(b.errorCode(l, t.schema, errors, idx));
    return 0;
}

fn newPromise(b: *Binder, t: *Trait, slot: u32, value: [*]u8) ?rt.core.Resolver {
    const ok, _ = script.payload(t.methods[slot]);
    const size = if (script.isVoid(ok)) 1 else memory.shapeOf(t.schema, ok).size;
    const promise, const resolver = b.core.host.promise(size) catch return null;
    memory.putObject(value, .{ .data = promise.data, .table = promise.table });
    return resolver;
}

fn resolveWith(b: *Binder, l: *State, t: *Trait, slot: usize, resolver: rt.core.Resolver, idx: c_int) void {
    const s = t.schema;
    const ok, const errors = script.payload(t.methods[slot]);
    if (script.isVoid(ok)) return resolver.resolve(null);
    // What it points at stays with the value till it's taken
    const a = rt.holding(&resolver);
    const mem = memory.alloc(a, memory.shapeOf(s, ok)) catch return resolver.reject(rt.unsupported_code);
    convert.fromLua(b, l, s, ok, c.lua_absindex(l, idx), mem, a) catch return resolver.reject(b.pendingCode(l, s, errors));
    resolver.resolve(mem);
}

/// What `watch` calls with `ok, value` once a task an async method started is done.
fn onSettleC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const b: *Binder = @ptrCast(@alignCast(c.lua_touserdata(l, lua.upvalue(1))));
    const box: *Box = @ptrCast(@alignCast(c.lua_touserdata(l, lua.upvalue(2))));
    const st = &box.settle;
    if (st.done) return 0;
    st.done = true;
    const was = b.cur;
    b.cur = l;
    defer b.cur = was;
    if (c.lua_toboolean(l, 1) != 0) {
        b.resolveWith(l, st.trait, st.slot, st.resolver, 2);
    } else {
        _, const errors = script.payload(st.trait.methods[st.slot]);
        st.resolver.reject(b.errorCode(l, st.trait.schema, errors, 2));
    }
    return 0;
}
