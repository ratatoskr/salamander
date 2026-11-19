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
    for (name) |ch| try w.writeByte(if (ch == '.') '_' else ch);
}

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
