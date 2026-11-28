//! Padding, bit order, table order and method lookup, shared so every generator agrees.
//! Doesn't allocate, so it runs at comptime too.

const std = @import("std");
const Schema = @import("Schema.zig");
const Ref = Schema.Ref;

/// What C, C++ and Rust pack a struct to when one of its fields can't have its natural alignment, or null when
/// none needs it. The smallest such field's, so every offset still holds, which is the struct's own unless it's
/// smaller. Zig lowers just those fields instead.
pub fn packing(s: Schema, t: *const Schema.Type) ?usize {
    var n: ?usize = null;
    var it: Slots = .init(s, t);
    while (it.next()) |slot| if (slot == .field and slot.field.alignment < slot.field.natural) {
        n = @min(n orelse slot.field.alignment, slot.field.alignment);
    };
    return n;
}

/// Whether a struct packed to `packing` keeps the alignment the schema gives it.
pub fn keepsAlignment(s: Schema, t: *const Schema.Type) bool {
    const n = packing(s, t) orelse return true;
    return n == t.alignment;
}

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

/// Whether a type reaches `to` through what it holds. A comptime pointer to something reaching back is lazy.
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

/// `core.TypeInfo`'s `hash`: a type's name and layout, and its fields' too, so the same type matches in another binary.
pub fn typeHash(s: Schema, r: Ref) u64 {
    var h: TypeHash = .{ .s = s };
    h.ref(r);
    return h.f;
}

const TypeHash = struct {
    s: Schema,
    f: u64 = 0xcbf29ce484222325,
    /// Named types being hashed, so one that reaches itself stops there.
    stack: [32][]const u8 = undefined,
    depth: usize = 0,

    fn bytes(h: *TypeHash, b: []const u8) void {
        for (b) |c| h.f = (h.f ^ c) *% 0x100000001b3;
        h.f = (h.f ^ 0xff) *% 0x100000001b3;
    }

    fn int(h: *TypeHash, v: u64) void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, v, .little);
        for (buf) |c| h.f = (h.f ^ c) *% 0x100000001b3;
    }

    fn ref(h: *TypeHash, r: Ref) void {
        h.int(@backingInt(@as(std.meta.Tag(Ref), r)));
        switch (r) {
            .prim => |p| h.int(@backingInt(p)),
            .named => |n| h.named(n),
            .pointer, .slice, .optional => |c| h.ref(c.*),
            .array => |a| {
                h.int(a.len);
                h.ref(a.child.*);
            },
            .result => |res| {
                h.ref(res.ok.*);
                h.bytes(res.err);
            },
            .func => |sig| h.int(Schema.signatureHash(sig.*)),
        }
    }

    fn named(h: *TypeHash, n: []const u8) void {
        h.bytes(n);
        for (h.stack[0..h.depth]) |o| if (std.mem.eql(u8, o, n)) return;
        if (h.depth == h.stack.len) return;
        // A trait's name is all there is to its layout
        const t = h.s.findType(n) orelse return;
        h.stack[h.depth] = n;
        h.depth += 1;
        defer h.depth -= 1;
        h.int(@backingInt(@as(std.meta.Tag(Schema.Type.Kind), t.kind)));
        if (h.s.memory(.{ .named = n })) |m| {
            h.int(m.size);
            h.int(m.alignment);
        }
        switch (t.kind) {
            .@"struct", .@"union" => {
                if (t.kind == .@"struct") if (t.kind.@"struct".tagged) |tg| {
                    h.bytes("tagged");
                    for (tg.members) |m| {
                        h.bytes(m.name);
                        h.ref(m.type);
                    }
                };
                var it: Slots = .init(h.s, t);
                while (it.next()) |slot| if (slot == .field) {
                    const f = slot.field.field;
                    h.bytes(f.name);
                    h.int(if (t.kind == .@"union") 0 else f.offset);
                    h.ref(f.type);
                };
            },
            .@"enum" => |e| {
                h.int(@backingInt(e.backing));
                for (e.values) |v| {
                    h.bytes(v.name);
                    h.int(@bitCast(@as(i64, @truncate(v.value))));
                }
            },
            .bitfield => |b| {
                h.int(@backingInt(b.backing));
                for (b.members) |m| {
                    h.bytes(m.name);
                    h.int(m.bit);
                    h.int(m.bits);
                    h.int(@backingInt(@as(std.meta.Tag(Schema.Bits.Member), m.type)));
                    if (m.type == .@"enum") h.named(m.type.@"enum");
                }
            },
            .@"error" => |e| for (e.errors) |x| {
                h.bytes(x.name);
                h.int(x.code);
            },
            .func => |sig| h.int(Schema.signatureHash(sig)),
            .@"opaque" => {},
        }
    }
};

/// What `core.TypeInfo` says about a type, for generators writing one.
pub const Info = struct {
    /// Its `TypeKind`'s name.
    kind: []const u8,
    /// Empty for what has no name, like `[]T`.
    name: []const u8,
    hash: u64,
    size: usize,
    alignment: usize,
    /// What a pointer, array, slice or optional holds, or an enum's or bitfield's backing.
    child: ?Ref = null,
    len: usize = 0,
};

pub fn info(s: Schema, r: Ref) Info {
    const m = s.memory(r) orelse Schema.Memory{ .size = 0, .alignment = 1 };
    var out: Info = .{ .kind = "", .name = "", .hash = typeHash(s, r), .size = m.size, .alignment = m.alignment };
    switch (r) {
        .prim => |p| {
            out.kind = @tagName(p);
            out.name = @tagName(p);
        },
        .named => |n| {
            out.name = n;
            out.kind = "object";
            if (s.findType(n)) |t| {
                out.kind = @tagName(t.kind);
                switch (t.kind) {
                    .@"enum" => |e| out.child = .{ .prim = e.backing },
                    .bitfield => |b| out.child = .{ .prim = b.backing },
                    .@"struct" => |st| if (st.tagged) |tg| {
                        out.kind = "tagged";
                        out.child = .{ .named = tg.tag };
                    },
                    else => {},
                }
            }
        },
        .pointer, .optional, .slice => |c| {
            out.kind = @tagName(r);
            out.child = c.*;
        },
        .array => |a| {
            out.kind = "array";
            out.child = a.child.*;
            out.len = a.len;
        },
        .func => out.kind = "func",
        .result => unreachable,
    }
    return out;
}

/// Named structs, unions, enums and bitfields have their own info, which the rest point to.
pub fn ownsInfo(s: Schema, r: Ref) bool {
    if (r != .named) return false;
    const t = s.findType(r.named) orelse return false;
    return switch (t.kind) {
        .@"struct", .@"union", .@"enum", .bitfield => true,
        else => false,
    };
}

pub const InfoField = struct {
    name: []const u8,
    type: Ref,
    offset: usize = 0,
    bit: u16 = 0,
    bits: u16 = 0,
};

/// A struct's or union's fields, or a bitfield's members, as `TypeInfo.fields` has them.
pub const InfoFields = struct {
    t: ?*const Schema.Type,
    slots: ?Slots = null,
    index: usize = 0,
    /// Where a tagged union's payload is.
    payload_at: usize = 0,

    pub fn init(s: Schema, r: Ref) InfoFields {
        const t = if (r == .named) s.findType(r.named) else null;
        var it: InfoFields = .{ .t = t };
        if (t) |tt| if (tt.kind == .@"struct" and tt.kind.@"struct".tagged != null) {
            for (tt.kind.@"struct".fields) |f| if (std.mem.eql(u8, f.name, "payload")) {
                it.payload_at = f.offset;
            };
        } else if (tt.kind == .@"struct" or tt.kind == .@"union") {
            it.slots = .init(s, tt);
        };
        return it;
    }

    pub fn next(it: *InfoFields) ?InfoField {
        const t = it.t orelse return null;
        if (t.kind == .@"struct") if (t.kind.@"struct".tagged) |tg| {
            if (it.index >= tg.members.len) return null;
            const m = tg.members[it.index];
            it.index += 1;
            return .{ .name = m.name, .type = m.type, .offset = it.payload_at };
        };
        if (it.slots) |*slots| {
            while (slots.next()) |slot| if (slot == .field) {
                const f = slot.field.field;
                return .{ .name = f.name, .type = f.type, .offset = if (t.kind == .@"union") 0 else f.offset };
            };
            return null;
        }
        if (t.kind != .bitfield) return null;
        const b = t.kind.bitfield;
        if (it.index >= b.members.len) return null;
        const m = b.members[it.index];
        it.index += 1;
        // As generated Zig has them: a wider bool is a number
        const ty: Ref = switch (m.type) {
            .bool => if (m.bits == 1) .{ .prim = .bool } else .{ .prim = b.backing },
            .uint => .{ .prim = b.backing },
            .@"enum" => |en| .{ .named = en },
        };
        return .{ .name = m.name, .type = ty, .bit = m.bit, .bits = m.bits };
    }
};

pub const InfoValue = struct {
    name: []const u8,
    value: i64,
};

/// An enum's or error set's values.
/// An enum's or error set's values, or each of a tagged union's members' tag values.
pub const InfoValues = struct {
    s: Schema,
    t: ?*const Schema.Type,
    index: usize = 0,

    pub fn init(s: Schema, r: Ref) InfoValues {
        return .{ .s = s, .t = if (r == .named) s.findType(r.named) else null };
    }

    pub fn next(it: *InfoValues) ?InfoValue {
        const t = it.t orelse return null;
        defer it.index += 1;
        if (t.kind == .@"struct") if (t.kind.@"struct".tagged) |tg| {
            if (it.index >= tg.members.len) return null;
            const m = tg.members[it.index];
            const e = it.s.findType(tg.tag) orelse return null;
            return .{ .name = m.name, .value = @truncate(Schema.enumValue(e, m.name) orelse 0) };
        };
        return switch (t.kind) {
            .@"enum" => |e| if (it.index < e.values.len) .{ .name = e.values[it.index].name, .value = @truncate(e.values[it.index].value) } else null,
            .@"error" => |e| if (it.index < e.errors.len) .{ .name = e.errors[it.index].name, .value = e.errors[it.index].code } else null,
            else => null,
        };
    }
};
