//! The `.sal` format. Structs are memory, traits are behaviour, impls say where a struct does a trait.

pub const Schema = @import("Schema.zig");
pub const Diagnostic = Schema.Diagnostic;
pub const plan = @import("plan.zig");

const parser = @import("parse.zig");
pub const Options = parser.Options;
pub const Namespace = parser.Namespace;
pub const Parsed = parser.Parsed;
pub const parse = parser.parse;
pub const parseType = parser.parseType;
pub const edit = @import("edit.zig");

test {
    _ = @import("tests.zig");
    _ = edit;
}

/// What `parseSignature` calls the function type it parsed.
pub const signature_name = "__signature";

pub const SignatureError = parser.Error || error{NotASignature};

/// A function type written on its own, like `[Thiscall] fn i32 (Actor* self, f32 amount)`, with
/// `base`'s types in scope. It's parsed as `signature_name` and problems say they're in `signature`.
/// Can also name a function `base` declares, like `spawn` or `Player.heal`, whose methods take `this` first.
pub fn parseSignature(gpa: @import("std").mem.Allocator, base: []const u8, text: []const u8, options: Options, diagnostic: ?*Diagnostic) SignatureError!Parsed {
    const std = @import("std");
    const keyword = findFn(text) orelse return declared(gpa, base, std.mem.trim(u8, text, " \t\r\n;"), options, diagnostic);
    const paren = std.mem.indexOfScalarPos(u8, text, keyword, '(') orelse return error.NotASignature;
    const trimmed = std.mem.trimEnd(u8, text, " \t\r\n;");
    if (paren >= trimmed.len) return error.NotASignature;
    const head = if (std.mem.startsWith(u8, base, Schema.bundle_marker)) "" else Schema.bundle_marker ++ "base\";\n";
    const source = try std.mem.concat(gpa, u8, &.{ head, base, "\n", Schema.bundle_marker, "signature\";\n", trimmed[0..paren], " " ++ signature_name, trimmed[paren..], ";\n" });
    defer gpa.free(source);
    return parse(gpa, source, options, diagnostic);
}

/// `base` with a declared function's type added as `signature_name`.
fn declared(gpa: @import("std").mem.Allocator, base: []const u8, name: []const u8, options: Options, diagnostic: ?*Diagnostic) SignatureError!Parsed {
    const std = @import("std");
    if (name.len == 0) return error.NotASignature;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') return error.NotASignature;
    var parsed = try parse(gpa, base, options, diagnostic);
    errdefer parsed.deinit();
    const s = &parsed.schema;
    const found = s.findFunction(name) orelse {
        if (diagnostic) |d| d.print("there's no function or method named {s}", .{name});
        return error.InvalidSchema;
    };
    const arena = parsed.arena.allocator();
    const types = try arena.alloc(Schema.Type, s.types.len + 1);
    @memcpy(types[0..s.types.len], s.types);
    types[s.types.len] = .{ .name = signature_name, .kind = .{ .func = try Schema.callSignature(found, arena) } };
    s.types = types;
    return parsed;
}

/// Where the `fn` keyword starts, after any annotations.
fn findFn(text: []const u8) ?usize {
    const std = @import("std");
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "fn")) |at| : (i = at + 2) {
        const before_ok = at == 0 or (!std.ascii.isAlphanumeric(text[at - 1]) and text[at - 1] != '_');
        const after_ok = at + 2 < text.len and !std.ascii.isAlphanumeric(text[at + 2]) and text[at + 2] != '_';
        if (before_ok and after_ok) return at;
    }
    return null;
}

/// One of many `.sal` files that make a schema together.
pub const File = struct {
    name: []const u8,
    text: []const u8,
};

pub const BundleError = error{ OutOfMemory, InvalidFileName };

/// Many files as one schema's text. Each sees every other's types and traits but keeps its own `use`s,
/// and problems say which file they're in. Caller frees it.
pub fn bundle(gpa: @import("std").mem.Allocator, files: []const File) BundleError![]u8 {
    var out: @import("std").ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (files) |f| {
        if (!validName(f.name)) return error.InvalidFileName;
        try out.print(gpa, Schema.bundle_marker ++ "{s}\";\n{s}\n", .{ f.name, f.text });
    }
    return out.toOwnedSlice(gpa);
}

fn validName(name: []const u8) bool {
    for (name) |c| if (c == '"' or c == '\n' or c == '\r') return false;
    return name.len > 0;
}
