//! Memory laid out like `rt.Abi`, for converting to and from a language's values.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const rt = @import("salamander_runtime");
const bind = @import("salamander_bind");

const Schema = salamander_schema.Schema;
const Ref = Schema.Ref;
const Shape = bind.abi.Shape;

/// Arrays included.
pub fn shapeOf(s: Schema, r: Ref) Shape {
    if (r == .array) {
        const m = s.memory(r).?;
        return .{ .size = m.size, .alignment = m.alignment };
    }
    return bind.abi.shapeOf(s, r);
}

/// Zeroed.
pub fn alloc(a: std.mem.Allocator, shape: Shape) error{OutOfMemory}![*]u8 {
    const n = @max(shape.size, 1);
    const p = a.rawAlloc(n, .fromByteUnits(@max(shape.alignment, 1)), @returnAddress()) orelse return error.OutOfMemory;
    @memset(p[0..n], 0);
    return p;
}

pub fn bits(mem: [*]const u8, n: usize) u64 {
    var v: u64 = 0;
    @memcpy(std.mem.asBytes(&v)[0..n], mem[0..n]);
    return v;
}

/// The low `n` bytes of `v`, sign extended.
pub fn signed(v: u64, n: usize) i64 {
    const shift: u6 = @intCast(64 - n * 8);
    return @as(i64, @bitCast(v << shift)) >> shift;
}

pub fn put(mem: [*]u8, n: usize, v: u64) void {
    @memcpy(mem[0..n], std.mem.asBytes(&v)[0..n]);
}

pub const Int = union(enum) {
    signed: i64,
    unsigned: u64,
};

pub fn int(mem: [*]const u8, p: Schema.Prim, ps: u8) Int {
    const n = p.size(ps);
    const v = bits(mem, n);
    return if (p.isSigned()) .{ .signed = signed(v, n) } else .{ .unsigned = v };
}

pub fn float(mem: [*]const u8, p: Schema.Prim) f64 {
    return if (p == .f32) @as(f32, @bitCast(@as(u32, @truncate(bits(mem, 4))))) else @bitCast(bits(mem, 8));
}

pub fn putFloat(mem: [*]u8, p: Schema.Prim, f: f64) void {
    if (p == .f32) put(mem, 4, @as(u32, @bitCast(@as(f32, @floatCast(f))))) else put(mem, 8, @bitCast(f));
}

pub fn slice(mem: [*]const u8) rt.Slice(u8) {
    var out: rt.Slice(u8) = undefined;
    @memcpy(std.mem.asBytes(&out), mem[0..@sizeOf(rt.Slice(u8))]);
    return out;
}

pub fn putSlice(mem: [*]u8, ptr: ?[*]const u8, len: usize) void {
    const out: rt.Slice(u8) = .{ .ptr = ptr, .len = len };
    @memcpy(mem[0..@sizeOf(rt.Slice(u8))], std.mem.asBytes(&out));
}

pub fn object(mem: [*]const u8) rt.AnyObject {
    return @as(*align(1) const rt.AnyObject, @ptrCast(mem)).*;
}

pub fn putObject(mem: [*]u8, obj: rt.AnyObject) void {
    @as(*align(1) rt.AnyObject, @ptrCast(mem)).* = obj;
}

/// Null for ones that are nullable themselves.
pub fn someFlag(s: Schema, child: Ref) ?usize {
    if (child == .pointer or s.isObject(child)) return null;
    return shapeOf(s, child).size;
}

/// May have no table.
pub fn blob(mem: [*]const u8) rt.Blob {
    const o = object(mem);
    return .{ .data = o.data, .table = o.table };
}

/// Once a script has its own counts. Union members are skipped, since only one is really there.
pub fn releaseBlobs(s: Schema, r: Ref, mem: [*]const u8) void {
    switch (r) {
        .prim => |p| if (p == .blob) {
            const b = blob(mem);
            if (b.table != null) b.release();
        },
        .named => |n| {
            const t = s.findType(n) orelse return;
            if (t.kind != .@"struct" or !s.holdsObject(r)) return;
            var it = fields(s, t);
            while (it.next()) |f| releaseBlobs(s, f.type, mem + f.offset);
        },
        .array => |a| {
            if (!s.holdsObject(a.child.*)) return;
            const size = shapeOf(s, a.child.*).size;
            for (0..a.len) |i| releaseBlobs(s, a.child.*, mem + i * size);
        },
        .slice => |child| {
            if (!s.holdsObject(child.*)) return;
            const sl = slice(mem);
            const at = sl.ptr orelse return;
            const size = shapeOf(s, child.*).size;
            for (0..sl.len) |i| releaseBlobs(s, child.*, at + i * size);
        },
        .optional => |child| {
            if (someFlag(s, child.*)) |at| if (mem[at] == 0) return;
            releaseBlobs(s, child.*, mem);
        },
        else => {},
    }
}

/// Union members overlap, so each is tried on what was there and only one that changes it goes in,
/// the last if more do. Structs are written straight through.
pub const UnionWrite = struct {
    was: []const u8 = &.{},
    tmp: []u8 = &.{},

    pub fn init(s: Schema, r: Ref, t: *const Schema.Type, mem: [*]const u8, a: std.mem.Allocator) error{OutOfMemory}!UnionWrite {
        if (t.kind != .@"union") return .{};
        const size = shapeOf(s, r).size;
        return .{ .was = try a.dupe(u8, mem[0..size]), .tmp = try a.alloc(u8, size) };
    }

    pub fn at(self: *UnionWrite, mem: [*]u8, offset: usize) [*]u8 {
        if (self.tmp.len == 0) return mem + offset;
        @memcpy(self.tmp, self.was);
        return self.tmp.ptr + offset;
    }

    pub fn done(self: *UnionWrite, mem: [*]u8) void {
        if (self.tmp.len == 0 or std.mem.eql(u8, self.tmp, self.was)) return;
        @memcpy(mem[0..self.tmp.len], self.tmp);
    }
};

pub fn isText(a: Ref.Array) ?Schema.Prim {
    if (a.child.* != .prim) return null;
    return switch (a.child.prim) {
        .utf8, .utf16 => a.child.prim,
        else => null,
    };
}

/// Up to the terminator.
pub fn utf8Text(mem: [*]const u8, len: usize) []const u8 {
    const text = mem[0..len];
    return text[0 .. std.mem.indexOfScalar(u8, text, 0) orelse len];
}

/// As UTF-8 in `buf`, cut short if it doesn't fit.
pub fn utf16Text(mem: [*]const u8, len: usize, buf: []u8) []const u8 {
    const units: [*]align(1) const u16 = @ptrCast(mem);
    var n: usize = 0;
    while (n < len and units[n] != 0) n += 1;
    var w: std.Io.Writer = .fixed(buf);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const cp = std.unicode.utf16DecodeSurrogatePair(&.{ units[i], if (i + 1 < n) units[i + 1] else 0 }) catch units[i];
        if (cp > 0xffff) i += 1;
        var tmp: [4]u8 = undefined;
        const nb = std.unicode.utf8Encode(cp, &tmp) catch std.unicode.utf8Encode(0xfffd, &tmp) catch unreachable;
        w.writeAll(tmp[0..nb]) catch break;
    }
    return w.buffered();
}

/// Leaves room for the terminator.
pub fn putText(mem: [*]u8, kind: Schema.Prim, len: usize, text: []const u8) error{InvalidUtf8}!void {
    if (kind == .utf8) {
        const n = @min(text.len, len -| 1);
        @memcpy(mem[0..n], text[0..n]);
        return;
    }
    const units: [*]align(1) u16 = @ptrCast(mem);
    var i: usize = 0;
    var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var cps = view.iterator();
    while (cps.nextCodepoint()) |cp| {
        if (cp < 0x10000) {
            if (i + 1 >= len) break;
            units[i] = @intCast(cp);
            i += 1;
        } else {
            if (i + 2 >= len) break;
            units[i] = @intCast(0xd800 + ((cp - 0x10000) >> 10));
            units[i + 1] = @intCast(0xdc00 + ((cp - 0x10000) & 0x3ff));
            i += 2;
        }
    }
}

/// As its backing's bits.
pub fn enumValue(e: Schema.Enum, name: []const u8) ?u64 {
    for (e.values) |v| if (std.mem.eql(u8, v.name, name)) return @truncate(@as(u128, @bitCast(v.value)));
    return null;
}

/// Bases' too, with offsets from the start.
pub fn fields(s: Schema, t: *const Schema.Type) Fields {
    return .{ .s = s, .at = t };
}

pub const Fields = struct {
    s: Schema,
    at: ?*const Schema.Type,
    i: usize = 0,
    depth: usize = 0,

    pub fn next(it: *Fields) ?Schema.Field {
        while (it.at) |t| {
            const list = switch (t.kind) {
                .@"struct", .@"union" => |st| st.fields,
                else => &.{},
            };
            if (it.i < list.len) {
                it.i += 1;
                return list[it.i - 1];
            }
            it.depth += 1;
            it.at = if (it.depth > it.s.types.len) null else it.s.baseOf(t);
            it.i = 0;
        }
        return null;
    }
};
