//! Live views as JS objects. Properties read and write memory when used, and methods come bound.
//! Names a view doesn't have fall through to a plain object's, so views print and compare like one.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const script = @import("salamander_script");

const qjs = @import("qjs.zig");
const convert = @import("convert.zig");
const Binder = @import("Binder.zig");

const c = qjs.c;
const Value = qjs.Value;
const Schema = salamander_schema.Schema;
const views = script.views;
const memory = script.memory;
const View = views.View;

const Box = struct {
    binder: *Binder,
    view: View,
};

pub fn register(b: *Binder) error{OutOfMemory}!void {
    const jrt = c.JS_GetRuntime(b.ctx);
    _ = c.JS_NewClassID(jrt, &b.view_class);
    var def = std.mem.zeroes(c.JSClassDef);
    def.class_name = qjs.cstr("View");
    def.finalizer = finalize;
    def.exotic = &exotic;
    if (c.JS_NewClass(jrt, b.view_class, &def) < 0) return error.OutOfMemory;
    _ = c.JS_NewClassID(jrt, &b.copy_class);
    var copy_def = std.mem.zeroes(c.JSClassDef);
    copy_def.class_name = qjs.cstr("Copy");
    copy_def.finalizer = finalizeCopy;
    if (c.JS_NewClass(jrt, b.copy_class, &copy_def) < 0) return error.OutOfMemory;
    const sym = c.JS_NewPrivateSymbol(b.ctx, qjs.cstr("salamander.copy"));
    if (c.JS_IsException(sym)) return error.OutOfMemory;
    defer c.JS_FreeValue(b.ctx, sym);
    b.copy_atom = c.JS_ValueToAtom(b.ctx, sym);
}

fn finalizeCopy(_: ?*c.JSRuntime, v: Value) callconv(.c) void {
    var id: c.JSClassID = 0;
    const copy_: *views.Copy = @ptrCast(@alignCast(c.JS_GetAnyOpaque(v, &id) orelse return));
    copy_.destroy();
}

/// QuickJS keeps a pointer to it, which C says isn't const.
var exotic: c.JSClassExoticMethods = blk: {
    var e = std.mem.zeroes(c.JSClassExoticMethods);
    e.get_own_property = getOwn;
    e.get_own_property_names = ownNames;
    e.has_property = has;
    e.get_property = get;
    e.set_property = set;
    break :blk e;
};

fn finalize(jrt: ?*c.JSRuntime, v: Value) callconv(.c) void {
    var id: c.JSClassID = 0;
    const box = c.JS_GetAnyOpaque(v, &id) orelse return;
    c.js_free_rt(jrt, box);
}

/// `v` as a JS object.
pub fn wrap(b: *Binder, unsized: View) convert.Error!Value {
    const v = b.core.sized(unsized);
    const obj = c.JS_NewObjectClass(b.ctx, @intCast(b.view_class));
    if (c.JS_IsException(obj)) return error.Exception;
    const box: *Box = @ptrCast(@alignCast(c.js_malloc_rt(c.JS_GetRuntime(b.ctx), @sizeOf(Box)) orelse {
        c.JS_FreeValue(b.ctx, obj);
        return error.OutOfMemory;
    }));
    box.* = .{ .binder = b, .view = v };
    _ = c.JS_SetOpaque(obj, box);
    return obj;
}

/// The view `v` is, if it's one.
pub fn of(b: *Binder, v: Value) ?View {
    const box: *Box = @ptrCast(@alignCast(c.JS_GetOpaque(v, b.view_class) orelse return null));
    return box.view;
}

fn boxOf(obj: Value) *Box {
    var id: c.JSClassID = 0;
    return @ptrCast(@alignCast(c.JS_GetAnyOpaque(obj, &id).?));
}

/// A property name, or null for symbols.
fn nameOf(ctx: *qjs.Context, atom: c.JSAtom) ?qjs.String {
    const v = c.JS_AtomToValue(ctx, atom);
    defer c.JS_FreeValue(ctx, v);
    if (c.JS_IsSymbol(v)) return null;
    return qjs.toString(ctx, v);
}

/// What a plain object has by that name, like `toString`.
fn plain(ctx: *qjs.Context, atom: c.JSAtom) Value {
    const o = c.JS_NewObject(ctx);
    defer c.JS_FreeValue(ctx, o);
    return c.JS_GetProperty(ctx, o, atom);
}

fn get(ctx_: ?*qjs.Context, obj: Value, atom: c.JSAtom, _: Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const box = boxOf(obj);
    const name = nameOf(ctx, atom) orelse return plain(ctx, atom);
    defer name.free();
    const m = views.member(box.view, name.slice()) orelse {
        if (std.mem.eql(u8, name.slice(), "toJSON")) return toJsonFunction(ctx, obj);
        return plain(ctx, atom);
    };
    return read(box.binder, box.view.schema, m, box.view.address) catch |e| failed(ctx, e);
}

fn set(ctx_: ?*qjs.Context, obj: Value, atom: c.JSAtom, value: Value, _: Value, _: c_int) callconv(.c) c_int {
    const ctx = ctx_.?;
    const box = boxOf(obj);
    const name = nameOf(ctx, atom) orelse {
        _ = qjs.throw(ctx, "a view has no symbol properties", .{});
        return -1;
    };
    defer name.free();
    const m = views.member(box.view, name.slice()) orelse {
        _ = qjs.throw(ctx, "{f} has no {s}", .{ box.view.type, name.slice() });
        return -1;
    };
    write(box.binder, box.view.schema, m, value) catch return -1;
    return 1;
}

fn has(ctx_: ?*qjs.Context, obj: Value, atom: c.JSAtom) callconv(.c) c_int {
    const ctx = ctx_.?;
    const name = nameOf(ctx, atom) orelse return 0;
    defer name.free();
    return @intFromBool(views.member(boxOf(obj).view, name.slice()) != null);
}

fn getOwn(ctx_: ?*qjs.Context, desc: [*c]c.JSPropertyDescriptor, obj: Value, atom: c.JSAtom) callconv(.c) c_int {
    const ctx = ctx_.?;
    const box = boxOf(obj);
    const name = nameOf(ctx, atom) orelse return 0;
    defer name.free();
    const m = views.member(box.view, name.slice()) orelse return 0;
    if (m == .method) return 0;
    if (desc) |d| {
        d.*.flags = c.JS_PROP_ENUMERABLE | c.JS_PROP_WRITABLE;
        d.*.getter = qjs.undefined_value;
        d.*.setter = qjs.undefined_value;
        d.*.value = read(box.binder, box.view.schema, m, box.view.address) catch return -1;
    }
    return 1;
}

fn ownNames(ctx_: ?*qjs.Context, ptab: [*c][*c]c.JSPropertyEnum, plen: [*c]u32, obj: Value) callconv(.c) c_int {
    const ctx = ctx_.?;
    const box = boxOf(obj);
    var arena: std.heap.ArenaAllocator = .init(box.binder.core.gpa);
    defer arena.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    views.names(box.view, arena.allocator(), &list) catch {
        _ = c.JS_ThrowOutOfMemory(ctx);
        return -1;
    };
    const tab: [*]c.JSPropertyEnum = @ptrCast(@alignCast(c.js_malloc(ctx, @max(list.items.len, 1) * @sizeOf(c.JSPropertyEnum)) orelse return -1));
    for (list.items, 0..) |n, i| tab[i] = .{ .is_enumerable = true, .atom = c.JS_NewAtomLen(ctx, qjs.chars(n), n.len) };
    ptab.* = tab;
    plen.* = @intCast(list.items.len);
    return 0;
}

fn failed(ctx: *qjs.Context, e: convert.Error) Value {
    return switch (e) {
        error.Exception => qjs.exception,
        error.OutOfMemory => c.JS_ThrowOutOfMemory(ctx),
    };
}

/// Throws what the core said went wrong.
fn located(b: *Binder, e: anyerror) convert.Error {
    _ = b.locateFailed("memory", e);
    return error.Exception;
}

/// A member's value now. Methods come bound to `this`.
pub fn read(b: *Binder, s: Schema, m: views.Member, this: usize) convert.Error!Value {
    const ctx = b.ctx;
    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    switch (m) {
        .value => |p| {
            const mem = b.core.readPlace(s, p, a) catch |e| return located(b, e);
            return convert.toJs(b, s, p.type, mem);
        },
        .pointer => |p| {
            const at = b.core.readPointer(p.address) catch |e| return located(b, e);
            if (at == 0) return qjs.null_value;
            return wrap(b, views.pointee(s, p.type, at));
        },
        .text => |p| {
            const at = b.core.readPointer(p.address) catch |e| return located(b, e);
            if (at == 0) return qjs.null_value;
            const text = b.core.readText(p.type.pointer.prim, at, a) catch |e| return located(b, e);
            return qjs.string(ctx, text);
        },
        .bits => |bits| {
            var word: u64 = 0;
            b.core.readMemory(bits.address, std.mem.asBytes(&word)[0..bits.backing.size(s.pointer_size)]) catch |e| return located(b, e);
            const v = views.readBits(bits, word);
            return switch (bits.member) {
                .bool => c.JS_NewBool(ctx, v != 0),
                else => c.JS_NewInt64(ctx, @bitCast(v)),
            };
        },
        .view => |v| return wrap(b, v),
        .method => |f| return b.boundMethod(f, this),
        .length => |n| return c.JS_NewInt64(ctx, @intCast(n)),
    }
}

pub fn write(b: *Binder, s: Schema, m: views.Member, v: Value) convert.Error!void {
    const ctx = b.ctx;
    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    switch (m) {
        .value, .pointer => |p| {
            const shape = memory.shapeOf(s, p.type);
            const mem = try memory.alloc(a, shape);
            try convert.fromJs(b, s, p.type, v, mem, a);
            b.core.writeMemory(p.address, mem[0..shape.size]) catch |e| return located(b, e);
        },
        .bits => |bits| {
            const n = bits.backing.size(s.pointer_size);
            var word: u64 = 0;
            b.core.readMemory(bits.address, std.mem.asBytes(&word)[0..n]) catch |e| return located(b, e);
            var value: i64 = 0;
            if (c.JS_IsBool(v)) {
                value = @intFromBool(c.JS_ToBool(ctx, v) > 0);
            } else if (c.JS_ToInt64Ext(ctx, &value, v) < 0) return error.Exception;
            word = views.writeBits(bits, word, @bitCast(value));
            b.core.writeMemory(bits.address, std.mem.asBytes(&word)[0..n]) catch |e| return located(b, e);
        },
        .text => return convert.throw(ctx, "text behind a pointer can't be set, only the pointer", .{}),
        .view => return convert.throw(ctx, "set its fields instead", .{}),
        .method => return convert.throw(ctx, "a method can't be set", .{}),
        .length => return convert.throw(ctx, "length can't be set", .{}),
    }
}

fn toJsonFunction(ctx: *qjs.Context, obj: Value) Value {
    var data = [_]Value{obj};
    return c.JS_NewCFunctionData(ctx, toJson, 0, 0, data.len, &data);
}

fn toJson(ctx_: ?*qjs.Context, _: Value, _: c_int, _: [*c]Value, _: c_int, data: [*c]Value) callconv(.c) Value {
    const ctx = ctx_.?;
    const box = boxOf(data[0]);
    return copy(box.binder, box.view, false, 0) catch |e| failed(ctx, e);
}

const max_depth = views.max_depth;

/// A plain copy of what's there now. Pointers can loop so they stay live views, or addresses for JSON.
pub fn copy(b: *Binder, v: View, live: bool, depth: usize) convert.Error!Value {
    const ctx = b.ctx;
    const is_array = v.type == .array;
    const out = if (is_array) c.JS_NewArray(ctx) else c.JS_NewObject(ctx);
    if (c.JS_IsException(out)) return error.Exception;
    errdefer c.JS_FreeValue(ctx, out);
    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
    defer arena.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    try views.names(v, arena.allocator(), &list);
    for (list.items) |name| {
        const m = views.member(v, name) orelse continue;
        const value = switch (m) {
            .view => |inner| if (depth < max_depth) try copy(b, inner, live, depth + 1) else qjs.null_value,
            .pointer => |p| if (live) try read(b, v.schema, m, v.address) else blk: {
                const at = b.core.readPointer(p.address) catch |e| return located(b, e);
                break :blk if (at == 0) qjs.null_value else c.JS_NewInt64(ctx, @bitCast(@as(u64, at)));
            },
            else => try read(b, v.schema, m, v.address),
        };
        qjs.set(ctx, out, name, value);
    }
    return out;
}

// Snapshots are plain copies read once, changed like any object, then saved back

/// Read in one go, so its fields are as quick as any object's. Pointers in it stay live views.
pub fn snapshot(b: *Binder, v: View) convert.Error!Value {
    const ctx = b.ctx;
    const taken = b.core.takeCopy(v) catch |e| return located(b, e);
    const copied = copy(b, taken.local(), true, 0) catch |e| {
        taken.destroy();
        return e;
    };
    const holder = c.JS_NewObjectClass(ctx, @intCast(b.copy_class));
    if (c.JS_IsException(holder)) {
        taken.destroy();
        c.JS_FreeValue(ctx, copied);
        return error.Exception;
    }
    _ = c.JS_SetOpaque(holder, taken);
    if (c.JS_DefinePropertyValue(ctx, copied, b.copy_atom, holder, 0) < 0) {
        c.JS_FreeValue(ctx, copied);
        return error.Exception;
    }
    return copied;
}

/// Writes back what changed since the snapshot was taken or last saved, and gives how many.
/// Text isn't written.
pub fn save(b: *Binder, copied: Value) convert.Error!usize {
    const ctx = b.ctx;
    const holder = c.JS_GetProperty(ctx, copied, b.copy_atom);
    defer c.JS_FreeValue(ctx, holder);
    const taken: *views.Copy = @ptrCast(@alignCast(c.JS_GetOpaque(holder, b.copy_class) orelse return convert.throw(ctx, "that isn't from snapshot", .{})));
    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
    defer arena.deinit();
    const lang: Lang = .{ .b = b, .a = arena.allocator() };
    return views.save(Lang, lang, b.core.gpa, taken, copied, &b.core) catch |e| switch (e) {
        error.Exception => error.Exception,
        error.OutOfMemory => error.OutOfMemory,
        else => located(b, e),
    };
}

/// A snapshot's parts, for `views.save`.
const Lang = struct {
    b: *Binder,
    a: std.mem.Allocator,

    pub const Item = Value;

    pub fn child(self: Lang, item: Value, name: []const u8) ?Value {
        if (!c.JS_IsObject(item)) return null;
        const atom = c.JS_NewAtomLen(self.b.ctx, qjs.chars(name), name.len);
        defer c.JS_FreeAtom(self.b.ctx, atom);
        return self.present(c.JS_GetProperty(self.b.ctx, item, atom));
    }

    pub fn element(self: Lang, item: Value, i: usize) ?Value {
        if (!c.JS_IsObject(item)) return null;
        return self.present(c.JS_GetPropertyUint32(self.b.ctx, item, @intCast(i)));
    }

    fn present(self: Lang, v: Value) ?Value {
        if (c.JS_IsException(v)) {
            c.JS_FreeValue(self.b.ctx, c.JS_GetException(self.b.ctx));
            return null;
        }
        if (c.JS_IsUndefined(v)) return null;
        return v;
    }

    pub fn release(self: Lang, item: Value) void {
        c.JS_FreeValue(self.b.ctx, item);
    }

    pub fn put(self: Lang, s: Schema, r: Schema.Ref, item: Value, mem: [*]u8) convert.Error!void {
        return convert.fromJs(self.b, s, r, item, mem, self.a);
    }

    pub fn bitsOf(self: Lang, item: Value) convert.Error!u64 {
        if (c.JS_IsBool(item)) return @intFromBool(c.JS_ToBool(self.b.ctx, item) > 0);
        var v: i64 = 0;
        if (c.JS_ToInt64Ext(self.b.ctx, &v, item) < 0) return error.Exception;
        return @bitCast(v);
    }
};
