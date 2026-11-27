//! What the language writers share: how each names and declares things, casing, and walking a type for
//! the slices, optionals and function values a language gives types of their own.

const std = @import("std");
const salamander_schema = @import("salamander_schema");

const Schema = salamander_schema.Schema;
const Ref = Schema.Ref;
const Allocator = std.mem.Allocator;

// Declarations

/// How a language writes something. Writers declare things from these, so docs show what they write.
pub const Decl = struct {
    /// Where it's declared, like `NextAsync`.
    name: []const u8,
    /// From anywhere, like `Wraith.Memory.Scan.NextAsync`. Null when it's `name`.
    path: ?[]const u8 = null,
    /// A function's parameters, typed as the language writes them.
    params: []const Param = &.{},
    /// What a function gives, or a field's, static's or constant's type. Null for none.
    type: ?[]const u8 = null,
    /// The whole declaration, like `Task NextAsync(string value)`.
    text: ?[]const u8 = null,
};

pub const Param = struct {
    name: []const u8,
    type: []const u8,
    /// As written in the list, like `int count[4]`, where the two don't just go side by side.
    text: []const u8,
};

/// The parameters as written in a list, like `int a, float b`.
pub fn paramList(a: Allocator, params: []const Param) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (params, 0..) |p, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, p.text);
    }
    return out.items;
}

/// `d` with its text and types as docs show them, through `f` like `unrooted`.
pub fn tidied(a: Allocator, d: Decl, f: *const fn (Allocator, []const u8) error{OutOfMemory}![]const u8) error{OutOfMemory}!Decl {
    var out = d;
    if (d.path) |p| out.path = try f(a, p);
    if (d.type) |t| out.type = try f(a, t);
    if (d.text) |t| out.text = try f(a, t);
    const params = try a.alloc(Param, d.params.len);
    for (d.params, params) |p, *q| q.* = .{ .name = p.name, .type = try f(a, p.type), .text = try f(a, p.text) };
    out.params = params;
    return out;
}

/// How one language names and declares things, over its writer's `Names`. Null is something it doesn't have.
pub const Names = struct {
    /// Like `ts`, the key docs use.
    id: []const u8,
    /// Like `TypeScript`.
    label: []const u8,
    ptr: *const anyopaque,
    vt: *const VTable,

    pub const VTable = struct {
        typeName: *const fn (*const anyopaque, *const Schema.Type) anyerror!?Decl,
        traitName: *const fn (*const anyopaque, *const Schema.Trait) anyerror!?Decl,
        method: *const fn (*const anyopaque, *const Schema.Trait, *const Schema.Method) anyerror!?Decl,
        field: *const fn (*const anyopaque, *const Schema.Type, *const Schema.Field) anyerror!?Decl,
        /// An enum's value, an error or a bitfield's member, by name.
        member: *const fn (*const anyopaque, *const Schema.Type, []const u8) anyerror!?Decl,
        /// Existing code's function, a struct's when the type's set.
        function: *const fn (*const anyopaque, ?*const Schema.Type, *const Schema.Method) anyerror!?Decl,
        static: *const fn (*const anyopaque, ?*const Schema.Type, *const Schema.Static) anyerror!?Decl,
        constant: *const fn (*const anyopaque, *const Schema.Constant) anyerror!?Decl,
    };

    /// Over `names`, which has to outlive it. What its type doesn't have is null.
    pub fn of(comptime N: type, id: []const u8, label: []const u8, names: *const N) Names {
        const F = struct {
            fn cast(p: *const anyopaque) *const N {
                return @ptrCast(@alignCast(p));
            }
            fn call(p: *const anyopaque, comptime f: []const u8, args: anytype) anyerror!?Decl {
                if (!@hasDecl(N, f)) return null;
                return @call(.auto, @field(N, f), .{cast(p)} ++ args);
            }
            fn typeName(p: *const anyopaque, t: *const Schema.Type) anyerror!?Decl {
                return call(p, "typeName", .{t});
            }
            fn traitName(p: *const anyopaque, t: *const Schema.Trait) anyerror!?Decl {
                return call(p, "traitName", .{t});
            }
            fn method(p: *const anyopaque, t: *const Schema.Trait, m: *const Schema.Method) anyerror!?Decl {
                return call(p, "method", .{ t, m });
            }
            fn field(p: *const anyopaque, t: *const Schema.Type, f: *const Schema.Field) anyerror!?Decl {
                return call(p, "field", .{ t, f });
            }
            fn member(p: *const anyopaque, t: *const Schema.Type, n: []const u8) anyerror!?Decl {
                return call(p, "member", .{ t, n });
            }
            fn function(p: *const anyopaque, in: ?*const Schema.Type, m: *const Schema.Method) anyerror!?Decl {
                return call(p, "function", .{ in, m });
            }
            fn static(p: *const anyopaque, in: ?*const Schema.Type, v: *const Schema.Static) anyerror!?Decl {
                return call(p, "static", .{ in, v });
            }
            fn constant(p: *const anyopaque, c: *const Schema.Constant) anyerror!?Decl {
                return call(p, "constant", .{c});
            }
            const vt: VTable = .{
                .typeName = typeName,
                .traitName = traitName,
                .method = method,
                .field = field,
                .member = member,
                .function = function,
                .static = static,
                .constant = constant,
            };
        };
        return .{ .id = id, .label = label, .ptr = names, .vt = &F.vt };
    }
};

/// A writer that keeps nothing, for running a writer only for its names.
pub fn sink(a: Allocator) error{OutOfMemory}!*std.Io.Writer {
    const d = try a.create(std.Io.Writer.Discarding);
    d.* = .init(&.{});
    return &d.writer;
}

/// `text` without `global::` and leading `::`, which generated code has so names can't be shadowed. For docs.
pub fn unrooted(a: Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "global::")) {
            i += "global::".len;
            continue;
        }
        const after_name = i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_' or text[i - 1] == '>');
        if (!after_name and std.mem.startsWith(u8, text[i..], "::")) {
            i += 2;
            continue;
        }
        try out.append(a, text[i]);
        i += 1;
    }
    return out.items;
}

// Names

pub fn contains(list: []const []const u8, n: []const u8) bool {
    for (list) |o| if (std.mem.eql(u8, o, n)) return true;
    return false;
}

/// The last part of a name, like `spawn` for `Game.spawn`.
pub fn leafOf(n: []const u8) []const u8 {
    const end = Schema.namespaceEnd(n) orelse return n;
    return n[end + 1 ..];
}

/// Claims `n` in `taken`, or fails saying `lang` can't have two of it.
pub fn claim(a: Allocator, taken: *std.ArrayList([]const u8), diag: *Schema.Diagnostic, n: []const u8, lang: []const u8) error{ OutOfMemory, NameClash }!void {
    if (contains(taken.items, n)) {
        diag.print("{s}: {s} can't have two things called that", .{ n, lang });
        return error.NameClash;
    }
    try taken.append(a, n);
}

/// `setSpeed` and `HTTPServer` as `set_speed` and `http_server`.
pub fn snake(a: Allocator, n: []const u8) error{OutOfMemory}![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    for (n, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            const prev_lower = i > 0 and (std.ascii.isLower(n[i - 1]) or std.ascii.isDigit(n[i - 1]));
            const next_lower = i > 0 and std.ascii.isUpper(n[i - 1]) and i + 1 < n.len and std.ascii.isLower(n[i + 1]);
            if ((prev_lower or next_lower) and o.items.len > 0 and o.items[o.items.len - 1] != '_') try o.append(a, '_');
            try o.append(a, std.ascii.toLower(c));
        } else try o.append(a, c);
    }
    return o.items;
}

/// `setSpeed` as `SET_SPEED`.
pub fn screaming(a: Allocator, n: []const u8) error{OutOfMemory}![]const u8 {
    const o = try a.dupe(u8, try snake(a, n));
    for (o) |*c| c.* = std.ascii.toUpper(c.*);
    return o;
}

/// `List_Scene_NodePtr` and `onLand` as `ListSceneNodePtr` and `OnLand`.
pub fn camel(a: Allocator, n: []const u8) error{OutOfMemory}![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    var up = true;
    for (n) |c| {
        if (c == '_') {
            up = true;
            continue;
        }
        try o.append(a, if (up) std.ascii.toUpper(c) else c);
        up = false;
    }
    if (o.items.len == 0) return n;
    return o.items;
}

// Types

pub fn isVoid(r: Ref) bool {
    return r == .prim and r.prim == .void;
}

/// A result's value, null when there's none.
pub fn resultOk(r: Ref) ?Ref {
    return switch (r) {
        .result => |res| if (isVoid(res.ok.*)) null else res.ok.*,
        else => null,
    };
}

/// `salamander.h`'s macros for a calling convention, which C and C++ share.
pub fn cConv(c: Schema.Conv) []const u8 {
    return switch (c) {
        .c => "",
        .cdecl => "SAL_CDECL ",
        .stdcall => "SAL_STDCALL ",
        .thiscall => "SAL_THISCALL ",
        .fastcall => "SAL_FASTCALL ",
        .winapi => "SAL_WINAPI ",
    };
}

/// Something a language makes a type of its own for: a function value, or a slice, optional or array.
pub const Extra = struct {
    name: []const u8,
    ref: Ref,
    /// A function value's, so the same signature in two places is one type.
    hash: u64 = 0,
    /// A named function type from an aliased file, which is used from there.
    base: bool = false,
};

/// Each distinct function value, named for where it's first used, like `Freecam_onLand_listener`.
pub const Fns = struct {
    list: std.ArrayList(Extra) = .empty,

    /// `r` is a `.func`. Only the first with its signature is kept.
    pub fn add(f: *Fns, a: Allocator, r: Ref, name: []const u8) error{OutOfMemory}!void {
        const h = Schema.signatureHash(r.func.*);
        for (f.list.items) |e| if (e.hash == h and e.ref == .func) return;
        try f.list.append(a, .{ .name = name, .ref = r, .hash = h });
    }

    /// The one with `sig`, which `add` has seen.
    pub fn of(f: *const Fns, sig: Schema.Signature) Extra {
        const h = Schema.signatureHash(sig);
        for (f.list.items) |e| if (e.hash == h and e.ref == .func) return e;
        unreachable;
    }

    /// A named function type's.
    pub fn named(f: *const Fns, n: []const u8) Extra {
        for (f.list.items) |e| if (e.ref == .named and std.mem.eql(u8, e.ref.named, n)) return e;
        unreachable;
    }
};

pub fn sigOf(s: Schema, e: Extra) Schema.Signature {
    return switch (e.ref) {
        .func => |sig| sig.*,
        .named => |n| s.findType(n).?.kind.func,
        else => unreachable,
    };
}

/// Adds `e` unless one with its name is there.
pub fn addUnique(a: Allocator, list: *std.ArrayList(Extra), e: Extra) error{OutOfMemory}!void {
    for (list.items) |o| if (std.mem.eql(u8, o.name, e.name)) return;
    try list.append(a, e);
}

/// Walks `r` inside out, calling what `v` has of `onSlice(child, r)`, `onOptional(child, r)` for ones
/// without their own null, `onArray(r)` and `onFunc(r, site)`. A function's parameters are at `site_param`.
pub fn collect(v: anytype, a: Allocator, s: Schema, r: Ref, site: []const u8) !void {
    const V = @TypeOf(v.*);
    switch (r) {
        .prim, .named => {},
        .pointer => |c| try collect(v, a, s, c.*, site),
        .array => |arr| {
            try collect(v, a, s, arr.child.*, site);
            if (@hasDecl(V, "onArray")) try v.onArray(r);
        },
        .slice => |c| {
            try collect(v, a, s, c.*, site);
            if (@hasDecl(V, "onSlice")) try v.onSlice(c.*, r);
        },
        .optional => |c| {
            try collect(v, a, s, c.*, site);
            // Pointers and objects have their own null
            if (@hasDecl(V, "onOptional") and c.* != .pointer and !s.isObject(c.*)) try v.onOptional(c.*, r);
        },
        .result => |res| try collect(v, a, s, res.ok.*, site),
        .func => |sig| {
            for (sig.params) |p| try collect(v, a, s, p.type, try std.fmt.allocPrint(a, "{s}_{s}", .{ site, p.name }));
            try collect(v, a, s, sig.ret, site);
            if (@hasDecl(V, "onFunc")) try v.onFunc(r, site);
        },
    }
}

// Testing

/// A schema with one of each thing `Names` gives, for each writer's test of it.
pub const names_fixture =
    \\namespace G;
    \\
    \\const u32 max_players = 4;
    \\
    \\trait Counter {
    \\    u32 count(string who);
    \\}
    \\
    \\struct Player {
    \\    u32 hp;
    \\    [Sig("E8")] bool heal(u32 amount);
    \\    [Sig("48")] static Player* instance;
    \\}
;

/// What `names_fixture`'s things should be declared as, by their `text`. Null is no text.
pub const Want = struct {
    method: ?[]const u8,
    field: ?[]const u8,
    function: ?[]const u8,
    static: ?[]const u8,
    constant: ?[]const u8,
};

/// Parses `names_fixture`, makes `N` over it with `make`, and checks each declaration's text.
pub fn expectNames(comptime N: type, comptime make: fn (Allocator, Schema) anyerror!N, want: Want) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try salamander_schema.parse(a, names_fixture, .{ .pointer_size = 8, .any_namespace = true, .uses = &.{"game"} }, null);
    const s = parsed.schema;
    const n = try make(a, s);
    const player = s.findType("G.Player").?;
    const counter = s.findTrait("G.Counter").?;
    try expectText(want.method, try n.method(counter, &counter.methods[0]));
    try expectText(want.field, try n.field(player, &player.kind.@"struct".fields[0]));
    try expectText(want.function, try n.function(player, &player.kind.@"struct".methods[0]));
    try expectText(want.static, try n.static(player, &player.kind.@"struct".statics[0]));
    if (@hasDecl(N, "constant")) try expectText(want.constant, try n.constant(s.findConstant("G.max_players").?));
}

fn expectText(want: ?[]const u8, got: ?Decl) !void {
    const text = if (got) |d| d.text else null;
    if (want == null and text == null) return;
    if (want == null or text == null) {
        std.debug.print("want {?s}, got {?s}\n", .{ want, text });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqualStrings(want.?, text.?);
}

test "casing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("http_server", try snake(a, "HTTPServer"));
    try std.testing.expectEqualStrings("SET_SPEED", try screaming(a, "setSpeed"));
    try std.testing.expectEqualStrings("OnLand", try camel(a, "onLand"));
    try std.testing.expectEqualStrings("Task Run(int a)", try unrooted(a, "global::Task Run(int a)"));
    try std.testing.expectEqualStrings("sal::Future<a::B>", try unrooted(a, "::sal::Future<::a::B>"));
}
