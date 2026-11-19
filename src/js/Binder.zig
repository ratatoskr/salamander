//! Traits in a QuickJS context, one per context. Any thread can call in, one at a time, through the core's gate.
//! Errors are thrown named after them with the code in `code`. Promises settle when `queue` is polled.
//! Objects lent for a borrowed parameter stop working when the call returns.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const rt = @import("salamander_runtime");
const bind = @import("salamander_bind");
const script = @import("salamander_script");

const qjs = @import("qjs.zig");
const convert = @import("convert.zig");
pub const views = @import("views.zig");

const c = qjs.c;
const memory = script.memory;
const Schema = salamander_schema.Schema;
const Allocator = std.mem.Allocator;

const Binder = @This();

pub const Value = qjs.Value;
pub const Core = script.Core(Binder);
pub const Trait = Core.Trait;
pub const Scope = Core.Scope;
pub const Impl = Core.Impl;
pub const Module = script.Module;

pub const TraitData = struct {
    proto: Value = qjs.undefined_value,
};

core: Core,
ctx: *qjs.Context,
/// Gets exceptions nobody else will see, like ones thrown by a method that has no result.
report: ?*const fn (b: *Binder, exception: Value) void,
/// For whoever made the binder.
user: ?*anyopaque = null,
class: c.JSClassID = 0,
/// For live views of memory, see `views.zig`.
view_class: c.JSClassID = 0,
/// What a snapshot holds, under `copy_atom`.
copy_class: c.JSClassID = 0,
copy_atom: c.JSAtom = 0,
/// Where a JS value keeps the native object kept for it.
cache: c.JSAtom,
/// On functions `salamander.fn` typed, holding their signature's trait.
fn_tag: c.JSAtom,
/// Set while converting a borrowed argument for the script, to boxes that stop working after.
lent_boxes: ?*std.ArrayList(Value) = null,
awaits: std.ArrayList(*Await) = .empty,

pub const Options = struct {
    host: ?rt.Host = null,
    queue: rt.Queue,
    report: ?*const fn (b: *Binder, exception: Value) void = null,
};

/// What the binder's class holds.
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
    funcs: [2]Value,
    trait: *Trait,
    slot: usize,
};

pub fn init(gpa: Allocator, ctx: *qjs.Context, options: Options) error{ OutOfMemory, Exception }!*Binder {
    const b = try gpa.create(Binder);
    errdefer gpa.destroy(b);
    const sym = c.JS_NewPrivateSymbol(ctx, qjs.cstr("salamander"));
    if (c.JS_IsException(sym)) return error.Exception;
    defer c.JS_FreeValue(ctx, sym);
    const tag = c.JS_NewPrivateSymbol(ctx, qjs.cstr("salamander.fn"));
    if (c.JS_IsException(tag)) return error.Exception;
    defer c.JS_FreeValue(ctx, tag);
    b.* = .{ .core = undefined, .ctx = ctx, .report = options.report, .cache = c.JS_ValueToAtom(ctx, sym), .fn_tag = c.JS_ValueToAtom(ctx, tag) };
    errdefer c.JS_FreeAtom(ctx, b.cache);
    errdefer c.JS_FreeAtom(ctx, b.fn_tag);
    const jrt = c.JS_GetRuntime(ctx);
    _ = c.JS_NewClassID(jrt, &b.class);
    var def = std.mem.zeroes(c.JSClassDef);
    def.class_name = qjs.cstr("Salamander");
    def.finalizer = finalize;
    if (c.JS_NewClass(jrt, b.class, &def) < 0) return error.OutOfMemory;
    try views.register(b);
    try b.core.init(gpa, options.host orelse rt.host(), options.queue);
    return b;
}

/// Stops calls into what scripts made and lets it all go. Free the context after, with no JS in between.
pub fn deinit(b: *Binder) void {
    const gpa = b.core.gpa;
    b.core.deinit();
    for (b.awaits.items) |a| {
        a.binder = null;
        for (a.funcs) |f| c.JS_FreeValue(b.ctx, f);
    }
    b.awaits.deinit(gpa);
    c.JS_FreeAtom(b.ctx, b.cache);
    c.JS_FreeAtom(b.ctx, b.fn_tag);
    c.JS_FreeAtom(b.ctx, b.copy_atom);
    gpa.destroy(b);
}

/// Parses a `.sal` and keeps it.
pub fn load(b: *Binder, source: []const u8, diagnostic: ?*Schema.Diagnostic) !*Module {
    return b.core.load(source, diagnostic);
}

pub fn trait(b: *Binder, m: *const Module, name: []const u8) convert.Error!*Trait {
    return b.core.trait(m, name) catch |e| b.traitFailed(e, name);
}

pub fn traitOf(b: *Binder, s: Schema, decl: *const Schema.Trait) convert.Error!*Trait {
    return b.core.traitOf(s, decl) catch |e| b.traitFailed(e, decl.name);
}

pub fn fnOf(b: *Binder, s: Schema, sig: *const Schema.Signature) convert.Error!*Trait {
    return b.core.fnOf(s, sig) catch |e| b.traitFailed(e, "fn");
}

fn traitFailed(b: *Binder, e: script.TraitError, name: []const u8) convert.Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.NoSuchTrait => convert.throw(b.ctx, "no trait {s}", .{name}),
        error.TooManyMethods => convert.throw(b.ctx, "{s} has too many methods", .{name}),
    };
}

pub fn openScope(b: *Binder, name: []const u8) error{OutOfMemory}!*Scope {
    return b.core.openScope(name);
}

pub fn closeScope(b: *Binder, s: *Scope) void {
    b.core.closeScope(s);
}

// What the core needs

pub fn initTrait(b: *Binder, t: *Trait) error{OutOfMemory}!void {
    if (t.sig != null) return;
    const proto = c.JS_NewObject(b.ctx);
    if (c.JS_IsException(proto)) return error.OutOfMemory;
    t.lang.proto = proto;
    for (t.methods, 0..) |m, i| {
        if (t.bound.methods[i] == null) continue;
        var name: [256:0]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&name, "{s}", .{m.name}, 0) catch continue;
        const f = c.JS_NewCFunctionMagic(b.ctx, callMethod, qjs.cstr(z), @intCast(m.signature.params.len), c.JS_CFUNC_generic_magic, @intCast(i));
        qjs.set(b.ctx, proto, m.name, f);
    }
}

/// A thread's just come in, so QuickJS measures its stack from here.
pub fn entered(b: *Binder) void {
    c.JS_UpdateStackTop(c.JS_GetRuntime(b.ctx));
}

pub fn deinitTrait(b: *Binder, t: *Trait) void {
    c.JS_FreeValue(b.ctx, t.lang.proto);
}

/// Lets go of an impl's JS value, and of the JS value's link to it.
pub fn forget(b: *Binder, impl: *Impl) void {
    const ctx = b.ctx;
    const cached = c.JS_GetProperty(ctx, impl.value, b.cache);
    defer c.JS_FreeValue(ctx, cached);
    if (b.boxOf(cached)) |box| switch (box.*) {
        .object => |*o| if (o.obj.data == @intFromPtr(&impl.record)) {
            o.obj = .{};
            _ = c.JS_DeleteProperty(ctx, impl.value, b.cache, 0);
        },
        .settle => {},
    };
    c.JS_FreeValue(ctx, impl.value);
    impl.value = qjs.undefined_value;
}

// Boxes for native objects

fn newBox(b: *Binder, proto: ?Value, box: Box) error{ Exception, OutOfMemory }!Value {
    const v = if (proto) |p| c.JS_NewObjectProtoClass(b.ctx, p, b.class) else c.JS_NewObjectClass(b.ctx, @intCast(b.class));
    if (c.JS_IsException(v)) return error.Exception;
    const p: *Box = @ptrCast(@alignCast(c.js_malloc_rt(c.JS_GetRuntime(b.ctx), @sizeOf(Box)) orelse {
        c.JS_FreeValue(b.ctx, v);
        return error.OutOfMemory;
    }));
    p.* = box;
    _ = c.JS_SetOpaque(v, p);
    return v;
}

fn boxOf(b: *Binder, v: Value) ?*Box {
    return @ptrCast(@alignCast(c.JS_GetOpaque(v, b.class)));
}

fn finalize(jrt: ?*c.JSRuntime, v: Value) callconv(.c) void {
    var id: c.JSClassID = 0;
    const box: *Box = @ptrCast(@alignCast(c.JS_GetAnyOpaque(v, &id) orelse return));
    switch (box.*) {
        // Never going to settle, so whoever waits gets Gone
        .settle => |*s| if (!s.done) s.resolver.drop(),
        .object => {},
    }
    c.js_free_rt(jrt, box);
}

/// `obj` as a JS object with `t`'s methods, or the JS value it came from if it's ours.
pub fn wrap(b: *Binder, t: *Trait, obj: rt.AnyObject) convert.Error!Value {
    if (obj.table == null) return qjs.null_value;
    if (b.core.ourImpl(obj)) |impl| return c.JS_DupValue(b.ctx, impl.value);
    return b.lend(try b.newBox(t.lang.proto, .{ .object = .{ .binder = b, .trait = t, .obj = obj } }));
}

/// Any object, which scripts can only hand back.
pub fn wrapAny(b: *Binder, obj: rt.AnyObject) convert.Error!Value {
    if (obj.table == null) return qjs.null_value;
    if (b.core.ourImpl(obj)) |impl| return c.JS_DupValue(b.ctx, impl.value);
    return b.lend(try b.newBox(null, .{ .object = .{ .binder = b, .trait = null, .obj = obj } }));
}

pub fn wrapFn(b: *Binder, t: *Trait, obj: rt.AnyObject) convert.Error!Value {
    if (obj.table == null) return qjs.null_value;
    if (b.core.ourImpl(obj)) |impl| return c.JS_DupValue(b.ctx, impl.value);
    var data = try b.lend(try b.newBox(null, .{ .object = .{ .binder = b, .trait = t, .obj = obj } }));
    defer c.JS_FreeValue(b.ctx, data);
    const f = c.JS_NewCFunctionData(b.ctx, callFn, @intCast(t.sig.?.params.len), 0, 1, &data);
    if (c.JS_IsException(f)) return error.Exception;
    return f;
}

/// Notes a box made for a borrowed argument, so it can stop working after the call.
fn lend(b: *Binder, box: Value) convert.Error!Value {
    const list = b.lent_boxes orelse return box;
    list.append(b.core.gpa, c.JS_DupValue(b.ctx, box)) catch {
        c.JS_FreeValue(b.ctx, box);
        c.JS_FreeValue(b.ctx, box);
        return error.OutOfMemory;
    };
    return box;
}

fn stopLent(b: *Binder, lent: *std.ArrayList(Value)) void {
    for (lent.items) |v| {
        if (b.boxOf(v)) |box| switch (box.*) {
            .object => |*o| o.obj = .{},
            .settle => {},
        };
        c.JS_FreeValue(b.ctx, v);
    }
    lent.deinit(b.core.gpa);
}

/// The native object a wrapped one holds, or `v` as a `t`.
pub fn unwrap(b: *Binder, t: *Trait, v: Value) convert.Error!rt.AnyObject {
    if (qjs.isNullish(v)) return .{};
    if (b.boxOf(v)) |box| switch (box.*) {
        .object => |o| {
            if (o.obj.table == null) return b.gone();
            if (o.trait == t) return o.obj;
            // Another version, or another schema's copy of it
            const adapted = b.core.host.raw().adapt(o.obj, @ptrCast(@constCast(t.bound.info)));
            if (adapted.table == null) return convert.throw(b.ctx, "that isn't a {s}", .{t.decl.name});
            return adapted;
        },
        .settle => return convert.throw(b.ctx, "that isn't a {s}", .{t.decl.name}),
    };
    if (!c.JS_IsObject(v)) return convert.throw(b.ctx, "expected an object for {s}", .{t.decl.name});
    return b.implement(t, v);
}

pub fn unwrapAny(b: *Binder, v: Value) convert.Error!rt.AnyObject {
    if (qjs.isNullish(v)) return .{};
    // A function `salamander.fn` gave a type
    if (c.JS_IsFunction(b.ctx, v)) {
        const tag = c.JS_GetProperty(b.ctx, v, b.fn_tag);
        defer c.JS_FreeValue(b.ctx, tag);
        if (c.JS_IsNumber(tag)) {
            var at: i64 = 0;
            _ = c.JS_ToInt64(b.ctx, &at, tag);
            return b.implement(@ptrFromInt(@as(usize, @intCast(at))), v);
        }
    }
    if (b.boxOf(v)) |box| switch (box.*) {
        .object => |o| return if (o.obj.table == null) b.gone() else o.obj,
        .settle => {},
    };
    return convert.throw(b.ctx, "expected a salamander object", .{});
}

pub fn unwrapFn(b: *Binder, t: *Trait, v: Value) convert.Error!rt.AnyObject {
    if (qjs.isNullish(v)) return .{};
    if (!c.JS_IsFunction(b.ctx, v)) return convert.throw(b.ctx, "expected a function", .{});
    return b.implement(t, v);
}

// The `salamander` module scripts import, for types they write while running

pub const builtin_module = "salamander";
pub const builtin_exports = [_][:0]const u8{ "fn", "native", "at", "addressOf", "typeOf", "sizeOf", "snapshot", "save", "edit", "load" };

/// One of `builtin_exports`, as a function.
pub fn builtin(b: *Binder, name: []const u8) Value {
    var data = c.JS_NewInt64(b.ctx, @bitCast(@as(u64, @intFromPtr(b))));
    const Builtin = @TypeOf(&builtinFn);
    const table = [_]struct { []const u8, Builtin }{
        .{ "fn", &builtinFn },
        .{ "native", &builtinNative },
        .{ "at", &builtinAt },
        .{ "addressOf", &builtinAddressOf },
        .{ "typeOf", &builtinTypeOf },
        .{ "sizeOf", &builtinSizeOf },
        .{ "snapshot", &builtinSnapshot },
        .{ "save", &builtinSave },
        .{ "edit", &builtinEdit },
        .{ "load", &builtinLoad },
    };
    const f = for (table) |e| {
        if (std.mem.eql(u8, e[0], name)) break e[1];
    } else unreachable;
    return c.JS_NewCFunctionData(b.ctx, f, 2, 0, 1, &data);
}

/// `at(type, address)`, a live view of `type` like `Player` or `u32[4]`. Null at 0.
fn builtinAt(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    if (argc < 2) return qjs.throw(ctx, "at takes a type and an address", .{});
    return binderData(ctx, data[0]).viewAt(argv[0], argv[1]);
}

/// `addressOf(view)`, where it is.
fn builtinAddressOf(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    const v = (if (argc > 0) views.of(b, argv[0]) else null) orelse return qjs.throw(ctx, "addressOf takes a view", .{});
    return c.JS_NewInt64(ctx, @bitCast(@as(u64, v.address)));
}

/// `typeOf(view)`, its type like `Player` or `u32[4]`.
fn builtinTypeOf(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    const v = (if (argc > 0) views.of(b, argv[0]) else null) orelse return qjs.throw(ctx, "typeOf takes a view", .{});
    var buf: [256]u8 = undefined;
    return qjs.string(ctx, std.fmt.bufPrint(&buf, "{f}", .{v.type}) catch "?");
}

/// `load(name, text)` loads a `.sal` written while running, in place of what was loaded as `name`.
/// Its names work from then on, and it gives what it declares like the `schema` module.
fn builtinLoad(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    if (argc < 2) return qjs.throw(ctx, "load takes a name and a schema's text", .{});
    const name = qjs.toString(ctx, argv[0]) orelse return qjs.exception;
    defer name.free();
    const text = qjs.toString(ctx, argv[1]) orelse return qjs.exception;
    defer text.free();
    var diag: Schema.Diagnostic = .{};
    const m = b.core.loadNamed(name.slice(), text.slice(), &diag) catch |e| return switch (e) {
        error.OutOfMemory => c.JS_ThrowOutOfMemory(ctx),
        else => qjs.throw(ctx, "{s}", .{if (diag.message().len > 0) diag.message() else @errorName(e)}),
    };
    const out = c.JS_NewObject(ctx);
    if (c.JS_IsException(out)) return out;
    b.fillSchema(out, m.schema()) catch |e| {
        c.JS_FreeValue(ctx, out);
        return failed(ctx, e);
    };
    return out;
}

/// `snapshot(view)`, a plain copy to change and `save`.
fn builtinSnapshot(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    const v = (if (argc > 0) views.of(b, argv[0]) else null) orelse return qjs.throw(ctx, "snapshot takes a view", .{});
    return views.snapshot(b, v) catch |e| failed(ctx, e);
}

/// `save(copy)` writes back what changed in a snapshot and gives how many parts.
fn builtinSave(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    if (argc < 1) return qjs.throw(ctx, "save takes a snapshot", .{});
    const n = views.save(b, argv[0]) catch |e| return failed(ctx, e);
    return c.JS_NewInt64(ctx, @intCast(n));
}

/// `edit(view, fn)` calls `fn` with a snapshot and saves it after, once its promise resolves if it
/// gives one. Nothing's saved if it throws.
fn builtinEdit(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    const v = (if (argc > 1) views.of(b, argv[0]) else null) orelse return qjs.throw(ctx, "edit takes a view and a function", .{});
    if (!c.JS_IsFunction(ctx, argv[1])) return qjs.throw(ctx, "edit takes a view and a function", .{});
    const plain = views.snapshot(b, v) catch |e| return failed(ctx, e);
    defer c.JS_FreeValue(ctx, plain);
    var args = [_]Value{plain};
    const r = c.JS_Call(ctx, argv[1], qjs.undefined_value, 1, &args);
    if (c.JS_IsException(r)) return r;
    const then = if (c.JS_IsObject(r)) qjs.get(ctx, r, "then") else qjs.undefined_value;
    defer c.JS_FreeValue(ctx, then);
    if (!c.JS_IsFunction(ctx, then)) {
        _ = views.save(b, plain) catch |e| {
            c.JS_FreeValue(ctx, r);
            return failed(ctx, e);
        };
        return r;
    }
    defer c.JS_FreeValue(ctx, r);
    var held = [_]Value{ data[0], plain };
    const after = c.JS_NewCFunctionData(ctx, saveThen, 1, 0, held.len, &held);
    if (c.JS_IsException(after)) return after;
    defer c.JS_FreeValue(ctx, after);
    var then_args = [_]Value{after};
    return c.JS_Call(ctx, then, r, 1, &then_args);
}

/// Saves the copy in `data[1]` once `edit`'s promise resolves, giving what it resolved to.
fn saveThen(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    _ = views.save(b, data[1]) catch |e| return failed(ctx, e);
    return if (argc > 0) c.JS_DupValue(ctx, argv[0]) else qjs.undefined_value;
}

/// `sizeOf(type)`, how many bytes a type or a view takes.
fn builtinSizeOf(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    if (argc < 1) return qjs.throw(ctx, "sizeOf takes a type or a view", .{});
    if (views.of(b, argv[0])) |v| return c.JS_NewInt64(ctx, @intCast(v.size()));
    const text = qjs.toString(ctx, argv[0]) orelse return qjs.exception;
    defer text.free();
    var diag: Schema.Diagnostic = .{};
    const s, const r = b.core.typeOf(text.slice(), &diag) catch |e| return switch (e) {
        error.OutOfMemory => c.JS_ThrowOutOfMemory(ctx),
        else => qjs.throw(ctx, "{s}: {s}", .{ text.slice(), if (diag.message().len > 0) diag.message() else @errorName(e) }),
    };
    return c.JS_NewInt64(ctx, @intCast(memory.shapeOf(s, r).size));
}

/// A word kept in a function's data, like a pointer.
fn dataWord(ctx: *qjs.Context, v: Value) usize {
    var at: i64 = 0;
    _ = c.JS_ToInt64(ctx, &at, v);
    return @truncate(@as(u64, @bitCast(at)));
}

fn binderData(ctx: *qjs.Context, v: Value) *Binder {
    return @ptrFromInt(dataWord(ctx, v));
}

fn signatureArg(b: *Binder, v: Value) convert.Error!script.Core(Binder).Signature {
    const text = qjs.toString(b.ctx, v) orelse return error.Exception;
    defer text.free();
    var diag: Schema.Diagnostic = .{};
    return b.core.signature(text.slice(), &diag) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSchema => convert.throw(b.ctx, "{s}", .{diag.message()}),
        error.NotASignature => convert.throw(b.ctx, "a signature looks like `fn i32 (u32 a)`, not `{s}`", .{text.slice()}),
        else => convert.throw(b.ctx, "can't use `{s}`: {t}", .{ text.slice(), e }),
    };
}

/// `fn(signature, f)` types `f`, so native code taking an object gets a function value of that type.
fn builtinFn(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    if (argc < 2 or !c.JS_IsFunction(ctx, argv[1])) return qjs.throw(ctx, "fn takes a signature and a function", .{});
    const sig = b.signatureArg(argv[0]) catch |e| return failed(ctx, e);
    if (c.JS_SetProperty(ctx, argv[1], b.fn_tag, c.JS_NewInt64(ctx, @bitCast(@as(u64, @intFromPtr(sig.trait))))) < 0) return qjs.exception;
    return c.JS_DupValue(ctx, argv[1]);
}

/// `native(signature, address)`, the native function at `address`.
fn builtinNative(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    if (argc < 2) return qjs.throw(ctx, "native takes a signature and an address", .{});
    const sig = b.signatureArg(argv[0]) catch |e| return failed(ctx, e);
    var address: i64 = 0;
    if (c.JS_ToInt64Ext(ctx, &address, argv[1]) < 0) return qjs.exception;
    if (address == 0) return qjs.throw(ctx, "native needs an address that isn't 0", .{});
    var held = [_]Value{
        data[0],
        c.JS_NewInt64(ctx, address),
        c.JS_NewInt64(ctx, @bitCast(@as(u64, @intFromPtr(sig.trait)))),
        c.JS_NewInt64(ctx, @bitCast(@as(u64, @intFromPtr(sig.function)))),
    };
    return c.JS_NewCFunctionData(ctx, callNative, @intCast(sig.trait.sig.?.params.len), 0, held.len, &held);
}

fn callNative(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    const address = dataWord(ctx, data[1]);
    const t: *Trait = @ptrFromInt(dataWord(ctx, data[2]));
    const function: *const bind.Function = @ptrFromInt(dataWord(ctx, data[3]));
    return b.callAt(t, function, .{ .address = address }, argv[0..@intCast(argc)]);
}

const Where = union(enum) {
    address: usize,
    /// Found by the core's locator. A given `this` goes before the script's arguments. A [Virtual(n)]
    /// one's found through its vtable, or else the first argument's.
    declared: struct { name: []const u8, found: Schema.Function, this: ?usize = null },
};

fn callAt(b: *Binder, t: *Trait, function: *const bind.Function, where: Where, args: []const Value) Value {
    const ctx = b.ctx;
    const sig = t.sig.?;
    const s = t.schema;
    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var ptrs: [bind.abi.max_args][*]const u8 = undefined;
    var this_word: usize = 0;
    const bound: ?usize = switch (where) {
        .declared => |d| if (d.found.hasThis()) d.this else null,
        .address => null,
    };
    // The script's arguments start after a bound `this`
    const first: usize = if (bound != null) 1 else 0;
    if (bound) |this| {
        if (sig.params.len == 0) return qjs.throw(ctx, "nothing to pass `this` to", .{});
        this_word = this;
        ptrs[0] = std.mem.asBytes(&this_word);
    }
    for (sig.params[first..], first..) |p, i| {
        const mem = memory.alloc(a, memory.shapeOf(s, p.type)) catch return c.JS_ThrowOutOfMemory(ctx);
        const arg = i - first;
        convert.fromJs(b, s, p.type, if (arg < args.len) args[arg] else qjs.undefined_value, mem, a) catch |e| return failed(ctx, e);
        ptrs[i] = mem;
    }
    const address = switch (where) {
        .address => |at| at,
        .declared => |d| blk: {
            const this: usize = if (d.found.hasThis() and sig.params.len > 0) @intCast(memory.bits(ptrs[0], s.pointer_size)) else 0;
            break :blk b.core.declaredAddress(d.name, d.found, this) catch |e| return b.locateFailed(d.name, e);
        },
    };
    const value = memory.alloc(a, function.lowered.value) catch return c.JS_ThrowOutOfMemory(ctx);
    const code = bind.callAt(function, address, ptrs[0..sig.params.len], value);
    for (sig.params[first..], first..) |p, i| if (!p.keep) memory.releaseBlobs(s, p.type, ptrs[i]);
    switch (sig.ret) {
        .result => |res| {
            if (code != 0) return c.JS_Throw(ctx, b.makeError(s, res.err, code));
            return convert.toJs(b, s, res.ok.*, value) catch |e| failed(ctx, e);
        },
        else => return convert.toJs(b, s, sig.ret, value) catch |e| failed(ctx, e),
    }
}

pub fn locateFailed(b: *Binder, name: []const u8, e: anyerror) Value {
    if (e == error.OutOfMemory) return c.JS_ThrowOutOfMemory(b.ctx);
    if (e == error.NoLocator) return qjs.throw(b.ctx, "{s}: nothing here finds the code schemas declare", .{name});
    return qjs.throw(b.ctx, "{s}: {s}", .{ name, script.withExplanation(b.core.host, @errorName(e)) });
}

/// Calls the declared function `name`, with `this` first for a bound method.
fn callDeclared(b: *Binder, name: []const u8, this: ?usize, args: []const Value) Value {
    const found = b.core.declared(name) orelse return qjs.throw(b.ctx, "{s} isn't declared", .{name});
    const f = switch (found) {
        .function => |f| f.found,
        .static => return qjs.throw(b.ctx, "{s} isn't a function", .{name}),
    };
    var diag: Schema.Diagnostic = .{};
    const sig = b.core.signature(name, &diag) catch |e| return switch (e) {
        error.OutOfMemory => c.JS_ThrowOutOfMemory(b.ctx),
        else => qjs.throw(b.ctx, "{s}: {s}", .{ name, if (diag.message().len > 0) diag.message() else @errorName(e) }),
    };
    return b.callAt(sig.trait, sig.function, .{ .declared = .{ .name = name, .found = f, .this = this } }, args);
}

// The `schema` module, for code that already exists like a game's. Structs with code or statics are
// classes. Statics read memory each time, methods take `this` first and `at(address)` gives a view.

pub const schema_module = "schema";

/// Structs and top-level functions. Top-level statics are only on the default export, since an
/// export can't read memory each time.
pub fn schemaExports(b: *Binder, out: *std.ArrayList([:0]const u8), a: std.mem.Allocator) error{OutOfMemory}!void {
    var it = b.core.declaring();
    while (it.next()) |s| {
        for (s.types) |t| if ((t.kind == .@"struct" or t.kind == .@"enum") and !t.nested) try out.append(a, try dupeZ(a, t.name));
        for (s.functions) |f| try out.append(a, try dupeZ(a, f.name));
    }
}

fn dupeZ(a: std.mem.Allocator, text: []const u8) error{OutOfMemory}![:0]const u8 {
    const out = try a.allocSentinel(u8, text.len, 0);
    @memcpy(out, text);
    return out;
}

/// The `schema` module's default export, with everything on it.
pub fn schemaObject(b: *Binder) convert.Error!Value {
    const all = c.JS_NewObject(b.ctx);
    if (c.JS_IsException(all)) return error.Exception;
    errdefer c.JS_FreeValue(b.ctx, all);
    var it = b.core.declaring();
    while (it.next()) |s| try b.fillSchema(all, s);
    return all;
}

/// Puts classes for structs, functions, statics and enums on `all`.
fn fillSchema(b: *Binder, all: Value, s: Schema) convert.Error!void {
    const ctx = b.ctx;
    var buf: [256]u8 = undefined;
    for (s.types) |*t| {
        if (t.kind == .@"enum" and !t.nested) {
            // Its values by name, to combine flags like `WindowFlags.NoTitleBar | WindowFlags.NoMove`
            const values = c.JS_NewObject(ctx);
            if (c.JS_IsException(values)) return error.Exception;
            for (t.kind.@"enum".values) |v| qjs.set(ctx, values, v.name, c.JS_NewInt64(ctx, @intCast(v.value)));
            qjs.set(ctx, all, t.name, values);
            continue;
        }
        if (t.kind != .@"struct" or t.nested) continue;
        const class = c.JS_NewObject(ctx);
        if (c.JS_IsException(class)) return error.Exception;
        qjs.set(ctx, all, t.name, class);
        // Bases' first, so the struct's own win
        var chain: [32]*const Schema.Type = undefined;
        var depth: usize = 0;
        var at: ?*const Schema.Type = t;
        while (at) |cur| : (at = s.baseOf(cur)) {
            if (depth == chain.len) break;
            chain[depth] = cur;
            depth += 1;
        }
        var i = depth;
        while (i > 0) {
            i -= 1;
            const st = chain[i].kind.@"struct";
            for (st.methods) |m| {
                const full = std.fmt.bufPrint(&buf, "{s}.{s}", .{ t.name, m.name }) catch continue;
                qjs.set(ctx, class, m.name, try b.declaredFunction(full, m.signature.params.len));
            }
            for (st.statics) |v| {
                const full = std.fmt.bufPrint(&buf, "{s}.{s}", .{ t.name, v.name }) catch continue;
                try b.declaredStatic(class, v.name, full);
            }
        }
        if (s.findFunction(std.fmt.bufPrint(&buf, "{s}.at", .{t.name}) catch continue) == null)
            qjs.set(ctx, class, "at", try b.classAt(t.name));
    }
    for (s.functions) |f| qjs.set(ctx, all, f.name, try b.declaredFunction(f.name, f.signature.params.len));
    for (s.statics) |v| try b.declaredStatic(all, v.name, v.name);
}

fn binderWord(b: *Binder) Value {
    return c.JS_NewInt64(b.ctx, @bitCast(@as(u64, @intFromPtr(b))));
}

fn declaredFunction(b: *Binder, name: []const u8, params: usize) convert.Error!Value {
    var data = [_]Value{ b.binderWord(), qjs.string(b.ctx, name) };
    defer c.JS_FreeValue(b.ctx, data[1]);
    const f = c.JS_NewCFunctionData(b.ctx, callDeclaredJs, @intCast(params), 0, data.len, &data);
    if (c.JS_IsException(f)) return error.Exception;
    return f;
}

fn callDeclaredJs(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    const name = qjs.toString(ctx, data[1]) orelse return qjs.exception;
    defer name.free();
    return b.callDeclared(name.slice(), null, argv[0..@intCast(argc)]);
}

/// A method of a view, with the view as `this`.
pub fn boundMethod(b: *Binder, f: Schema.Function, this: usize) convert.Error!Value {
    var buf: [256]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}.{s}", .{ f.in.?.name, f.method.name }) catch return error.OutOfMemory;
    var data = [_]Value{ b.binderWord(), qjs.string(b.ctx, full), c.JS_NewInt64(b.ctx, @bitCast(@as(u64, this))) };
    defer c.JS_FreeValue(b.ctx, data[1]);
    const params = f.method.signature.params.len;
    const out = c.JS_NewCFunctionData(b.ctx, callBound, @intCast(params), 0, data.len, &data);
    if (c.JS_IsException(out)) return error.Exception;
    return out;
}

fn callBound(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    const name = qjs.toString(ctx, data[1]) orelse return qjs.exception;
    defer name.free();
    return b.callDeclared(name.slice(), dataWord(ctx, data[2]), argv[0..@intCast(argc)]);
}

/// A class's `at(address)`.
fn classAt(b: *Binder, type_name: []const u8) convert.Error!Value {
    var data = [_]Value{ b.binderWord(), qjs.string(b.ctx, type_name) };
    defer c.JS_FreeValue(b.ctx, data[1]);
    const f = c.JS_NewCFunctionData(b.ctx, classAtJs, 1, 0, data.len, &data);
    if (c.JS_IsException(f)) return error.Exception;
    return f;
}

fn classAtJs(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    if (argc < 1) return qjs.throw(ctx, "at takes an address", .{});
    return b.viewAt(data[1], argv[0]);
}

/// A view of the type named by `type_text` at `address`, or null at 0.
fn viewAt(b: *Binder, type_text: Value, address_v: Value) Value {
    const ctx = b.ctx;
    const text = qjs.toString(ctx, type_text) orelse return qjs.exception;
    defer text.free();
    var address: i64 = 0;
    if (views.of(b, address_v)) |v| {
        address = @bitCast(@as(u64, v.address));
    } else if (c.JS_ToInt64Ext(ctx, &address, address_v) < 0) return qjs.exception;
    if (address == 0) return qjs.null_value;
    var diag: Schema.Diagnostic = .{};
    const s, const r = b.core.typeOf(text.slice(), &diag) catch |e| return switch (e) {
        error.OutOfMemory => c.JS_ThrowOutOfMemory(ctx),
        else => qjs.throw(ctx, "{s}: {s}", .{ text.slice(), if (diag.message().len > 0) diag.message() else @errorName(e) }),
    };
    const v: script.views.View = .{ .schema = s, .type = r, .address = @truncate(@as(u64, @bitCast(address))) };
    return switch (script.views.place(s, r, v.address)) {
        .view => |inner| views.wrap(b, inner) catch |e| failed(ctx, e),
        else => qjs.throw(ctx, "{s} isn't a struct, union, bitfield or array", .{text.slice()}),
    };
}

/// A property of `obj` that reads and writes the static `full` each time.
fn declaredStatic(b: *Binder, obj: Value, name: []const u8, full: []const u8) convert.Error!void {
    const ctx = b.ctx;
    var data = [_]Value{ b.binderWord(), qjs.string(ctx, full) };
    defer c.JS_FreeValue(ctx, data[1]);
    const getter = c.JS_NewCFunctionData(ctx, getStatic, 0, 0, data.len, &data);
    if (c.JS_IsException(getter)) return error.Exception;
    const setter = c.JS_NewCFunctionData(ctx, setStatic, 1, 0, data.len, &data);
    if (c.JS_IsException(setter)) {
        c.JS_FreeValue(ctx, getter);
        return error.Exception;
    }
    const atom = c.JS_NewAtomLen(ctx, qjs.chars(name), name.len);
    defer c.JS_FreeAtom(ctx, atom);
    if (c.JS_DefinePropertyGetSet(ctx, obj, atom, getter, setter, c.JS_PROP_ENUMERABLE) < 0) return error.Exception;
}

fn staticMember(b: *Binder, name: []const u8) convert.Error!struct { Schema, script.views.Member } {
    const found = b.core.declared(name) orelse return convert.throw(b.ctx, "{s} isn't declared", .{name});
    const v = switch (found) {
        .static => |v| v,
        .function => return convert.throw(b.ctx, "{s} isn't a static", .{name}),
    };
    const m = b.core.staticMember(name, v.schema, v.found.static) catch |e| {
        _ = b.locateFailed(name, e);
        return error.Exception;
    };
    return .{ v.schema, m };
}

fn getStatic(ctx_: ?*qjs.Context, _: Value, _: c_int, _: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    const name = qjs.toString(ctx, data[1]) orelse return qjs.exception;
    defer name.free();
    const s, const m = b.staticMember(name.slice()) catch |e| return failed(ctx, e);
    return views.read(b, s, m, 0) catch |e| failed(ctx, e);
}

fn setStatic(ctx_: ?*qjs.Context, _: Value, argc: c_int, argv: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const b = binderData(ctx, data[0]);
    const name = qjs.toString(ctx, data[1]) orelse return qjs.exception;
    defer name.free();
    const s, const m = b.staticMember(name.slice()) catch |e| return failed(ctx, e);
    views.write(b, s, m, if (argc > 0) argv[0] else qjs.undefined_value) catch |e| return failed(ctx, e);
    return qjs.undefined_value;
}

fn gone(b: *Binder) error{Exception} {
    _ = c.JS_Throw(b.ctx, b.makeError(null, "", rt.gone_code));
    return error.Exception;
}

/// A borrowed one while converting a borrowed argument. Otherwise kept once per JS value.
fn implement(b: *Binder, t: *Trait, v: Value) convert.Error!rt.AnyObject {
    const cached = c.JS_GetProperty(b.ctx, v, b.cache);
    defer c.JS_FreeValue(b.ctx, cached);
    if (b.boxOf(cached)) |box| switch (box.*) {
        .object => |o| if (o.trait == t and o.obj.table != null) {
            if (b.core.ourImpl(o.obj)) |impl| b.core.hold(impl);
            return o.obj;
        },
        .settle => {},
    };
    const made = try b.core.make(t, c.JS_DupValue(b.ctx, v));
    if (made.kept) {
        const box = try b.newBox(null, .{ .object = .{ .binder = b, .trait = t, .obj = made.obj } });
        _ = c.JS_DefinePropertyValue(b.ctx, v, b.cache, box, 0);
    }
    return made.obj;
}

// Scripts calling native objects

fn callMethod(ctx: ?*qjs.Context, this: Value, argc: c_int, argv: [*c]Value, magic: c_int) callconv(.c) Value {
    var id: c.JSClassID = 0;
    const box: *Box = @ptrCast(@alignCast(c.JS_GetAnyOpaque(this, &id) orelse return qjs.throw(ctx.?, "not a salamander object", .{})));
    const o = switch (box.*) {
        .object => |o| o,
        .settle => return qjs.throw(ctx.?, "not a salamander object", .{}),
    };
    const t = o.trait orelse return qjs.throw(ctx.?, "not a salamander object", .{});
    if (o.obj.table == null) return c.JS_Throw(ctx.?, o.binder.makeError(null, "", rt.gone_code));
    return o.binder.invoke(t, o.obj, @intCast(magic), argv[0..@intCast(argc)]);
}

fn callFn(ctx: ?*qjs.Context, this: Value, argc: c_int, argv: [*c]Value, magic: c_int, data: [*c]Value) callconv(.c) Value {
    _ = this;
    _ = magic;
    var id: c.JSClassID = 0;
    const box: *Box = @ptrCast(@alignCast(c.JS_GetAnyOpaque(data[0], &id).?));
    const o = box.object;
    if (o.obj.table == null) return c.JS_Throw(ctx.?, o.binder.makeError(null, "", rt.gone_code));
    return o.binder.invoke(o.trait.?, o.obj, 0, argv[0..@intCast(argc)]);
}

fn invoke(b: *Binder, t: *Trait, obj: rt.AnyObject, slot: usize, args: []const Value) Value {
    const ctx = b.ctx;
    const m = t.methods[slot];
    const l = &(t.bound.methods[slot] orelse return qjs.throw(ctx, "{s} can't be called from script", .{m.name}));
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
        const mem = memory.alloc(a, l.shapes[i]) catch return c.JS_ThrowOutOfMemory(ctx);
        const v = if (i < args.len) args[i] else qjs.undefined_value;
        ptrs[i] = mem;
        if (p.inoutType()) |child| {
            // Memory's already null
            if (p.nullable() and qjs.isNullish(v)) continue;
            const target = memory.alloc(a, memory.shapeOf(s, child)) catch return c.JS_ThrowOutOfMemory(ctx);
            if (!c.JS_IsObject(v)) return qjs.throw(ctx, "{s} is inout, so it takes {s}", .{ p.name, if (script.inoutBoxed(s, child)) "a { value } box" else "an object" });
            const src = if (script.inoutBoxed(s, child)) qjs.get(ctx, v, "value") else c.JS_DupValue(ctx, v);
            defer c.JS_FreeValue(ctx, src);
            convert.fromJs(b, s, child, src, target, a) catch |e| return failed(ctx, e);
            memory.put(mem, s.pointer_size, @intFromPtr(target));
            targets[i] = target;
            continue;
        }
        const was = b.core.lending(if (p.keep) null else &lent);
        defer _ = b.core.lending(was);
        convert.fromJs(b, s, p.type, v, mem, a) catch |e| return failed(ctx, e);
    }
    const value = memory.alloc(a, l.value) catch return c.JS_ThrowOutOfMemory(ctx);
    const code = bind.call(t.bound, obj, slot, ptrs[0..m.signature.params.len], value);
    // Blobs made for borrowed arguments are ours to let go
    for (m.signature.params, 0..) |p, i| if (!p.keep and !p.inout) memory.releaseBlobs(s, p.type, ptrs[i]);
    for (m.signature.params, 0..) |p, i| {
        const target = targets[i] orelse continue;
        b.writeBack(s, p.inoutType().?, args[i], target) catch |e| return failed(ctx, e);
    }
    if (m.async) return b.awaitPromise(t, slot, @as(*align(1) const rt.core.Promise, @ptrCast(value)).*);
    const ret = m.signature.ret;
    if (ret == .result) {
        if (code != 0) return c.JS_Throw(ctx, b.makeError(s, ret.result.err, code));
        // The script holds its own counts of blobs it was given
        defer memory.releaseBlobs(s, ret.result.ok.*, value);
        return convert.toJs(b, s, ret.result.ok.*, value) catch |e| failed(ctx, e);
    }
    defer memory.releaseBlobs(s, ret, value);
    return convert.toJs(b, s, ret, value) catch |e| failed(ctx, e);
}

/// Puts what an `inout` parameter points at now back into the script's object or box.
fn writeBack(b: *Binder, s: Schema, child: Schema.Ref, v: Value, target: [*]const u8) convert.Error!void {
    const now = try convert.toJs(b, s, child, target);
    if (script.inoutBoxed(s, child)) return qjs.set(b.ctx, v, "value", now);
    defer c.JS_FreeValue(b.ctx, now);
    const global = c.JS_GetGlobalObject(b.ctx);
    defer c.JS_FreeValue(b.ctx, global);
    const object = qjs.get(b.ctx, global, "Object");
    defer c.JS_FreeValue(b.ctx, object);
    const assign = qjs.get(b.ctx, object, "assign");
    defer c.JS_FreeValue(b.ctx, assign);
    var argv = [_]Value{ v, now };
    const r = c.JS_Call(b.ctx, assign, object, 2, &argv);
    if (c.JS_IsException(r)) return error.Exception;
    c.JS_FreeValue(b.ctx, r);
}

fn failed(ctx: *qjs.Context, e: convert.Error) Value {
    return switch (e) {
        error.Exception => qjs.exception,
        error.OutOfMemory => c.JS_ThrowOutOfMemory(ctx),
    };
}

/// An Error named after `code` in `errors`, with the code in `code`.
pub fn makeError(b: *Binder, s: ?Schema, errors: []const u8, code: u32) Value {
    const e = c.JS_NewError(b.ctx);
    const name = script.errorName(s, errors, code);
    qjs.set(b.ctx, e, "name", qjs.string(b.ctx, name));
    qjs.set(b.ctx, e, "message", qjs.string(b.ctx, script.withExplanation(b.core.host, name)));
    qjs.set(b.ctx, e, "code", c.JS_NewInt64(b.ctx, code));
    return e;
}

/// The code for something a script threw, explained with its message for whoever gets the error.
fn errorCode(b: *Binder, s: Schema, errors: ?[]const u8, err: Value) u32 {
    const code = b.codeOf(s, errors, err);
    const message = if (c.JS_IsObject(err)) qjs.get(b.ctx, err, "message") else c.JS_DupValue(b.ctx, err);
    defer c.JS_FreeValue(b.ctx, message);
    if (qjs.toString(b.ctx, message)) |text| {
        defer text.free();
        script.explainThrown(b.core.host, s, errors, code, text.slice());
    } else c.JS_FreeValue(b.ctx, c.JS_GetException(b.ctx));
    return code;
}

/// Its `code`, or the one its `name` has.
fn codeOf(b: *Binder, s: Schema, errors: ?[]const u8, err: Value) u32 {
    if (!c.JS_IsObject(err)) return rt.unsupported_code;
    const code = qjs.get(b.ctx, err, "code");
    defer c.JS_FreeValue(b.ctx, code);
    if (c.JS_IsNumber(code)) {
        var n: i64 = 0;
        if (c.JS_ToInt64Ext(b.ctx, &n, code) == 0 and n > 0 and n <= std.math.maxInt(u32)) return @intCast(n);
    }
    const name = qjs.get(b.ctx, err, "name");
    defer c.JS_FreeValue(b.ctx, name);
    const text = qjs.toString(b.ctx, name) orelse {
        c.JS_FreeValue(b.ctx, c.JS_GetException(b.ctx));
        return rt.unsupported_code;
    };
    defer text.free();
    return script.errorCode(s, errors, text.slice());
}

fn awaitPromise(b: *Binder, t: *Trait, slot: usize, promise: rt.core.Promise) Value {
    const ctx = b.ctx;
    const gpa = b.core.gpa;
    if (promise.table == null) return c.JS_Throw(ctx, b.makeError(t.schema, "", rt.gone_code));
    var funcs: [2]Value = undefined;
    const p = c.JS_NewPromiseCapability(ctx, &funcs);
    if (c.JS_IsException(p)) {
        promise.release();
        return p;
    }
    const a = gpa.create(Await) catch {
        promise.release();
        for (funcs) |f| c.JS_FreeValue(ctx, f);
        c.JS_FreeValue(ctx, p);
        return c.JS_ThrowOutOfMemory(ctx);
    };
    a.* = .{ .gpa = gpa, .binder = b, .promise = promise, .funcs = funcs, .trait = t, .slot = slot };
    b.awaits.append(gpa, a) catch {
        promise.release();
        for (funcs) |f| c.JS_FreeValue(ctx, f);
        c.JS_FreeValue(ctx, p);
        gpa.destroy(a);
        return c.JS_ThrowOutOfMemory(ctx);
    };
    promise.then(rt.Task.init(a, settled), b.core.queue.raw());
    return p;
}

/// Back on the script's thread with a native promise settled.
fn settled(a: *Await) void {
    defer a.gpa.destroy(a);
    const b = a.binder orelse {
        // The binder's gone, so nobody's waiting
        a.promise.release();
        return;
    };
    defer a.promise.release();
    if (std.mem.indexOfScalar(*Await, b.awaits.items, a)) |i| _ = b.awaits.swapRemove(i);
    const ctx = b.ctx;
    defer for (a.funcs) |f| c.JS_FreeValue(ctx, f);
    const s = a.trait.schema;
    const ok, const errors = script.payload(a.trait.methods[a.slot]);
    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
    defer arena.deinit();
    const shape: bind.abi.Shape = if (script.isVoid(ok)) .{ .size = 1, .alignment = 1 } else memory.shapeOf(s, ok);
    const mem = memory.alloc(arena.allocator(), shape) catch return b.settleWith(a.funcs[1], c.JS_ThrowOutOfMemory(ctx));
    const code = a.promise.take(mem);
    if (code != 0) return b.settleWith(a.funcs[1], b.makeError(s, errors orelse "", code));
    defer if (!script.isVoid(ok)) memory.releaseBlobs(s, ok, mem);
    const v = convert.toJs(b, s, ok, mem) catch return b.settleWith(a.funcs[1], c.JS_GetException(ctx));
    b.settleWith(a.funcs[0], v);
}

/// Calls `f` with `v`, and takes `v`. Takes the pending exception for `exception`.
fn settleWith(b: *Binder, f: Value, v: Value) void {
    var arg = if (c.JS_IsException(v)) c.JS_GetException(b.ctx) else v;
    defer c.JS_FreeValue(b.ctx, arg);
    const r = c.JS_Call(b.ctx, f, qjs.undefined_value, 1, &arg);
    if (c.JS_IsException(r)) b.reportPending() else c.JS_FreeValue(b.ctx, r);
}

fn reportPending(b: *Binder) void {
    const e = c.JS_GetException(b.ctx);
    defer c.JS_FreeValue(b.ctx, e);
    if (b.report) |f| f(b, e);
}

// Native code calling scripts

/// Native code calling a method a script implements. The core's checked it can.
pub fn dispatch(b: *Binder, impl: *Impl, method: u32, args: []const [*]u8, value: [*]u8) u32 {
    const ctx = b.ctx;
    const t = impl.trait;
    const s = t.schema;
    const m = t.methods[method];
    const ok, const errors = script.payload(m);
    const is_result = script.isResult(m);

    var argv: [bind.abi.max_args]Value = undefined;
    var n: usize = 0;
    defer for (argv[0..n]) |v| c.JS_FreeValue(ctx, v);
    // Native objects handed over for the call only, which stop working after
    var lent: std.ArrayList(Value) = .empty;
    defer b.stopLent(&lent);
    // What `inout` ones point at, read back after
    var targets: [bind.abi.max_args]?[*]u8 = @splat(null);
    for (m.signature.params, args, 0..) |p, mem, i| {
        if (p.inoutType()) |child| {
            const target: ?[*]u8 = @ptrFromInt(@as(usize, @intCast(memory.bits(mem, s.pointer_size))));
            argv[n] = if (target) |at| blk: {
                const v = convert.toJs(b, s, child, at) catch return b.thrown(s, errors, is_result);
                if (!script.inoutBoxed(s, child)) break :blk v;
                const box = c.JS_NewObject(ctx);
                qjs.set(ctx, box, "value", v);
                break :blk box;
            } else qjs.null_value;
            targets[i] = target;
            n += 1;
            continue;
        }
        const saved = b.lent_boxes;
        b.lent_boxes = if (p.keep) null else &lent;
        defer b.lent_boxes = saved;
        argv[n] = convert.toJs(b, s, p.type, mem) catch return b.thrown(s, errors, is_result);
        n += 1;
    }

    const r = if (t.sig != null)
        c.JS_Call(ctx, impl.value, qjs.undefined_value, @intCast(n), &argv)
    else blk: {
        const f = qjs.get(ctx, impl.value, m.name);
        defer c.JS_FreeValue(ctx, f);
        if (!c.JS_IsFunction(ctx, f)) return if (is_result) rt.unsupported_code else 0;
        break :blk c.JS_Call(ctx, f, impl.value, @intCast(n), &argv);
    };
    defer c.JS_FreeValue(ctx, r);
    if (c.JS_IsException(r)) {
        if (m.async) return b.settledPromise(t, method, value, null);
        return b.thrown(s, errors, is_result);
    }
    for (m.signature.params, 0..) |p, i| {
        const target = targets[i] orelse continue;
        const child = p.inoutType().?;
        const src = if (script.inoutBoxed(s, child)) qjs.get(ctx, argv[i], "value") else c.JS_DupValue(ctx, argv[i]);
        defer c.JS_FreeValue(ctx, src);
        convert.fromJs(b, s, child, src, target, b.core.returned()) catch return b.thrown(s, errors, is_result);
    }
    if (m.async) return b.settledPromise(t, method, value, r);
    const ret = if (is_result) ok else m.signature.ret;
    if (script.isVoid(ret)) return 0;
    convert.fromJs(b, s, ret, r, value, b.core.returned()) catch return b.thrown(s, errors, is_result);
    return 0;
}

/// The code for what's pending. Ones with nowhere to go are reported.
fn thrown(b: *Binder, s: Schema, errors: ?[]const u8, is_result: bool) u32 {
    if (!is_result) {
        b.reportPending();
        return 0;
    }
    const e = c.JS_GetException(b.ctx);
    defer c.JS_FreeValue(b.ctx, e);
    return b.errorCode(s, errors, e);
}

/// Writes a native promise for what a script's async method gave back to `value`. A pending
/// exception rejects it when `r` is null.
fn settledPromise(b: *Binder, t: *Trait, slot: u32, value: [*]u8, r: ?Value) u32 {
    const s = t.schema;
    const ok, const errors = script.payload(t.methods[slot]);
    const size = if (script.isVoid(ok)) 1 else memory.shapeOf(s, ok).size;
    const promise, const resolver = b.core.host.promise(size) catch return 0;
    @as(*align(1) rt.core.Promise, @ptrCast(value)).* = promise;

    const v = r orelse {
        const e = c.JS_GetException(b.ctx);
        defer c.JS_FreeValue(b.ctx, e);
        resolver.reject(b.errorCode(s, errors, e));
        return 0;
    };
    if (!c.JS_IsPromise(v)) {
        b.resolveWith(t, slot, resolver, v);
        return 0;
    }
    var data = b.newBox(null, .{ .settle = .{ .binder = b, .resolver = resolver, .trait = t, .slot = slot } }) catch {
        resolver.drop();
        b.reportPending();
        return 0;
    };
    defer c.JS_FreeValue(b.ctx, data);
    var handlers = [2]Value{
        c.JS_NewCFunctionData(b.ctx, onSettle, 1, 0, 1, &data),
        c.JS_NewCFunctionData(b.ctx, onSettle, 1, 1, 1, &data),
    };
    defer for (handlers) |h| c.JS_FreeValue(b.ctx, h);
    const then = qjs.get(b.ctx, v, "then");
    defer c.JS_FreeValue(b.ctx, then);
    const out = c.JS_Call(b.ctx, then, v, 2, &handlers);
    if (c.JS_IsException(out)) b.reportPending() else c.JS_FreeValue(b.ctx, out);
    return 0;
}

fn resolveWith(b: *Binder, t: *Trait, slot: usize, resolver: rt.core.Resolver, v: Value) void {
    const s = t.schema;
    const ok, const errors = script.payload(t.methods[slot]);
    if (script.isVoid(ok)) return resolver.resolve(null);
    // What it points at stays with the value till it's taken
    const a = rt.holding(&resolver);
    const mem = memory.alloc(a, memory.shapeOf(s, ok)) catch return resolver.reject(rt.unsupported_code);
    convert.fromJs(b, s, ok, v, mem, a) catch {
        const e = c.JS_GetException(b.ctx);
        defer c.JS_FreeValue(b.ctx, e);
        return resolver.reject(b.errorCode(s, errors, e));
    };
    resolver.resolve(mem);
}

fn onSettle(ctx: ?*qjs.Context, this: Value, argc: c_int, argv: [*c]Value, magic: c_int, data: [*c]Value) callconv(.c) Value {
    _ = this;
    _ = ctx;
    var id: c.JSClassID = 0;
    const box: *Box = @ptrCast(@alignCast(c.JS_GetAnyOpaque(data[0], &id).?));
    const st = &box.settle;
    if (st.done) return qjs.undefined_value;
    st.done = true;
    const b = st.binder;
    const v = if (argc > 0) argv[0] else qjs.undefined_value;
    if (magic == 0) {
        b.resolveWith(st.trait, st.slot, st.resolver, v);
    } else {
        _, const errors = script.payload(st.trait.methods[st.slot]);
        st.resolver.reject(b.errorCode(st.trait.schema, errors, v));
    }
    return qjs.undefined_value;
}
