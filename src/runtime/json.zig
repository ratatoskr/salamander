//! Sal values as JSON, the same in every language. The README's "JSON" says how each type looks.
//! Works on generated types. Fields Zig can't tell apart, like `[]u8` from `string`, are named in their `salamander_json`.

const std = @import("std");

const rt = @import("root.zig");

const Stringify = std.json.Stringify;
const Value = std.json.Value;

/// When JSON doesn't fit the type, or is a type that has no JSON.
pub const ReadError = error{ OutOfMemory, Mismatch };
pub const ParseError = std.json.ParseError(std.json.Scanner) || ReadError;

/// What a field's `u8`s are, when their Zig type says otherwise.
const Hint = enum { none, text, bytes };

/// The largest whole number every language reads exactly, as JavaScript's numbers are doubles.
const exact = (1 << 53) - 1;

/// `v` as one JSON value on `s`.
pub fn write(s: *Stringify, v: anytype) Stringify.Error!void {
    return writeAs(@TypeOf(v), .none, s, v);
}

/// `v` as JSON text.
pub fn stringify(v: anytype, options: Stringify.Options, w: *std.Io.Writer) Stringify.Error!void {
    var s: Stringify = .{ .writer = w, .options = options };
    try write(&s, v);
}

/// `v` as JSON text the caller frees.
pub fn stringifyAlloc(gpa: std.mem.Allocator, v: anytype, options: Stringify.Options) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    stringify(v, options, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `text` as a `T`, kept in an arena that `deinit` frees. Blobs in it have a count the caller releases.
pub fn parse(comptime T: type, gpa: std.mem.Allocator, text: []const u8) ParseError!std.json.Parsed(T) {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    return .{ .arena = arena, .value = try parseLeaky(T, arena.allocator(), text) };
}

/// `text` as a `T`, with what it holds in `a`, which should be an arena.
pub fn parseLeaky(comptime T: type, a: std.mem.Allocator, text: []const u8) ParseError!T {
    // Numbers stay text, so each is read at its own type's width
    const v = try std.json.parseFromSliceLeaky(Value, a, text, .{ .duplicate_field_behavior = .use_last, .parse_numbers = false });
    return fromValue(T, a, v);
}

/// An already parsed value as a `T`, with what it holds in `a`.
pub fn fromValue(comptime T: type, a: std.mem.Allocator, v: Value) ReadError!T {
    return readAs(T, .none, a, v);
}

fn hintOf(comptime T: type, comptime field: []const u8) Hint {
    if (!@hasDecl(T, "salamander_json")) return .none;
    const J = T.salamander_json;
    if (@hasDecl(J, "text")) inline for (J.text) |n| if (std.mem.eql(u8, n, field)) return .text;
    if (@hasDecl(J, "bytes")) inline for (J.bytes) |n| if (std.mem.eql(u8, n, field)) return .bytes;
    return .none;
}

/// Padding generated Zig adds, which isn't the schema's.
fn skipped(comptime n: []const u8) bool {
    return std.mem.startsWith(u8, n, "_pad_") or std.mem.startsWith(u8, n, "_bit_");
}

fn checkValue(comptime T: type) void {
    if (@hasField(T, "data") and @hasField(T, "table")) @compileError("salamander: " ++ @typeName(T) ++ " is an object, which has no JSON");
}

fn writeAs(comptime T: type, comptime hint: Hint, s: *Stringify, v: T) Stringify.Error!void {
    if (T == rt.Blob) {
        if (v.table == null) return s.write(null);
        try s.beginWriteRaw();
        try s.writer.writeByte('"');
        try std.base64.standard.Encoder.encodeWriter(s.writer, v.bytes());
        try s.writer.writeByte('"');
        s.endWriteRaw();
        return;
    }
    switch (@typeInfo(T)) {
        .bool => try s.write(v),
        .int => |i| {
            // Past what doubles hold, as text so nothing's lost
            const big = i.bits > 53 and (v > exact or (i.signedness == .signed and v < -exact));
            if (big) try s.print("\"{d}\"", .{v}) else try s.print("{d}", .{v});
        },
        .float => {
            if (std.math.isNan(v)) return s.write(@as([]const u8, "NaN"));
            if (std.math.isInf(v)) return s.write(@as([]const u8, if (v > 0) "Infinity" else "-Infinity"));
            try s.print("{d}", .{v});
        },
        .@"enum" => |e| {
            inline for (e.field_names) |n| if (v == @field(T, n)) return s.write(@as([]const u8, n));
            try s.print("{d}", .{@backingInt(v)});
        },
        .array => |arr| {
            if (hint == .text and arr.child == u8) return s.write(@as([]const u8, std.mem.sliceTo(&v, 0)));
            try s.beginArray();
            for (v) |x| try writeAs(arr.child, hint, s, x);
            try s.endArray();
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("salamander: " ++ @typeName(T) ++ " is a pointer, which has no JSON");
            if (p.child == u8 and hint != .bytes) return s.write(@as([]const u8, v));
            try s.beginArray();
            for (v) |x| try writeAs(p.child, hint, s, x);
            try s.endArray();
        },
        .optional => |o| if (v) |x| try writeAs(o.child, hint, s, x) else try s.write(null),
        // A tagged union: its member's name, keyed to what it holds
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("salamander: " ++ @typeName(T) ++ " has no JSON, as which member a union holds isn't known");
            switch (v) {
                inline else => |x, which| {
                    if (@TypeOf(x) == void) return s.write(@as([]const u8, @tagName(which)));
                    try s.beginObject();
                    try s.objectField(@tagName(which));
                    try writeAs(@TypeOf(x), .none, s, x);
                    try s.endObject();
                },
            }
        },
        .@"struct" => |st| {
            checkValue(T);
            // A wire slice, from a raw type
            if (@hasDecl(T, "salamander_slice")) return writeAs([]const T.salamander_slice, hint, s, v.get());
            try s.beginObject();
            inline for (st.field_names, st.field_types) |n, F| {
                if (comptime skipped(n)) continue;
                try s.objectField(n);
                try writeAs(F, comptime hintOf(T, n), s, @field(v, n));
            }
            try s.endObject();
        },
        else => @compileError("salamander: " ++ @typeName(T) ++ " has no JSON, as which member a union holds isn't known"),
    }
}

fn readAs(comptime T: type, comptime hint: Hint, a: std.mem.Allocator, v: Value) ReadError!T {
    if (T == rt.Blob) {
        const text = switch (v) {
            .null => return .{},
            .string => |t| t,
            else => return error.Mismatch,
        };
        const decoder = std.base64.standard.Decoder;
        const b = try rt.blobs.make(decoder.calcSizeForSlice(text) catch return error.Mismatch);
        decoder.decode(rt.blobs.mutable(b), text) catch {
            b.release();
            return error.Mismatch;
        };
        return b;
    }
    switch (@typeInfo(T)) {
        .bool => return switch (v) {
            .bool => |b| b,
            else => error.Mismatch,
        },
        .int => return intOf(T, v),
        .float => return floatOf(T, v),
        .@"enum" => |e| switch (v) {
            .string => |text| {
                inline for (e.field_names) |n| if (std.mem.eql(u8, text, n)) return @field(T, n);
                return error.Mismatch;
            },
            .integer, .number_string, .float => {
                const n = try intOf(e.tag_type, v);
                if (e.mode == .nonexhaustive) return @fromBackingInt(n);
                inline for (e.field_names) |name| if (n == @backingInt(@field(T, name))) return @field(T, name);
                return error.Mismatch;
            },
            else => return error.Mismatch,
        },
        .array => |arr| {
            var out: T = undefined;
            if (hint == .text and arr.child == u8) {
                const text = switch (v) {
                    .string => |t| t,
                    else => return error.Mismatch,
                };
                if (text.len > arr.len) return error.Mismatch;
                @memset(&out, 0);
                @memcpy(out[0..text.len], text);
                return out;
            }
            const items = switch (v) {
                .array => |list| list.items,
                else => return error.Mismatch,
            };
            if (items.len != arr.len) return error.Mismatch;
            for (items, &out) |x, *o| o.* = try readAs(arr.child, hint, a, x);
            return out;
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("salamander: " ++ @typeName(T) ++ " is a pointer, which has no JSON");
            if (p.child == u8 and hint != .bytes) {
                const text = switch (v) {
                    .string => |t| t,
                    else => return error.Mismatch,
                };
                // Parsed text can point into what was parsed, which callers may free
                return a.dupe(u8, text);
            }
            const items = switch (v) {
                .array => |list| list.items,
                else => return error.Mismatch,
            };
            const out = try a.alloc(p.child, items.len);
            for (items, out) |x, *o| o.* = try readAs(p.child, hint, a, x);
            return out;
        },
        .optional => |o| return if (v == .null) null else try readAs(o.child, hint, a, v),
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("salamander: " ++ @typeName(T) ++ " has no JSON, as which member a union holds isn't known");
            switch (v) {
                .string => |text| inline for (u.field_names, u.field_types) |n, F| if (F == void and std.mem.eql(u8, text, n)) return @unionInit(T, n, {}),
                .object => |o| if (o.count() == 1) {
                    const key = o.keys()[0];
                    inline for (u.field_names, u.field_types) |n, F| if (F != void and std.mem.eql(u8, key, n)) return @unionInit(T, n, try readAs(F, .none, a, o.values()[0]));
                },
                else => {},
            }
            return error.Mismatch;
        },
        .@"struct" => |st| {
            checkValue(T);
            if (@hasDecl(T, "salamander_slice")) return .init(try readAs([]const T.salamander_slice, hint, a, v));
            const object = switch (v) {
                .object => |o| o,
                else => return error.Mismatch,
            };
            // What's missing or null keeps its default, and what the type doesn't have is left
            var out: T = undefined;
            inline for (st.field_names, st.field_types, st.field_attrs) |n, F, attrs| {
                @field(out, n) = comptime attrs.defaultValue(F) orelse std.mem.zeroes(F);
                if (!comptime skipped(n)) if (object.get(n)) |x| if (x != .null) {
                    @field(out, n) = try readAs(F, comptime hintOf(T, n), a, x);
                };
            }
            return out;
        },
        else => @compileError("salamander: " ++ @typeName(T) ++ " has no JSON, as which member a union holds isn't known"),
    }
}

fn intOf(comptime T: type, v: Value) ReadError!T {
    return switch (v) {
        .integer => |n| std.math.cast(T, n) orelse error.Mismatch,
        .float => |f| wholeOf(T, f),
        // 64-bit numbers can come as text
        .number_string, .string => |text| std.fmt.parseInt(T, text, 10) catch
            wholeOf(T, std.fmt.parseFloat(f64, text) catch return error.Mismatch),
        else => error.Mismatch,
    };
}

/// `1.0` as an integer, which some writers give.
fn wholeOf(comptime T: type, f: f64) ReadError!T {
    if (f != @trunc(f) or @abs(f) > exact) return error.Mismatch;
    return std.math.cast(T, @as(i64, @intFromFloat(f))) orelse error.Mismatch;
}

fn floatOf(comptime T: type, v: Value) ReadError!T {
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |n| @floatFromInt(n),
        .number_string => |text| std.fmt.parseFloat(T, text) catch error.Mismatch,
        .string => |text| if (std.mem.eql(u8, text, "NaN"))
            std.math.nan(T)
        else if (std.mem.eql(u8, text, "Infinity"))
            std.math.inf(T)
        else if (std.mem.eql(u8, text, "-Infinity"))
            -std.math.inf(T)
        else
            error.Mismatch,
        else => error.Mismatch,
    };
}

// Values described by `core.TypeInfo`, for `any`

const TypeInfo = rt.core.raw.TypeInfo;

pub const InfoWriteError = Stringify.Error || error{Unsupported};
pub const InfoReadError = ReadError || error{Unsupported};

fn load(comptime T: type, p: [*]const u8) T {
    return std.mem.bytesToValue(T, p[0..@sizeOf(T)]);
}

fn store(comptime T: type, p: [*]u8, v: T) void {
    @memcpy(p[0..@sizeOf(T)], std.mem.asBytes(&v));
}

/// A slice as it crosses, whatever it holds.
const Bytes = extern struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,
};

fn infoSlice(comptime T: type, s: rt.Slice(T)) []const T {
    return s.get();
}

fn nameOf(info: *const TypeInfo) []const u8 {
    return info.name.get();
}

/// An integer kind's value at `p`.
fn intAt(kind: rt.core.TypeKind, p: [*]const u8) ?i128 {
    return switch (kind) {
        .u8, .utf8 => load(u8, p),
        .u16, .utf16 => load(u16, p),
        .u32 => load(u32, p),
        .u64 => load(u64, p),
        .usize => load(usize, p),
        .i8 => load(i8, p),
        .i16 => load(i16, p),
        .i32 => load(i32, p),
        .i64 => load(i64, p),
        .isize => load(isize, p),
        else => null,
    };
}

/// `v` into an integer kind at `p`, if it fits.
fn putInt(kind: rt.core.TypeKind, p: [*]u8, v: i128) ReadError!void {
    switch (kind) {
        inline .u8, .utf8, .u16, .utf16, .u32, .u64, .usize, .i8, .i16, .i32, .i64, .isize => |k| {
            const T = switch (k) {
                .u8, .utf8 => u8,
                .u16, .utf16 => u16,
                .u32 => u32,
                .u64 => u64,
                .usize => usize,
                .i8 => i8,
                .i16 => i16,
                .i32 => i32,
                .i64 => i64,
                .isize => isize,
                else => unreachable,
            };
            store(T, p, std.math.cast(T, v) orelse return error.Mismatch);
        },
        else => return error.Mismatch,
    }
}

fn intKindRead(kind: rt.core.TypeKind, v: Value) ReadError!i128 {
    return switch (kind) {
        .u64, .usize => try intOf(u64, v),
        else => try intOf(i64, v),
    };
}

fn writeBig(s: *Stringify, v: i128) Stringify.Error!void {
    if (v > exact or v < -exact) try s.print("\"{d}\"", .{v}) else try s.print("{d}", .{v});
}

fn writeFloat(s: *Stringify, v: anytype) Stringify.Error!void {
    if (std.math.isNan(v)) return s.write(@as([]const u8, "NaN"));
    if (std.math.isInf(v)) return s.write(@as([]const u8, if (v > 0) "Infinity" else "-Infinity"));
    try s.print("{d}", .{v});
}

fn enumName(info: *const TypeInfo, v: i128) ?[]const u8 {
    for (infoSlice(rt.core.raw.EnumValue, info.values)) |e| if (e.value == v) return e.name.get();
    return null;
}

fn enumValue(info: *const TypeInfo, name: []const u8) ?i64 {
    for (infoSlice(rt.core.raw.EnumValue, info.values)) |e| if (std.mem.eql(u8, e.name.get(), name)) return e.value;
    return null;
}

/// The value at `p`, of type `info`, as one JSON value on `s`.
pub fn writeInfo(s: *Stringify, info: *const TypeInfo, p: [*]const u8) InfoWriteError!void {
    switch (info.kind) {
        .bool => try s.write(p[0] != 0),
        .u8, .utf8, .u16, .utf16, .u32, .u64, .usize, .i8, .i16, .i32, .i64, .isize => try writeBig(s, intAt(info.kind, p).?),
        .f32 => try writeFloat(s, load(f32, p)),
        .f64 => try writeFloat(s, load(f64, p)),
        .string => try s.write(load(rt.String, p).get()),
        .cstring => if (load(?[*:0]const u8, p)) |z| try s.write(std.mem.span(z)) else try s.write(null),
        .blob => try writeAs(rt.Blob, .none, s, load(rt.Blob, p)),
        .@"struct" => {
            try s.beginObject();
            for (infoSlice(rt.core.raw.FieldInfo, info.fields)) |f| {
                try s.objectField(f.name.get());
                try writeInfo(s, f.type.?, p + f.offset);
            }
            try s.endObject();
        },
        .@"enum" => {
            const v = intAt(info.child.?.kind, p) orelse return error.Unsupported;
            if (enumName(info, v)) |n| try s.write(n) else try s.print("{d}", .{v});
        },
        .bitfield => {
            const bits: u64 = @intCast(intAt(info.child.?.kind, p) orelse return error.Unsupported);
            try s.beginObject();
            for (infoSlice(rt.core.raw.FieldInfo, info.fields)) |f| {
                try s.objectField(f.name.get());
                const v = (bits >> @intCast(f.bit)) & ((@as(u64, 1) << @intCast(f.bits)) - 1);
                switch (f.type.?.kind) {
                    .bool => try s.write(v != 0),
                    .@"enum" => if (enumName(f.type.?, v)) |n| try s.write(n) else try s.print("{d}", .{v}),
                    else => try s.print("{d}", .{v}),
                }
            }
            try s.endObject();
        },
        .array => {
            const child = info.child.?;
            if (child.kind == .utf8) return s.write(std.mem.sliceTo(p[0..info.len], 0));
            try s.beginArray();
            for (0..info.len) |i| try writeInfo(s, child, p + i * child.size);
            try s.endArray();
        },
        .slice => {
            const child = info.child.?;
            const items = load(Bytes, p);
            const base: [*]const u8 = items.ptr orelse "";
            const len = if (items.ptr == null) 0 else items.len;
            if (child.kind == .utf8) return s.write(base[0..len]);
            try s.beginArray();
            for (0..len) |i| try writeInfo(s, child, base + i * child.size);
            try s.endArray();
        },
        .tagged => {
            const f = liveMember(info, p) orelse return error.Unsupported;
            if (f.type.?.kind == .void) return s.write(f.name.get());
            try s.beginObject();
            try s.objectField(f.name.get());
            try writeInfo(s, f.type.?, p + f.offset);
            try s.endObject();
        },
        // As `rt.Opt` has it: the value, then whether it's there
        .optional => {
            const child = info.child.?;
            if (child.kind == .pointer or child.kind == .object or child.kind == .func) return error.Unsupported;
            if (p[child.size] == 0) try s.write(null) else try writeInfo(s, child, p);
        },
        else => return error.Unsupported,
    }
}

/// `v` as a value of type `info`, written at `out`, which starts zeroed. What it points at goes in `a`.
pub fn readInfo(info: *const TypeInfo, a: std.mem.Allocator, v: Value, out: [*]u8) InfoReadError!void {
    switch (info.kind) {
        .bool => out[0] = switch (v) {
            .bool => |b| @intFromBool(b),
            else => return error.Mismatch,
        },
        .u8, .utf8, .u16, .utf16, .u32, .u64, .usize, .i8, .i16, .i32, .i64, .isize => try putInt(info.kind, out, try intKindRead(info.kind, v)),
        .f32 => store(f32, out, try floatOf(f32, v)),
        .f64 => store(f64, out, try floatOf(f64, v)),
        .string => store(rt.String, out, .init(try readAs([]const u8, .none, a, v))),
        .cstring => if (v != .null) {
            const text = switch (v) {
                .string => |t| t,
                else => return error.Mismatch,
            };
            store([*:0]const u8, out, (try a.dupeSentinel(u8, text, 0)).ptr);
        },
        .blob => store(rt.Blob, out, try readAs(rt.Blob, .none, a, v)),
        .@"struct" => {
            const object = switch (v) {
                .object => |o| o,
                else => return error.Mismatch,
            };
            for (infoSlice(rt.core.raw.FieldInfo, info.fields)) |f| {
                const x = object.get(f.name.get()) orelse continue;
                if (x != .null) try readInfo(f.type.?, a, x, out + f.offset);
            }
        },
        .@"enum" => {
            const n: i128 = switch (v) {
                .string => |text| enumValue(info, text) orelse return error.Mismatch,
                else => try intKindRead(info.child.?.kind, v),
            };
            try putInt(info.child.?.kind, out, n);
        },
        .bitfield => {
            const object = switch (v) {
                .object => |o| o,
                else => return error.Mismatch,
            };
            var bits: u64 = 0;
            for (infoSlice(rt.core.raw.FieldInfo, info.fields)) |f| {
                const x = object.get(f.name.get()) orelse continue;
                const n: u64 = switch (x) {
                    .null => continue,
                    .bool => |b| if (f.type.?.kind == .bool) @intFromBool(b) else return error.Mismatch,
                    .string => |text| if (f.type.?.kind == .@"enum") @bitCast(enumValue(f.type.?, text) orelse return error.Mismatch) else return error.Mismatch,
                    else => try intOf(u64, x),
                };
                const mask = (@as(u64, 1) << @intCast(f.bits)) - 1;
                if (n > mask) return error.Mismatch;
                bits |= n << @intCast(f.bit);
            }
            try putInt(info.child.?.kind, out, bits);
        },
        .array => {
            const child = info.child.?;
            if (child.kind == .utf8) {
                const text = switch (v) {
                    .string => |t| t,
                    else => return error.Mismatch,
                };
                if (text.len > info.len) return error.Mismatch;
                @memcpy(out[0..text.len], text);
                return;
            }
            const items = switch (v) {
                .array => |list| list.items,
                else => return error.Mismatch,
            };
            if (items.len != info.len) return error.Mismatch;
            for (items, 0..) |x, i| try readInfo(child, a, x, out + i * child.size);
        },
        .slice => {
            const child = info.child.?;
            if (child.kind == .utf8) {
                const text = try readAs([]const u8, .none, a, v);
                return store(Bytes, out, .{ .ptr = @constCast(text.ptr), .len = text.len });
            }
            const items = switch (v) {
                .array => |list| list.items,
                else => return error.Mismatch,
            };
            if (items.len == 0) return;
            const size = child.size * items.len;
            const base = a.rawAlloc(size, .fromByteUnits(child.alignment), @returnAddress()) orelse return error.OutOfMemory;
            @memset(base[0..size], 0);
            for (items, 0..) |x, i| try readInfo(child, a, x, base + i * child.size);
            store(Bytes, out, .{ .ptr = base, .len = items.len });
        },
        .optional => {
            const child = info.child.?;
            if (child.kind == .pointer or child.kind == .object or child.kind == .func) return error.Unsupported;
            if (v == .null) return;
            try readInfo(child, a, v, out);
            out[child.size] = 1;
        },
        .tagged => {
            const fields = infoSlice(rt.core.raw.FieldInfo, info.fields);
            const values = infoSlice(rt.core.raw.EnumValue, info.values);
            const key: []const u8, const held: ?Value = switch (v) {
                .string => |text| .{ text, null },
                .object => |o| if (o.count() == 1) .{ o.keys()[0], o.values()[0] } else return error.Mismatch,
                else => return error.Mismatch,
            };
            for (fields, values) |f, value| if (std.mem.eql(u8, f.name.get(), key)) {
                const holds = f.type.?.kind != .void;
                if (holds != (held != null)) return error.Mismatch;
                try putInt(info.child.?.child.?.kind, out, value.value);
                if (held) |x| try readInfo(f.type.?, a, x, out + f.offset);
                return;
            };
            return error.Mismatch;
        },
        else => return error.Unsupported,
    }
}

/// Moves what the value at `at` points at to `buf` from `cursor` on, or with no `buf`, only counts how far it goes.
fn pack(info: *const TypeInfo, at: [*]u8, buf: ?[]u8, cursor: *usize) void {
    switch (info.kind) {
        .string, .slice => {
            const elem: *const TypeInfo = if (info.kind == .string) &byte_info else info.child.?;
            const items = load(Bytes, at);
            const from = items.ptr orelse return;
            cursor.* = std.mem.alignForward(usize, cursor.*, @max(elem.alignment, 1));
            const size = elem.size * items.len;
            const start = cursor.*;
            cursor.* += size;
            const b = buf orelse {
                // Counting goes through the old copy
                for (0..items.len) |i| pack(elem, from + i * elem.size, null, cursor);
                return;
            };
            @memcpy(b[start..][0..size], from[0..size]);
            store(Bytes, at, .{ .ptr = b[start..].ptr, .len = items.len });
            for (0..items.len) |i| pack(elem, b[start..].ptr + i * elem.size, b, cursor);
        },
        .cstring => {
            const z = load(?[*:0]u8, at) orelse return;
            const text = std.mem.span(z);
            const start = cursor.*;
            cursor.* += text.len + 1;
            const b = buf orelse return;
            @memcpy(b[start..][0..text.len], text);
            b[start + text.len] = 0;
            store([*:0]u8, at, @ptrCast(b[start..].ptr));
        },
        .@"struct" => for (infoSlice(rt.core.raw.FieldInfo, info.fields)) |f| pack(f.type.?, at + f.offset, buf, cursor),
        .array => for (0..info.len) |i| pack(info.child.?, at + i * info.child.?.size, buf, cursor),
        .optional => if (at[info.child.?.size] != 0) pack(info.child.?, at, buf, cursor),
        .tagged => if (liveMember(info, at)) |f| pack(f.type.?, at + f.offset, buf, cursor),
        else => {},
    }
}

const byte_info: TypeInfo = .{ .kind = .u8, .size = 1, .alignment = 1 };

/// The member a tagged union's tag says is there.
fn liveMember(info: *const TypeInfo, p: [*]const u8) ?rt.core.raw.FieldInfo {
    const tag = intAt(info.child.?.child.?.kind, p) orelse return null;
    for (infoSlice(rt.core.raw.FieldInfo, info.fields), infoSlice(rt.core.raw.EnumValue, info.values)) |f, value| if (value.value == tag) return f;
    return null;
}

/// The value at `value` as JSON text the caller frees.
pub fn stringifyInfo(gpa: std.mem.Allocator, info: *const TypeInfo, value: *const anyopaque, options: Stringify.Options) error{ OutOfMemory, Unsupported }![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s: Stringify = .{ .writer = &out.writer, .options = options };
    writeInfo(&s, info, @ptrCast(value)) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        error.Unsupported => error.Unsupported,
    };
    return out.toOwnedSlice();
}

/// `text` as a value of type `info` at the start of a blob, with what it points at after it, so releasing the blob frees it all.
pub fn parseInfoBlob(gpa: std.mem.Allocator, info: *const TypeInfo, text: []const u8) (InfoReadError || error{Invalid})!rt.Blob {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const v = std.json.parseFromSliceLeaky(Value, a, text, .{ .duplicate_field_behavior = .use_last, .parse_numbers = false }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Invalid,
    };
    const value = a.rawAlloc(@max(info.size, 1), .fromByteUnits(@max(info.alignment, 1)), @returnAddress()) orelse return error.OutOfMemory;
    @memset(value[0..info.size], 0);
    try readInfo(info, a, v, value);
    var size = info.size;
    pack(info, value, null, &size);
    const b = try rt.blobs.make(size);
    const buf = rt.blobs.mutable(b);
    @memcpy(buf[0..info.size], value[0..info.size]);
    var cursor = info.size;
    pack(info, buf.ptr, buf, &cursor);
    return b;
}

const testing = std.testing;

const Mode = enum(u8) { walk = 1, run = 2, _ };
const Flags = bitpack struct(u8) { on: bool = false, _bit_1: u3 = 0, level: u4 = 0 };
const Item = struct {
    name: []const u8 = "",
    data: []const u8 = &.{},
    label: [8]u8 = @splat(0),
    wide: [4]u16 = @splat(0),
    pub const salamander_json = struct {
        pub const text: []const []const u8 = &.{"label"};
        pub const bytes: []const []const u8 = &.{"data"};
    };
};
const Doc = struct {
    id: u64 = 0,
    small: i64 = 0,
    scale: f32 = 1,
    mode: Mode = .walk,
    flags: Flags = .{},
    items: []const Item = &.{},
    point: [3]f32 = @splat(0),
    _pad_0x40: [4]u8 = @splat(0),
};

test "values go to JSON and back" {
    const doc: Doc = .{
        .id = 1 << 60,
        .small = -5,
        .scale = 0.1,
        .mode = .run,
        .flags = .{ .on = true, .level = 3 },
        .items = &.{.{ .name = "kai", .data = &.{ 1, 2 }, .label = "hi\x00\x00\x00\x00\x00\x00".*, .wide = .{ 'o', 'k', 0, 0 } }},
        .point = .{ 1, 2.5, -3 },
    };
    const text = try stringifyAlloc(testing.allocator, doc, .{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\{"id":"1152921504606846976","small":-5,"scale":0.1,"mode":"run","flags":{"on":true,"level":3},"items":[{"name":"kai","data":[1,2],"label":"hi","wide":[111,107,0,0]}],"point":[1,2.5,-3]}
    , text);

    const back = try parse(Doc, testing.allocator, text);
    defer back.deinit();
    try testing.expectEqual(doc.id, back.value.id);
    try testing.expectEqual(doc.small, back.value.small);
    try testing.expectEqual(doc.scale, back.value.scale);
    try testing.expectEqual(doc.mode, back.value.mode);
    try testing.expectEqual(doc.flags, back.value.flags);
    try testing.expectEqualStrings("kai", back.value.items[0].name);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, back.value.items[0].data);
    try testing.expectEqual(doc.items[0].label, back.value.items[0].label);
    try testing.expectEqual(doc.items[0].wide, back.value.items[0].wide);
    try testing.expectEqual(doc.point, back.value.point);
}

test "missing fields keep defaults, and unknown ones are left" {
    const back = try parse(Doc, testing.allocator,
        \\{"small":3,"later":{"x":1},"mode":null}
    );
    defer back.deinit();
    try testing.expectEqual(3, back.value.small);
    try testing.expectEqual(1, back.value.scale);
    try testing.expectEqual(Mode.walk, back.value.mode);
}

test "numbers in other forms" {
    const back = try parse(Doc, testing.allocator,
        \\{"id":7,"small":"-9","scale":"NaN","mode":9,"point":[1.0,2,3e0]}
    );
    defer back.deinit();
    try testing.expectEqual(7, back.value.id);
    try testing.expectEqual(-9, back.value.small);
    try testing.expect(std.math.isNan(back.value.scale));
    // Unnamed values of open enums stay numbers
    try testing.expectEqual(9, @backingInt(back.value.mode));
    try testing.expectEqual([3]f32{ 1, 2, 3 }, back.value.point);
    const text = try stringifyAlloc(testing.allocator, back.value, .{});
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"scale\":\"NaN\",\"mode\":9") != null);
}

test "what doesn't fit is a mismatch" {
    const bad = [_][]const u8{
        \\{"small":"x"}
        ,
        \\{"mode":"fly"}
        ,
        \\{"point":[1,2]}
        ,
        \\{"items":[{"label":"far too long"}]}
        ,
        \\{"items":{}}
        ,
        \\{"id":-1}
        ,
        \\[]
    };
    for (bad) |text| try testing.expectError(error.Mismatch, parse(Doc, testing.allocator, text));
}
