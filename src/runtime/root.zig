//! What generated Zig runs on. A trait is a `Desc` type whose `salamander` namespace has `name`, `hash` and `methods`.
//! Shared state like owners, promises and the registry is the `Host`'s, so plugins in other binaries share it.

const std = @import("std");
const builtin = @import("builtin");

const thunk = @import("thunk.zig");
pub const Owner = @import("Owner.zig").Owner;
/// The runtime's own traits, generated from `core.sal`.
pub const core = @import("core.zig");
const host_file = @import("Host.zig");
pub const Host = host_file.Host;
pub const Local = @import("Local.zig");
const queue_file = @import("Queue.zig");
pub const Queue = queue_file.Queue;
pub const Task = queue_file.Task;
pub const Where = queue_file.Where;
pub const host = host_file.host;
pub const setHost = host_file.setHost;
pub const ProvideError = host_file.ProvideError;
/// For generated Zig finding a game's code, see `declared.zig`.
pub const declared = @import("declared.zig");

pub const Conv = enum { c, cdecl, stdcall, thiscall, fastcall, winapi };

/// `winapi` is stdcall on x86, Microsoft's on x64, and plain C on aarch64 off Windows.
pub fn callingConvention(comptime conv: Conv) std.lang.CallingConvention {
    if (conv == .winapi) return switch (builtin.cpu.arch) {
        .x86, .x86_64 => std.lang.CallingConvention.winapi,
        .aarch64, .thumb => if (builtin.os.tag == .windows) std.lang.CallingConvention.winapi else .c,
        else => .c,
    };
    if (builtin.cpu.arch != .x86) return .c;
    return switch (conv) {
        .c, .cdecl => .c,
        .stdcall => .{ .x86_stdcall = .{} },
        .thiscall => .{ .x86_thiscall = .{} },
        .fastcall => .{ .x86_fastcall = .{} },
        .winapi => unreachable,
    };
}

pub const Method = struct {
    name: [:0]const u8,
    /// How Zig calls it, without `this`.
    Fn: type,
    conv: Conv = .c,
    static: bool = false,
    /// A result's error set as an `enum(u32)`, which is what crosses. Zig gets its own errors by name.
    Errors: ?type = null,
    /// Its signature's hash, which callers match along with the name. Generated code gives the schema's.
    sig: u64 = 0,
};

/// What a table's methods are, so a caller built against another version of the trait finds its own.
pub const Info = extern struct {
    hash: u64,
    /// `abi_version` when it was made. Tables from another don't mix.
    abi: u32 = abi_version,
    name: String,
    methods: Slice(MethodInfo),
};

/// Goes up when tables, objects or info change shape.
pub const abi_version: u32 = 1;

pub const MethodInfo = extern struct {
    name: String,
    sig: u64,
};

fn fnv(h: u64, bytes: []const u8) u64 {
    var x = h;
    for (bytes) |c| x = (x ^ c) *% 0x100000001b3;
    return x;
}

pub fn sigOf(comptime m: Method) u64 {
    if (m.sig != 0) return m.sig;
    // Hand-written traits only have to agree with themselves
    return fnv(fnv(0xcbf29ce484222325, @typeName(m.Fn)), &.{ @backingInt(m.conv), @intFromBool(m.static) });
}

pub fn infoOf(comptime Desc: type) *const Info {
    return &struct {
        const ms = Desc.salamander.methods;
        const list: [ms.len]MethodInfo = blk: {
            var l: [ms.len]MethodInfo = undefined;
            for (ms, 0..) |m, i| l[i] = .{ .name = .{ .ptr = m.name.ptr, .len = m.name.len }, .sig = sigOf(m) };
            break :blk l;
        };
        const info: Info = .{
            .hash = Desc.salamander.hash,
            .name = .{ .ptr = Desc.salamander.name.ptr, .len = Desc.salamander.name.len },
            .methods = .{ .ptr = &list, .len = ms.len },
        };
    }.info;
}

/// Every result can fail with these.
pub const Failure = error{ Gone, Unsupported, Cancelled };
pub const cancelled_code: u32 = std.math.maxInt(u32) - 2;
pub const unsupported_code: u32 = std.math.maxInt(u32) - 1;
pub const gone_code: u32 = std.math.maxInt(u32);

/// `[]const T` across the boundary.
pub fn Slice(comptime T: type) type {
    return extern struct {
        const Self = @This();
        pub const salamander_slice = T;

        ptr: ?[*]const T = null,
        len: usize = 0,

        pub fn init(s: []const T) Self {
            return .{ .ptr = s.ptr, .len = s.len };
        }

        pub fn get(self: Self) []const T {
            return if (self.ptr) |p| p[0..self.len] else &.{};
        }
    };
}

/// UTF-8, borrowed.
pub const String = Slice(u8);

/// `?T` for a `T` that has no null of its own.
pub fn Opt(comptime T: type) type {
    return extern struct {
        const Self = @This();

        value: T = undefined,
        some: bool = false,

        pub fn init(v: ?T) Self {
            return if (v) |x| .{ .value = x, .some = true } else .{};
        }

        pub fn get(self: Self) ?T {
            return if (self.some) self.value else null;
        }
    };
}

/// Something that implements `Desc`, as `{data, table}`. A null table is no object.
pub fn Object(comptime Desc: type) type {
    // Already an object type, like a generated one with its methods
    if (@typeInfo(Desc) == .@"struct" and @hasField(Desc, "data") and @hasField(Desc, "table")) return Desc;
    return extern struct {
        const Self = @This();

        data: usize = 0,
        /// A `*const Table(Desc)`, typed loosely so traits can mention themselves.
        table: ?*const anyopaque = null,

        pub const Trait = Desc;
        pub const salamander = Desc.salamander;

        pub fn init(data: anytype, table: *const Table(Desc)) Self {
            return .{ .data = toData(data), .table = table };
        }

        pub fn call(self: Self, comptime name: @TypeOf(.enum_literal), args: Args(Desc, @tagName(name))) Return(Desc, @tagName(name)) {
            return invoke(Desc, @tagName(name), self, args);
        }

        /// Done holding it, from a `keep` parameter or a return.
        pub fn release(self: Self) void {
            host().release(self);
        }
    };
}

/// Any trait object, the format's `object`.
pub const AnyObject = extern struct {
    data: usize = 0,
    table: ?*const anyopaque = null,

    pub fn of(obj: anytype) AnyObject {
        return .{ .data = obj.data, .table = obj.table };
    }

    pub fn as(self: AnyObject, comptime T: type) T {
        return .{ .data = self.data, .table = self.table };
    }
};

/// A value with its type info, the format's `any`. Borrowed for the call.
pub const Any = extern struct {
    type: ?*const core.raw.TypeInfo = null,
    value: ?*const anyopaque = null,

    /// `v`, a generated type's wire value. It has to outlive the call.
    pub fn of(v: anytype) Any {
        const T = @typeInfo(@TypeOf(v)).pointer.child;
        return .{ .type = &T.salamander_type, .value = v };
    }

    /// `v`, any generated type's value, as it crosses. What it points at goes in `a`.
    pub fn from(a: std.mem.Allocator, v: anytype) error{OutOfMemory}!Any {
        const T = @TypeOf(v);
        const W = if (@hasDecl(T, "salamander_raw")) T.salamander_raw else T;
        const wire = try a.create(W);
        wire.* = try toWire(W, a, v);
        return .{ .type = &T.salamander_type, .value = wire };
    }

    /// Its value if it's a `T`, matched by hash. Wire types for ones with plain versions.
    pub fn as(self: Any, comptime T: type) ?*const T {
        const info = self.type orelse return null;
        if (info.hash != T.salamander_type.hash) return null;
        return @ptrCast(@alignCast(self.value));
    }

    /// Its value as plain `T`, if it's one, with what it points at in `a`.
    pub fn lift(self: Any, comptime T: type, a: std.mem.Allocator) error{OutOfMemory}!?T {
        const W = if (@hasDecl(T, "salamander_raw")) T.salamander_raw else T;
        const info = self.type orelse return null;
        if (info.hash != T.salamander_type.hash) return null;
        const wire: *const W = @ptrCast(@alignCast(self.value));
        return try fromWire(T, a, wire.*);
    }
};

/// Follows fields through pointers, like `follow(manager, "items.table.data")`, each read through `declared.read`.
/// Null at a null or unreadable pointer. A struct held by value on the way gives a pointer to it.
pub fn follow(start: anytype, comptime path: []const u8) ?Followed(Start(@TypeOf(start)), path) {
    const from: Start(@TypeOf(start)) = if (@typeInfo(@TypeOf(start)) == .optional) start orelse return null else start;
    return followFrom(from, path);
}

fn followFrom(from: anytype, comptime path: []const u8) ?Followed(@TypeOf(from), path) {
    if (path.len == 0) return from;
    const dot = comptime std.mem.indexOfScalar(u8, path, '.');
    const name = path[0 .. dot orelse path.len];
    const next = step(from, name) orelse return null;
    return if (dot) |d| followFrom(next, path[d + 1 ..]) else next;
}

/// What `follow` gives for `path` from a `P`.
fn Followed(comptime P: type, comptime path: []const u8) type {
    var T = P;
    var rest = path;
    while (rest.len > 0) {
        const dot = std.mem.indexOfScalar(u8, rest, '.');
        T = Step(T, rest[0 .. dot orelse rest.len]);
        rest = if (dot) |d| rest[d + 1 ..] else "";
    }
    return T;
}

fn Start(comptime S: type) type {
    const P = if (@typeInfo(S) == .optional) @typeInfo(S).optional.child else S;
    const info = @typeInfo(P);
    if (info != .pointer or info.pointer.size != .one) @compileError("follow starts at a pointer to a struct, not " ++ @typeName(S));
    return P;
}

fn Step(comptime P: type, comptime name: []const u8) type {
    const ptr = @typeInfo(P).pointer;
    const F = @FieldType(ptr.child, name);
    return switch (@typeInfo(F)) {
        .pointer => |p| if (p.size == .one) F else @compileError(name ++ " isn't a pointer to one thing, so follow can't go through it"),
        .optional => |o| if (@typeInfo(o.child) == .pointer and @typeInfo(o.child).pointer.size == .one) o.child else @compileError(name ++ " is optional, but not a pointer"),
        else => if (ptr.attrs.@"const") *const F else *F,
    };
}

fn step(from: anytype, comptime name: []const u8) ?Step(@TypeOf(from), name) {
    const F = @FieldType(@typeInfo(@TypeOf(from)).pointer.child, name);
    // Only where it is, nothing's read yet
    const field = &@field(from.*, name);
    return switch (@typeInfo(F)) {
        .pointer, .optional => {
            var word: usize = 0;
            if (!declared.read(@intFromPtr(field), std.mem.asBytes(&word)[0..@sizeOf(F)])) return null;
            return if (word == 0) null else @ptrFromInt(word);
        },
        else => field,
    };
}

test "follow goes through pointers and stops at a null one" {
    const Data = extern struct { count: u32 };
    const Sheet = extern struct { data: ?*Data };
    const Holder = extern struct { pad: u64 = 0, table: ?*Sheet, inline_data: Data };
    var data: Data = .{ .count = 3 };
    var table: Sheet = .{ .data = &data };
    var holder: Holder = .{ .table = &table, .inline_data = .{ .count = 9 } };
    try std.testing.expectEqual(&data, follow(&holder, "table.data").?);
    try std.testing.expectEqual(9, follow(@as(?*Holder, &holder), "inline_data").?.count);
    table.data = null;
    try std.testing.expectEqual(null, follow(&holder, "table.data"));
    try std.testing.expectEqual(null, follow(@as(?*Holder, null), "table"));

    // A pointer that can't be read stops it too
    const Unreadable = struct {
        var bad: usize = 0;
        fn address(_: ?*anyopaque, _: []const u8) anyerror!usize {
            return error.NotFound;
        }
        fn read(_: ?*anyopaque, at: usize, out: []u8) bool {
            if (at == bad) return false;
            @memcpy(out, @as([*]const u8, @ptrFromInt(at))[0..out.len]);
            return true;
        }
    };
    Unreadable.bad = @intFromPtr(&holder.table);
    declared.setLocator(.{ .address = Unreadable.address, .read = Unreadable.read });
    defer declared.setLocator(null);
    table.data = &data;
    try std.testing.expectEqual(null, follow(&holder, "table.data"));
    try std.testing.expectEqual(9, follow(&holder, "inline_data").?.count);
}

/// A function value. It's a trait object with one method, `call`, so it has an owner like any other.
pub fn Fn(comptime m: Method) type {
    return extern struct {
        const Self = @This();
        const R = @typeInfo(m.Fn).@"fn".return_type.?;

        data: usize = 0,
        table: ?*const anyopaque = null,

        pub const salamander = struct {
            pub const name = "fn";
            pub const hash: u64 = 0;
            pub const methods: []const Method = &.{.{ .name = "call", .Fn = m.Fn, .conv = m.conv, .Errors = m.Errors, .sig = m.sig }};
        };

        /// `function` gets `ctx` first. Lives as long as its binary.
        pub fn init(ctx: anytype, comptime function: anytype) Self {
            return .{ .data = toData(ctx), .table = &struct {
                const table: Table(Self) = .{ .salamander_info = infoOf(Self), .salamander_owner = null, .call = entryFor(salamander.methods[0], function) };
            }.table };
        }

        /// Stops being called once `owner` closes.
        pub fn owned(owner: *Owner, ctx: anytype, comptime function: anytype) error{OutOfMemory}!Self {
            const static = init(ctx, function);
            return .{ .data = static.data, .table = try host().adopt(Self, @ptrCast(@alignCast(static.table.?)), owner) };
        }

        pub fn invoke(self: Self, args: std.meta.ArgsTuple(m.Fn)) R {
            return callMethod(Self, "call", self, args);
        }

        /// Done holding it, from a `keep` parameter or a return.
        pub fn release(self: Self) void {
            host().release(self);
        }
    };
}

const promise = @import("promise.zig");
pub const Promise = promise.Promise;
pub const Resolver = promise.Resolver;
pub const holding = promise.holding;
pub const blobs = @import("blob.zig");
/// Bytes kept by a count, `blob` in schemas. Each holder owns a count and releases it.
pub const Blob = blobs.Blob;
/// Sal values as JSON, the same in every language.
pub const json = @import("json.zig");
pub const Awaited = promise.Awaited;

/// A pointer comptime types use where a real one would make a type contain itself. `Get.Type` is looked up lazily.
pub fn Ptr(comptime Get: type) type {
    return extern struct {
        const Self = @This();

        raw: ?*anyopaque = null,

        pub fn init(p: ?*Get.Type) Self {
            return .{ .raw = p };
        }

        pub fn get(self: Self) ?*Get.Type {
            return @ptrCast(@alignCast(self.raw));
        }
    };
}

/// A pointer, an optional one or a `usize`, as an object's data.
pub fn toData(data: anytype) usize {
    return switch (@typeInfo(@TypeOf(data))) {
        .pointer => @intFromPtr(data),
        .optional => if (data) |d| @intFromPtr(d) else 0,
        .null => 0,
        .int, .comptime_int => data,
        else => @compileError("salamander: an object's data is a pointer or a usize, not " ++ @typeName(@TypeOf(data))),
    };
}

fn isObjectLike(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "salamander") and @hasField(T, "table");
}

/// How `T` crosses. Most things are themselves.
pub fn Abi(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) Slice(p.child) else T,
        .optional => |o| switch (@typeInfo(o.child)) {
            .pointer => |p| if (p.size == .slice) Opt(Abi(o.child)) else T,
            else => if (isObjectLike(o.child)) o.child else Opt(Abi(o.child)),
        },
        .@"struct" => |s| if (s.layout == .auto) @compileError("salamander: " ++ @typeName(T) ++ " can't cross, its layout is up to Zig") else T,
        .error_union => @compileError("salamander: a result only goes in a return"),
        else => T,
    };
}

pub fn lower(comptime T: type, v: T) Abi(T) {
    const A = Abi(T);
    if (A == T) return v;
    switch (@typeInfo(T)) {
        .pointer => |p| return A.init(if (p.attrs.@"const") v else @as([]const p.child, v)),
        .optional => |o| {
            if (A == o.child) return v orelse .{};
            return if (v) |x| .{ .value = lower(o.child, x), .some = true } else .{};
        },
        else => unreachable,
    }
}

pub fn lift(comptime T: type, a: Abi(T)) T {
    const A = Abi(T);
    if (A == T) return a;
    switch (@typeInfo(T)) {
        .pointer => |p| return if (p.attrs.@"const") a.get() else @constCast(a.get()),
        .optional => |o| {
            if (A == o.child) return if (a.table != null) a else null;
            return if (a.some) lift(o.child, a.value) else null;
        },
        else => unreachable,
    }
}

pub fn method(comptime Desc: type, comptime name: []const u8) Method {
    // Comparing names takes a branch a char, which adds up on big traits
    @setEvalBranchQuota(1000 + Desc.salamander.methods.len * 400);
    for (Desc.salamander.methods) |m| if (std.mem.eql(u8, m.name, name)) return m;
    @compileError("salamander: " ++ Desc.salamander.name ++ " has no method " ++ name);
}

pub fn Args(comptime Desc: type, comptime name: []const u8) type {
    return std.meta.ArgsTuple(method(Desc, name).Fn);
}

/// What a generated method `name` returns, in plain types. `Return` for a trait without methods of its own.
pub fn Plain(comptime Desc: type, comptime name: []const u8) type {
    if (@hasDecl(Desc, name)) return @typeInfo(@TypeOf(@field(Desc, name))).@"fn".return_type.?;
    return Return(Desc, name);
}

pub fn Return(comptime Desc: type, comptime name: []const u8) type {
    return @typeInfo(method(Desc, name).Fn).@"fn".return_type.?;
}

const Shape = struct {
    params: []const type,
    ret: type,
    /// `T!E` returns a code and puts the `T` through a pointer at the end.
    result: bool,
    out: ?type,
};

fn shape(comptime m: Method) Shape {
    @setEvalBranchQuota(100_000);
    const info = @typeInfo(m.Fn).@"fn";
    var params: []const type = if (m.static) &.{} else &.{usize};
    for (info.param_types) |p| params = params ++ &[_]type{Abi(p.?)};
    const R = info.return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |eu| if (eu.payload == void)
            .{ .params = params, .ret = u32, .result = true, .out = null }
        else
            .{ .params = params ++ &[_]type{*Abi(eu.payload)}, .ret = u32, .result = true, .out = Abi(eu.payload) },
        else => .{ .params = params, .ret = Abi(R), .result = false, .out = null },
    };
}

/// The C function behind a method.
pub fn Entry(comptime m: Method) type {
    const s = shape(m);
    return thunk.Raw(s.params, s.ret, callingConvention(m.conv));
}

/// The same for every table, so any language can read it.
pub const Header = extern struct {
    info: *const Info,
    owner: ?*Owner,
};

pub fn headerOf(table: *const anyopaque) *const Header {
    return @ptrCast(@alignCast(table));
}

/// `salamander_info`, `salamander_owner`, then a pointer per method, null if missing. Enter the owner before calling through it.
pub fn Table(comptime Desc: type) type {
    @setEvalBranchQuota(100_000);
    const ms = Desc.salamander.methods;
    var names: [ms.len + 2][:0]const u8 = undefined;
    var types: [ms.len + 2]type = undefined;
    names[0] = "salamander_info";
    types[0] = *const Info;
    names[1] = "salamander_owner";
    types[1] = ?*Owner;
    for (ms, 2..) |m, i| {
        names[i] = m.name;
        types[i] = ?*const Entry(m);
    }
    const attrs: [ms.len + 2]std.lang.Type.Struct.FieldAttributes = @splat(.{});
    return @Struct(.@"extern", null, &names, &types, &attrs);
}

fn zero(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .void => {},
        .pointer => |p| if (p.size == .slice) &.{} else @panic("salamander: called something that's gone, and its return can't be null"),
        else => std.mem.zeroes(T),
    };
}

fn gone(comptime R: type) R {
    return if (@typeInfo(R) == .error_union) error.Gone else zero(R);
}

fn missing(comptime R: type) R {
    return if (@typeInfo(R) == .error_union) error.Unsupported else zero(R);
}

const callMethod = invoke;

/// Calls `name` on `obj`, which is any object type for `Desc`.
pub fn invoke(comptime Desc: type, comptime name: []const u8, obj: anytype, args: Args(Desc, name)) Return(Desc, name) {
    const m = comptime method(Desc, name);
    var table: *const Table(Desc) = @ptrCast(@alignCast(obj.table orelse return gone(Return(Desc, name))));
    // From another version of the trait, so methods match by name, since their order isn't ours
    if (table.salamander_info.hash != Desc.salamander.hash) {
        const fitted = host().adapt(Desc, obj);
        table = @ptrCast(@alignCast(fitted.table orelse return missing(Return(Desc, name))));
    }
    const entry = @field(table, name) orelse return missing(Return(Desc, name));
    const owner = table.salamander_owner;
    if (owner) |o| if (!o.enter()) return gone(Return(Desc, name));
    defer if (owner) |o| o.leave();
    return callEntry(m, entry, obj.data, args);
}

/// `implement`, then the host's copy that stops calling into `owner` once it closes.
pub fn implementOwned(comptime Desc: type, comptime Impl: type, owner: *Owner) error{OutOfMemory}!*const Table(Desc) {
    return host().adopt(Desc, implement(Desc, Impl), owner);
}

fn callEntry(comptime m: Method, entry: *const Entry(m), this: usize, args: std.meta.ArgsTuple(m.Fn)) @typeInfo(m.Fn).@"fn".return_type.? {
    const s = comptime shape(m);
    const info = @typeInfo(m.Fn).@"fn";
    const R = info.return_type.?;
    const first = if (m.static) 0 else 1;
    var raw: @Tuple(s.params) = undefined;
    if (!m.static) raw[0] = this;
    inline for (info.param_types, 0..) |P, i| raw[first + i] = lower(P.?, args[i]);
    if (!s.result) return lift(R, @call(.auto, entry, raw));
    const E = @typeInfo(R).error_union.error_set;
    if (s.out) |Out| {
        var out: Out = undefined;
        raw[s.params.len - 1] = &out;
        const code = @call(.auto, entry, raw);
        if (code != 0) return liftError(E, m.Errors, code);
        return lift(@typeInfo(R).error_union.payload, out);
    }
    const code = @call(.auto, entry, raw);
    if (code != 0) return liftError(E, m.Errors, code);
}

/// A code back to Zig's error. Unknown ones, from a newer impl, are `Unsupported`.
pub fn liftError(comptime E: type, comptime Errors: ?type, code: u32) E {
    if (code == gone_code) return error.Gone;
    if (comptime inSet(E, "Cancelled")) if (code == cancelled_code) return @errorCast(error.Cancelled);
    if (Errors) |En| inline for (@typeInfo(En).@"enum".field_names, @typeInfo(En).@"enum".field_values) |n, v| {
        if (comptime inSet(E, n)) if (code == v) return @errorCast(@field(anyerror, n));
    };
    return error.Unsupported;
}

fn inSet(comptime E: type, comptime name: []const u8) bool {
    const list = @typeInfo(E).error_set.error_names orelse return true;
    for (list) |e| if (std.mem.eql(u8, e, name)) return true;
    return false;
}

/// Zig's error as a code. Ones the enum doesn't have are `Unsupported`.
pub fn lowerError(comptime Errors: ?type, err: anyerror) u32 {
    if (err == error.Gone) return gone_code;
    if (err == error.Cancelled) return cancelled_code;
    if (Errors) |En| inline for (@typeInfo(En).@"enum".field_names, @typeInfo(En).@"enum".field_values) |n, v| {
        if (err == @field(anyerror, n)) return v;
    };
    return unsupported_code;
}

/// A static table for `Impl`, which has a function per method. Ones with `this` take a pointer to the data first.
pub fn implement(comptime Desc: type, comptime Impl: type) *const Table(Desc) {
    return &struct {
        const table: Table(Desc) = blk: {
            var t: Table(Desc) = undefined;
            t.salamander_info = infoOf(Desc);
            t.salamander_owner = null;
            for (Desc.salamander.methods) |m| {
                if (!@hasDecl(Impl, m.name)) @compileError("salamander: " ++ @typeName(Impl) ++ " is missing " ++ Desc.salamander.name ++ "." ++ m.name);
                @field(t, m.name) = entryFor(m, @field(Impl, m.name));
            }
            break :blk t;
        };
    }.table;
}

/// How an impl in a `.sal` file does each method. Aliases are already resolved to their target.
pub const How = union(enum) {
    /// A slot of the vtable at the start of the data.
    virtual: Virtual,
    /// Reads the field at this offset.
    get: usize,
    /// Writes it.
    set: usize,
    /// Left out, or for a tool to fill in later.
    missing,

    pub const Virtual = struct {
        slot: usize,
        /// The game function's, which can differ from the trait's.
        conv: Conv = .c,
    };
};

pub const Mapped = struct {
    method: [:0]const u8,
    how: How,
};

/// A table for a game struct, made from its impl. It's a `var` so tools can fill in what they find.
pub fn mapped(comptime Desc: type, comptime items: []const Mapped) *Table(Desc) {
    return &struct {
        var table: Table(Desc) = blk: {
            var t: Table(Desc) = undefined;
            t.salamander_info = infoOf(Desc);
            t.salamander_owner = null;
            for (Desc.salamander.methods) |m| @field(t, m.name) = null;
            for (items) |it| {
                const m = method(Desc, it.method);
                @field(t, it.method) = switch (it.how) {
                    .virtual => |v| virtualEntry(m, v.slot, v.conv),
                    .get => |offset| getEntry(m, offset),
                    .set => |offset| setEntry(m, offset),
                    .missing => null,
                };
            }
            break :blk t;
        };
    }.table;
}

/// A table whose methods call the C function `Calls.function(name)`, `this` as data first, for C APIs like Dear ImGui.
/// A method `Calls.allowed()` refuses gives its zero.
pub fn forwarding(comptime Desc: type, comptime Calls: type) *const Table(Desc) {
    return &struct {
        const table: Table(Desc) = blk: {
            @setEvalBranchQuota(100 * Desc.salamander.methods.len + 100_000);
            var t: Table(Desc) = undefined;
            t.salamander_info = infoOf(Desc);
            t.salamander_owner = null;
            for (Desc.salamander.methods) |m| @field(t, m.name) = forwardEntry(m, Calls);
            break :blk t;
        };
    }.table;
}

fn forwardEntry(comptime m: Method, comptime Calls: type) *const Entry(m) {
    const s = shape(m);
    const cc = callingConvention(m.conv);
    const C = thunk.Raw(s.params, s.ret, cc);
    return thunk.make(s.params, s.ret, cc, struct {
        fn body(raw: @Tuple(s.params)) s.ret {
            if (!Calls.allowed()) return std.mem.zeroes(s.ret);
            const f: *const C = @ptrCast(@alignCast(Calls.function(m.name)));
            return @call(.auto, f, raw);
        }
    }.body);
}

/// `v`, a plain Zig value, as wire type `W`. Changed slices go in `a`.
pub fn toWire(comptime W: type, a: std.mem.Allocator, v: anytype) error{OutOfMemory}!W {
    const V = @TypeOf(v);
    if (V == W) return v;
    switch (@typeInfo(W)) {
        .@"struct" => |info| {
            // A tagged union, as its tag and payload
            if (@typeInfo(V) == .@"union") {
                const Tag = @FieldType(W, "tag");
                var out: W = std.mem.zeroes(W);
                switch (v) {
                    inline else => |x, which| {
                        out.tag = @field(Tag, @tagName(which));
                        if (@TypeOf(x) != void) @field(out.payload, @tagName(which)) = try toWire(@FieldType(@FieldType(W, "payload"), @tagName(which)), a, x);
                    },
                }
                return out;
            }
            if (@hasDecl(W, "salamander_slice")) {
                const E = W.salamander_slice;
                const items: []const @typeInfo(V).pointer.child = v;
                if (@typeInfo(V).pointer.child == E) return .init(items);
                const out = try a.alloc(E, items.len);
                for (items, out) |x, *o| o.* = try toWire(E, a, x);
                return .init(out);
            }
            var out: W = .{};
            inline for (info.field_names) |n| {
                if (@hasField(V, n)) @field(out, n) = try toWire(@FieldType(W, n), a, @field(v, n));
            }
            return out;
        },
        .array => |arr| {
            var out: W = undefined;
            for (v, &out) |x, *o| o.* = try toWire(arr.child, a, x);
            return out;
        },
        .pointer => |ptr| {
            // A slice parameter, which crosses as Zig's
            const out = try a.alloc(ptr.child, v.len);
            for (v, out) |x, *o| o.* = try toWire(ptr.child, a, x);
            return out;
        },
        .optional => |o| return if (v) |x| try toWire(o.child, a, x) else null,
        else => return v,
    }
}

/// `w`, a wire value, as plain type `P`. Text points where `w`'s did, changed slices go in `a`.
pub fn fromWire(comptime P: type, a: std.mem.Allocator, w: anytype) error{OutOfMemory}!P {
    const Wt = @TypeOf(w);
    if (Wt == P) return w;
    switch (@typeInfo(P)) {
        .pointer => |ptr| {
            // A return, which crosses as a Zig slice, or a field
            const E, const items = if (@typeInfo(Wt) == .pointer) .{ @typeInfo(Wt).pointer.child, w } else .{ Wt.salamander_slice, w.get() };
            if (ptr.child == E) return items;
            const out = try a.alloc(ptr.child, items.len);
            for (items, out) |x, *o| o.* = try fromWire(ptr.child, a, x);
            return out;
        },
        .@"struct" => |info| {
            var out: P = .{};
            inline for (info.field_names) |n| {
                @field(out, n) = try fromWire(@FieldType(P, n), a, @field(w, n));
            }
            return out;
        },
        // A tagged union, from its tag and payload
        .@"union" => |info| {
            const Tag = @TypeOf(w.tag);
            inline for (info.field_names, info.field_types) |n, F| if (w.tag == @field(Tag, n)) {
                return @unionInit(P, n, if (F == void) {} else try fromWire(F, a, @field(w.payload, n)));
            };
            // A tag from a newer version reads as the first member, as it would be if zeroed
            const F = info.field_types[0];
            return @unionInit(P, info.field_names[0], if (F == void) {} else plainDefault(F));
        },
        .array => |arr| {
            var out: P = undefined;
            for (w, &out) |x, *o| o.* = try fromWire(arr.child, a, x);
            return out;
        },
        .optional => |o| return if (w) |x| try fromWire(o.child, a, x) else null,
        else => return w,
    }
}

/// What a plain type is when nothing's said, like zeroed memory read as it.
fn plainDefault(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .@"struct" => if (@hasDecl(T, "salamander_raw") or @typeInfo(T).@"struct".layout != .@"extern") .{} else std.mem.zeroes(T),
        .pointer => &.{},
        .@"union" => |info| @unionInit(T, info.field_names[0], if (info.field_types[0] == void) {} else plainDefault(info.field_types[0])),
        else => std.mem.zeroes(T),
    };
}

threadlocal var lifted: ?std.heap.ArenaAllocator = null;
threadlocal var given: ?std.heap.ArenaAllocator = null;

/// Where an entry's converted result goes, read by its caller before it returns.
fn giving() std.mem.Allocator {
    if (given) |*g| {
        _ = g.reset(.retain_capacity);
    } else given = .init(std.heap.smp_allocator);
    return given.?.allocator();
}

/// Where a call's converted plain results live, good till this thread's next call that needs it.
pub fn lifting() std.mem.Allocator {
    if (lifted) |*l| {
        _ = l.reset(.retain_capacity);
    } else lifted = .init(std.heap.smp_allocator);
    return lifted.?.allocator();
}

/// Calls the game's function with the same arguments, nothing converted.
pub fn virtualEntry(comptime m: Method, comptime slot: usize, comptime conv: Conv) *const Entry(m) {
    const s = shape(m);
    if (m.static) @compileError("salamander: " ++ m.name ++ " is static, so it has no vtable slot");
    const Game = thunk.Raw(s.params, s.ret, callingConvention(conv));
    return thunk.make(s.params, s.ret, callingConvention(m.conv), struct {
        fn body(raw: @Tuple(s.params)) s.ret {
            const vtable: *const [*]const *const Game = @ptrFromInt(raw[0]);
            return @call(.auto, vtable.*[slot], raw);
        }
    }.body);
}

pub fn getEntry(comptime m: Method, comptime offset: usize) *const Entry(m) {
    const s = shape(m);
    return thunk.make(s.params, s.ret, callingConvention(m.conv), struct {
        fn body(raw: @Tuple(s.params)) s.ret {
            const field: *align(1) const s.ret = @ptrFromInt(raw[0] + offset);
            return field.*;
        }
    }.body);
}

pub fn setEntry(comptime m: Method, comptime offset: usize) *const Entry(m) {
    const s = shape(m);
    return thunk.make(s.params, s.ret, callingConvention(m.conv), struct {
        fn body(raw: @Tuple(s.params)) s.ret {
            const field: *align(1) s.params[1] = @ptrFromInt(raw[0] + offset);
            field.* = raw[1];
        }
    }.body);
}

/// A C entry that converts and calls `function`. Converted results last till this thread's next conversion.
pub fn entryFor(comptime m: Method, comptime function: anytype) *const Entry(m) {
    const s = shape(m);
    const want = @typeInfo(m.Fn).@"fn";
    const have = @typeInfo(@TypeOf(function)).@"fn";
    const first = if (m.static) 0 else 1;
    const where = m.name ++ " is " ++ @typeName(@TypeOf(function)) ++ ", but should be like " ++ @typeName(m.Fn);
    if (have.param_types.len != want.param_types.len + first) @compileError("salamander: " ++ where ++ (if (m.static) "" else " with its data first"));
    const R = want.return_type.?;
    const HR = have.return_type.?;
    if (s.result and @typeInfo(HR) != .error_union) @compileError("salamander: " ++ where);

    const Body = struct {
        fn body(raw: @Tuple(s.params)) s.ret {
            // Parameters for this call only, results till this thread's next entry gives some
            var params: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
            defer params.deinit();
            const a = params.allocator();
            var call: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
            if (!m.static) call[0] = @ptrFromInt(raw[0]);
            inline for (want.param_types, have.param_types[first..], 0..) |P, H, i| {
                const v = lift(P.?, raw[first + i]);
                call[first + i] = if (P.? == H.?) v else fromWire(H.?, a, v) catch return failed(s.ret, s.result);
            }
            const r = @call(.auto, function, call);
            if (!s.result) {
                if (HR == R) return lower(R, r);
                return lower(R, toWire(R, giving(), r) catch return failed(s.ret, false));
            }
            if (r) |v| {
                if (s.out) |_| {
                    const WP = @typeInfo(R).error_union.payload;
                    const wv: WP = if (@TypeOf(v) == WP) v else toWire(WP, giving(), v) catch return unsupported_code;
                    raw[s.params.len - 1].* = lower(WP, wv);
                }
                return 0;
            } else |err| return lowerError(m.Errors, err);
        }
    };
    return thunk.make(s.params, s.ret, callingConvention(m.conv), Body.body);
}

/// What an entry gives when it couldn't convert.
fn failed(comptime T: type, comptime result: bool) T {
    if (result) return unsupported_code;
    return std.mem.zeroes(T);
}

test {
    _ = @import("tests.zig");
    _ = promise;
    _ = blobs;
    _ = json;
    _ = @import("Owner.zig");
    _ = Local;
    _ = queue_file;
    _ = declared;
}
