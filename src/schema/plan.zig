//! Padding, bit order, table order and method lookup, shared so every generator agrees.
//! Doesn't allocate, so it runs at comptime too.

const std = @import("std");
const Schema = @import("Schema.zig");
const Ref = Schema.Ref;

/// Most methods a trait can have, bases included.
pub const max_methods = 1024;

/// An error set's codes go in an enum with this after its name.
pub const code_suffix = "Code";

/// A struct's fields and its bases' in offset order, with padding between.
pub const Slot = union(enum) {
    pad: Pad,
    field: Field,

    pub const Pad = struct {
        offset: usize,
        len: usize,
    };

    pub const Field = struct {
        field: Schema.Field,
        /// Less than natural when the offset or size don't allow it.
        alignment: usize,
        natural: usize,
    };
};

pub const Slots = struct {
    s: Schema,
    t: *const Schema.Type,
    cursor: usize = 0,
    /// For unions, the next field's index.
    index: usize = 0,
    done: bool = false,

    pub fn init(s: Schema, t: *const Schema.Type) Slots {
        return .{ .s = s, .t = t };
    }

    pub fn next(it: *Slots) ?Slot {
        if (it.done) return null;
        if (it.t.kind == .@"union") return it.nextUnion();
        // The field with the lowest offset at or after the cursor
        var best: ?Schema.Field = null;
        var chain: ?*const Schema.Type = it.t;
        while (chain) |cur| : (chain = it.s.baseOf(cur)) {
            for (cur.kind.@"struct".fields) |f| {
                if (f.offset < it.cursor) continue;
                if (best == null or f.offset < best.?.offset) best = f;
            }
        }
        const f = best orelse {
            it.done = true;
            if (it.t.size > it.cursor) return .{ .pad = .{ .offset = it.cursor, .len = it.t.size - it.cursor } };
            return null;
        };
        if (f.offset > it.cursor) {
            defer it.cursor = f.offset;
            return .{ .pad = .{ .offset = it.cursor, .len = f.offset - it.cursor } };
        }
        const m = it.s.memory(f.type).?;
        it.cursor = f.offset + @max(m.size, 1);
        return .{ .field = .{ .field = f, .natural = m.alignment, .alignment = Schema.fitAlign(m.alignment, f.offset, it.t.size) } };
    }

    fn nextUnion(it: *Slots) ?Slot {
        const fields = it.t.kind.@"union".fields;
        if (it.index < fields.len) {
            const f = fields[it.index];
            it.index += 1;
            const m = it.s.memory(f.type).?;
            it.cursor = @max(it.cursor, m.size);
            return .{ .field = .{ .field = f, .natural = m.alignment, .alignment = Schema.fitAlign(m.alignment, 0, it.t.size) } };
        }
        it.done = true;
        // `[Size]` bigger than the largest field
        if (it.t.size > it.cursor) return .{ .pad = .{ .offset = 0, .len = it.t.size } };
        return null;
    }
};

/// Bitfield members in bit order, with unused bits between.
pub const Bit = union(enum) {
    pad: Pad,
    member: Schema.Bits,

    pub const Pad = struct {
        bit: u16,
        bits: u16,
    };
};

pub const Bits = struct {
    members: []const Schema.Bits,
    width: u16,
    cursor: u16 = 0,
    done: bool = false,

    pub fn init(s: Schema, b: Schema.Bitfield) Bits {
        return .{ .members = b.members, .width = @intCast(b.backing.size(s.pointer_size) * 8) };
    }

    pub fn next(it: *Bits) ?Bit {
        if (it.done) return null;
        var best: ?Schema.Bits = null;
        for (it.members) |m| {
            if (m.bit < it.cursor) continue;
            if (best == null or m.bit < best.?.bit) best = m;
        }
        const m = best orelse {
            it.done = true;
            if (it.width > it.cursor) return .{ .pad = .{ .bit = it.cursor, .bits = it.width - it.cursor } };
            return null;
        };
        if (m.bit > it.cursor) {
            defer it.cursor = m.bit;
            return .{ .pad = .{ .bit = it.cursor, .bits = m.bit - it.cursor } };
        }
        it.cursor = m.bit + m.bits;
        return .{ .member = m };
    }
};

/// A trait's methods in table order. Bases first, depth first, each once.
pub fn methods(s: Schema, t: *const Schema.Trait, out: *[max_methods]*const Schema.Method) []const *const Schema.Method {
    var len: usize = 0;
    collect(s, t, out, &len, 0);
    return out[0..len];
}

fn collect(s: Schema, t: *const Schema.Trait, out: *[max_methods]*const Schema.Method, len: *usize, depth: usize) void {
    if (depth > s.traits.len) return;
    for (t.bases) |b| if (s.findTrait(b)) |base| collect(s, base, out, len, depth + 1);
    outer: for (t.methods) |*m| {
        for (out[0..len.*]) |o| if (o == m) continue :outer;
        if (len.* == max_methods) return;
        out[len.*] = m;
        len.* += 1;
    }
}

pub const How = union(enum) {
    virtual: Virtual,
    get: usize,
    set: usize,
    missing,

    pub const Virtual = struct {
        slot: usize,
        /// The game function's, which can differ from the trait's.
        conv: Schema.Conv,
    };
};

/// How an impl does `method`. Aliases follow their target. Tools fill in their own later.
pub fn how(s: Schema, impl: *const Schema.Impl, method: *const Schema.Method) How {
    const ty = s.findType(impl.@"for").?;
    var name = method.name;
    // `check` made sure an alias points at something that isn't one
    for (0..2) |_| {
        const item = for (impl.items) |it| {
            if (std.mem.eql(u8, it.method, name)) break it;
        } else return .missing;
        switch (item.source) {
            .virtual => |n| return .{ .virtual = .{ .slot = n, .conv = item.conv orelse impl.conv orelse method.signature.conv } },
            .external => return .missing,
            .field => |path| {
                const f = s.fieldPath(ty, path).?;
                return if (method.signature.params.len == 0) .{ .get = f.offset } else .{ .set = f.offset };
            },
            .alias => |target| name = target,
        }
    }
    return .missing;
}

/// Whether a type reaches `to` through what it holds, by value or pointer.
/// A comptime pointer to something that reaches back is lazy, or the type would contain itself.
pub fn reaches(s: Schema, from: []const u8, to: []const u8) bool {
    var seen: [256][]const u8 = undefined;
    var len: usize = 0;
    return reachesIn(s, from, to, &seen, &len);
}

fn reachesIn(s: Schema, from: []const u8, to: []const u8, seen: *[256][]const u8, len: *usize) bool {
    if (std.mem.eql(u8, from, to)) return true;
    const t = s.findType(from) orelse return false;
    for (seen[0..len.*]) |n| if (std.mem.eql(u8, n, from)) return false;
    if (len.* == seen.len) return true;
    seen[len.*] = from;
    len.* += 1;
    const st = switch (t.kind) {
        .@"struct", .@"union" => |x| x,
        else => return false,
    };
    if (st.base) |b| if (reachesIn(s, b, to, seen, len)) return true;
    for (st.fields) |f| if (refReaches(s, f.type, to, seen, len)) return true;
    return false;
}

fn refReaches(s: Schema, r: Ref, to: []const u8, seen: *[256][]const u8, len: *usize) bool {
    return switch (r) {
        .prim => false,
        .named => |n| reachesIn(s, n, to, seen, len),
        .pointer, .slice, .optional => |c| refReaches(s, c.*, to, seen, len),
        .array => |a| refReaches(s, a.child.*, to, seen, len),
        .result => |res| refReaches(s, res.ok.*, to, seen, len),
        .func => |sig| blk: {
            for (sig.params) |p| if (refReaches(s, p.type, to, seen, len)) break :blk true;
            break :blk refReaches(s, sig.ret, to, seen, len);
        },
    };
}

/// Zig wants an enum exhaustive when every tag value is named.
pub fn exhaustive(bits: u16, count: usize) bool {
    return bits < 64 and count == @as(u64, 1) << @intCast(bits);
}

/// Whether an enum of these values can be zero, so zero makes a default.
pub fn hasZero(bits: u16, values: []const Schema.Enum.Value) bool {
    if (!exhaustive(bits, values.len)) return true;
    for (values) |v| if (v.value == 0) return true;
    return false;
}

/// Like `reaches`, for what a pointer points at.
pub fn refReachesType(s: Schema, r: Ref, to: []const u8) bool {
    var seen: [256][]const u8 = undefined;
    var len: usize = 0;
    return refReaches(s, r, to, &seen, &len);
}

/// Names that mean something in the generated file's top level.
pub const reserved = [_][]const u8{ "rt", "impl" };
