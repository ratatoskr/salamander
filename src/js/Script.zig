//! A QuickJS-ng script behind the engine interface, with its own runtime and context.
//! ES modules go through the embedder's resolver.

const std = @import("std");
const rt = @import("salamander_runtime");
const script = @import("salamander_script");

const qjs = @import("qjs.zig");
const Binder = @import("Binder.zig");

const c = qjs.c;
const engine = script.engine;
const Value = qjs.Value;
const Allocator = std.mem.Allocator;

const Script = @This();

gpa: Allocator,
jrt: *c.JSRuntime,
ctx: *qjs.Context,
binder: *Binder,
queue: rt.Queue,
resolver: ?engine.Resolver,
report: ?engine.Report,
natives: engine.Natives = .{},
/// What `run` ran, for `take`.
main: ?*c.JSModuleDef = null,
/// What `require` ran, by name, as each one's `module`.
required: Value = qjs.undefined_value,
/// Promises rejected with nothing handling them yet.
rejections: std.ArrayList([2]Value) = .empty,
last_error: std.ArrayList(u8) = .empty,
interrupted: std.atomic.Value(bool) = .init(false),

pub fn create(options: engine.Options) !engine.Script {
    const gpa = options.gpa;
    const host = options.host orelse rt.host();
    const jrt = c.JS_NewRuntime() orelse return error.OutOfMemory;
    errdefer c.JS_FreeRuntime(jrt);
    const ctx = c.JS_NewContext(jrt) orelse return error.OutOfMemory;
    errdefer c.JS_FreeContext(ctx);
    const self = try gpa.create(Script);
    errdefer gpa.destroy(self);
    const queue = try host.queue();
    self.* = .{
        .gpa = gpa,
        .jrt = jrt,
        .ctx = ctx,
        .binder = undefined,
        .queue = queue,
        .resolver = options.resolver,
        .report = options.report,
    };
    self.binder = Binder.init(gpa, ctx, .{ .host = host, .queue = queue, .report = binderReport }) catch return error.OutOfMemory;
    self.binder.user = self;
    self.binder.core.policy = options.policy;
    self.binder.core.schema_options = options.schema_options;
    self.binder.core.locator = options.locator;
    c.JS_SetContextOpaque(ctx, self);
    c.JS_SetMaxStackSize(jrt, options.stack_size);
    if (options.memory_limit) |limit| c.JS_SetMemoryLimit(jrt, limit);
    c.JS_SetInterruptHandler(jrt, onInterrupt, self);
    c.JS_SetModuleLoaderFunc(jrt, normalize, load, self);
    c.JS_SetHostPromiseRejectionTracker(jrt, trackRejection, self);
    // Also a global, for code that isn't a module, like a console's
    const builtins = c.JS_NewObject(ctx);
    for (Binder.builtin_exports) |e| qjs.set(ctx, builtins, e, self.binder.builtin(e));
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    qjs.set(ctx, global, Binder.builtin_module, builtins);
    self.required = c.JS_NewObject(ctx);
    qjs.set(ctx, global, "require", c.JS_NewCFunction(ctx, require, qjs.cstr("require"), 1));
    return .of(Script, self);
}

pub fn deinit(self: *Script) void {
    const ctx = self.ctx;
    c.JS_FreeValue(ctx, self.required);
    self.binder.deinit();
    for (self.rejections.items) |r| {
        c.JS_FreeValue(ctx, r[0]);
        c.JS_FreeValue(ctx, r[1]);
    }
    self.rejections.deinit(self.gpa);
    self.natives.deinit(self.gpa);
    self.last_error.deinit(self.gpa);
    c.JS_FreeContext(ctx);
    c.JS_FreeRuntime(self.jrt);
    self.gpa.destroy(self);
}

fn of(ctx: *qjs.Context) *Script {
    return @ptrCast(@alignCast(c.JS_GetContextOpaque(ctx)));
}

// Errors

/// An exception's text and stack.
fn describe(ctx: *qjs.Context, e: Value, w: *std.Io.Writer) void {
    if (qjs.toString(ctx, e)) |s| {
        defer s.free();
        w.writeAll(s.slice()) catch {};
    } else {
        c.JS_FreeValue(ctx, c.JS_GetException(ctx));
        w.writeAll("(an exception that can't be shown)") catch {};
    }
    if (!c.JS_IsError(e)) return;
    const stack = qjs.get(ctx, e, "stack");
    defer c.JS_FreeValue(ctx, stack);
    if (!c.JS_IsString(stack)) return;
    const s = qjs.toString(ctx, stack) orelse return;
    defer s.free();
    const trimmed = std.mem.trimEnd(u8, s.slice(), "\n");
    if (trimmed.len != 0) w.print("\n{s}", .{trimmed}) catch {};
}

/// Makes `e` the last error.
fn keep(self: *Script, e: Value) void {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    describe(self.ctx, e, &w);
    self.last_error.clearRetainingCapacity();
    self.last_error.appendSlice(self.gpa, w.buffered()) catch {};
}

fn failed(self: *Script, comptime fmt: []const u8, args: anytype) error{Thrown} {
    self.last_error.clearRetainingCapacity();
    self.last_error.print(self.gpa, fmt, args) catch {};
    return error.Thrown;
}

fn keepPending(self: *Script) error{Thrown} {
    const e = c.JS_GetException(self.ctx);
    defer c.JS_FreeValue(self.ctx, e);
    self.keep(e);
    return error.Thrown;
}

fn say(self: *Script, prefix: []const u8, e: Value) void {
    const r = self.report orelse return;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll(prefix) catch {};
    describe(self.ctx, e, &w);
    r.f(r.ctx, w.buffered());
}

fn binderReport(b: *Binder, e: Value) void {
    const self: *Script = @ptrCast(@alignCast(b.user.?));
    self.say("", e);
}

fn trackRejection(ctx_: ?*qjs.Context, p: Value, reason: Value, handled: bool, opaque_: ?*anyopaque) callconv(.c) void {
    const self: *Script = @ptrCast(@alignCast(opaque_.?));
    if (handled) return self.forgetRejection(p);
    const ctx = ctx_.?;
    self.rejections.append(self.gpa, .{ c.JS_DupValue(ctx, p), c.JS_DupValue(ctx, reason) }) catch {};
}

fn forgetRejection(self: *Script, p: Value) void {
    for (self.rejections.items, 0..) |r, i| if (c.JS_IsStrictEqual(self.ctx, r[0], p)) {
        c.JS_FreeValue(self.ctx, r[0]);
        c.JS_FreeValue(self.ctx, r[1]);
        _ = self.rejections.orderedRemove(i);
        return;
    };
}

fn reportRejections(self: *Script) void {
    for (self.rejections.items) |r| {
        self.say("Unhandled promise rejection: ", r[1]);
        c.JS_FreeValue(self.ctx, r[0]);
        c.JS_FreeValue(self.ctx, r[1]);
    }
    self.rejections.clearRetainingCapacity();
}

fn onInterrupt(_: ?*qjs.Context, opaque_: ?*anyopaque) callconv(.c) c_int {
    const self: *Script = @ptrCast(@alignCast(opaque_.?));
    return @intFromBool(self.interrupted.load(.monotonic));
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

/// A native object as a JS value, for a global or an export.
fn exported(self: *Script, e: engine.Export) engine.Error!Value {
    const t = self.binder.trait(e.schema, e.trait) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Exception => self.keepPending(),
    };
    return self.binder.wrap(t, e.obj) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Exception => self.keepPending(),
    };
}

pub fn expose(self: *Script, name: []const u8, e: engine.Export) engine.Error!void {
    self.binder.core.enter();
    defer self.binder.core.leave();
    const v = try self.exported(e);
    const g = c.JS_GetGlobalObject(self.ctx);
    defer c.JS_FreeValue(self.ctx, g);
    qjs.set(self.ctx, g, name, v);
}

pub fn module(self: *Script, name: []const u8, exports: []const engine.Export) engine.Error!void {
    try self.natives.add(self.gpa, name, exports);
}

pub fn run(self: *Script, source: []const u8, name: []const u8) engine.Error!void {
    self.binder.core.enter();
    defer self.binder.core.leave();
    defer self.interrupted.store(false, .monotonic);
    var buf: [512:0]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return error.OutOfMemory;
    const compiled = self.eval_(source, qjs.cstr(z), c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
    if (c.JS_IsException(compiled)) return self.keepPending();
    // The context keeps every module, so this stays good for `take`
    self.main = @ptrCast(c.JS_VALUE_GET_PTR(compiled));
    const result = c.JS_EvalFunction(self.ctx, compiled);
    defer c.JS_FreeValue(self.ctx, result);
    if (c.JS_IsException(result)) return self.keepPending();
    // A module runs as a promise since it may await at the top
    self.pumpJobs();
    if (c.JS_PromiseState(self.ctx, result) == c.JS_PROMISE_REJECTED) {
        self.forgetRejection(result);
        const why = c.JS_PromiseResult(self.ctx, result);
        defer c.JS_FreeValue(self.ctx, why);
        self.keep(why);
        return error.Thrown;
    }
}

pub fn eval(self: *Script, source: []const u8, buf: []u8) engine.Evaluated {
    self.binder.core.enter();
    defer self.binder.core.leave();
    defer self.interrupted.store(false, .monotonic);
    const ctx = self.ctx;
    const v = self.eval_(source, qjs.cstr("<eval>"), c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, v);
    var w: std.Io.Writer = .fixed(buf);
    if (c.JS_IsException(v)) {
        const e = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, e);
        describe(ctx, e, &w);
        return .{ .thrown = w.buffered() };
    }
    self.pumpJobs();
    show(ctx, v, &w);
    return .{ .value = w.buffered() };
}

/// As JSON where it can be, else as a string.
fn show(ctx: *qjs.Context, v: Value, w: *std.Io.Writer) void {
    if (!c.JS_IsString(v) and !c.JS_IsUndefined(v) and !c.JS_IsFunction(ctx, v)) {
        const json = c.JS_JSONStringify(ctx, v, qjs.undefined_value, qjs.undefined_value);
        defer c.JS_FreeValue(ctx, json);
        if (c.JS_IsString(json)) if (qjs.toString(ctx, json)) |s| {
            defer s.free();
            return w.writeAll(s.slice()) catch {};
        };
        if (c.JS_IsException(json)) c.JS_FreeValue(ctx, c.JS_GetException(ctx));
    }
    const s = qjs.toString(ctx, v) orelse {
        c.JS_FreeValue(ctx, c.JS_GetException(ctx));
        return w.writeAll("(a value that can't be shown)") catch {};
    };
    defer s.free();
    w.writeAll(s.slice()) catch {};
}

pub fn take(self: *Script, name: []const u8, s: *const script.Module, trait: []const u8) engine.Error!rt.AnyObject {
    self.binder.core.enter();
    defer self.binder.core.leave();
    const t = self.binder.trait(s, trait) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Exception => self.keepPending(),
    };
    const main = self.main orelse return self.failed("there's no main module to take {s} from", .{name});
    const ns = c.JS_GetModuleNamespace(self.ctx, main);
    if (c.JS_IsException(ns)) return self.keepPending();
    defer c.JS_FreeValue(self.ctx, ns);
    const v = qjs.get(self.ctx, ns, name);
    defer c.JS_FreeValue(self.ctx, v);
    if (c.JS_IsUndefined(v)) return self.failed("the main module doesn't export {s}", .{name});
    return self.binder.unwrap(t, v) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Exception => self.keepPending(),
    };
}

pub fn pump(self: *Script) void {
    self.binder.core.enter();
    defer self.binder.core.leave();
    defer self.interrupted.store(false, .monotonic);
    self.pumpJobs();
}

fn pumpJobs(self: *Script) void {
    // Settling can queue jobs, and jobs can settle, so round a few times
    for (0..64) |_| {
        const polled = self.queue.poll();
        var ran = false;
        var pctx: ?*qjs.Context = null;
        while (true) {
            const r = c.JS_ExecutePendingJob(self.jrt, &pctx);
            if (r == 0) break;
            ran = true;
            if (r < 0) {
                const e = c.JS_GetException(self.ctx);
                defer c.JS_FreeValue(self.ctx, e);
                self.say("", e);
            }
        }
        if (polled == 0 and !ran) break;
    }
    self.reportRejections();
}

pub fn interrupt(self: *Script) void {
    self.interrupted.store(true, .monotonic);
}

/// QuickJS reads one past the end, so the source gets a 0 after it.
fn eval_(self: *Script, source: []const u8, name: [*c]const u8, flags: c_int) qjs.Value {
    const z = self.gpa.allocSentinel(u8, source.len, 0) catch return c.JS_ThrowOutOfMemory(self.ctx);
    @memcpy(z, source);
    defer self.gpa.free(z);
    return c.JS_Eval(self.ctx, qjs.chars(z), z.len, name, flags);
}

// Modules

fn normalize(ctx_: ?*qjs.Context, base_: [*c]const u8, name_: [*c]const u8, opaque_: ?*anyopaque) callconv(.c) [*c]u8 {
    const ctx = ctx_.?;
    const self: *Script = @ptrCast(@alignCast(opaque_.?));
    const base = std.mem.span(@as([*:0]const u8, @ptrCast(base_)));
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(name_)));
    if (self.natives.find(name) != null or std.mem.eql(u8, name, Binder.builtin_module) or std.mem.eql(u8, name, Binder.schema_module)) return c.js_strdup(ctx, name_);
    const r = self.resolver orelse {
        _ = qjs.throw(ctx, "can't import '{s}': there's no module by that name", .{name});
        return null;
    };
    var buf: [512:0]u8 = undefined;
    const resolved = r.resolve(r.ctx, buf[0 .. buf.len - 1], base, name) orelse {
        _ = qjs.throw(ctx, "can't import '{s}'", .{name});
        return null;
    };
    buf[resolved.len] = 0;
    return c.js_strndup(ctx, qjs.chars(resolved), resolved.len);
}

fn load(ctx_: ?*qjs.Context, name_: [*c]const u8, opaque_: ?*anyopaque) callconv(.c) ?*c.JSModuleDef {
    const ctx = ctx_.?;
    const self: *Script = @ptrCast(@alignCast(opaque_.?));
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(name_)));
    if (self.natives.find(name)) |n| {
        const m = c.JS_NewCModule(ctx, name_, initNative) orelse return null;
        for (n.exports) |e| {
            var buf: [256:0]u8 = undefined;
            const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{e.name}, 0) catch continue;
            _ = c.JS_AddModuleExport(ctx, m, qjs.cstr(z));
        }
        return m;
    }
    if (std.mem.eql(u8, name, Binder.builtin_module)) {
        const m = c.JS_NewCModule(ctx, name_, initBuiltin) orelse return null;
        for (Binder.builtin_exports) |e| _ = c.JS_AddModuleExport(ctx, m, qjs.cstr(e));
        return m;
    }
    if (std.mem.eql(u8, name, Binder.schema_module)) {
        const m = c.JS_NewCModule(ctx, name_, initSchema) orelse return null;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var names: std.ArrayList([:0]const u8) = .empty;
        self.binder.schemaExports(&names, arena.allocator()) catch {
            _ = c.JS_ThrowOutOfMemory(ctx);
            return null;
        };
        _ = c.JS_AddModuleExport(ctx, m, qjs.cstr("default"));
        for (names.items) |e| _ = c.JS_AddModuleExport(ctx, m, qjs.cstr(e));
        return m;
    }
    const r = self.resolver orelse return null;
    const source = r.read(r.ctx, self.gpa, name) orelse {
        _ = qjs.throw(ctx, "can't load module '{s}'", .{name});
        return null;
    };
    defer self.gpa.free(source);
    const module_ = self.eval_(source, name_, c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
    if (c.JS_IsException(module_)) return null;
    const def: *c.JSModuleDef = @ptrCast(c.JS_VALUE_GET_PTR(module_));
    c.JS_FreeValue(ctx, module_);
    return def;
}

/// For CommonJS libraries that set `exports` or `module.exports`. Each runs once, found through
/// the resolver like imports are.
fn require(ctx_: ?*qjs.Context, this: Value, argc: c_int, argv: [*c]Value) callconv(.c) Value {
    _ = this;
    const ctx = ctx_.?;
    const self = of(ctx);
    if (argc < 1) return qjs.throw(ctx, "require needs a name", .{});
    const s = qjs.toString(ctx, argv[0]) orelse return qjs.exception;
    defer s.free();
    const name = s.slice();
    if (self.requireNative(ctx, name)) |v| return v;
    const r = self.resolver orelse return qjs.throw(ctx, "can't require '{s}': there's no module by that name", .{name});
    var buf: [512]u8 = undefined;
    const resolved = r.resolve(r.ctx, &buf, "", name) orelse return qjs.throw(ctx, "can't require '{s}': there's no module by that name", .{name});
    var key_buf: [512:0]u8 = undefined;
    const key = std.fmt.bufPrintSentinel(&key_buf, "{s}", .{resolved}, 0) catch return qjs.throw(ctx, "can't require '{s}': its name is too long", .{name});
    const cached = c.JS_GetPropertyStr(ctx, self.required, qjs.cstr(key));
    if (!c.JS_IsUndefined(cached)) {
        defer c.JS_FreeValue(ctx, cached);
        return qjs.get(ctx, cached, "exports");
    }
    const source = r.read(r.ctx, self.gpa, key) orelse return qjs.throw(ctx, "can't load '{s}'", .{name});
    defer self.gpa.free(source);
    // On the first line, so its lines stay its own
    const wrapped = std.mem.concat(self.gpa, u8, &.{ "(function (exports, require, module) {", source, "\n})" }) catch return c.JS_ThrowOutOfMemory(ctx);
    defer self.gpa.free(wrapped);
    const f = self.eval_(wrapped, qjs.cstr(key), c.JS_EVAL_TYPE_GLOBAL);
    if (c.JS_IsException(f)) return f;
    defer c.JS_FreeValue(ctx, f);
    const module_ = c.JS_NewObject(ctx);
    defer c.JS_FreeValue(ctx, module_);
    qjs.set(ctx, module_, "exports", c.JS_NewObject(ctx));
    // Kept before it runs, so a cycle gets what's there so far
    _ = c.JS_SetPropertyStr(ctx, self.required, qjs.cstr(key), c.JS_DupValue(ctx, module_));
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    var args = [3]Value{ qjs.get(ctx, module_, "exports"), qjs.get(ctx, global, "require"), c.JS_DupValue(ctx, module_) };
    defer for (args) |a| c.JS_FreeValue(ctx, a);
    const ran = c.JS_Call(ctx, f, qjs.undefined_value, 3, &args);
    if (c.JS_IsException(ran)) {
        // So the next try runs it again
        _ = c.JS_SetPropertyStr(ctx, self.required, qjs.cstr(key), qjs.undefined_value);
        return ran;
    }
    c.JS_FreeValue(ctx, ran);
    return qjs.get(ctx, module_, "exports");
}

/// A native module, the schema or the builtins as one object, like importing all of it. Made once.
/// Null if `name` is none of them.
fn requireNative(self: *Script, ctx: *qjs.Context, name: []const u8) ?Value {
    const native = self.natives.find(name);
    const is_schema = std.mem.eql(u8, name, Binder.schema_module);
    const is_builtin = std.mem.eql(u8, name, Binder.builtin_module);
    if (native == null and !is_schema and !is_builtin) return null;
    var key_buf: [512:0]u8 = undefined;
    const key = std.fmt.bufPrintSentinel(&key_buf, "native:{s}", .{name}, 0) catch return qjs.throw(ctx, "can't require '{s}': its name is too long", .{name});
    const cached = c.JS_GetPropertyStr(ctx, self.required, qjs.cstr(key));
    if (!c.JS_IsUndefined(cached)) return cached;

    const obj = if (is_schema) self.binder.schemaObject() catch return qjs.exception else c.JS_NewObject(ctx);
    if (native) |n| for (n.exports) |e| {
        const v = self.exported(e) catch {
            c.JS_FreeValue(ctx, obj);
            return qjs.throw(ctx, "can't export {s}", .{e.name});
        };
        var buf: [256:0]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{e.name}, 0) catch {
            c.JS_FreeValue(ctx, v);
            continue;
        };
        _ = c.JS_SetPropertyStr(ctx, obj, qjs.cstr(z), v);
    };
    if (is_builtin) for (Binder.builtin_exports) |e| {
        const f = self.binder.builtin(e);
        if (c.JS_IsException(f)) {
            c.JS_FreeValue(ctx, obj);
            return f;
        }
        _ = c.JS_SetPropertyStr(ctx, obj, qjs.cstr(e), f);
    };
    _ = c.JS_SetPropertyStr(ctx, self.required, qjs.cstr(key), c.JS_DupValue(ctx, obj));
    return obj;
}

fn initBuiltin(ctx_: ?*qjs.Context, m: ?*c.JSModuleDef) callconv(.c) c_int {
    const ctx = ctx_.?;
    const self = of(ctx);
    for (Binder.builtin_exports) |e| {
        const f = self.binder.builtin(e);
        if (c.JS_IsException(f)) return -1;
        if (c.JS_SetModuleExport(ctx, m, qjs.cstr(e), f) < 0) return -1;
    }
    return 0;
}

/// Everything's on the default export, and structs and functions are named ones too.
fn initSchema(ctx_: ?*qjs.Context, m: ?*c.JSModuleDef) callconv(.c) c_int {
    const ctx = ctx_.?;
    const self = of(ctx);
    const all = self.binder.schemaObject() catch return -1;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    var names: std.ArrayList([:0]const u8) = .empty;
    self.binder.schemaExports(&names, arena.allocator()) catch {
        c.JS_FreeValue(ctx, all);
        _ = c.JS_ThrowOutOfMemory(ctx);
        return -1;
    };
    for (names.items) |e| {
        if (c.JS_SetModuleExport(ctx, m, qjs.cstr(e), c.JS_GetPropertyStr(ctx, all, qjs.cstr(e))) < 0) {
            c.JS_FreeValue(ctx, all);
            return -1;
        }
    }
    return c.JS_SetModuleExport(ctx, m, qjs.cstr("default"), all);
}

fn initNative(ctx_: ?*qjs.Context, m: ?*c.JSModuleDef) callconv(.c) c_int {
    const ctx = ctx_.?;
    const self = of(ctx);
    const atom = c.JS_GetModuleName(ctx, m);
    defer c.JS_FreeAtom(ctx, atom);
    const name_v = c.JS_AtomToString(ctx, atom);
    defer c.JS_FreeValue(ctx, name_v);
    const name = qjs.toString(ctx, name_v) orelse return -1;
    defer name.free();
    const n = self.natives.find(name.slice()) orelse return -1;
    for (n.exports) |e| {
        const v = self.exported(e) catch {
            _ = qjs.throw(ctx, "can't export {s}", .{e.name});
            return -1;
        };
        var buf: [256:0]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{e.name}, 0) catch {
            c.JS_FreeValue(ctx, v);
            continue;
        };
        if (c.JS_SetModuleExport(ctx, m, qjs.cstr(z), v) < 0) return -1;
    }
    return 0;
}
