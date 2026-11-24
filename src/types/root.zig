//! Editor typings for `.sal` schemas, TypeScript and LuaLS, for scripts on the JS and Lua hosts.
//! Docs come from the `//` lines above each thing in the source.

const std = @import("std");
const Schema = @import("salamander_schema").Schema;

pub const ts = @import("ts.zig");
pub const luals = @import("luals.zig");

/// What a module gives scripts.
pub const Api = struct {
    /// What scripts import or require, like `"game"`.
    module: []const u8,
    /// A trait whose methods each give one of the module's exports, like an embedder's areas.
    /// Without it the module only has types.
    root: ?[]const u8 = null,
    /// The exports as globals too, for consoles.
    globals: bool = false,
};

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

/// A type's name as one identifier. Nested ones, like a field's bitfield, are `Struct.field`.
pub fn writeTypeName(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    return Schema.writeFlatName(w, name);
}

/// What the `schema` module has in a namespace, like `Node` in `Scene`: structs, enums, functions
/// and statics. Generics' instances aren't, since their names aren't names in scripts.
pub const Member = struct {
    /// Its whole name, like `Scene.Node`.
    name: []const u8,
    what: What,

    pub const What = union(enum) {
        type: *const Schema.Type,
        function: *const Schema.Method,
        static: *const Schema.Static,
    };

    pub fn parent(m: Member) []const u8 {
        return m.name[0..Schema.namespaceEnd(m.name).?];
    }

    pub fn leaf(m: Member) []const u8 {
        return m.name[Schema.namespaceEnd(m.name).? + 1 ..];
    }
};

pub const Members = struct {
    s: Schema,
    i: usize = 0,

    pub fn next(it: *Members) ?Member {
        const s = it.s;
        while (it.i < s.types.len + s.functions.len + s.statics.len) {
            const i = it.i;
            it.i += 1;
            const m: Member = if (i < s.types.len) blk: {
                const t = &s.types[i];
                if (t.nested or (t.kind != .@"struct" and t.kind != .@"enum")) continue;
                break :blk .{ .name = t.name, .what = .{ .type = t } };
            } else if (i < s.types.len + s.functions.len) blk: {
                const f = &s.functions[i - s.types.len];
                break :blk .{ .name = f.name, .what = .{ .function = f } };
            } else blk: {
                const v = &s.statics[i - s.types.len - s.functions.len];
                break :blk .{ .name = v.name, .what = .{ .static = v } };
            };
            if (Schema.namespaceEnd(m.name) == null or std.mem.indexOfScalar(u8, m.name, '<') != null) continue;
            return m;
        }
        return null;
    }
};

/// Whether `path` is a struct or union, whose class has what's in a namespace of its name.
pub fn isRecordName(s: Schema, path: []const u8) bool {
    const t = s.findType(path) orelse return false;
    return t.kind == .@"struct" or t.kind == .@"union";
}

/// Namespaces that aren't structs, like `Scene` and `Scene.Tools`, each once, outer ones first.
pub const Namespaces = struct {
    members: Members,
    current: ?Member = null,
    /// How much of `current`'s namespace has been given.
    done: usize = 0,

    pub fn init(s: Schema) Namespaces {
        return .{ .members = .{ .s = s } };
    }

    pub fn next(it: *Namespaces) ?[]const u8 {
        const s = it.members.s;
        while (true) {
            const m = it.current orelse {
                it.current = it.members.next() orelse return null;
                it.done = 0;
                continue;
            };
            const path = m.parent();
            if (it.done >= path.len) {
                it.current = null;
                continue;
            }
            const end = if (std.mem.indexOfScalarPos(u8, path, it.done + 1, '.')) |d| d else path.len;
            it.done = end;
            const ns = path[0..end];
            // What's in a struct is on its class
            if (isRecordName(s, ns)) {
                it.current = null;
                continue;
            }
            if (it.seenBefore(ns)) continue;
            return ns;
        }
    }

    fn seenBefore(it: *const Namespaces, ns: []const u8) bool {
        var earlier: Members = .{ .s = it.members.s };
        while (earlier.next()) |o| {
            if (earlier.i >= it.members.i) return false;
            const p = o.parent();
            if (std.mem.eql(u8, p, ns) or (std.mem.startsWith(u8, p, ns) and p[ns.len] == '.')) return true;
        }
        return false;
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
