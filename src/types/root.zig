//! Editor typings for `.sal` schemas, TypeScript and LuaLS, for scripts on the JS and Lua hosts.
//! Docs come from the `//` lines above each thing in the source.

const std = @import("std");
const Schema = @import("salamander_schema").Schema;

pub const ts = @import("ts.zig");
pub const luals = @import("luals.zig");

/// The `//` lines right above the line `at` is on, past any annotation lines, without their slashes.
pub fn docLines(source: []const u8, at: usize) DocLines {
    if (at > source.len) return .{ .source = source, .start = 0, .end = 0 };
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..at], '\n')) |n| n + 1 else 0;
    // Something on the same line before it, like its struct, means the comment above is that's
    if (std.mem.indexOfAny(u8, source[line_start..at], "{;") != null) return .{ .source = source, .start = 0, .end = 0 };
    var start = line_start;
    var first = line_start;
    while (start > 0) {
        const prev_end = start - 1;
        const prev_start = if (std.mem.lastIndexOfScalar(u8, source[0..prev_end], '\n')) |n| n + 1 else 0;
        const line = std.mem.trim(u8, source[prev_start..prev_end], " \t\r");
        if (std.mem.startsWith(u8, line, "//")) {
            first = prev_start;
        } else if (!(std.mem.startsWith(u8, line, "[") and first == line_start)) break;
        start = prev_start;
    }
    return .{ .source = source, .start = first, .end = line_start };
}

pub const DocLines = struct {
    source: []const u8,
    start: usize,
    end: usize,

    pub fn next(self: *DocLines) ?[]const u8 {
        while (self.start < self.end) {
            const nl = std.mem.indexOfScalarPos(u8, self.source, self.start, '\n') orelse self.end;
            const line = std.mem.trim(u8, self.source[self.start..@min(nl, self.end)], " \t\r");
            self.start = nl + 1;
            if (!std.mem.startsWith(u8, line, "//")) continue;
            return std.mem.trim(u8, line[2..], " \t");
        }
        return null;
    }

    pub fn empty(self: DocLines) bool {
        var copy = self;
        return copy.next() == null;
    }
};

/// A type's name as scripts write it, like `World.Counter`, each part one identifier, like `StdVector_ItemPtr`.
pub fn writeTypeName(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    var rest = name;
    while (firstDot(rest)) |d| {
        try Schema.writeFlatName(w, rest[0..d]);
        try w.writeByte('.');
        rest = rest[d + 1 ..];
    }
    try Schema.writeFlatName(w, rest);
}

/// The first dot in `name` that isn't in a generic's `<..>`.
pub fn firstDot(name: []const u8) ?usize {
    var depth: usize = 0;
    for (name, 0..) |c, i| switch (c) {
        '<' => depth += 1,
        '>' => depth -|= 1,
        '.' => if (depth == 0) return i,
        else => {},
    };
    return null;
}

/// Something with a name scripts know, like the struct `World.Counter` or `Wraith.tweaks` for `Wraith.Api.tweaks`.
pub const Entry = struct {
    /// Its namespace, like `World`. Empty at the top.
    parent: []const u8,
    leaf: []const u8,
    what: What,

    pub const What = union(enum) {
        type: *const Schema.Type,
        trait: *const Schema.Trait,
        function: *const Schema.Method,
        static: *const Schema.Static,
        /// A `[Root]` trait's method giving one of its namespace's objects.
        accessor: *const Schema.Method,
        /// One of `singletons`, as a function by its lowercased name. `leaf` is still the trait's.
        singleton: *const Schema.Trait,
    };

    fn of(name: []const u8, what: What) Entry {
        const end = Schema.namespaceEnd(name) orelse return .{ .parent = "", .leaf = name, .what = what };
        return .{ .parent = name[0..end], .leaf = name[end + 1 ..], .what = what };
    }

    /// Whether it's there while scripts run. Generics' instances and top-level statics aren't.
    pub fn isValue(e: Entry, s: Schema) bool {
        if (std.mem.indexOfScalar(u8, e.parent, '<') != null or std.mem.indexOfScalar(u8, e.leaf, '<') != null) return false;
        return switch (e.what) {
            .type => |t| !t.nested and (t.kind == .@"struct" or t.kind == .@"enum"),
            .trait => |t| hasInstance(s, t),
            .function, .accessor, .singleton => true,
            .static => e.parent.len > 0,
        };
    }

    /// Whether it's a type, which the other kinds aren't.
    pub fn isType(e: Entry) bool {
        return switch (e.what) {
            .type => |t| t.kind != .@"opaque",
            .trait => true,
            else => false,
        };
    }

    /// Whether it's a struct, enum or trait whose value has its own things on it.
    pub fn holds(e: Entry, s: Schema) bool {
        return e.isValue(s) and (e.what == .type or e.what == .trait);
    }
};

/// Whether `t` gets a static `instance()`: a root, what a root's accessor gives, or a singleton.
pub fn hasInstance(s: Schema, t: *const Schema.Trait) bool {
    return t.root or s.accessorOf(t.name) != null or isSingleton(t.name);
}

/// Traits the host gives scripts one of, like `Freecam.Camera`, each a function like `Freecam.camera()`. Set while `globals` writes.
pub threadlocal var singletons: []const []const u8 = &.{};

fn isSingleton(name: []const u8) bool {
    for (singletons) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Whether a root's accessor in the same namespace already has the name a singleton of `t` would.
fn givenByRoot(s: Schema, t: *const Schema.Trait) bool {
    var buf: [128]u8 = undefined;
    const name = singletonName(&buf, t.name);
    const end = Schema.namespaceEnd(t.name);
    for (s.traits) |*r| {
        if (!r.root) continue;
        const r_end = Schema.namespaceEnd(r.name);
        const same = if (end) |e| r_end != null and std.mem.eql(u8, r.name[0..r_end.?], t.name[0..e]) else r_end == null;
        if (!same) continue;
        for (r.methods) |*m| if (s.isAccessor(m) and std.mem.eql(u8, m.name, name)) return true;
    }
    return false;
}

/// A singleton's function, `Camera` lowercased at the start like `camera`, in `buf`.
pub fn singletonName(buf: []u8, trait_name: []const u8) []const u8 {
    const leaf = leafOf(trait_name);
    const n = @min(leaf.len, buf.len);
    @memcpy(buf[0..n], leaf[0..n]);
    if (n > 0) buf[0] = std.ascii.toLower(buf[0]);
    return buf[0..n];
}

/// Every `Entry` in a schema: types, traits, functions, statics, roots' accessors, then singletons.
pub const Entries = struct {
    s: Schema,
    i: usize = 0,
    /// The method of the root at `i`, for accessors.
    j: usize = 0,

    pub fn next(it: *Entries) ?Entry {
        const s = it.s;
        while (true) {
            var i = it.i;
            if (i < s.types.len) {
                it.i += 1;
                return .of(s.types[i].name, .{ .type = &s.types[i] });
            }
            i -= s.types.len;
            if (i < s.traits.len) {
                it.i += 1;
                return .of(s.traits[i].name, .{ .trait = &s.traits[i] });
            }
            i -= s.traits.len;
            if (i < s.functions.len) {
                it.i += 1;
                return .of(s.functions[i].name, .{ .function = &s.functions[i] });
            }
            i -= s.functions.len;
            if (i < s.statics.len) {
                it.i += 1;
                return .of(s.statics[i].name, .{ .static = &s.statics[i] });
            }
            i -= s.statics.len;
            if (i >= s.traits.len) {
                const k = i - s.traits.len;
                if (k >= singletons.len) return null;
                it.i += 1;
                const t = s.findTrait(singletons[k]) orelse continue;
                if (givenByRoot(s, t)) continue;
                return .of(t.name, .{ .singleton = t });
            }
            const t = &s.traits[i];
            if (!t.root or it.j >= t.methods.len) {
                it.i += 1;
                it.j = 0;
                continue;
            }
            const m = &t.methods[it.j];
            it.j += 1;
            if (!s.isAccessor(m)) continue;
            const end = Schema.namespaceEnd(t.name);
            return .{ .parent = if (end) |e| t.name[0..e] else "", .leaf = m.name, .what = .{ .accessor = m } };
        }
    }
};

/// What an entry's kept for, its value or its type.
pub const Side = enum {
    value,
    type,

    pub fn keeps(side: Side, s: Schema, e: Entry) bool {
        return switch (side) {
            .value => e.isValue(s),
            .type => e.isType(),
        };
    }
};

/// The namespaces right in `path`, as whole names, each once, holding something `side` keeps. Empty `path` is the top.
pub const Children = struct {
    s: Schema,
    path: []const u8,
    side: Side,
    entries: Entries,
    /// How many entries have been looked at.
    n: usize = 0,

    pub fn init(s: Schema, path: []const u8, side: Side) Children {
        return .{ .s = s, .path = path, .side = side, .entries = .{ .s = s } };
    }

    pub fn next(it: *Children) ?[]const u8 {
        while (it.entries.next()) |e| {
            it.n += 1;
            const child = it.childOf(e) orelse continue;
            var earlier: Entries = .{ .s = it.s };
            var k: usize = 1;
            const seen = while (k < it.n) : (k += 1) {
                const o = earlier.next().?;
                if (it.childOf(o)) |c| if (std.mem.eql(u8, c, child)) break true;
            } else false;
            if (!seen) return child;
        }
        return null;
    }

    fn childOf(it: *const Children, e: Entry) ?[]const u8 {
        if (!it.side.keeps(it.s, e)) return null;
        const p = e.parent;
        const start = if (it.path.len == 0) 0 else start: {
            if (p.len <= it.path.len or !std.mem.startsWith(u8, p, it.path) or p[it.path.len] != '.') return null;
            break :start it.path.len + 1;
        };
        if (p.len == 0) return null;
        const end = if (firstDot(p[start..])) |d| start + d else p.len;
        return p[0..end];
    }
};

/// The part of `name` after its namespace.
pub fn leafOf(name: []const u8) []const u8 {
    return name[if (Schema.namespaceEnd(name)) |e| e + 1 else 0..];
}

/// Whether `path` names something that holds things on its value, like a struct's class.
pub fn holder(s: Schema, path: []const u8) ?Entry {
    if (s.findType(path)) |t| {
        const e: Entry = .of(path, .{ .type = t });
        if (e.holds(s)) return e;
    }
    if (s.findTrait(path)) |t| {
        const e: Entry = .of(path, .{ .trait = t });
        if (e.holds(s)) return e;
    }
    return null;
}

/// Which structs are in memory, whose fields are live views. The rest are plain values whose fields go both ways.
pub const Live = struct {
    bits: std.StaticBitSet(max) = .empty,

    const max = 4096;

    /// Structs with methods or statics, what statics are and what pointers point to, then what's
    /// in those and their bases.
    pub fn init(s: Schema) Live {
        var l: Live = .{};
        for (s.types, 0..) |t, i| switch (t.kind) {
            .@"struct", .@"union" => |st| {
                if (st.methods.len > 0 or st.statics.len > 0) l.set(i);
                for (st.fields) |f| l.reach(s, f.type, false);
                for (st.methods) |m| l.signature(s, m.signature);
                for (st.statics) |v| l.reach(s, v.type, true);
            },
            .func => |sig| l.signature(s, sig),
            else => {},
        };
        for (s.statics) |v| l.reach(s, v.type, true);
        for (s.functions) |f| l.signature(s, f.signature);
        for (s.traits) |t| for (t.methods) |m| l.signature(s, m.signature);
        var changed = true;
        while (changed) {
            changed = false;
            for (s.types, 0..) |t, i| {
                if (i >= max or !l.bits.isSet(i)) continue;
                const st = switch (t.kind) {
                    .@"struct", .@"union" => |st| st,
                    else => continue,
                };
                const before = l.bits.count();
                if (st.base) |b| l.mark(s, b);
                for (st.fields) |f| l.reach(s, f.type, true);
                if (l.bits.count() != before) changed = true;
            }
        }
        return l;
    }

    pub fn has(l: Live, s: Schema, t: *const Schema.Type) bool {
        const i = (@intFromPtr(t) - @intFromPtr(s.types.ptr)) / @sizeOf(Schema.Type);
        return i >= max or l.bits.isSet(i);
    }

    fn set(l: *Live, i: usize) void {
        if (i < max) l.bits.set(i);
    }

    fn mark(l: *Live, s: Schema, name: []const u8) void {
        const t = s.findType(name) orelse return;
        l.set((@intFromPtr(t) - @intFromPtr(s.types.ptr)) / @sizeOf(Schema.Type));
    }

    fn signature(l: *Live, s: Schema, sig: Schema.Signature) void {
        for (sig.params) |p| l.reach(s, p.type, false);
        l.reach(s, sig.ret, false);
    }

    /// Marks what `r` points to, and `r` itself if `direct`.
    fn reach(l: *Live, s: Schema, r: Schema.Ref, direct: bool) void {
        switch (r) {
            .named => |n| if (direct) l.mark(s, n),
            .pointer => |c| l.reach(s, c.*, true),
            .array => |a| l.reach(s, a.child.*, direct),
            .slice, .optional => |c| l.reach(s, c.*, direct),
            .result => |res| l.reach(s, res.ok.*, direct),
            .prim, .func => {},
        }
    }
};

/// Whether `r` is a struct or union, which scripts see as objects.
pub fn isRecord(s: Schema, r: Schema.Ref) bool {
    if (r != .named) return false;
    const t = s.findType(r.named) orelse return false;
    return t.kind == .@"struct" or t.kind == .@"union";
}

/// `u8[N]` or `u16[N]`, which are strings.
pub fn isTextArray(r: Schema.Ref) bool {
    if (r != .array) return false;
    return r.array.child.* == .prim and (r.array.child.prim == .u8 or r.array.child.prim == .u16);
}

/// `u8*` or `u16*`, read as text when memory can be.
pub fn isTextPointer(r: Schema.Ref) bool {
    if (r != .pointer) return false;
    return r.pointer.* == .prim and (r.pointer.prim == .u8 or r.pointer.prim == .u16);
}

/// A struct's own fields and its bases', bases first.
pub fn allFields(s: Schema, t: *const Schema.Type, out: []Schema.Field) []Schema.Field {
    var chain: [16]*const Schema.Type = undefined;
    var depth: usize = 0;
    var at: ?*const Schema.Type = t;
    while (at) |cur| : (at = s.baseOf(cur)) {
        if (depth == chain.len) break;
        chain[depth] = cur;
        depth += 1;
    }
    var n: usize = 0;
    var i = depth;
    while (i > 0) {
        i -= 1;
        const fields = switch (chain[i].kind) {
            .@"struct", .@"union" => |st| st.fields,
            else => continue,
        };
        for (fields) |f| {
            if (n == out.len) return out[0..n];
            out[n] = f;
            n += 1;
        }
    }
    return out[0..n];
}

test {
    _ = ts;
    _ = luals;
}

test "docs are the comments right above, past annotations" {
    const source =
        \\// Not this one
        \\
        \\// Hello
        \\// there
        \\[Sig("..")]
        \\struct A {}
        \\struct B { u32 b; }
    ;
    var it = docLines(source, std.mem.indexOf(u8, source, "struct A").?);
    try std.testing.expectEqualStrings("Hello", it.next().?);
    try std.testing.expectEqualStrings("there", it.next().?);
    try std.testing.expectEqual(null, it.next());
    try std.testing.expect(docLines(source, std.mem.indexOf(u8, source, "struct B").?).empty());
    try std.testing.expect(docLines(source, std.mem.indexOf(u8, source, "u32 b").?).empty());
}
