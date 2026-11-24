//! ReClass-style edits to struct fields in `.sal` text, keeping its formatting.

const std = @import("std");

const Schema = @import("Schema.zig");
const parser = @import("parse.zig");

pub const Change = union(enum) {
    /// A new field. Unions ignore `offset`.
    define: Define,
    retype: Retype,
    rename: Rename,
    remove: Remove,
    size: Size,
    add_struct: AddStruct,

    pub const Define = struct { owner: []const u8, offset: usize, type: []const u8, name: []const u8 };
    pub const Retype = struct { owner: []const u8, field: []const u8, type: []const u8 };
    pub const Rename = struct { owner: []const u8, field: []const u8, name: []const u8 };
    pub const Remove = struct { owner: []const u8, field: []const u8 };
    pub const Size = struct { owner: []const u8, size: usize };
    pub const AddStruct = struct { name: []const u8, size: ?usize = null };
};

pub const Error = error{
    OutOfMemory,
    InvalidSchema,
    NoSuchType,
    NoSuchField,
    NotAStruct,
    /// Can't be changed in place, like a field's own bitfield type.
    NotInSource,
};

pub const Options = struct {
    parse: parser.Options = .{},
    diagnostic: ?*Schema.Diagnostic = null,
};

/// Applies `changes` in order, checking the text after each. Caller owns the result.
pub fn apply(gpa: std.mem.Allocator, source: []const u8, changes: []const Change, options: Options) Error![:0]u8 {
    var text = try gpa.dupeSentinel(u8, source, 0);
    errdefer gpa.free(text);
    for (changes) |change| {
        var parsed = try parser.parse(gpa, text, options.parse, options.diagnostic);
        defer parsed.deinit();
        const next = try one(gpa, &parsed, change);
        gpa.free(text);
        text = next;
    }
    var parsed = try parser.parse(gpa, text, options.parse, options.diagnostic);
    parsed.deinit();
    return text;
}

const Patch = struct {
    at: usize,
    cut: usize = 0,
    put: []const u8 = "",
    /// Goes after other text at the same spot.
    after: bool = false,
};

const Patches = struct {
    list: [4]Patch = undefined,
    len: usize = 0,

    fn add(self: *Patches, p: Patch) void {
        self.list[self.len] = p;
        self.len += 1;
    }
};

fn one(gpa: std.mem.Allocator, parsed: *const parser.Parsed, change: Change) Error![:0]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = parsed.source;
    const schema = parsed.schema;
    var patches: Patches = .{};

    switch (change) {
        .define => |d| {
            const t, const s = try structOf(schema, d.owner);
            const is_union = t.kind == .@"union";
            const stmt = if (is_union)
                try std.fmt.allocPrint(a, "{s} {s};", .{ d.type, d.name })
            else
                try std.fmt.allocPrint(a, "[0x{X}] {s} {s};", .{ d.offset, d.type, d.name });
            const before: ?usize = if (is_union) null else for (s.fields, 0..) |f, i| {
                if (f.offset > d.offset) break i;
            } else null;
            if (before) |i| {
                const f = s.fields[i];
                const start = statementStart(text, f);
                const ls = lineStart(text, start);
                if (blank(text[ls..start])) {
                    patches.add(.{ .at = ls, .put = try std.mem.concat(a, u8, &.{ text[ls..start], stmt, "\n" }) });
                } else {
                    patches.add(.{ .at = start, .put = try std.mem.concat(a, u8, &.{ stmt, " " }) });
                }
                try pin(a, text, f, &patches);
            } else if (s.fields.len > 0) {
                const last = s.fields[s.fields.len - 1];
                const start = statementStart(text, last);
                const end = try statementEnd(text, last);
                const ls = lineStart(text, start);
                if (blank(text[ls..start])) {
                    // After any comment that ends the line
                    var le = std.mem.indexOfScalarPos(u8, text, end, '\n') orelse text.len;
                    if (le > end and text[le - 1] == '\r') le -= 1;
                    const rest = std.mem.trim(u8, text[end..le], " \t");
                    const after = if (rest.len == 0 or std.mem.startsWith(u8, rest, "//")) le else end;
                    patches.add(.{ .at = after, .put = try std.mem.concat(a, u8, &.{ "\n", text[ls..start], stmt }) });
                } else {
                    patches.add(.{ .at = end, .put = try std.mem.concat(a, u8, &.{ " ", stmt }) });
                }
            } else {
                const open = try bodyOpen(text, t);
                const close = try matching(text, open, '{', '}');
                const ls = lineStart(text, t.at);
                const outer = leading(text[ls..]);
                if (blank(text[open + 1 .. close])) {
                    patches.add(.{ .at = open + 1, .cut = close - open - 1, .put = try std.mem.concat(a, u8, &.{ "\n", outer, "    ", stmt, "\n", outer }) });
                } else {
                    patches.add(.{ .at = open + 1, .put = try std.mem.concat(a, u8, &.{ "\n", outer, "    ", stmt }) });
                }
            }
        },
        .retype => |r| {
            const t, const s = try structOf(schema, r.owner);
            const i = try fieldIndex(s, r.field);
            const f = s.fields[i];
            if (isOwnBits(schema, f)) return error.NotInSource;
            patches.add(.{ .at = f.at, .cut = skipBack(text, try at(text, f.name)) - f.at, .put = r.type });
            if (t.kind == .@"struct" and i + 1 < s.fields.len) try pin(a, text, s.fields[i + 1], &patches);
        },
        .rename => |r| {
            _, const s = try structOf(schema, r.owner);
            const f = s.fields[try fieldIndex(s, r.field)];
            patches.add(.{ .at = try at(text, f.name), .cut = f.name.len, .put = r.name });
        },
        .remove => |r| {
            const t, const s = try structOf(schema, r.owner);
            const i = try fieldIndex(s, r.field);
            const f = s.fields[i];
            var start = statementStart(text, f);
            var end = try statementEnd(text, f);
            // A field alone on its line takes the line, comment and all
            const ls = lineStart(text, start);
            const le = std.mem.indexOfScalarPos(u8, text, end, '\n') orelse text.len;
            const rest = std.mem.trim(u8, text[end..le], " \t\r");
            if (blank(text[ls..start]) and (rest.len == 0 or std.mem.startsWith(u8, rest, "//"))) {
                start = ls;
                end = @min(le + 1, text.len);
            }
            patches.add(.{ .at = start, .cut = end - start });
            if (t.kind == .@"struct" and i + 1 < s.fields.len) try pin(a, text, s.fields[i + 1], &patches);
        },
        .size => |z| {
            const t, _ = try structOf(schema, z.owner);
            // Its `struct` or `union` keyword
            const kw = t.at;
            const attrs = attrsBefore(text, kw);
            const number = try std.fmt.allocPrint(a, "0x{X}", .{z.size});
            if (attrs < kw) {
                const written = text[attrs..kw];
                if (std.mem.indexOf(u8, written, "Size(")) |i| {
                    const open = attrs + i + "Size(".len;
                    const close = std.mem.indexOfScalarPos(u8, text, open, ')') orelse return error.NotInSource;
                    patches.add(.{ .at = open, .cut = close - open, .put = number });
                } else {
                    patches.add(.{ .at = attrs + 1, .put = try std.fmt.allocPrint(a, "Size({s}), ", .{number}) });
                }
            } else {
                const ls = lineStart(text, kw);
                if (blank(text[ls..kw])) {
                    patches.add(.{ .at = ls, .put = try std.fmt.allocPrint(a, "{s}[Size({s})]\n", .{ text[ls..kw], number }) });
                } else {
                    patches.add(.{ .at = kw, .put = try std.fmt.allocPrint(a, "[Size({s})] ", .{number}) });
                }
            }
        },
        .add_struct => |n| {
            const gap = if (text.len == 0) "" else if (text[text.len - 1] == '\n') "\n" else "\n\n";
            const size = if (n.size) |z| try std.fmt.allocPrint(a, "[Size(0x{X})]\n", .{z}) else "";
            patches.add(.{ .at = text.len, .put = try std.fmt.allocPrint(a, "{s}{s}struct {s} {{\n}}\n", .{ gap, size, n.name }) });
        },
    }
    return patched(gpa, text, patches.list[0..patches.len]);
}

/// Patches must not overlap.
fn patched(gpa: std.mem.Allocator, text: []const u8, list: []Patch) error{OutOfMemory}![:0]u8 {
    std.mem.sort(Patch, list, {}, struct {
        fn later(_: void, x: Patch, y: Patch) bool {
            if (x.at != y.at) return x.at > y.at;
            return x.after and !y.after;
        }
    }.later);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, text);
    for (list) |p| try out.replaceRange(gpa, p.at, p.cut, p.put);
    return out.toOwnedSliceSentinel(gpa, 0);
}

/// Writes `f`'s offset in if it follows the field before it.
fn pin(a: std.mem.Allocator, text: []const u8, f: Schema.Field, patches: *Patches) Error!void {
    if (hasOffset(text[attrsBefore(text, f.at)..f.at])) return;
    patches.add(.{ .at = f.at, .put = try std.fmt.allocPrint(a, "[0x{X}] ", .{f.offset}), .after = true });
}

/// Whether annotations like `[0x10]` or `[Offset(0x10), game.Note]` give an offset.
fn hasOffset(attrs: []const u8) bool {
    if (std.mem.indexOf(u8, attrs, "Offset(") != null) return true;
    for (attrs, 0..) |c, i| {
        if (c != '[' and c != ',') continue;
        const next = skipForward(attrs, i + 1);
        if (next < attrs.len and std.ascii.isDigit(attrs[next])) return true;
    }
    return false;
}

fn structOf(schema: Schema, name: []const u8) Error!struct { *const Schema.Type, Schema.Struct } {
    const t = schema.findType(name) orelse return error.NoSuchType;
    return switch (t.kind) {
        .@"struct", .@"union" => |s| .{ t, s },
        else => error.NotAStruct,
    };
}

fn fieldIndex(s: Schema.Struct, name: []const u8) Error!usize {
    for (s.fields, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return i;
    return error.NoSuchField;
}

fn at(text: []const u8, slice: []const u8) Error!usize {
    const start = @intFromPtr(text.ptr);
    const p = @intFromPtr(slice.ptr);
    if (p < start or p + slice.len > start + text.len) return error.NotInSource;
    return p - start;
}

/// `u8 flags { .. }`, whose type is its own bitfield.
fn isOwnBits(schema: Schema, f: Schema.Field) bool {
    const t = schema.findType(if (f.type == .named) f.type.named else return false) orelse return false;
    return t.nested;
}

fn statementStart(text: []const u8, f: Schema.Field) usize {
    return attrsBefore(text, f.at);
}

/// Just past `f`'s `;`, or its own bits' `}`.
fn statementEnd(text: []const u8, f: Schema.Field) Error!usize {
    const name = try at(text, f.name);
    var i = skipForward(text, name + f.name.len);
    if (i < text.len and text[i] == '{') {
        i = skipForward(text, try matching(text, i, '{', '}') + 1);
        return if (i < text.len and text[i] == ';') i + 1 else i;
    }
    if (i < text.len and text[i] == ';') return i + 1;
    return error.NotInSource;
}

fn bodyOpen(text: []const u8, t: *const Schema.Type) Error!usize {
    if (t.at >= text.len) return error.NotInSource;
    return std.mem.indexOfScalarPos(u8, text, t.at, '{') orelse error.NotInSource;
}

/// Matching close bracket, skipping strings.
fn matching(text: []const u8, open: usize, comptime l: u8, comptime r: u8) Error!usize {
    var depth: usize = 0;
    var in_string = false;
    for (text[open..], open..) |c, i| {
        if (c == '"') in_string = !in_string;
        if (in_string) continue;
        if (c == l) depth += 1;
        if (c == r) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return error.NotInSource;
}

/// Start of the `[...]` attributes before `i`, or `i`.
fn attrsBefore(text: []const u8, i: usize) usize {
    var start = i;
    var end = skipBack(text, i);
    while (end > 0 and text[end - 1] == ']') {
        var depth: usize = 0;
        var in_string = false;
        var j = end;
        const open = while (j > 0) {
            j -= 1;
            const c = text[j];
            if (c == '"') in_string = !in_string;
            if (in_string) continue;
            if (c == ']') depth += 1;
            if (c == '[') {
                depth -= 1;
                if (depth == 0) break j;
            }
        } else return start;
        start = open;
        end = skipBack(text, open);
    }
    return start;
}

fn skipBack(text: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and std.ascii.isWhitespace(text[j - 1])) j -= 1;
    return j;
}

fn skipForward(text: []const u8, i: usize) usize {
    var j = i;
    while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
    return j;
}

fn lineStart(text: []const u8, i: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, text[0..i], '\n')) |n| n + 1 else 0;
}

fn leading(line: []const u8) []const u8 {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
    return line[0..n];
}

fn blank(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isWhitespace(c)) return false;
    return true;
}

fn identChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const testing = std.testing;

fn expectApplied(source: []const u8, changes: []const Change, expected: []const u8) !void {
    var diag: Schema.Diagnostic = .{};
    const text = apply(testing.allocator, source, changes, .{ .parse = .{ .any_namespace = true }, .diagnostic = &diag }) catch |err| {
        std.debug.print("{t}: {s}\n", .{ err, diag.message() });
        return err;
    };
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

fn offsetOf(source: [:0]const u8, owner: []const u8, name: []const u8) !usize {
    var parsed = try parser.parse(testing.allocator, source, .{}, null);
    defer parsed.deinit();
    const t = parsed.schema.findType(owner).?;
    return parsed.schema.findField(t, name).?.offset;
}

test "define in a gap" {
    const source =
        \\// Players
        \\struct Player {
        \\    f32 health;
        \\    [0x10] u32 id;
        \\    u32 next; // right after id
        \\}
        \\
    ;
    try expectApplied(source, &.{.{ .define = .{ .owner = "Player", .offset = 0x8, .type = "f32", .name = "speed" } }},
        \\// Players
        \\struct Player {
        \\    f32 health;
        \\    [0x8] f32 speed;
        \\    [0x10] u32 id;
        \\    u32 next; // right after id
        \\}
        \\
    );
    // Past the end it goes last
    try expectApplied(source, &.{.{ .define = .{ .owner = "Player", .offset = 0x40, .type = "Player*", .name = "target" } }},
        \\// Players
        \\struct Player {
        \\    f32 health;
        \\    [0x10] u32 id;
        \\    u32 next; // right after id
        \\    [0x40] Player* target;
        \\}
        \\
    );
    try testing.expectError(error.InvalidSchema, apply(testing.allocator, source, &.{.{ .define = .{ .owner = "Player", .offset = 0x14, .type = "u8", .name = "x" } }}, .{}));
    var diag: Schema.Diagnostic = .{};
    try testing.expectError(error.InvalidSchema, apply(testing.allocator, source, &.{.{ .define = .{ .owner = "Player", .offset = 0x2, .type = "u32", .name = "bad" } }}, .{ .diagnostic = &diag }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "overlap") != null);
}

test "define in empty struct and union" {
    try expectApplied("struct A {}\n", &.{.{ .define = .{ .owner = "A", .offset = 0x4, .type = "i32", .name = "n" } }}, "struct A {\n    [0x4] i32 n;\n}\n");
    try expectApplied("struct V { f32 x; f32 y; }\n", &.{.{ .define = .{ .owner = "V", .offset = 0x8, .type = "f32", .name = "z" } }}, "struct V { f32 x; f32 y; [0x8] f32 z; }\n");
    try expectApplied("union U {\n    i32 int;\n}\n", &.{.{ .define = .{ .owner = "U", .offset = 0, .type = "f32", .name = "float" } }}, "union U {\n    i32 int;\n    f32 float;\n}\n");
}

test "retype, rename and remove" {
    const source =
        \\struct P {
        \\    u8 a;
        \\    u8 b;
        \\    [0x8] u32 c;
        \\}
        \\
    ;
    try expectApplied(source, &.{.{ .retype = .{ .owner = "P", .field = "a", .type = "i8" } }},
        \\struct P {
        \\    i8 a;
        \\    [0x1] u8 b;
        \\    [0x8] u32 c;
        \\}
        \\
    );
    try testing.expectError(error.InvalidSchema, apply(testing.allocator, source, &.{.{ .retype = .{ .owner = "P", .field = "a", .type = "u16" } }}, .{}));
    try expectApplied(source, &.{.{ .rename = .{ .owner = "P", .field = "b", .name = "flags" } }},
        \\struct P {
        \\    u8 a;
        \\    u8 flags;
        \\    [0x8] u32 c;
        \\}
        \\
    );
    try expectApplied(source, &.{.{ .remove = .{ .owner = "P", .field = "a" } }},
        \\struct P {
        \\    [0x1] u8 b;
        \\    [0x8] u32 c;
        \\}
        \\
    );
    try expectApplied("struct Q {\n    u8 a; // gone too\n    u8 b;\n}\n", &.{.{ .remove = .{ .owner = "Q", .field = "a" } }}, "struct Q {\n    [0x1] u8 b;\n}\n");
    const removed = try apply(testing.allocator, source, &.{.{ .remove = .{ .owner = "P", .field = "a" } }}, .{});
    defer testing.allocator.free(removed);
    try testing.expectEqual(0x1, try offsetOf(removed, "P", "b"));
    try testing.expectError(error.NoSuchField, apply(testing.allocator, source, &.{.{ .remove = .{ .owner = "P", .field = "nope" } }}, .{}));
}

test "own bits and attributes go whole" {
    try expectApplied("struct S {\n    [0x4] u8 flags { bool a; [Bit(3)] bool b; }\n    u32 n;\n}\n", &.{.{ .remove = .{ .owner = "S", .field = "flags" } }}, "struct S {\n    [0x8] u32 n;\n}\n");
    try testing.expectError(error.NotInSource, apply(testing.allocator, "struct S { u8 flags { bool a; } }", &.{.{ .retype = .{ .owner = "S", .field = "flags", .type = "u16" } }}, .{}));
}

test "sizes and new structs" {
    try expectApplied("// x\nstruct A { u8 a; }\n", &.{.{ .size = .{ .owner = "A", .size = 0x20 } }}, "// x\n[Size(0x20)]\nstruct A { u8 a; }\n");
    try expectApplied("[Size(0x10)]\nstruct A { u8 a; }\n", &.{.{ .size = .{ .owner = "A", .size = 0x40 } }}, "[Size(0x40)]\nstruct A { u8 a; }\n");
    try expectApplied("[game.VirtualTable(\"48 8D 0D ?? ?? ?? ??\", Rip)] struct A { u8 a; }\n", &.{.{ .size = .{ .owner = "A", .size = 8 } }}, "[Size(0x8), game.VirtualTable(\"48 8D 0D ?? ?? ?? ??\", Rip)] struct A { u8 a; }\n");
    try expectApplied("struct A {\n    [0x8] u8 b;\n}", &.{
        .{ .add_struct = .{ .name = "B", .size = 0x10 } },
        .{ .define = .{ .owner = "A", .offset = 0, .type = "B*", .name = "b_ptr" } },
    },
        \\struct A {
        \\    [0x0] B* b_ptr;
        \\    [0x8] u8 b;
        \\}
        \\
        \\[Size(0x10)]
        \\struct B {
        \\}
        \\
    );
}

test "types and annotations around fields" {
    try expectApplied("struct P {\n    [game.Note] u8[4] raw;\n    [game.Note] u32 next;\n}\n", &.{.{ .retype = .{ .owner = "P", .field = "raw", .type = "u16[2]" } }},
        \\struct P {
        \\    [game.Note] u16[2] raw;
        \\    [game.Note] [0x4] u32 next;
        \\}
        \\
    );
    try expectApplied("struct I {}\nstruct P { [0x8] I* one; }\n", &.{.{ .retype = .{ .owner = "P", .field = "one", .type = "?I*" } }}, "struct I {}\nstruct P { [0x8] ?I* one; }\n");
}
