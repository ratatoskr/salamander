//! Memory laid out like `rt.Abi` to JS values and back. Ints up to 32 bits, usize and pointers are numbers, i64 and u64 BigInts.
//! `u8[N]` and `u16[N]` text are strings, enums take a number or a name.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const script = @import("salamander_script");
const rt = @import("salamander_runtime");

const qjs = @import("qjs.zig");
const Binder = @import("Binder.zig");

const c = qjs.c;
const memory = script.memory;
const views = script.views;
const Value = qjs.Value;
const Schema = salamander_schema.Schema;
const Ref = Schema.Ref;

pub const Error = error{ Exception, OutOfMemory };

fn int(b: *Binder, mem: [*]const u8, p: Schema.Prim, ps: u8) Value {
    return switch (memory.int(mem, p, ps)) {
        .signed => |v| if (p == .i64) c.JS_NewBigInt64(b.ctx, v) else c.JS_NewInt64(b.ctx, v),
        .unsigned => |v| if (p == .u64) c.JS_NewBigUint64(b.ctx, v) else c.JS_NewInt64(b.ctx, @bitCast(v)),
    };
}

/// The value at `mem`. Borrowed things like strings are copied.
pub fn toJs(b: *Binder, s: Schema, r: Ref, mem: [*]const u8) Error!Value {
    const ctx = b.ctx;
    switch (r) {
        .prim => |p| return switch (p) {
            .f32, .f64 => c.JS_NewFloat64(ctx, memory.float(mem, p)),
            .bool => c.JS_NewBool(ctx, mem[0] != 0),
            .string => qjs.string(ctx, memory.slice(mem).get()),
            .cstring => blk: {
                const at: ?[*:0]const u8 = @ptrFromInt(@as(usize, @intCast(memory.bits(mem, s.pointer_size))));
                break :blk if (at) |text| qjs.string(ctx, std.mem.span(text)) else qjs.null_value;
            },
            .object => b.wrapAny(memory.object(mem)),
            .blob => blobToJs(ctx, memory.blob(mem)),
            .any => anyToJs(b, mem),
            .void => qjs.undefined_value,
            else => int(b, mem, p, s.pointer_size),
        },
        .named => |n| {
            if (s.findTrait(n)) |t| return b.wrap(try b.traitOf(s, t), memory.object(mem));
            const t = s.findType(n).?;
            switch (t.kind) {
                .@"struct", .@"union" => {
                    if (t.kind == .@"struct" and t.kind.@"struct".tagged != null) return taggedToJs(b, s, t, mem);
                    const obj = c.JS_NewObject(ctx);
                    if (c.JS_IsException(obj)) return error.Exception;
                    errdefer c.JS_FreeValue(ctx, obj);
                    var it = memory.fields(s, t);
                    while (it.next()) |f| qjs.set(ctx, obj, f.name, try toJs(b, s, f.type, mem + f.offset));
                    return obj;
                },
                .@"enum" => |e| return int(b, mem, e.backing, s.pointer_size),
                .bitfield => |bf| return int(b, mem, bf.backing, s.pointer_size),
                .func => |*sig| return b.wrapFn(try b.fnOf(s, sig), memory.object(mem)),
                .@"error", .@"opaque" => unreachable,
            }
        },
        .pointer => {
            const v = memory.bits(mem, s.pointer_size);
            if (v == 0) return qjs.null_value;
            // Structs and text behind pointers are live, once something can read memory
            if (b.core.locator != null) switch (views.place(s, r, 0)) {
                .pointer => return Binder.views.wrap(b, views.pointee(s, r, @intCast(v))),
                .text => {
                    var arena: std.heap.ArenaAllocator = .init(b.core.gpa);
                    defer arena.deinit();
                    const text = b.core.readText(r.pointer.prim, @intCast(v), arena.allocator()) catch |e| {
                        _ = b.locateFailed("text", e);
                        return error.Exception;
                    };
                    return qjs.string(ctx, text);
                },
                else => {},
            };
            return c.JS_NewInt64(ctx, @bitCast(v));
        },
        .array => |a| {
            if (memory.isText(a)) |kind| {
                if (kind == .utf8) return qjs.string(ctx, memory.utf8Text(mem, a.len));
                var buf: [1024]u8 = undefined;
                return qjs.string(ctx, memory.utf16Text(mem, a.len, &buf));
            }
            return array(b, s, a.child.*, mem, a.len);
        },
        .slice => |child| {
            const sl = memory.slice(mem);
            return array(b, s, child.*, if (sl.ptr) |p| p else mem, sl.len);
        },
        .optional => |child| {
            if (memory.someFlag(s, child.*)) |at| if (mem[at] == 0) return qjs.null_value;
            return toJs(b, s, child.*, mem);
        },
        .func => |sig| return b.wrapFn(try b.fnOf(s, sig), memory.object(mem)),
        .result => unreachable,
    }
}

fn array(b: *Binder, s: Schema, child: Ref, mem: [*]const u8, len: usize) Error!Value {
    const out = c.JS_NewArray(b.ctx);
    if (c.JS_IsException(out)) return error.Exception;
    errdefer c.JS_FreeValue(b.ctx, out);
    const size = memory.shapeOf(s, child).size;
    for (0..len) |i| {
        const v = try toJs(b, s, child, mem + i * size);
        if (c.JS_SetPropertyUint32(b.ctx, out, @intCast(i), v) < 0) return error.Exception;
    }
    return out;
}

/// Writes `v` to `mem`, which is zeroed. Copies of strings and slices go in `a`.
pub fn fromJs(b: *Binder, s: Schema, r: Ref, v: Value, mem: [*]u8, a: std.mem.Allocator) Error!void {
    const ctx = b.ctx;
    switch (r) {
        .prim => |p| switch (p) {
            .f32, .f64 => memory.putFloat(mem, p, try float(ctx, v)),
            .bool => mem[0] = @intFromBool(c.JS_ToBool(ctx, v) > 0),
            .string => {
                const text = try copyString(ctx, v, a);
                memory.putSlice(mem, text.ptr, text.len);
            },
            .cstring => if (!qjs.isNullish(v)) {
                const text = try copyString(ctx, v, a);
                const z = try a.allocSentinel(u8, text.len, 0);
                @memcpy(z, text);
                memory.put(mem, s.pointer_size, @intFromPtr(z.ptr));
            },
            .object => memory.putObject(mem, try b.unwrapAny(v)),
            .blob => {
                const made = try blobFromJs(b, v);
                memory.putObject(mem, .{ .data = made.data, .table = made.table });
            },
            .any => try anyFromJs(b, v, mem, a),
            .void => {},
            else => memory.put(mem, p.size(s.pointer_size), try intBits(ctx, v, p == .u64)),
        },
        .named => |n| {
            if (s.findTrait(n)) |t| return memory.putObject(mem, try b.unwrap(try b.traitOf(s, t), v));
            const t = s.findType(n).?;
            switch (t.kind) {
                .@"struct", .@"union" => {
                    if (t.kind == .@"struct" and t.kind.@"struct".tagged != null) return taggedFromJs(b, s, t, v, mem, a);
                    if (!c.JS_IsObject(v)) return throw(ctx, "expected an object for {s}", .{t.name});
                    var u: memory.UnionWrite = try .init(s, r, t, mem, a);
                    var it = memory.fields(s, t);
                    while (it.next()) |f| {
                        const fv = qjs.get(ctx, v, f.name);
                        defer c.JS_FreeValue(ctx, fv);
                        if (c.JS_IsException(fv)) return error.Exception;
                        if (c.JS_IsUndefined(fv)) continue;
                        try fromJs(b, s, f.type, fv, u.at(mem, f.offset), a);
                        u.done(mem);
                    }
                },
                .@"enum" => |e| {
                    const size = e.backing.size(s.pointer_size);
                    if (c.JS_IsString(v)) {
                        const name = qjs.toString(ctx, v) orelse return error.Exception;
                        defer name.free();
                        const bits = memory.enumValue(e, name.slice()) orelse return throw(ctx, "{s} has no {s}", .{ t.name, name.slice() });
                        return memory.put(mem, size, bits);
                    }
                    memory.put(mem, size, try intBits(ctx, v, false));
                },
                .bitfield => |bf| memory.put(mem, bf.backing.size(s.pointer_size), try intBits(ctx, v, bf.backing == .u64)),
                .func => |*sig| memory.putObject(mem, try b.unwrapFn(try b.fnOf(s, sig), v)),
                .@"error", .@"opaque" => unreachable,
            }
        },
        .pointer => if (Binder.views.of(b, v)) |view| {
            memory.put(mem, s.pointer_size, view.address);
        } else if (!qjs.isNullish(v)) memory.put(mem, s.pointer_size, try intBits(ctx, v, true)),
        .array => |arr| {
            if (memory.isText(arr)) |kind| if (c.JS_IsString(v)) {
                const text = qjs.toString(ctx, v) orelse return error.Exception;
                defer text.free();
                return memory.putText(mem, kind, arr.len, text.slice()) catch throw(ctx, "bad UTF-8", .{});
            };
            const len = try length(ctx, v);
            const size = memory.shapeOf(s, arr.child.*).size;
            for (0..@min(len, arr.len)) |i| try element(b, s, arr.child.*, v, i, mem + i * size, a);
        },
        .slice => |child| {
            // Bytes take typed arrays and ArrayBuffers too, copied
            if (child.* == .prim and child.prim == .u8) if (byteView(ctx, v)) |bytes| {
                const copy = try a.dupe(u8, bytes);
                return memory.putSlice(mem, copy.ptr, copy.len);
            };
            const len = try length(ctx, v);
            const shape = memory.shapeOf(s, child.*);
            const items = try memory.alloc(a, .{ .size = shape.size * len, .alignment = shape.alignment });
            for (0..len) |i| try element(b, s, child.*, v, i, items + i * shape.size, a);
            memory.putSlice(mem, items, len);
        },
        .optional => |child| {
            if (qjs.isNullish(v)) return;
            try fromJs(b, s, child.*, v, mem, a);
            if (memory.someFlag(s, child.*)) |at| mem[at] = 1;
        },
        .func => |sig| memory.putObject(mem, try b.unwrapFn(try b.fnOf(s, sig), v)),
        .result => unreachable,
    }
}

fn element(b: *Binder, s: Schema, child: Ref, v: Value, i: usize, mem: [*]u8, a: std.mem.Allocator) Error!void {
    const e = c.JS_GetPropertyUint32(b.ctx, v, @intCast(i));
    defer c.JS_FreeValue(b.ctx, e);
    if (c.JS_IsException(e)) return error.Exception;
    try fromJs(b, s, child, e, mem, a);
}

fn length(ctx: *qjs.Context, v: Value) Error!usize {
    if (!c.JS_IsArray(v)) return throw(ctx, "expected an array", .{});
    var n: i64 = 0;
    if (c.JS_GetLength(ctx, v, &n) < 0) return error.Exception;
    return @intCast(n);
}

fn float(ctx: *qjs.Context, v: Value) Error!f64 {
    var f: f64 = 0;
    if (c.JS_ToFloat64(ctx, &f, v) < 0) return error.Exception;
    return f;
}

/// Numbers wrap like JS's own int conversions, and BigInts take their low bits.
fn intBits(ctx: *qjs.Context, v: Value, unsigned64: bool) Error!u64 {
    if (c.JS_IsBigInt(v)) {
        if (unsigned64) {
            var u: u64 = 0;
            if (c.JS_ToBigUint64(ctx, &u, v) < 0) return error.Exception;
            return u;
        }
        var i: i64 = 0;
        if (c.JS_ToBigInt64(ctx, &i, v) < 0) return error.Exception;
        return @bitCast(i);
    }
    if (c.JS_IsBool(v)) return @intFromBool(c.JS_ToBool(ctx, v) > 0);
    if (!c.JS_IsNumber(v)) return throw(ctx, "expected a number", .{});
    var i: i64 = 0;
    if (c.JS_ToInt64Ext(ctx, &i, v) < 0) return error.Exception;
    return @bitCast(i);
}

fn copyString(ctx: *qjs.Context, v: Value, a: std.mem.Allocator) Error![]const u8 {
    if (!c.JS_IsString(v)) return throw(ctx, "expected a string", .{});
    const text = qjs.toString(ctx, v) orelse return error.Exception;
    defer text.free();
    return a.dupe(u8, text.slice());
}

/// A `Uint8Array` over the blob's own bytes, holding a count till it's collected.
fn blobToJs(ctx: *qjs.Context, blob: rt.Blob) Error!Value {
    if (blob.table == null) return qjs.null_value;
    const held = std.heap.smp_allocator.create(rt.Blob) catch return error.OutOfMemory;
    blob.retain();
    held.* = blob;
    const bytes = blob.bytes();
    const v = c.JS_NewUint8Array(ctx, @constCast(bytes.ptr), bytes.len, freeBlob, held, false);
    if (c.JS_IsException(v)) {
        _ = freeBlob(null, held, null, 0);
        return error.Exception;
    }
    return v;
}

/// QuickJS lets go of an array's memory as a realloc to 0. Blobs don't grow.
fn freeBlob(_: ?*c.JSRuntime, opaque_: ?*anyopaque, _: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    if (size != 0) return null;
    const held: *rt.Blob = @ptrCast(@alignCast(opaque_.?));
    held.release();
    std.heap.smp_allocator.destroy(held);
    return null;
}

/// The bytes of a `Uint8Array` or `ArrayBuffer`, or null for anything else.
fn byteView(ctx: *qjs.Context, v: Value) ?[]const u8 {
    if (!c.JS_IsObject(v)) return null;
    var len: usize = 0;
    if (c.JS_IsArrayBuffer(v)) {
        const ptr = c.JS_GetArrayBuffer(ctx, &len, v) orelse return &.{};
        return ptr[0..len];
    }
    const kind = c.JS_GetTypedArrayType(v);
    if (kind != c.JS_TYPED_ARRAY_UINT8 and kind != c.JS_TYPED_ARRAY_UINT8C) return null;
    const ptr = c.JS_GetUint8Array(ctx, &len, v) orelse {
        c.JS_FreeValue(ctx, c.JS_GetException(ctx));
        return null;
    };
    return ptr[0..len];
}

/// A new blob copying a `Uint8Array` or `ArrayBuffer`, with one count. None for null.
fn blobFromJs(b: *Binder, v: Value) Error!rt.Blob {
    if (qjs.isNullish(v)) return .{};
    const bytes = byteView(b.ctx, v) orelse return throw(b.ctx, "expected a Uint8Array or ArrayBuffer for a blob", .{});
    const made = b.core.host.raw().blob(bytes.len);
    if (made.table == null) return error.OutOfMemory;
    @memcpy(@constCast(made.bytes())[0..bytes.len], bytes);
    return made;
}

/// A tagged union as `{ member: value }`, or a member's name when it holds nothing, like its JSON.
fn taggedToJs(b: *Binder, s: Schema, t: *const Schema.Type, mem: [*]const u8) Error!Value {
    const ctx = b.ctx;
    const m = memory.liveMember(s, t, mem) orelse return qjs.null_value;
    if (memory.isVoid(m.type)) return qjs.string(ctx, m.name);
    const obj = c.JS_NewObject(ctx);
    if (c.JS_IsException(obj)) return error.Exception;
    errdefer c.JS_FreeValue(ctx, obj);
    qjs.set(ctx, obj, m.name, try toJs(b, s, m.type, mem + memory.payloadAt(t)));
    return obj;
}

fn taggedFromJs(b: *Binder, s: Schema, t: *const Schema.Type, v: Value, mem: [*]u8, a: std.mem.Allocator) Error!void {
    const ctx = b.ctx;
    const tg = t.kind.@"struct".tagged.?;
    if (c.JS_IsString(v)) {
        const text = qjs.toString(ctx, v) orelse return error.Exception;
        defer text.free();
        for (tg.members) |m| if (memory.isVoid(m.type) and std.mem.eql(u8, m.name, text.slice())) return memory.putTag(s, t, mem, m.name);
        return throw(ctx, "{s} has no member {s} that holds nothing", .{ t.name, text.slice() });
    }
    if (!c.JS_IsObject(v)) return throw(ctx, "expected {{ member: value }} or a member's name for {s}", .{t.name});
    for (tg.members) |m| if (!memory.isVoid(m.type)) {
        const fv = qjs.get(ctx, v, m.name);
        defer c.JS_FreeValue(ctx, fv);
        if (c.JS_IsException(fv)) return error.Exception;
        if (c.JS_IsUndefined(fv)) continue;
        memory.putTag(s, t, mem, m.name);
        return fromJs(b, s, m.type, fv, mem + memory.payloadAt(t), a);
    };
    return throw(ctx, "expected one of {s}'s members", .{t.name});
}

/// An `any` as `{ type, value }`. The value's null when no loaded schema has its type.
fn anyToJs(b: *Binder, mem: [*]const u8) Error!Value {
    const ctx = b.ctx;
    const held = std.mem.bytesToValue(rt.Any, mem[0..@sizeOf(rt.Any)]);
    const info = held.type orelse return qjs.null_value;
    const obj = c.JS_NewObject(ctx);
    if (c.JS_IsException(obj)) return error.Exception;
    errdefer c.JS_FreeValue(ctx, obj);
    qjs.set(ctx, obj, "type", qjs.string(ctx, info.name.get()));
    const found = b.core.typeOfInfo(info);
    const value = if (found != null and held.value != null) try toJs(b, found.?[0], found.?[1], @ptrCast(held.value.?)) else qjs.null_value;
    qjs.set(ctx, obj, "value", value);
    return obj;
}

/// `{ type, value }`, like `any("Vec3", v)` makes, as an `any` holding `value` as that type.
fn anyFromJs(b: *Binder, v: Value, mem: [*]u8, a: std.mem.Allocator) Error!void {
    const ctx = b.ctx;
    if (qjs.isNullish(v)) return @memset(mem[0..@sizeOf(rt.Any)], 0);
    const type_v = qjs.get(ctx, v, "type");
    defer c.JS_FreeValue(ctx, type_v);
    if (!c.JS_IsString(type_v)) return throw(ctx, "an any is {{ type, value }}, like any(\"Vec3\", v)", .{});
    const name = qjs.toString(ctx, type_v) orelse return error.Exception;
    defer name.free();
    var diag: Schema.Diagnostic = .{};
    const s, const r, const info = b.core.anyOf(name.slice(), &diag) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => throw(ctx, "{s}: {s}", .{ name.slice(), if (diag.message().len > 0) diag.message() else @errorName(e) }),
    };
    const m = s.memory(r) orelse return throw(ctx, "{s} has no value to hold", .{name.slice()});
    const at = a.rawAlloc(@max(m.size, 1), .fromByteUnits(m.alignment), @returnAddress()) orelse return error.OutOfMemory;
    @memset(at[0..m.size], 0);
    const value_v = qjs.get(ctx, v, "value");
    defer c.JS_FreeValue(ctx, value_v);
    try fromJs(b, s, r, value_v, at, a);
    const held: rt.Any = .{ .type = info, .value = at };
    @memcpy(mem[0..@sizeOf(rt.Any)], std.mem.asBytes(&held));
}

pub fn throw(ctx: *qjs.Context, comptime fmt: []const u8, args: anytype) error{Exception} {
    _ = qjs.throw(ctx, fmt, args);
    return error.Exception;
}
