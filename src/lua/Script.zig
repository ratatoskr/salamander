//! A Lua script behind the engine interface, with its own state and the safe standard libraries.
//! `require` goes through the embedder's resolver. Scripts get `task.spawn`, `task.yield` and `:await()`.

const std = @import("std");
const rt = @import("salamander_runtime");
const script = @import("salamander_script");

const lua = @import("lua.zig");
const Binder = @import("Binder.zig");

const c = lua.c;
const engine = script.engine;
const State = lua.State;
const Allocator = std.mem.Allocator;

const Script = @This();

gpa: Allocator,
l: *State,
binder: *Binder,
queue: rt.Queue,
resolver: ?engine.Resolver,
report: ?engine.Report,
natives: engine.Natives = .{},
/// What `require` loaded, by name, by registry ref.
loaded: c_int = lua.noref,
/// The task `run` started, for `take`.
main: c_int = lua.noref,
last_error: std.ArrayList(u8) = .empty,
interrupted: std.atomic.Value(bool) = .init(false),

/// In instructions.
const check_every = 1000;

pub fn create(options: engine.Options) !engine.Script {
    const gpa = options.gpa;
    const host = options.host orelse rt.host();
    const self = try gpa.create(Script);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .l = undefined, .binder = undefined, .queue = try host.queue(), .resolver = options.resolver, .report = options.report };
    const l = c.lua_newstate(alloc, self, @truncate(@intFromPtr(self))) orelse return error.OutOfMemory;
    errdefer c.lua_close(l);
    self.l = l;
    const slot: **Script = @ptrFromInt(@intFromPtr(l) - @sizeOf(*anyopaque));
    slot.* = self;

    const libs = .{
        .{ "_G", c.luaopen_base },
        .{ "coroutine", c.luaopen_coroutine },
        .{ "table", c.luaopen_table },
        .{ "string", c.luaopen_string },
        .{ "math", c.luaopen_math },
        .{ "utf8", c.luaopen_utf8 },
    };
    inline for (libs) |lib| {
        c.luaL_requiref(l, lua.cstr(lib[0]), lib[1], 1);
        lua.pop(l, 1);
    }
    // Nothing that reaches files
    inline for (.{ "dofile", "loadfile" }) |name| {
        c.lua_pushnil(l);
        c.lua_setglobal(l, lua.cstr(name));
    }
    lua.newTable(l);
    self.loaded = lua.ref(l);
    c.lua_pushlightuserdata(l, self);
    lua.pushClosure(l, requireC, 1);
    c.lua_setglobal(l, lua.cstr("require"));

    self.binder = Binder.init(gpa, l, .{ .host = host, .queue = self.queue, .report = binderReport }) catch return error.OutOfMemory;
    self.binder.user = self;
    self.binder.core.policy = options.policy;
    self.binder.core.resume_on = options.resume_on;
    self.binder.core.schema_options = options.schema_options;
    self.binder.core.locator = options.locator;
    self.binder.pushTask(l);
    c.lua_setglobal(l, lua.cstr("task"));
    c.lua_sethook(l, onHook, c.LUA_MASKCOUNT, check_every);
    return .of(Script, self);
}

pub fn deinit(self: *Script) void {
    const gpa = self.gpa;
    self.binder.deinit();
    lua.unref(self.l, self.loaded);
    lua.unref(self.l, self.main);
    c.lua_close(self.l);
    self.natives.deinit(gpa);
    self.last_error.deinit(gpa);
    gpa.destroy(self);
}

fn of(l: *State) *Script {
    const slot: **Script = @ptrFromInt(@intFromPtr(l) - @sizeOf(*anyopaque));
    return slot.*;
}

/// Lua says how big a block was when it frees it.
fn alloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const self: *Script = @ptrCast(@alignCast(ud.?));
    const Block = [*]align(16) u8;
    if (nsize == 0) {
        if (ptr) |p| self.gpa.free(@as(Block, @ptrCast(@alignCast(p)))[0..osize]);
        return null;
    }
    const p = ptr orelse return (self.gpa.alignedAlloc(u8, .@"16", nsize) catch return null).ptr;
    const grown = self.gpa.realloc(@as(Block, @ptrCast(@alignCast(p)))[0..osize], nsize) catch return null;
    return grown.ptr;
}

fn onHook(l_: ?*State, _: [*c]c.lua_Debug) callconv(.c) void {
    const l = l_.?;
    if (of(l).interrupted.load(.monotonic)) _ = c.luaL_error(l, lua.cstr("interrupted"));
}

// Errors

fn binderReport(b: *Binder, message: []const u8) void {
    const self: *Script = @ptrCast(@alignCast(b.user.?));
    const r = self.report orelse return;
    r.f(r.ctx, message);
}

/// Makes what the binder has pending the last error.
fn keepPending(self: *Script) error{Thrown} {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    self.binder.takeError(self.l, &w);
    self.last_error.clearRetainingCapacity();
    self.last_error.appendSlice(self.gpa, w.buffered()) catch {};
    return error.Thrown;
}

fn failed(self: *Script, e: Binder.Error) engine.Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Raise => self.keepPending(),
    };
}

fn failedWith(self: *Script, comptime fmt: []const u8, args: anytype) error{Thrown} {
    self.last_error.clearRetainingCapacity();
    self.last_error.print(self.gpa, fmt, args) catch {};
    return error.Thrown;
}

// The engine interface

pub fn schema(self: *Script, source: []const u8) engine.Error!*const script.Module {
    self.binder.core.enter();
    defer self.binder.core.leave();
    var diag: @import("salamander_schema").Diagnostic = .{};
    return self.binder.load(source, &diag) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            self.last_error.clearRetainingCapacity();
            self.last_error.appendSlice(self.gpa, diag.message()) catch {};
            return error.Thrown;
        },
    };
}

/// Pushes a native object for a global or an export.
fn pushExport(self: *Script, l: *State, e: engine.Export) Binder.Error!void {
    const t = self.binder.trait(e.schema, e.trait) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => self.binder.fail(l, "no trait {s}", .{e.trait}),
    };
    try self.binder.wrap(l, t, e.obj);
}

pub fn expose(self: *Script, name: []const u8, e: engine.Export) engine.Error!void {
    self.binder.core.enter();
    defer self.binder.core.leave();
    const l = self.l;
    self.pushExport(l, e) catch |err| return self.failed(err);
    var buf: [256:0]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return error.OutOfMemory;
    c.lua_setglobal(l, lua.cstr(z));
}

pub fn module(self: *Script, name: []const u8, exports: []const engine.Export) engine.Error!void {
    try self.natives.add(self.gpa, name, exports);
}

pub fn namespaces(self: *Script, name: []const u8, roots: []const engine.Export, globals: bool) engine.Error!void {
    self.binder.core.enter();
    defer self.binder.core.leave();
    const l = self.l;
    const base = lua.top(l);
    defer c.lua_settop(l, base);
    self.binder.pushSchema(l) catch |err| return self.failed(err);
    const all = lua.top(l);
    for (roots) |r| self.binder.exposeRoot(l, all, r.schema, r.trait, r.obj) catch |err| return self.failed(err);
    if (globals) {
        var buf: [128]u8 = undefined;
        const clash = self.binder.globalsFrom(l, all, &buf) catch |err| return self.failed(err);
        if (clash) |n| return self.failedWith("the namespace {s} would hide Lua's own {s}", .{ n, n });
    }
    lua.pushRef(l, self.loaded);
    c.lua_pushvalue(l, all);
    lua.rawSet(l, lua.top(l) - 1, name);
}

pub fn extend(self: *Script, s: *const script.Module, trait: []const u8, source: []const u8) engine.Error!void {
    self.binder.core.enter();
    defer self.binder.core.leave();
    const l = self.l;
    const base = lua.top(l);
    defer c.lua_settop(l, base);
    const t = self.binder.trait(s, trait) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => self.failedWith("no trait {s}", .{trait}),
    };
    var name_buf: [256:0]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&name_buf, "={s} methods", .{trait}, 0) catch return error.OutOfMemory;
    if (lua.load(l, source, name) != lua.ok) {
        self.binder.keepError(l);
        return self.keepPending();
    }
    if (!self.binder.protectedCall(l, 0)) return self.keepPending();
    self.binder.extend(l, t, -1) catch |err| return self.failed(err);
}

/// The task promise on top's state. Lets go of the marker `run` puts on it.
fn taskState(l: *State) []const u8 {
    const p = lua.top(l);
    _ = lua.rawGet(l, p, "state");
    defer lua.pop(l, 1);
    return lua.toString(l, -1) orelse "pending";
}

pub fn run(self: *Script, source: []const u8, name: []const u8) engine.Error!void {
    self.binder.core.enter();
    defer self.binder.core.leave();
    defer self.interrupted.store(false, .monotonic);
    const l = self.l;
    const base = lua.top(l);
    defer c.lua_settop(l, base);
    var buf: [512:0]u8 = undefined;
    const chunk = std.fmt.bufPrintSentinel(&buf, "@{s}", .{name}, 0) catch return error.OutOfMemory;
    if (lua.load(l, source, chunk) != lua.ok) {
        self.binder.keepError(l);
        return self.keepPending();
    }
    if (!self.binder.startTask(l, 0)) return self.keepPending();
    const p = lua.top(l);
    // Kept for `take`, which reads what main returns
    lua.unref(l, self.main);
    c.lua_pushvalue(l, p);
    self.main = lua.ref(l);
    // Something waits on it while it runs, so failing settles it rather than being reported
    lua.newTable(l);
    lua.rawSet(l, p, "waiters");
    self.pumpJobs(self.queue);
    const state = taskState(l);
    if (std.mem.eql(u8, state, "rejected")) {
        _ = lua.rawGet(l, p, "value");
        self.binder.keepError(l);
        return self.keepPending();
    }
    if (std.mem.eql(u8, state, "pending")) {
        // Still going, so failing later is reported
        _ = lua.rawGet(l, p, "waiters");
        const none = c.lua_rawlen(l, -1) == 0;
        lua.pop(l, 1);
        if (none) {
            c.lua_pushnil(l);
            lua.rawSet(l, p, "waiters");
        }
    }
}

pub fn eval(self: *Script, source: []const u8, buf: []u8) engine.Evaluated {
    self.binder.core.enter();
    defer self.binder.core.leave();
    defer self.interrupted.store(false, .monotonic);
    const l = self.l;
    const base = lua.top(l);
    defer c.lua_settop(l, base);
    var w: std.Io.Writer = .fixed(buf);
    // As an expression first, so `1 + 1` shows 2
    var expr: [4096]u8 = undefined;
    const as_expr = std.fmt.bufPrint(&expr, "return {s}", .{source}) catch "";
    if (as_expr.len == 0 or lua.load(l, as_expr, "=eval") != lua.ok) {
        c.lua_settop(l, base);
        if (lua.load(l, source, "=eval") != lua.ok) {
            self.binder.keepError(l);
            self.binder.takeError(l, &w);
            return .{ .thrown = w.buffered() };
        }
    }
    if (!self.binder.startTask(l, 0)) {
        self.binder.takeError(l, &w);
        return .{ .thrown = w.buffered() };
    }
    const p = lua.top(l);
    lua.newTable(l);
    lua.rawSet(l, p, "waiters");
    self.pumpJobs(self.queue);
    const state = taskState(l);
    if (std.mem.eql(u8, state, "pending")) return .{ .value = "(running)" };
    _ = lua.rawGet(l, p, "value");
    if (std.mem.eql(u8, state, "rejected")) {
        Binder.describe(l, -1, &w);
        return .{ .thrown = w.buffered() };
    }
    show(l, -1, &w);
    return .{ .value = w.buffered() };
}

fn show(l: *State, idx: c_int, w: *std.Io.Writer) void {
    switch (lua.typeOf(l, idx)) {
        c.LUA_TNIL, c.LUA_TNONE => w.writeAll("nil") catch {},
        c.LUA_TBOOLEAN => w.writeAll(if (c.lua_toboolean(l, idx) != 0) "true" else "false") catch {},
        c.LUA_TNUMBER => if (c.lua_isinteger(l, idx) != 0)
            w.print("{d}", .{c.lua_tointegerx(l, idx, null)}) catch {}
        else
            w.print("{d}", .{c.lua_tonumberx(l, idx, null)}) catch {},
        c.LUA_TSTRING => w.writeAll(lua.toString(l, idx).?) catch {},
        else => Binder.describe(l, idx, w),
    }
}

pub fn take(self: *Script, name: []const u8, s: *const script.Module, trait: []const u8) engine.Error!rt.AnyObject {
    self.binder.core.enter();
    defer self.binder.core.leave();
    const l = self.l;
    const base = lua.top(l);
    defer c.lua_settop(l, base);
    const t = self.binder.trait(s, trait) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => self.failed(self.binder.fail(l, "no trait {s}", .{trait})),
    };
    var buf: [256:0]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return error.OutOfMemory;
    if (self.main == lua.noref) return self.failedWith("there's no main chunk to take {s} from", .{name});
    lua.pushRef(l, self.main);
    if (!std.mem.eql(u8, taskState(l), "fulfilled")) return self.failedWith("main hasn't finished, so {s} isn't there yet", .{name});
    _ = lua.rawGet(l, lua.top(l), "value");
    if (lua.typeOf(l, -1) != c.LUA_TTABLE) return self.failedWith("main doesn't return a table, so there's no {s}", .{name});
    _ = c.lua_getfield(l, -1, lua.cstr(z));
    if (lua.isNil(l, -1)) return self.failedWith("main's table has no {s}", .{name});
    return self.binder.unwrap(l, t, lua.top(l)) catch |err| self.failed(err);
}

pub fn pump(self: *Script) void {
    self.binder.core.enter();
    defer self.binder.core.leave();
    defer self.interrupted.store(false, .monotonic);
    self.pumpJobs(self.queue);
}

fn pumpJobs(self: *Script, queue: rt.Queue) void {
    for (0..64) |_| {
        if (queue.poll() == 0) break;
        self.binder.runJobs();
    }
    self.binder.runJobs();
}

/// Like `pump`, from another queue that `resume_on` posts to, on this thread.
pub fn pumpQueue(self: *Script, queue: rt.Queue, wait: bool) bool {
    if (wait) self.binder.core.enter() else if (!self.binder.core.tryEnter()) return false;
    defer self.binder.core.leave();
    defer self.interrupted.store(false, .monotonic);
    self.pumpJobs(queue);
    return true;
}

pub fn interrupt(self: *Script) void {
    self.interrupted.store(true, .monotonic);
}

// Modules

fn requireC(l_: ?*State) callconv(.c) c_int {
    const l = l_.?;
    const self: *Script = @ptrCast(@alignCast(c.lua_touserdata(l, lua.upvalue(1))));
    return self.require(l) catch |e| self.binder.raise(l, e);
}

/// A native module, or a script one through the resolver. Each loads once.
fn require(self: *Script, l: *State) Binder.Error!c_int {
    const b = self.binder;
    const name = lua.toString(l, 1) orelse return b.fail(l, "require: expected a module name", .{});
    c.lua_settop(l, 1);
    lua.pushRef(l, self.loaded);
    const loaded = lua.top(l);
    // What `namespaces` made, or a native module already loaded
    if (lua.rawGet(l, loaded, name) != c.LUA_TNIL) return 1;
    lua.pop(l, 1);

    if (std.mem.eql(u8, name, Binder.builtin_module)) {
        if (lua.rawGet(l, loaded, name) != c.LUA_TNIL) return 1;
        lua.pop(l, 1);
        b.pushBuiltin(l);
        c.lua_pushvalue(l, -1);
        lua.rawSet(l, loaded, name);
        return 1;
    }
    if (std.mem.eql(u8, name, Binder.schema_module)) {
        if (lua.rawGet(l, loaded, name) != c.LUA_TNIL) return 1;
        lua.pop(l, 1);
        try b.pushSchema(l);
        c.lua_pushvalue(l, -1);
        lua.rawSet(l, loaded, name);
        return 1;
    }
    if (self.natives.find(name)) |n| {
        if (lua.rawGet(l, loaded, name) != c.LUA_TNIL) return 1;
        lua.pop(l, 1);
        lua.newTable(l);
        const t = lua.top(l);
        for (n.exports) |e| {
            try self.pushExport(l, e);
            lua.rawSet(l, t, e.name);
        }
        c.lua_pushvalue(l, t);
        lua.rawSet(l, loaded, name);
        return 1;
    }

    const r = self.resolver orelse return b.fail(l, "can't require '{s}': there's no module by that name", .{name});
    var buf: [512:0]u8 = undefined;
    const resolved = r.resolve(r.ctx, buf[0 .. buf.len - 1], "", name) orelse return b.fail(l, "can't require '{s}'", .{name});
    if (lua.rawGet(l, loaded, resolved) != c.LUA_TNIL) return 1;
    lua.pop(l, 1);
    var chunk_buf: [514:0]u8 = undefined;
    const chunk = std.fmt.bufPrintSentinel(&chunk_buf, "@{s}", .{resolved}, 0) catch return b.fail(l, "can't require '{s}': its name is too long", .{name});
    const status = blk: {
        const source = r.read(r.ctx, self.gpa, resolved) orelse return b.fail(l, "can't require '{s}': there's no {s}", .{ name, resolved });
        defer self.gpa.free(source);
        break :blk lua.load(l, source, chunk);
    };
    if (status != lua.ok) {
        b.keepError(l);
        return error.Raise;
    }
    lua.pushString(l, resolved);
    if (!b.protectedCall(l, 1)) return error.Raise;
    if (lua.isNil(l, -1)) {
        lua.pop(l, 1);
        c.lua_pushboolean(l, 1);
    }
    c.lua_pushvalue(l, -1);
    lua.rawSet(l, loaded, resolved);
    return 1;
}
