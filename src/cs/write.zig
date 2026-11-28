//! A schema as C# over `Salamander.cs`, in two layers like the Zig one. Needs `AllowUnsafeBlocks`.
//! `<Namespace>.Raw` is exactly what crosses, laid out like Zig and C. Over it is plain C# with classes, spans, tasks and delegates.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const lang = @import("salamander_lang");

const Schema = salamander_schema.Schema;
const plan = salamander_schema.plan;
const Ref = Schema.Ref;

pub const Error = std.Io.Writer.Error || error{ OutOfMemory, NameClash };

pub const Options = struct {
    /// Where it came from, for the header.
    label: []const u8 = "schema.sal",
    /// Where what has no schema namespace goes, with `Raw`, the converters and `class`. None if empty.
    namespace: []const u8 = "",
    /// The static class with the schema's constants and `PointerSize`.
    class: []const u8 = "Schema",
    /// Writing the runtime's own `core.sal`, into the `Salamander` namespace with `Salamander.cs`.
    core: bool = false,
    /// The bundle's text, so `aliases` can tell which file each thing came from.
    source: []const u8 = "",
    aliases: []const Alias = &.{},
    /// Traits the host gives one of, by full name. Each gets an `Instance` reading `Salamander.Singletons`.
    singletons: []const []const u8 = &.{},
};

/// Files whose names start with `prefix` were written elsewhere, home namespace `namespace`, and are used from there.
pub const Alias = struct {
    prefix: []const u8,
    namespace: []const u8,
};

pub fn write(gpa: std.mem.Allocator, s: Schema, w: *std.Io.Writer, options: Options, diagnostic: ?*Schema.Diagnostic) Error!void {
    var scratch: Schema.Diagnostic = .{};
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var g: Gen = .init(s, w, arena.allocator(), options, diagnostic orelse &scratch);
    try g.file();
}

const keywords = [_][]const u8{
    "abstract", "as",       "base",     "bool",     "break",     "byte",     "case",   "catch",      "char",      "checked",
    "class",    "const",    "continue", "decimal",  "default",   "delegate", "do",     "double",     "else",      "enum",
    "event",    "explicit", "extern",   "false",    "finally",   "fixed",    "float",  "for",        "foreach",   "goto",
    "if",       "implicit", "in",       "int",      "interface", "internal", "is",     "lock",       "long",      "namespace",
    "new",      "null",     "object",   "operator", "out",       "override", "params", "private",    "protected", "public",
    "readonly", "ref",      "return",   "sbyte",    "sealed",    "short",    "sizeof", "stackalloc", "static",    "string",
    "struct",   "switch",   "this",     "throw",    "true",      "try",      "typeof", "uint",       "ulong",     "unchecked",
    "unsafe",   "ushort",   "using",    "virtual",  "void",      "volatile", "while",
};

/// Names raw helpers and thunks use for locals, so parameters avoid them. Plain-layer locals start with `__`.
const helper_locals = [_][]const u8{ "self", "t", "r", "e", "data", "table", "f", "impl" };

/// What every raw trait struct has, so its methods can't be called that.
const trait_members = [_][]const u8{ "data", "table", "Info", "AsObject", "FromObject", "Of", "Unowned", "Free", "Implemented" };

/// What every trait's class has.
const wrapper_members = [_][]const u8{ "Raw", "FromRaw", "From", "Dispose", "TraitName", "FromObject", "Provided", "Provide", "Adapter", "Instance" };

const leafOf = lang.leafOf;
const contains = lang.contains;
const isVoid = lang.isVoid;
const resultOk = lang.resultOk;
/// Something C# needs its own raw struct for.
const Extra = lang.Extra;

/// Where a slice is, since parameters can take spans but fields and returns are arrays.
const Ctx = enum { field, param, ret };

const sal = "global::Salamander.";
const sal_raw = "global::Salamander.Raw.";
const sys = "global::System.";

const Gen = struct {
    s: Schema,
    w: *std.Io.Writer,
    a: std.mem.Allocator,
    o: Options,
    diag: *Schema.Diagnostic,
    top: std.ArrayList([]const u8) = .empty,
    slices: std.ArrayList(Extra) = .empty,
    opts: std.ArrayList(Extra) = .empty,
    arrays: std.ArrayList(Extra) = .empty,
    fns: lang.Fns = .{},
    /// For temporaries' names, so nested conversions don't share them.
    tmp: usize = 0,

    fn init(s: Schema, w: *std.Io.Writer, a: std.mem.Allocator, options: Options, diag: *Schema.Diagnostic) Gen {
        var g: Gen = .{ .s = s, .w = w, .a = a, .o = options, .diag = diag };
        if (options.core) {
            g.o.namespace = "Salamander";
            g.o.class = "Core";
        }
        return g;
    }

    fn print(g: *Gen, comptime f: []const u8, args: anytype) Error!void {
        try g.w.print(f, args);
    }

    fn fmt(g: *Gen, comptime f: []const u8, args: anytype) Error![]const u8 {
        return std.fmt.allocPrint(g.a, f, args);
    }

    fn next(g: *Gen) usize {
        g.tmp += 1;
        return g.tmp;
    }

    fn claim(g: *Gen, n: []const u8) Error!void {
        try lang.claim(g.a, &g.top, g.diag, n, "C#");
    }

    /// Kept off C#'s keywords with an `@`.
    fn ident(g: *Gen, n: []const u8) Error![]const u8 {
        return if (contains(&keywords, n)) g.fmt("@{s}", .{n}) else n;
    }

    /// A raw parameter's name, kept off C#'s keywords and the raw helpers' locals.
    fn local(g: *Gen, n: []const u8) Error![]const u8 {
        return if (contains(&helper_locals, n)) g.fmt("{s}_", .{n}) else g.ident(n);
    }

    /// A member's name, which can't be its type's.
    fn member(g: *Gen, owner: []const u8, n: []const u8) Error![]const u8 {
        return if (std.mem.eql(u8, owner, n)) g.fmt("{s}_", .{n}) else g.ident(n);
    }

    /// `setSpeed` and `max_players` as `SetSpeed` and `MaxPlayers`.
    fn pascal(g: *Gen, n: []const u8) Error![]const u8 {
        const p = try lang.camel(g.a, n);
        if (p.len == 0 or std.ascii.isDigit(p[0])) return g.ident(try g.fmt("_{s}", .{p}));
        return g.ident(p);
    }

    fn bare(g: *Gen, n: []const u8) Error![]const u8 {
        return Schema.flatName(g.a, n);
    }

    /// The last part of a name, as one identifier, like `Node` for `Scene.Node`.
    fn leaf(g: *Gen, n: []const u8) Error![]const u8 {
        const start = if (Schema.namespaceEnd(n)) |e| e + 1 else 0;
        return g.ident(try g.bare(n[start..]));
    }

    fn nsDot(g: *Gen) []const u8 {
        return if (g.o.namespace.len > 0) g.fmt("{s}.", .{g.o.namespace}) catch "" else "";
    }

    /// The namespace what's declared at `at` is used from, if its file's aliased.
    fn aliasOf(g: *Gen, at: Schema.Pos) ?[]const u8 {
        if (g.o.aliases.len == 0) return null;
        const file_name = Schema.fileOf(g.o.source, at);
        for (g.o.aliases) |a| if (std.mem.startsWith(u8, file_name, a.prefix)) return a.namespace;
        return null;
    }

    fn aliasOfName(g: *Gen, n: []const u8) ?[]const u8 {
        if (g.o.aliases.len == 0) return null;
        if (g.s.findType(n)) |t| return g.aliasOf(t.at);
        if (g.s.findTrait(n)) |t| return g.aliasOf(t.at);
        return null;
    }

    /// Whether `n` is aliased, so it's used from there.
    fn isBase(g: *Gen, n: []const u8) bool {
        return g.aliasOfName(n) != null;
    }

    /// The namespace `n` is in, with a dot, its alias's if it has one.
    fn nsDotOf(g: *Gen, n: []const u8) []const u8 {
        const ns = g.aliasOfName(n) orelse return g.nsDot();
        return if (ns.len > 0) g.fmt("{s}.", .{ns}) catch "" else "";
    }

    /// Where a plain type is, like `global::Game.Scene.Node`, with `prefix` before its last part.
    fn plainRefWith(g: *Gen, n: []const u8, prefix: []const u8) Error![]const u8 {
        const end = Schema.namespaceEnd(n);
        const path = if (end) |e|
            (if (g.inType(n[0..e])) try g.fmt("{s}{s}.", .{ g.nsDotOf(n[0 .. std.mem.indexOfScalar(u8, n, '.') orelse e]), n[0..e] }) else try g.fmt("{s}.", .{n[0..e]}))
        else
            g.nsDotOf(n);
        return g.fmt("global::{s}{s}{s}", .{ path, prefix, try g.leaf(n) });
    }

    /// Whether a scope starts with a type rather than a namespace, so it's nested in one with no namespace.
    fn inType(g: *Gen, scope: []const u8) bool {
        const first = scope[0 .. std.mem.indexOfScalar(u8, scope, '.') orelse scope.len];
        return g.s.findType(first) != null or g.s.findTrait(first) != null;
    }

    fn plainRef(g: *Gen, n: []const u8) Error![]const u8 {
        return g.plainRefWith(n, "");
    }

    fn rawNs(g: *Gen) Error![]const u8 {
        return g.fmt("global::{s}Raw", .{g.nsDot()});
    }

    /// A raw type, by its flat name.
    fn rawRef(g: *Gen, flat: []const u8) Error![]const u8 {
        return g.fmt("{s}.{s}", .{ try g.rawNs(), try g.ident(flat) });
    }

    /// A named type's raw one, in the base's `Raw` if the base has it.
    fn rawRefOf(g: *Gen, n: []const u8) Error![]const u8 {
        return g.fmt("global::{s}Raw.{s}", .{ g.nsDotOf(n), try g.ident(try g.bare(n)) });
    }

    fn convRef(g: *Gen) Error![]const u8 {
        return g.fmt("global::{s}SalamanderConvert", .{g.nsDot()});
    }

    /// The converters for a named function type, the base's if it has it.
    fn convRefOf(g: *Gen, n: []const u8) Error![]const u8 {
        return g.fmt("global::{s}SalamanderConvert", .{g.nsDotOf(n)});
    }

    // What needs converting

    const Kind = enum { shared, twin, trait, func, none };

    fn kindOf(g: *Gen, n: []const u8) Kind {
        if (g.s.findTrait(n) != null) return .trait;
        const t = g.s.findType(n) orelse return .none;
        return switch (t.kind) {
            .func => .func,
            .@"struct" => if (g.needsTwin(t, 0)) .twin else .shared,
            else => .shared,
        };
    }

    /// A struct holding strings, slices or objects, which plain C# has as a class.
    fn needsTwin(g: *Gen, t: *const Schema.Type, depth: usize) bool {
        if (t.kind != .@"struct" or depth > g.s.types.len) return false;
        var it: plan.Slots = .init(g.s, t);
        while (it.next()) |slot| if (slot == .field and g.converts(slot.field.field.type, depth + 1)) return true;
        return false;
    }

    fn converts(g: *Gen, r: Ref, depth: usize) bool {
        return switch (r) {
            .prim => |p| p == .string or p == .cstring or p == .blob,
            .named => |n| if (g.s.findTrait(n) != null) true else if (g.s.findType(n)) |t| switch (t.kind) {
                .@"struct" => g.needsTwin(t, depth),
                .func => !g.o.core,
                else => false,
            } else false,
            .pointer, .result => false,
            .array => |a| a.count == null and a.len > 0 and g.converts(a.child.*, depth),
            .slice => true,
            .optional => |c| g.converts(c.*, depth),
            .func => !g.o.core,
        };
    }

    /// Plain and raw are the same type, which a span can hold.
    fn same(g: *Gen, r: Ref) bool {
        return switch (r) {
            .prim => |p| switch (p) {
                .bool, .utf16, .string, .cstring, .blob, .void => false,
                else => true,
            },
            .named => |n| g.kindOf(n) == .shared,
            else => false,
        };
    }

    // Raw names

    fn mangle(g: *Gen, r: Ref) Error![]const u8 {
        return switch (r) {
            .prim => |p| @tagName(p),
            .named => |n| g.bare(n),
            .pointer => |c| g.fmt("{s}Ptr", .{try g.mangle(c.*)}),
            .array => |a| g.fmt("{s}x{d}", .{ try g.mangle(a.child.*), a.len }),
            .slice => |c| g.fmt("Slice_{s}", .{try g.mangle(c.*)}),
            .optional => |c| g.fmt("Opt_{s}", .{try g.mangle(c.*)}),
            .func => |sig| (try g.fnOf(sig.*)).name,
            .result => |res| g.fmt("{s}Or{s}", .{ try g.mangle(res.ok.*), res.err }),
        };
    }

    /// An unnamed `fn(...)` is named for where it's first used, like `Freecam_onLand_listener`.
    fn fnOf(g: *Gen, sig: Schema.Signature) Error!Extra {
        return g.fns.of(sig);
    }

    fn namedFn(g: *Gen, n: []const u8) Extra {
        return g.fns.named(n);
    }

    /// Finds every slice, value optional, array and function value, so each gets one struct.
    fn collect(g: *Gen, r: Ref, site: []const u8) Error!void {
        try lang.collect(g, g.a, g.s, r, site);
    }

    pub fn onArray(g: *Gen, r: Ref) Error!void {
        // One whose length is another field's is only reached through a pointer
        if (r.array.count == null and r.array.len > 0) try lang.addUnique(g.a, &g.arrays, .{ .name = try g.mangle(r), .ref = r });
    }

    pub fn onSlice(g: *Gen, child: Ref, r: Ref) Error!void {
        try lang.addUnique(g.a, &g.slices, .{ .name = try g.mangle(r), .ref = child });
    }

    pub fn onOptional(g: *Gen, child: Ref, r: Ref) Error!void {
        try lang.addUnique(g.a, &g.opts, .{ .name = try g.mangle(r), .ref = child });
    }

    pub fn onFunc(g: *Gen, r: Ref, site: []const u8) Error!void {
        try g.fns.add(g.a, r, try g.bare(site));
    }

    // Raw types

    fn prim(p: Schema.Prim) []const u8 {
        return switch (p) {
            .u8, .utf8 => "byte",
            .u16, .utf16 => "ushort",
            .u32 => "uint",
            .u64 => "ulong",
            .i8 => "sbyte",
            .i16 => "short",
            .i32 => "int",
            .i64 => "long",
            .f32 => "float",
            .f64 => "double",
            .bool => sal ++ "Bool",
            .usize => "nuint",
            .isize => "nint",
            .string => sal ++ "Str",
            .object => sal ++ "AnyObject",
            .blob => sal_raw ++ "Blob",
            .any => sal ++ "Any",
            .cstring => "byte*",
            .void => "void",
        };
    }

    /// C# enums can't be native ints, so those are the size they are here.
    fn enumBacking(g: *Gen, p: Schema.Prim) []const u8 {
        return switch (p) {
            .usize => if (g.s.pointer_size == 8) "ulong" else "uint",
            .isize => if (g.s.pointer_size == 8) "long" else "int",
            else => prim(p),
        };
    }

    fn ty(g: *Gen, r: Ref) Error![]const u8 {
        return switch (r) {
            .prim => |p| prim(p),
            .named => |n| switch (g.kindOf(n)) {
                .shared, .none => g.plainRef(n),
                else => g.rawRefOf(n),
            },
            .pointer => |c| g.fmt("{s}*", .{try g.ty(c.*)}),
            .array => |a| if (a.count != null or a.len == 0) g.fmt("{s}*", .{try g.ty(a.child.*)}) else g.rawRef(try g.mangle(r)),
            .slice => g.rawRef(try g.mangle(r)),
            .optional => |c| if (c.* == .pointer or g.s.isObject(c.*)) g.ty(c.*) else g.rawRef(try g.mangle(r)),
            .func => |sig| g.rawRef((try g.fnOf(sig.*)).name),
            .result => unreachable,
        };
    }

    fn conv(c: Schema.Conv) []const u8 {
        return switch (c) {
            // C's own is cdecl on 32-bit Windows, where C#'s plain unmanaged is stdcall
            .c, .cdecl => "Cdecl",
            .stdcall => "Stdcall",
            .thiscall => "Thiscall",
            .fastcall => "Fastcall",
            // The Windows ABI, which is stdcall on x86 and the only one on x64 Windows
            .winapi => "Stdcall",
        };
    }

    /// A raw method's return. A code for results, a promise for async.
    fn retType(g: *Gen, m: *const Schema.Method) Error![]const u8 {
        if (m.async) return sal_raw ++ "Promise";
        if (m.signature.ret == .result) return "uint";
        return g.ty(m.signature.ret);
    }

    /// `delegate* unmanaged[Cdecl]<nuint, float, Vec3*, uint>`, a table's entry.
    fn entryType(g: *Gen, m: *const Schema.Method) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(g.a);
        const w = &out.writer;
        try w.print("delegate* unmanaged[{s}]<", .{conv(m.signature.conv)});
        if (!m.static) try w.writeAll("nuint, ");
        for (m.signature.params) |p| try w.print("{s}, ", .{try g.ty(p.type)});
        if (!m.async) if (resultOk(m.signature.ret)) |ok| try w.print("{s}*, ", .{try g.ty(ok)});
        try w.print("{s}>", .{try g.retType(m)});
        return out.written();
    }

    /// A raw method's `(uint n, Vec3* @out)` and the arguments to pass them on, without `this`.
    fn params(g: *Gen, m: *const Schema.Method) Error!struct { decl: []const u8, args: []const u8 } {
        var decl: std.Io.Writer.Allocating = .init(g.a);
        var args: std.Io.Writer.Allocating = .init(g.a);
        for (m.signature.params, 0..) |p, i| {
            const pn = try g.local(p.name);
            const sep = if (i > 0) ", " else "";
            try decl.writer.print("{s}{s} {s}", .{ sep, try g.ty(p.type), pn });
            try args.writer.print("{s}{s}", .{ sep, pn });
        }
        if (!m.async) if (resultOk(m.signature.ret)) |ok| {
            const sep = if (m.signature.params.len > 0) ", " else "";
            try decl.writer.print("{s}{s}* @out", .{ sep, try g.ty(ok) });
            try args.writer.print("{s}@out", .{sep});
        };
        return .{ .decl = decl.written(), .args = args.written() };
    }

    // Plain types, and turning them into raw ones and back

    fn optional(t: []const u8) bool {
        return std.mem.endsWith(u8, t, "?");
    }

    /// A function value's delegate.
    fn delegateRef(g: *Gen, f: Extra) Error![]const u8 {
        return switch (f.ref) {
            .named => |n| g.plainRef(n),
            else => g.fmt("global::{s}{s}", .{ g.nsDot(), try g.pascal(f.name) }),
        };
    }

    fn plain(g: *Gen, r: Ref, ctx: Ctx) Error![]const u8 {
        return switch (r) {
            .prim => |p| switch (p) {
                .bool => "bool",
                .utf16 => "char",
                .string => "string",
                .cstring => "string?",
                .blob => sal ++ "Blob?",
                else => prim(p),
            },
            .named => |n| switch (g.kindOf(n)) {
                .shared, .none, .twin => g.plainRef(n),
                .trait => g.fmt("{s}?", .{try g.plainRef(n)}),
                .func => if (g.o.core) g.ty(r) else g.fmt("{s}?", .{try g.delegateRef(g.namedFn(n))}),
            },
            .pointer => g.ty(r),
            .array => |a| if (a.count != null or a.len == 0 or (!g.converts(r, 0) and std.mem.endsWith(u8, try g.ty(a.child.*), "*")))
                g.ty(r)
            else
                g.fmt("{s}[]", .{try g.plain(a.child.*, .field)}),
            .slice => |c| if (std.mem.endsWith(u8, try g.ty(c.*), "*"))
                g.ty(r)
            else if (g.same(c.*))
                (if (ctx == .param) g.fmt(sys ++ "ReadOnlySpan<{s}>", .{try g.ty(c.*)}) else g.fmt("{s}[]", .{try g.ty(c.*)}))
            else if (ctx == .param)
                g.fmt(sys ++ "Collections.Generic.IReadOnlyList<{s}>", .{try g.plain(c.*, .field)})
            else
                g.fmt("{s}[]", .{try g.plain(c.*, .field)}),
            .optional => |c| if (c.* == .pointer)
                g.ty(c.*)
            else if (g.s.isObject(c.*))
                g.plain(c.*, ctx)
            else blk: {
                const p = try g.plain(c.*, ctx);
                break :blk if (optional(p)) p else g.fmt("{s}?", .{p});
            },
            .func => |sig| if (g.o.core) g.ty(r) else g.fmt("{s}?", .{try g.delegateRef(try g.fnOf(sig.*))}),
            .result => unreachable,
        };
    }

    /// Whether a value of `r` in plain C# is its raw one, so there's nothing to convert.
    fn asIs(g: *Gen, r: Ref) Error!bool {
        return std.mem.eql(u8, try g.plain(r, .field), try g.ty(r));
    }

    /// Plain `e` as raw, with memory from `__a`. `keep` is C# for whether objects outlive the call.
    fn lower(g: *Gen, r: Ref, e: []const u8, keep: []const u8) Error![]const u8 {
        if (try g.asIs(r)) return e;
        return switch (r) {
            .prim => |p| switch (p) {
                .utf16 => g.fmt("(ushort)({s})", .{e}),
                .string => g.fmt(sal ++ "Str.From({s}, __a)", .{e}),
                .cstring => g.fmt(sal ++ "Str.CString({s}, __a)", .{e}),
                .blob => g.fmt("(({s})?.Raw ?? default)", .{e}),
                else => e,
            },
            .named => |n| switch (g.kindOf(n)) {
                .twin => g.fmt("(({s})?.ToRaw(__a, {s}) ?? default)", .{ e, keep }),
                .trait => g.fmt("(({s})?.Raw ?? default)", .{e}),
                .func => g.fmt("{s}.Lower_{s}({s}, __a, {s})", .{ try g.convRefOf(n), g.namedFn(n).name, e, keep }),
                else => e,
            },
            .array, .slice => g.fmt("{s}.Lower_{s}({s}, __a, {s})", .{ try g.convRef(), try g.mangle(r), e, keep }),
            .optional => |c| if (c.* == .pointer or g.s.isObject(c.*)) g.lower(c.*, e, keep) else blk: {
                const n = g.next();
                const v = try g.fmt("__v{d}", .{n});
                break :blk g.fmt("(({s}) is {{}} {s} ? new {s} {{ value = {s}, some = true }} : default)", .{ e, v, try g.ty(r), try g.lower(c.*, v, keep) });
            },
            .func => |sig| g.fmt("{s}.Lower_{s}({s}, __a, {s})", .{ try g.convRef(), (try g.fnOf(sig.*)).name, e, keep }),
            else => e,
        };
    }

    /// Raw `e` as plain. `owned` is C# for whether objects in it are the caller's to let go of.
    fn lift(g: *Gen, r: Ref, e: []const u8, owned: []const u8) Error![]const u8 {
        if (try g.asIs(r)) return e;
        return switch (r) {
            .prim => |p| switch (p) {
                .bool => g.fmt("(bool)({s})", .{e}),
                .utf16 => g.fmt("(char)({s})", .{e}),
                .string => g.fmt("({s}).ToString()", .{e}),
                .cstring => g.fmt(sal ++ "Str.FromCString({s})", .{e}),
                .blob => g.fmt(sal ++ "Blob.FromRaw({s}, {s})", .{ e, owned }),
                else => e,
            },
            .named => |n| switch (g.kindOf(n)) {
                .twin => g.fmt("{s}.FromRaw({s})", .{ try g.plainRef(n), e }),
                .trait => g.fmt("{s}.FromRaw({s}, {s})", .{ try g.plainRef(n), e, owned }),
                .func => g.fmt("{s}.Lift_{s}({s})", .{ try g.convRefOf(n), g.namedFn(n).name, e }),
                else => e,
            },
            .array, .slice => g.fmt("{s}.Lift_{s}({s})", .{ try g.convRef(), try g.mangle(r), e }),
            .optional => |c| if (c.* == .pointer or g.s.isObject(c.*)) g.lift(c.*, e, owned) else blk: {
                const n = g.next();
                const o = try g.fmt("__o{d}", .{n});
                break :blk g.fmt("(({s}) is {{ some.value: not 0 }} {s} ? ({s})({s}) : null)", .{ e, o, try g.plain(r, .ret), try g.lift(c.*, try g.fmt("{s}.value", .{o}), owned) });
            },
            .func => |sig| g.fmt("{s}.Lift_{s}({s})", .{ try g.convRef(), (try g.fnOf(sig.*)).name, e }),
            else => e,
        };
    }

    // The file

    fn file(g: *Gen) Error!void {
        const s = g.s;
        try g.print(
            \\// <auto-generated/>
            \\// Generated by salamander from {s}. Don't edit it, it's written again every build.
            \\
            \\#nullable enable
            \\#pragma warning disable CS0649, CS0169, CS1591, CS8500, CS8981
            \\
        , .{g.o.label});

        // Named function types first, so their signatures keep their own names
        for (s.types) |t| if (t.kind == .func) {
            const base = g.isBase(t.name);
            if (!base) {
                for (t.kind.func.params) |p| try g.collect(p.type, try g.fmt("{s}_{s}", .{ t.name, p.name }));
                try g.collect(t.kind.func.ret, t.name);
            }
            try g.fns.list.append(g.a, .{ .name = try g.bare(t.name), .ref = .{ .named = t.name }, .hash = Schema.signatureHash(t.kind.func), .base = base });
        };
        for (s.types) |t| {
            if (g.isBase(t.name)) continue;
            try g.claim(try g.bare(t.name));
            switch (t.kind) {
                .@"struct", .@"union" => |st| for (st.fields) |f| try g.collect(f.type, try g.fmt("{s}_{s}", .{ t.name, f.name })),
                else => {},
            }
        }
        // What existing code declares takes `this` first, and handlers for hooking it are function values
        if (!g.o.core) {
            for (s.types) |*t| {
                if (g.isBase(t.name) or t.kind != .@"struct") continue;
                for (t.kind.@"struct".methods) |*m| try g.collectDeclared(.{ .in = t, .owner = t, .method = m }, try g.fmt("{s}_{s}", .{ t.name, m.name }));
            }
            for (s.functions) |*m| if (g.aliasOf(m.at) == null) try g.collectDeclared(.{ .method = m }, m.name);
        }
        for (s.traits) |*t| {
            if (g.isBase(t.name)) continue;
            const n = try g.bare(t.name);
            try g.claim(n);
            try g.claim(try g.fmt("{s}_Table", .{n}));
            try g.claim(try g.fmt("I{s}", .{n}));
            for (t.methods) |m| {
                for (m.signature.params) |p| try g.collect(p.type, try g.fmt("{s}_{s}_{s}", .{ t.name, m.name, p.name }));
                try g.collect(m.signature.ret, try g.fmt("{s}_{s}", .{ t.name, m.name }));
            }
        }
        try g.claim(g.o.class);
        try g.claim("Raw");
        try g.claim("SalamanderConvert");
        for (g.fns.list.items) |f| {
            if (f.base) continue;
            if (f.ref == .func) {
                try g.claim(f.name);
                if (!g.o.core) try g.claim(try g.pascal(f.name));
            }
            try g.claim(try g.fmt("{s}_Table", .{f.name}));
            try g.claim(try g.fmt("I{s}", .{f.name}));
        }
        for (g.slices.items) |x| try g.claim(x.name);
        for (g.opts.items) |x| try g.claim(x.name);
        for (g.arrays.items) |x| try g.claim(x.name);

        // Plain C#, with what both layers share
        var close = try g.open("");
        try g.print("\npublic static unsafe partial class {s}\n{{\n    /// <summary>What these types are laid out for.</summary>\n    public const int PointerSize = {d};\n", .{ try g.ident(g.o.class), s.pointer_size });
        for (s.constants) |k| if (g.aliasOf(k.at) == null) try g.constant(k);
        try g.print("}}\n", .{});
        if (!g.o.core) for (g.fns.list.items) |f| if (f.ref == .func) try g.delegateDef(try g.pascal(f.name), f.ref.func.*);
        try g.converters();
        try g.print("{s}", .{close});
        if (!g.o.core) try g.declaredTop();

        for (s.types) |*t| {
            if (t.kind == .func and g.o.core) continue;
            if (g.isBase(t.name)) continue;
            close = try g.open(t.name);
            switch (t.kind) {
                .@"struct" => if (g.kindOf(t.name) == .twin) try g.twinDef(t) else {
                    try g.structDef(t, false);
                    if (!g.o.core) try g.declaredOf(t);
                },
                .@"union" => try g.structDef(t, false),
                .@"enum" => |e| try g.enumDef(t, e),
                .bitfield => |b| try g.bitfieldDef(t, b),
                .@"error" => |e| try g.errorDef(t, e),
                // Partial, so the core's Owner and Info are Salamander.cs's
                .@"opaque" => try g.print("\npublic partial struct {s} {{ }}\n", .{try g.leaf(t.name)}),
                .func => |sig| try g.delegateDef(try g.leaf(t.name), sig),
            }
            if (t.kind != .@"enum" and plan.ownsInfo(s, .{ .named = t.name }) and g.kindOf(t.name) != .twin) try g.typeOfPart(t, try g.leaf(t.name));
            if (t.kind == .@"struct") if (t.kind.@"struct".tagged) |tg| try g.taggedPart(try g.leaf(t.name), tg);
            try g.print("{s}", .{close});
        }
        for (s.traits) |*t| {
            if (g.isBase(t.name)) continue;
            close = try g.open(t.name);
            try g.wrapper(t);
            try g.print("{s}", .{close});
        }

        // What crosses
        try g.print("\nnamespace {s}\n{{\n", .{(try g.rawNs())["global::".len..]});
        for (s.types) |*t| if (!g.isBase(t.name) and g.kindOf(t.name) == .twin) {
            try g.structDef(t, true);
            try g.typeOfPart(t, try g.ident(try g.bare(t.name)));
        };
        for (g.slices.items) |x| try g.print("\npublic unsafe struct {s}\n{{\n    public {s}* ptr;\n    public nuint len;\n}}\n", .{ try g.ident(x.name), try g.ty(x.ref) });
        for (g.opts.items) |x| try g.print("\npublic unsafe struct {s}\n{{\n    public {s} value;\n    public {s}Bool some;\n}}\n", .{ try g.ident(x.name), try g.ty(x.ref), sal });
        for (g.arrays.items) |x| try g.arrayDef(x);
        for (g.fns.list.items) |f| {
            if (f.base) continue;
            const sig = g.sigOf(f);
            const m: Schema.Method = .{ .name = "call", .signature = sig };
            const ms = [_]*const Schema.Method{&m};
            try g.print("\n// fn{f}\n", .{sig});
            try g.object(f.name, "fn", 0, &ms, &.{Schema.signatureHash(sig)}, &.{});
        }
        for (s.traits) |*t| {
            if (g.isBase(t.name)) continue;
            var buf: [plan.max_methods]*const Schema.Method = undefined;
            const ms = plan.methods(g.s, t, &buf);
            const sigs = try g.a.alloc(u64, ms.len);
            for (ms, 0..) |m, i| sigs[i] = Schema.methodHash(m);
            try g.print("\n// {s}\n", .{t.name});
            try g.object(try g.bare(t.name), t.name, g.s.traitHash(t), ms, sigs, t.bases);
        }
        try g.print("}}\n", .{});
        try g.typeInfos();
    }

    // What existing code declares, found through `Salamander.Declared`

    fn collectDeclared(g: *Gen, f: Schema.Function, site: []const u8) Error!void {
        const sig = try g.a.create(Schema.Signature);
        sig.* = try Schema.callSignature(f, g.a);
        try g.collect(.{ .func = sig }, site);
    }

    /// The members a struct's declared methods and statics give it, in a partial of its own.
    fn declaredOf(g: *Gen, t: *const Schema.Type) Error!void {
        const st = t.kind.@"struct";
        if (st.methods.len + st.statics.len == 0) return;
        const n = try g.leaf(t.name);
        try g.print("\npublic unsafe partial struct {s}\n{{\n", .{n});
        try g.declaredAddresses(t.name, st.methods, st.statics);
        for (st.statics) |*v| try g.declaredStatic(n, t.name, v);
        for (st.methods) |*m| try g.declaredMethod(n, .{ .in = t, .owner = t, .method = m });
        try g.print("}}\n", .{});
    }

    /// Top-level functions and statics, in the class with the schema's constants.
    fn declaredTop(g: *Gen) Error!void {
        const s = g.s;
        for (s.functions) |*m| {
            if (g.aliasOf(m.at) != null) continue;
            const close = try g.open(m.name);
            try g.print("\npublic static unsafe partial class {s}\n{{\n", .{try g.ident(g.o.class)});
            try g.declaredAddresses("", &.{m.*}, &.{});
            try g.declaredMethod(try g.ident(g.o.class), .{ .method = m });
            try g.print("}}\n{s}", .{close});
        }
        for (s.statics) |*v| {
            if (g.aliasOf(v.at) != null) continue;
            const close = try g.open(v.name);
            try g.print("\npublic static unsafe partial class {s}\n{{\n", .{try g.ident(g.o.class)});
            try g.declaredAddresses("", &.{}, &.{v.*});
            try g.declaredStatic(try g.ident(g.o.class), "", v);
            try g.print("}}\n{s}", .{close});
        }
    }

    /// `Player.heal`, or `spawn` at the top.
    fn declaredName(g: *Gen, owner: []const u8, name: []const u8) Error![]const u8 {
        return if (owner.len == 0) name else g.fmt("{s}.{s}", .{ owner, name });
    }

    fn declaredAddresses(g: *Gen, owner: []const u8, methods: []const Schema.Method, statics: []const Schema.Static) Error!void {
        try g.print("    /// <summary>Where each is, found by name the first time it's asked for.</summary>\n    public static partial class Addresses\n    {{\n", .{});
        for (methods) |m| try g.print("        public static nuint {s}() => {s}Declared.Address(\"{s}\");\n", .{ try g.pascal(leafOf(m.name)), sal, try g.declaredName(owner, m.name) });
        for (statics) |v| try g.print("        public static nuint {s}() => {s}Declared.Address(\"{s}\");\n", .{ try g.pascal(leafOf(v.name)), sal, try g.declaredName(owner, v.name) });
        try g.print("    }}\n", .{});
    }

    /// A pointer static gives what's stored there, with an OrFail that throws on null. Anything else gives a pointer to it.
    fn declaredStatic(g: *Gen, n: []const u8, owner: []const u8, v: *const Schema.Static) Error!void {
        _ = n;
        const full = try g.declaredName(owner, v.name);
        const d = try g.staticDecl(if (owner.len > 0) g.s.findType(owner) else null, v);
        const vn = d.name;
        const t = try g.ty(v.type);
        if (isStored(v)) {
            try g.print("\n    /// <summary>`{s}`, what's stored there.</summary>\n    public {s} => *({s}*){s}Declared.Address(\"{s}\");\n", .{ full, d.text.?, t, sal, full });
            try g.print("\n    /// <summary>`{s}`, throwing while it's null, like before the game's made it.</summary>\n    public static {s} {s}OrFail() => {s}() is var __p && __p != null ? __p : throw new {s}InvalidOperationException(\"{s} is null\");\n", .{ full, t, vn, vn, sys, full });
            return;
        }
        try g.print("\n    /// <summary>`{s}`, the global itself.</summary>\n    public {s} => ({s}*){s}Declared.Address(\"{s}\");\n", .{ full, d.text.?, t, sal, full });
    }

    /// Its function pointer type, a call converting plain C# both ways, and a hook handler of its type.
    fn declaredMethod(g: *Gen, n: []const u8, f: Schema.Function) Error!void {
        const m = f.method;
        const owner = if (f.in) |t| t.name else "";
        const full = try g.declaredName(owner, m.name);
        const sig = try Schema.callSignature(f, g.a);
        const d = try g.declaredDecl(f.in, m);
        const pn = d.name;
        // The type it's called as
        var fp: std.Io.Writer.Allocating = .init(g.a);
        try fp.writer.print("delegate* unmanaged[{s}]<", .{conv(sig.conv)});
        for (sig.params) |p| try fp.writer.print("{s}, ", .{try g.ty(p.type)});
        try fp.writer.print("{s}>", .{try g.ty(sig.ret)});
        const fn_type = fp.written();
        try g.print("\n    /// <summary>`{s}` as the function at `at`, like a hook's original.</summary>\n    public static {s} {s}At(nuint at) => ({s})at;\n", .{ full, fn_type, pn, fn_type });

        // The call, with `this` from the struct it's called on
        const has_this = f.hasThis();
        const where = if (m.virtual) |slot|
            try g.fmt("{s}Declared.Virtual(__self, {d})", .{ sal, slot })
        else
            try g.fmt("{s}Declared.Address(\"{s}\")", .{ sal, full });
        try g.print("\n    /// <summary>`{s}`{s}.</summary>\n    public {s}\n    {{\n", .{ full, if (m.virtual != null) ", through the vtable" else "", d.text.? });
        if (has_this) try g.print("        var __self = ({s}*){s}Runtime.CompilerServices.Unsafe.AsPointer(ref this);\n", .{ n, sys });
        var args: std.Io.Writer.Allocating = .init(g.a);
        if (has_this) try args.writer.writeAll("__self");
        for (m.signature.params, 0..) |p, i| {
            if (has_this or i > 0) try args.writer.writeAll(", ");
            try args.writer.writeAll(try g.lower(p.type, try g.ident(p.name), if (p.keep) "true" else "false"));
        }
        if (std.mem.indexOf(u8, args.written(), "__a") != null) try g.print("        using var __s = {s}Scratch.Enter();\n        var __a = __s.Allocator;\n", .{sal});
        const call = try g.fmt("{s}At({s})({s})", .{ pn, where, args.written() });
        if (isVoid(m.signature.ret)) try g.print("        {s};\n    }}\n", .{call}) else try g.print("        var __r = {s};\n        return {s};\n    }}\n", .{ call, try g.lift(m.signature.ret, "__r", "true") });

        // What hooks.named takes for it
        const fv = try g.fnOf(sig);
        try g.print(
            \\
            \\    /// <summary>A handler for hooking `{s}`, for hooks.Named. It's held till the hook's done with it.</summary>
            \\    public static {s}AnyObject {s}Handler({s} handler)
            \\    {{
            \\        using var __s = {s}Scratch.Enter();
            \\        return {s}.Lower_{s}(handler, __s.Allocator, true).AsObject();
            \\    }}
            \\
        , .{ full, sal, pn, try g.delegateRef(fv), sal, try g.convRef(), fv.name });

        // It as a value, for typed hooks
        const call_sig: Schema.Method = .{ .name = "call", .signature = sig };
        const cs = try g.plainSig(&call_sig, "call", null);
        var hook_name: []const u8 = "hook";
        for (sig.params) |p| if (std.mem.eql(u8, p.name, "hook")) {
            hook_name = "hook_";
        };
        const handler = try g.delegateRef(fv);
        try g.print(
            \\
            \\    public static partial class Fns
            \\    {{
            \\        /// <summary>`{s}` as a value, for typed hooks and the like.</summary>
            \\        public static readonly {s}Fn {s} = new();
            \\
            \\        public sealed class {s}Fn : {s}DeclaredFunction<{s}, {s}Fn.HookedHandler>
            \\        {{
            \\            internal {s}Fn() : base("{s}") {{ }}
            \\
            \\            /// <summary>What a hooked handler gets first: the function as it was, and the hook's context.</summary>
            \\            public readonly struct Hooked({s}HookCell cell)
            \\            {{
            \\                public {s} Original() => ({s})cell.Original;
            \\                public nuint Context => cell.Context;
            \\            }}
            \\
            \\            public delegate {s} HookedHandler(Hooked {s}{s}{s});
            \\
            \\            public override {s}AnyObject Lower({s} handler) => {s}Handler(handler);
            \\
            \\            public override {s}AnyObject Lower(HookedHandler handler, {s}HookCell cell) => {s}Handler(({s}) => handler(new Hooked(cell){s}{s}));
            \\        }}
            \\    }}
            \\
        , .{
            full,    pn,        pn,
            pn,      sal,       handler,
            pn,      pn,        full,
            sal,     fn_type,   fn_type,
            cs.ret,  hook_name, if (cs.decl.len > 0) ", " else "",
            cs.decl, sal,       handler,
            pn,      sal,       sal,
            pn,      cs.decl,   if (cs.args.len > 0) ", " else "",
            cs.args,
        });
    }

    fn sigOf(g: *Gen, f: Extra) Schema.Signature {
        return switch (f.ref) {
            .func => |sig| sig.*,
            .named => |n| g.s.findType(n).?.kind.func,
            else => unreachable,
        };
    }

    /// Opens what `name` is in, its namespaces then the types it's nested in, and gives what closes them.
    fn open(g: *Gen, name: []const u8) Error![]const u8 {
        const end = Schema.namespaceEnd(name) orelse name.len;
        const path = if (name.len == 0) "" else name[0..@min(end, name.len)];
        const scope = if (Schema.namespaceEnd(name) == null) "" else path;
        var ns: std.ArrayList(u8) = .empty;
        // Only what has no namespace of its own goes in the home one, like what's nested in a type that has none
        if (scope.len == 0 or g.inType(scope)) try ns.appendSlice(g.a, g.o.namespace);
        var nested: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        while (i < scope.len) {
            const dot = std.mem.indexOfScalarPos(u8, scope, i, '.') orelse scope.len;
            const prefix = scope[0..dot];
            if (nested.items.len == 0 and g.s.findType(prefix) == null and g.s.findTrait(prefix) == null) {
                if (ns.items.len > 0) try ns.append(g.a, '.');
                try ns.appendSlice(g.a, scope[i..dot]);
            } else try nested.append(g.a, prefix);
            i = dot + 1;
        }
        var closing: std.ArrayList(u8) = .empty;
        if (ns.items.len > 0) {
            try g.print("\nnamespace {s}\n{{\n", .{ns.items});
            try closing.appendSlice(g.a, "}\n");
        }
        for (nested.items) |p| {
            const decl: []const u8 = switch (g.kindOf(p)) {
                .twin, .trait => "public sealed unsafe partial class",
                .shared => blk: {
                    const t = g.s.findType(p).?;
                    if (t.kind == .@"enum" or t.kind == .@"error") {
                        g.diag.print("{s}: C# can't have types in an enum", .{name});
                        return error.NameClash;
                    }
                    break :blk "public unsafe partial struct";
                },
                .func => {
                    g.diag.print("{s}: C# can't have types in a delegate", .{name});
                    return error.NameClash;
                },
                .none => "public static unsafe partial class",
            };
            try g.print("\n{s} {s}\n{{\n", .{ decl, try g.leaf(p) });
            try closing.insertSlice(g.a, 0, "}\n");
        }
        return closing.items;
    }

    // What both layers share

    fn constant(g: *Gen, k: Schema.Constant) Error!void {
        const d = try g.constantDecl(k);
        const p = k.type.prim;
        try g.print("    public {s} = ", .{d.text.?});
        switch (k.value) {
            .int => |v| if (p.isFloat()) try g.print("{d}{s}", .{ v, if (p == .f32) "f" else "d" }) else try g.print("{d}", .{v}),
            .float => |v| try g.print("{d}{s}", .{ v, if (p == .f32) "f" else "d" }),
            .bool => |v| try g.print("{}", .{v}),
            .string => |v| {
                try g.print("\"", .{});
                for (v) |c| switch (c) {
                    '"', '\\' => try g.print("\\{c}", .{c}),
                    '\n' => try g.print("\\n", .{}),
                    else => try g.print("{c}", .{c}),
                };
                try g.print("\"", .{});
            },
        }
        try g.print(";\n", .{});
    }

    // Type info, each type's `TypeInfo` for `Any`, in the class with the constants

    fn infosRef(g: *Gen) Error![]const u8 {
        return g.fmt("global::{s}{s}.SalamanderTypes", .{ g.nsDot(), try g.ident(g.o.class) });
    }

    /// `ITypeOf` for a struct as it crosses.
    fn typeOfPart(g: *Gen, t: *const Schema.Type, name: []const u8) Error!void {
        const h = plan.info(g.s, .{ .named = t.name }).hash;
        try g.print("\npublic unsafe partial struct {s} : {s}ITypeOf\n{{\n    /// <summary>What it is, for Any.</summary>\n    public static {s}TypeInfo* SalamanderType => {s}.info_{x:0>16};\n}}\n", .{ name, sal, sal_raw, try g.infosRef(), h });
    }

    /// For each member: `TryGet` what it holds if the tag says it's that one, and `Of` to make one.
    fn taggedPart(g: *Gen, n: []const u8, tg: Schema.Tagged) Error!void {
        const tag = try g.plainRef(tg.tag);
        try g.print("\npublic unsafe partial struct {s}\n{{\n", .{n});
        for (tg.members) |m| {
            const p = try g.pascal(m.name);
            if (m.type == .prim and m.type.prim == .void) {
                try g.print("    public bool Is{s} => Tag == {s}.{s};\n", .{ p, tag, p });
                try g.print("    public static {s} Of{s}() => new() {{ Tag = {s}.{s} }};\n", .{ n, p, tag, p });
                continue;
            }
            const member_type = try g.ty(m.type);
            try g.print("    /// <summary>Its {s}, if the tag says it's that one.</summary>\n    public bool TryGet{s}(out {s} value)\n    {{\n        value = Tag == {s}.{s} ? Payload.{s} : default;\n        return Tag == {s}.{s};\n    }}\n", .{ m.name, p, member_type, tag, p, p, tag, p });
            try g.print("    public static {s} Of{s}({s} value)\n    {{\n        var s = new {s} {{ Tag = {s}.{s} }};\n        s.Payload.{s} = value;\n        return s;\n    }}\n", .{ n, p, member_type, n, tag, p, p });
        }
        try g.print("}}\n", .{});
    }

    fn typeInfos(g: *Gen) Error!void {
        const s = g.s;
        var o: InfoOut = .{ .g = g, .fills = .init(g.a) };
        for (s.types) |t| if (!g.isBase(t.name) and plan.ownsInfo(s, .{ .named = t.name })) {
            _ = try o.ref(.{ .named = t.name });
        };
        if (o.order.items.len == 0) return;
        const close = try g.open("");
        try g.print("\npublic static unsafe partial class {s}\n{{\n    /// <summary>Each type's info, for Any. Kept for good.</summary>\n    public static unsafe class SalamanderTypes\n    {{\n", .{try g.ident(g.o.class)});
        for (o.order.items) |h| try g.print("        public static readonly {s}TypeInfo* info_{x:0>16};\n", .{ sal_raw, h });
        try g.print("\n        static SalamanderTypes()\n        {{\n", .{});
        for (o.order.items) |h| try g.print("            info_{x:0>16} = {s}TypeInfos.Make();\n", .{ h, sal });
        try g.print("{s}        }}\n    }}\n}}\n{s}", .{ o.fills.written(), close });
    }

    /// Each type's info once, by hash, made first and filled after so they can point at each other.
    const InfoOut = struct {
        g: *Gen,
        fills: std.Io.Writer.Allocating,
        order: std.ArrayList(u64) = .empty,

        fn ref(o: *InfoOut, r: Ref) Error![]const u8 {
            const g = o.g;
            const i = plan.info(g.s, r);
            const name = try g.fmt("info_{x:0>16}", .{i.hash});
            for (o.order.items) |h| if (h == i.hash) return name;
            try o.order.append(g.a, i.hash);
            var out: std.Io.Writer.Allocating = .init(g.a);
            const w = &out.writer;
            try w.print("            *{s} = new {s}TypeInfo {{ kind = {s}TypeKind.{s}, name = {s}TypeInfos.Name(\"{s}\"u8), hash = 0x{x:0>16}UL, size = {d}, alignment = {d}", .{ name, sal_raw, sal, try g.pascal(i.kind), sal, i.name, i.hash, i.size, i.alignment });
            if (i.child) |c| try w.print(", child = {s}", .{try o.ref(c)});
            if (i.len > 0) try w.print(", len = {d}", .{i.len});
            var fields: plan.InfoFields = .init(g.s, r);
            if (fields.t != null and fields.next() != null) {
                fields = .init(g.s, r);
                try w.print(", fields = {s}TypeInfos.Fields(", .{sal});
                var first = true;
                while (fields.next()) |f| {
                    try w.print("{s}new {s}FieldInfo {{ name = {s}TypeInfos.Name(\"{s}\"u8), type = {s}, offset = {d}, bit = {d}, bits = {d} }}", .{ if (first) "" else ", ", sal_raw, sal, f.name, try o.ref(f.type), f.offset, f.bit, f.bits });
                    first = false;
                }
                try w.writeAll(")");
            }
            var values: plan.InfoValues = .init(g.s, r);
            if (values.next() != null) {
                values = .init(g.s, r);
                try w.print(", values = {s}TypeInfos.Values(", .{sal});
                var first = true;
                while (values.next()) |v| {
                    try w.print("{s}new {s}EnumValue {{ name = {s}TypeInfos.Name(\"{s}\"u8), value = {d} }}", .{ if (first) "" else ", ", sal_raw, sal, v.name, v.value });
                    first = false;
                }
                try w.writeAll(")");
            }
            try w.writeAll(" };\n");
            try o.fills.writer.writeAll(out.written());
            return name;
        }
    };

    fn enumDef(g: *Gen, t: *const Schema.Type, e: Schema.Enum) Error!void {
        try g.print("\npublic enum {s} : {s}\n{{\n", .{ try g.leaf(t.name), g.enumBacking(e.backing) });
        for (e.values) |v| try g.print("    {s} = {d},\n", .{ try g.pascal(v.name), v.value });
        try g.print("}}\n", .{});
    }

    /// The codes as an enum, and an exception that carries one.
    fn errorDef(g: *Gen, t: *const Schema.Type, e: Schema.ErrorSet) Error!void {
        const n = try g.leaf(t.name);
        const en = try g.plainRef(t.name);
        try g.print("\n/// <summary>Codes a result can give, besides Abi.Cancelled, Abi.Unsupported and Abi.Gone.</summary>\npublic enum {s} : uint\n{{\n", .{n});
        for (e.errors) |x| try g.print("    {s} = {d},\n", .{ try g.pascal(x.name), x.code });
        try g.print("}}\n", .{});
        try g.print(
            \\
            \\public sealed class {s}Exception : {s}SalamanderException
            \\{{
            \\    public {s}Exception({s} error, string? message = null) : base((uint)error, message ?? NameOf(error)) {{ }}
            \\
            \\    public {s} Error => ({s})Code;
            \\
            \\    /// <summary>Its name in the schema, which explanations go by.</summary>
            \\    public static string NameOf({s} error) => error switch
            \\    {{
            \\
        , .{ n, sal, n, en, en, en, en });
        for (e.errors) |x| try g.print("        {s}.{s} => \"{s}\",\n", .{ en, try g.pascal(x.name), x.name });
        try g.print("        _ => error.ToString(),\n    }};\n\n    /// <summary>A code as what to throw.</summary>\n    public static {s}Exception Raise(uint code) => code switch\n    {{\n", .{sys});
        for (e.errors) |x| try g.print("        {d} => new {s}Exception({s}.{s}, {s}Runtime.Explanation(\"{s}\")),\n", .{ x.code, n, en, try g.pascal(x.name), sal, x.name });
        try g.print(
            \\        _ => {s}Promises.Fail(code),
            \\    }};
            \\
            \\    /// <summary>What a thrown exception crosses as. Its message is explained to the caller.</summary>
            \\    public static uint CodeOf({s}Exception e)
            \\    {{
            \\        if (e is {s}Exception x)
            \\        {{
            \\            {s}Runtime.Explain(NameOf(x.Error), x.Message);
            \\            return x.Code;
            \\        }}
            \\        return {s}Promises.CodeOf(e);
            \\    }}
            \\}}
            \\
        , .{ sal, sys, n, sal, sal });
    }

    fn bitfieldDef(g: *Gen, t: *const Schema.Type, b: Schema.Bitfield) Error!void {
        const n = try g.leaf(t.name);
        const backing = prim(b.backing);
        try g.print("\npublic partial struct {s}\n{{\n    public {s} Raw;\n", .{ n, backing });
        for (b.members) |m| {
            const mn = try g.member(n, try g.pascal(m.name));
            if (std.mem.eql(u8, mn, "Raw")) {
                g.diag.print("{s}.{s}: C# has the bitfield's bits called that", .{ t.name, m.name });
                return error.NameClash;
            }
            const mask = try g.fmt("0x{x}UL", .{(@as(u128, 1) << @intCast(m.bits)) - 1});
            const got = try g.fmt("(((ulong)Raw >> {d}) & {s})", .{ m.bit, mask });
            const T: []const u8, const get: []const u8, const set: []const u8 = switch (m.type) {
                .bool => if (m.bits == 1) .{ "bool", try g.fmt("{s} != 0", .{got}), "(value ? 1UL : 0UL)" } else .{ backing, try g.fmt("({s}){s}", .{ backing, got }), "(ulong)value" },
                .uint => .{ backing, try g.fmt("({s}){s}", .{ backing, got }), "(ulong)value" },
                .@"enum" => |en| blk: {
                    const et = try g.plainRef(en);
                    break :blk .{ et, try g.fmt("({s}){s}", .{ et, got }), "(ulong)value" };
                },
            };
            try g.print("    public {s} {s}\n    {{\n        readonly get => {s};\n        set => Raw = ({s})(((ulong)Raw & ~({s} << {d})) | (({s} & {s}) << {d}));\n    }}\n", .{
                T, mn, get, backing, mask, m.bit, set, mask, m.bit,
            });
        }
        try g.print("}}\n", .{});
    }

    /// A struct as it crosses. Raw ones keep the schema's names, shared ones are PascalCase.
    fn structDef(g: *Gen, t: *const Schema.Type, raw: bool) Error!void {
        const n = if (raw) try g.ident(try g.bare(t.name)) else try g.leaf(t.name);
        const is_union = t.kind == .@"union";
        try g.print("\n[{s}Runtime.InteropServices.StructLayout({s}Runtime.InteropServices.LayoutKind.Explicit", .{ sys, sys });
        if (t.size > 0) try g.print(", Size = 0x{x}", .{t.size});
        try g.print(")]\npublic unsafe partial struct {s}\n{{\n", .{n});
        var it: plan.Slots = .init(g.s, t);
        while (it.next()) |slot| switch (slot) {
            .pad => {},
            .field => |f| {
                const offset = if (is_union) 0 else f.field.offset;
                const fname = try g.member(n, if (raw) f.field.name else try g.pascal(f.field.name));
                if (f.field.type == .array and (f.field.type.array.count != null or f.field.type.array.len == 0)) {
                    // As long as another field says, so it's reached through a pointer to the struct
                    const child = try g.ty(f.field.type.array.child.*);
                    try g.print("    public static {s}* {s}({s}* self) => ({s}*)((byte*)self + 0x{x});\n", .{ child, fname, n, child, offset });
                    continue;
                }
                const ft = if (raw) try g.ty(f.field.type) else (try g.fieldDecl(t, f.field)).type.?;
                try g.print("    [{s}Runtime.InteropServices.FieldOffset(0x{x})] public {s} {s};\n", .{ sys, offset, ft, fname });
            },
        };
        try g.print("}}\n", .{});
    }

    fn arrayDef(g: *Gen, x: Extra) Error!void {
        const len = x.ref.array.len;
        const child = try g.ty(x.ref.array.child.*);
        if (!std.mem.endsWith(u8, child, "*")) {
            try g.print("\n[{s}Runtime.CompilerServices.InlineArray({d})]\npublic unsafe struct {s}\n{{\n    private {s} _element0;\n}}\n", .{ sys, len, try g.ident(x.name), child });
            return;
        }
        // Inline arrays can't hold pointers or have their own indexer, so it's ints the same size
        try g.print(
            \\
            \\[{s}Runtime.InteropServices.StructLayout({s}Runtime.InteropServices.LayoutKind.Sequential, Size = {d})]
            \\public unsafe struct {s}
            \\{{
            \\    private nint _element0;
            \\
            \\    public {s} this[int i]
            \\    {{
            \\        readonly get => ({s}){s}Runtime.InteropServices.MemoryMarshal.CreateReadOnlySpan(in _element0, {d})[i];
            \\        set => {s}Runtime.InteropServices.MemoryMarshal.CreateSpan(ref _element0, {d})[i] = (nint)value;
            \\    }}
            \\}}
            \\
        , .{ sys, sys, len * g.s.pointer_size, try g.ident(x.name), child, child, sys, len, sys, len });
    }

    // Raw traits and function values

    /// Its table, its struct with info and helpers, and its interface to implement it with.
    fn object(g: *Gen, n: []const u8, label: []const u8, hash: u64, ms: []const *const Schema.Method, sigs: []const u64, bases: []const []const u8) Error!void {
        const id = try g.ident(n);
        for (ms) |m| if (contains(&trait_members, m.name) or std.mem.eql(u8, m.name, n)) {
            g.diag.print("{s}.{s}: C#'s {s} has its own member called that", .{ label, m.name, n });
            return error.NameClash;
        };

        try g.print("\n/// <summary>A null method is one this table doesn't have.</summary>\npublic unsafe struct {s}_Table\n{{\n    public {s}Info* salamander_info;\n    public {s}Owner* salamander_owner;\n", .{ n, sal, sal });
        for (ms) |m| try g.print("    public {s} {s};\n", .{ try g.entryType(m), try g.ident(m.name) });
        try g.print("}}\n", .{});

        try g.print("\npublic unsafe partial struct {s}\n{{\n    public nuint data;\n    public {s}_Table* table;\n\n", .{ id, n });
        try g.print("    public static readonly {s}Info* Info = {s}Abi.MakeInfo(global::{s}{s}.PointerSize, 0x{x:0>16}UL, \"{s}\"u8, \"", .{ sal, sal, g.nsDot(), try g.ident(g.o.class), hash, label });
        for (ms) |m| try g.print("{s}\\0", .{m.name});
        try g.print("\"u8, new ulong[] {{ ", .{});
        for (sigs, 0..) |sig, i| try g.print("{s}0x{x:0>16}UL", .{ if (i > 0) ", " else "", sig });
        try g.print(" }});\n", .{});

        for (ms) |m| try g.helper(m);
        try g.print(
            \\
            \\    public readonly {s}AnyObject AsObject() => new() {{ data = data, table = table }};
            \\
            \\    public static {s} FromObject({s}AnyObject o) => new() {{ data = o.data, table = ({s}_Table*)o.table }};
            \\
            \\    /// <summary>
            \\    /// One that calls impl, which it holds on to till Free, or till the host lets go of it
            \\    /// when it went to a keep parameter. Guarded by Runtime.Owner once there is one.
            \\    /// </summary>
            \\    public static {s} Of(I{s} impl) => new() {{ data = {s}Abi.Hold(impl), table = Implemented.Owned() }};
            \\
            \\    /// <summary>Like Of, without an owner, so only Free lets go of it.</summary>
            \\    public static {s} Unowned(I{s} impl) => new() {{ data = {s}Abi.Hold(impl), table = Implemented.salamander_table }};
            \\
            \\    /// <summary>Lets go of one from Of or Unowned, once nothing's going to call it.</summary>
            \\    public static void Free({s} obj) => {s}Abi.Free(obj.data);
            \\
            \\    static class Implemented
            \\    {{
            \\        public static readonly {s}_Table* salamander_table = Make();
            \\        static {s}_Table* owned;
            \\
            \\        static {s}_Table* Make()
            \\        {{
            \\            var t = ({s}_Table*){s}Abi.MakeTable((nuint)sizeof({s}_Table), Info);
            \\
        , .{ sal, id, sal, n, id, n, sal, id, n, sal, id, sal, n, n, n, n, sal, n });
        for (ms) |m| if (!m.static) try g.print("            t->{s} = &{s};\n", .{ try g.ident(m.name), try g.ident(m.name) });
        try g.print(
            \\            return t;
            \\        }}
            \\
            \\        public static {s}_Table* Owned()
            \\        {{
            \\            var o = {s}Runtime.Owner;
            \\            if (o == null) return salamander_table;
            \\            var t = owned;
            \\            if (t == null || t->salamander_owner != o)
            \\            {{
            \\                t = ({s}_Table*){s}Abi.MakeTable((nuint)sizeof({s}_Table), Info);
            \\                *t = *salamander_table;
            \\                t->salamander_owner = o;
            \\                owned = t;
            \\            }}
            \\            return t;
            \\        }}
            \\
        , .{ n, sal, n, sal, n });
        for (ms) |m| if (!m.static) try g.thunk(n, m);
        try g.print("    }}\n}}\n", .{});

        try g.print("\npublic unsafe interface I{s}", .{n});
        var first = true;
        for (bases) |b| if (g.s.findTrait(b) != null) {
            const base_i = if (g.isBase(b)) try g.fmt("global::{s}Raw.I{s}", .{ g.nsDotOf(b), try g.bare(b) }) else try g.fmt("I{s}", .{try g.bare(b)});
            try g.print("{s}{s}", .{ if (first) " : " else ", ", base_i });
            first = false;
        };
        try g.print("\n{{\n", .{});
        for (ms) |m| {
            // Only its own, its bases' interfaces have theirs. Static ones have no this to find it with.
            if (m.static or !g.ownMethod(m, bases)) continue;
            const ret = try g.retType(m);
            // Left out, it's what a table without it gives
            const body = if (std.mem.eql(u8, ret, "void")) " { }" else " => default!;";
            try g.print("    {s} {s}({s}){s}\n", .{ ret, try g.ident(m.name), (try g.params(m)).decl, body });
        }
        try g.print("}}\n", .{});
    }

    /// A plain interface method's body for when an implementation leaves it out, like a table without it:
    /// nothing, zero, an empty string, or a new one of a class that converts.
    fn plainDefault(g: *Gen, m: *const Schema.Method, ret: []const u8) Error![]const u8 {
        const task = "global::System.Threading.Tasks.Task";
        if (std.mem.eql(u8, ret, "void")) return " { }";
        if (std.mem.eql(u8, ret, task)) return " => " ++ task ++ ".CompletedTask;";
        if (std.mem.startsWith(u8, ret, task ++ "<")) {
            const inner = ret[task.len + 1 .. ret.len - 1];
            return g.fmt(" => {s}.FromResult<{s}>({s});", .{ task, inner, g.zeroOf(m, inner) });
        }
        return g.fmt(" => {s};", .{g.zeroOf(m, ret)});
    }

    fn zeroOf(g: *Gen, m: *const Schema.Method, t: []const u8) []const u8 {
        if (std.mem.eql(u8, t, "string")) return "\"\"";
        if (std.mem.endsWith(u8, t, "?")) return "null";
        const ok = lang.resultOk(m.signature.ret) orelse m.signature.ret;
        if (ok == .named and g.kindOf(ok.named) == .twin) return "new()";
        // Null for a trait or class, which is what a missing method gives too
        return "default!";
    }

    fn ownMethod(g: *Gen, m: *const Schema.Method, bases: []const []const u8) bool {
        for (bases) |b| {
            const base = g.s.findTrait(b) orelse continue;
            var buf: [plan.max_methods]*const Schema.Method = undefined;
            for (plan.methods(g.s, base, &buf)) |bm| if (bm == m) return false;
        }
        return true;
    }

    /// Calls through the table, entering the owner around it.
    fn helper(g: *Gen, m: *const Schema.Method) Error!void {
        const p = try g.params(m);
        const mn = try g.ident(m.name);
        const self_arg: []const u8 = if (m.static) "" else if (p.args.len > 0) "data, " else "data";
        const ret = try g.retType(m);
        const is_void = !m.async and isVoid(m.signature.ret);
        const is_result = !m.async and m.signature.ret == .result;
        try g.print("\n    public readonly {s} {s}({s})\n    {{\n        var t = table;\n", .{ ret, mn, p.decl });
        if (is_void) {
            try g.print("        if (t == null || t->{s} == null || !{s}Abi.Enter(t->salamander_owner)) return;\n", .{ mn, sal });
            try g.print("        t->{s}({s}{s});\n        {s}Abi.Leave(t->salamander_owner);\n    }}\n", .{ mn, self_arg, p.args, sal });
            return;
        }
        if (is_result) {
            try g.print("        if (t == null) return {s}Abi.Gone;\n        if (t->{s} == null) return {s}Abi.Unsupported;\n        if (!{s}Abi.Enter(t->salamander_owner)) return {s}Abi.Gone;\n", .{ sal, mn, sal, sal, sal });
        } else {
            try g.print("        if (t == null || t->{s} == null || !{s}Abi.Enter(t->salamander_owner)) return default;\n", .{ mn, sal });
        }
        try g.print("        var r = t->{s}({s}{s});\n        {s}Abi.Leave(t->salamander_owner);\n        return r;\n    }}\n", .{ mn, self_arg, p.args, sal });
    }

    /// What a table made in C# calls, which finds the object and calls its interface.
    fn thunk(g: *Gen, n: []const u8, m: *const Schema.Method) Error!void {
        const p = try g.params(m);
        const mn = try g.ident(m.name);
        const ret = try g.retType(m);
        const is_void = !m.async and isVoid(m.signature.ret);
        const is_result = !m.async and m.signature.ret == .result;
        try g.print("\n        [{s}Runtime.InteropServices.UnmanagedCallersOnly(CallConvs = new[] {{ typeof({s}Runtime.CompilerServices.CallConv{s}) }})]\n", .{ sys, sys, conv(m.signature.conv) });
        try g.print("        static {s} {s}(nuint self{s}{s})\n        {{\n", .{ ret, mn, if (p.decl.len > 0) ", " else "", p.decl });
        const call = try g.fmt("{s}Abi.Held<I{s}>(self).{s}({s})", .{ sal, n, mn, p.args });
        if (is_void) {
            try g.print("            try {{ {s}; }}\n            catch ({s}Exception e) {{ {s}Abi.Threw(e); }}\n        }}\n", .{ call, sys, sal });
        } else {
            try g.print("            try {{ return {s}; }}\n            catch ({s}Exception e) {{ {s}Abi.Threw(e); return {s}; }}\n        }}\n", .{ call, sys, sal, if (is_result) sal ++ "Abi.Gone" else "default" });
        }
    }

    // Plain C#

    /// A method's plain signature: what it gives back, its name, and its parameters.
    const Sig = struct { ret: []const u8, name: []const u8, decl: []const u8, args: []const u8, params: []const lang.Param };

    fn plainSig(g: *Gen, m: *const Schema.Method, name: []const u8, cancel: ?[]const u8) Error!Sig {
        const ok: ?Ref = if (m.signature.ret == .result) resultOk(m.signature.ret) else if (isVoid(m.signature.ret)) null else m.signature.ret;
        const ret = if (m.async)
            (if (ok) |o| try g.fmt(sys ++ "Threading.Tasks.Task<{s}>", .{try g.plain(o, .ret)}) else sys ++ "Threading.Tasks.Task")
        else if (ok) |o| try g.plain(o, .ret) else "void";
        var list: std.ArrayList(lang.Param) = .empty;
        var args: std.Io.Writer.Allocating = .init(g.a);
        for (m.signature.params, 0..) |p, i| {
            const pn = try g.ident(if (std.mem.eql(u8, p.name, "cancel")) "cancel_" else p.name);
            // Async methods can't take spans
            const ctx: Ctx = if (m.async) .field else .param;
            const t = if (p.inoutType()) |inner| (if (p.nullable()) try g.ty(p.type) else try g.fmt("ref {s}", .{try g.plain(inner, .field)})) else try g.plain(p.type, ctx);
            try list.append(g.a, .{ .name = pn, .type = t, .text = try g.fmt("{s} {s}", .{ t, pn }) });
            try args.writer.print("{s}{s}{s}", .{ if (i > 0) ", " else "", if (p.inoutType() != null and !p.nullable()) "ref " else "", pn });
        }
        if (m.async) if (cancel) |default| {
            const t = sys ++ "Threading.CancellationToken";
            try list.append(g.a, .{ .name = "cancel", .type = t, .text = try g.fmt("{s} cancel{s}", .{ t, default }) });
        };
        return .{ .ret = ret, .name = try g.fmt("{s}{s}", .{ try g.pascal(name), if (m.async) "Async" else "" }), .decl = try lang.paramList(g.a, list.items), .args = args.written(), .params = list.items };
    }

    // How each thing's declared, which `Names` gives docs too

    /// A trait's method, `cancel` the default an async one's token has, or null for none.
    fn methodDecl(g: *Gen, m: *const Schema.Method, cancel: ?[]const u8) Error!lang.Decl {
        const sig = try g.plainSig(m, m.name, cancel);
        return .{ .name = sig.name, .params = sig.params, .type = sig.ret, .text = try g.fmt("{s} {s}({s})", .{ sig.ret, sig.name, sig.decl }) };
    }

    /// A plain struct's field, or a class's property for one that holds what converts.
    fn fieldDecl(g: *Gen, t: *const Schema.Type, f: Schema.Field) Error!lang.Decl {
        const n = try g.member(try g.leaf(t.name), try g.pascal(f.name));
        const ft = if (g.kindOf(t.name) == .twin) try g.plain(f.type, .field) else try g.ty(f.type);
        return .{ .name = n, .type = ft, .text = try g.fmt("{s} {s}", .{ ft, n }) };
    }

    /// The class top-level code is in, in `name`'s namespace, like `Game.Schema`.
    fn classOf(g: *Gen, name: []const u8) Error![]const u8 {
        const cls = try g.ident(g.o.class);
        if (Schema.namespaceEnd(name)) |e| return g.fmt("{s}.{s}", .{ name[0..e], cls });
        return if (g.o.namespace.len > 0) g.fmt("{s}.{s}", .{ g.o.namespace, cls }) else cls;
    }

    /// Existing code's function, a struct's member when `in` is set, or one on the class with the constants.
    fn declaredDecl(g: *Gen, in: ?*const Schema.Type, m: *const Schema.Method) Error!lang.Decl {
        const n = if (in) |t| try g.leaf(t.name) else try g.ident(g.o.class);
        const pn = try g.member(n, try g.pascal(leafOf(m.name)));
        const call_m: Schema.Method = .{ .name = m.name, .signature = m.signature };
        const ps = try g.plainSig(&call_m, m.name, null);
        const has_this = in != null and !m.static;
        return .{
            .name = pn,
            .path = if (in != null) null else try g.fmt("{s}.{s}", .{ try g.classOf(m.name), pn }),
            .params = ps.params,
            .type = ps.ret,
            .text = try g.fmt("{s}{s} {s}({s})", .{ if (has_this) "" else "static ", ps.ret, pn, ps.decl }),
        };
    }

    /// A pointer static gives what's stored there, anything else a pointer to it.
    fn staticDecl(g: *Gen, in: ?*const Schema.Type, v: *const Schema.Static) Error!lang.Decl {
        const n = if (in) |t| try g.leaf(t.name) else try g.ident(g.o.class);
        const vn = try g.member(n, try g.pascal(leafOf(v.name)));
        const t = try g.ty(v.type);
        const ret = if (isStored(v)) t else try g.fmt("{s}*", .{t});
        return .{ .name = vn, .path = if (in != null) null else try g.fmt("{s}.{s}", .{ try g.classOf(v.name), vn }), .type = ret, .text = try g.fmt("static {s} {s}()", .{ ret, vn }) };
    }

    fn isStored(v: *const Schema.Static) bool {
        return v.type == .pointer or (v.type == .optional and v.type.optional.* == .pointer);
    }

    fn constantDecl(g: *Gen, k: Schema.Constant) Error!lang.Decl {
        const n = try g.pascal(try g.bare(k.name));
        const t: []const u8 = switch (k.value) {
            .bool => "bool",
            .string => "string",
            else => prim(k.type.prim),
        };
        return .{ .name = n, .path = try g.fmt("{s}.{s}", .{ try g.classOf(""), n }), .type = t, .text = try g.fmt("const {s} {s}", .{ t, n }) };
    }

    fn errorRef(g: *Gen, m: *const Schema.Method) Error![]const u8 {
        return if (m.signature.ret == .result) g.fmt("{s}Exception", .{try g.plainRef(m.signature.ret.result.err)}) else "";
    }

    /// The body of a plain method calling `target`'s raw one, converting both ways.
    fn callBody(g: *Gen, m: *const Schema.Method, target: []const u8, indent: []const u8) Error!void {
        var temps: std.Io.Writer.Allocating = .init(g.a);
        var args: std.Io.Writer.Allocating = .init(g.a);
        var after: std.Io.Writer.Allocating = .init(g.a);
        for (m.signature.params, 0..) |p, i| {
            const pn = try g.ident(if (std.mem.eql(u8, p.name, "cancel")) "cancel_" else p.name);
            if (i > 0) try args.writer.writeAll(", ");
            const keep = if (p.keep) "true" else "false";
            if (p.inoutType()) |inner| if (!p.nullable()) {
                // Copied in and back out, since what the plain one points at can move
                const rt = try g.ty(inner);
                try temps.writer.print("{s}var __t{d} = ({s}*)__a.Alloc((nuint)sizeof({s}), 16);\n{s}*__t{d} = {s};\n", .{ indent, i, rt, rt, indent, i, try g.lower(inner, pn, keep) });
                try args.writer.print("__t{d}", .{i});
                try after.writer.print("{s}{s} = {s};\n", .{ indent, pn, try g.lift(inner, try g.fmt("*__t{d}", .{i}), "false") });
                continue;
            };
            try args.writer.writeAll(try g.lower(p.type, pn, keep));
        }
        // Memory for the call, only when something's converted into it
        if (std.mem.indexOf(u8, temps.written(), "__a") != null or std.mem.indexOf(u8, args.written(), "__a") != null)
            try g.print("{s}using var __s = {s}Scratch.Enter();\n{s}var __a = __s.Allocator;\n{s}", .{ indent, sal, indent, temps.written() });
        const mn = try g.ident(m.name);
        if (m.async) {
            try g.print("{s}var __p = {s}.{s}({s});\n{s}", .{ indent, target, mn, args.written(), after.written() });
            const fail = if (m.signature.ret == .result) try g.fmt("{s}.Raise", .{try g.errorRef(m)}) else sal ++ "Promises.Fail";
            const ok: ?Ref = if (m.signature.ret == .result) resultOk(m.signature.ret) else if (isVoid(m.signature.ret)) null else m.signature.ret;
            const o = ok orelse return g.print("{s}return {s}Promises.AwaitVoid(__p, cancel, {s});\n", .{ indent, sal, fail });
            const w = try g.ty(o);
            const pointer = std.mem.endsWith(u8, w, "*");
            const got = try g.lift(o, if (pointer) try g.fmt("({s})__w", .{w}) else "__w", "true");
            return g.print("{s}return {s}Promises.Await<{s}, {s}>(__p, cancel, {s}, static __w => {s});\n", .{ indent, sal, if (pointer) "nint" else w, try g.plain(o, .ret), fail, got });
        }
        if (m.signature.ret == .result) {
            const sep = if (args.written().len > 0) ", " else "";
            if (resultOk(m.signature.ret)) |ok| {
                try g.print("{s}{s} __o;\n{s}var __code = {s}.{s}({s}{s}&__o);\n{s}", .{ indent, try g.ty(ok), indent, target, mn, args.written(), sep, after.written() });
                try g.print("{s}if (__code != 0) throw {s}.Raise(__code);\n{s}return {s};\n", .{ indent, try g.errorRef(m), indent, try g.lift(ok, "__o", "true") });
            } else {
                try g.print("{s}var __code = {s}.{s}({s});\n{s}", .{ indent, target, mn, args.written(), after.written() });
                try g.print("{s}if (__code != 0) throw {s}.Raise(__code);\n", .{ indent, try g.errorRef(m) });
            }
            return;
        }
        if (isVoid(m.signature.ret)) return g.print("{s}{s}.{s}({s});\n{s}", .{ indent, target, mn, args.written(), after.written() });
        try g.print("{s}var __r = {s}.{s}({s});\n{s}{s}return {s};\n", .{ indent, target, mn, args.written(), after.written(), indent, try g.lift(m.signature.ret, "__r", "true") });
    }

    /// A raw method calling plain `invoke`, converting both ways. `arena` is the adapter's arena for what it gives back.
    fn adapterMethod(g: *Gen, m: *const Schema.Method, invoke: []const u8, arena: usize) Error!void {
        const p = try g.params(m);
        try g.print("\n        public {s} {s}({s})\n        {{\n", .{ try g.retType(m), try g.ident(m.name), p.decl });
        const has_inout = for (m.signature.params) |x| {
            if (x.inoutType() != null and !x.nullable()) break true;
        } else false;
        // What it gives back stays good till it's called again
        if (!m.async and (!isVoid(m.signature.ret) or has_inout)) try g.print("            var __a = salamander_keep({d});\n", .{arena});
        var args: std.Io.Writer.Allocating = .init(g.a);
        var after: std.Io.Writer.Allocating = .init(g.a);
        for (m.signature.params, 0..) |x, i| {
            const pn = try g.local(x.name);
            if (i > 0) try args.writer.writeAll(", ");
            if (x.inoutType()) |inner| if (!x.nullable()) {
                try g.print("            var __v{d} = {s};\n", .{ i, try g.lift(inner, try g.fmt("*{s}", .{pn}), "false") });
                try args.writer.print("ref __v{d}", .{i});
                try after.writer.print("            *{s} = {s};\n", .{ pn, try g.lower(inner, try g.fmt("__v{d}", .{i}), "false") });
                continue;
            };
            try args.writer.writeAll(try g.lift(x.type, pn, if (x.keep) "true" else "false"));
        }
        const call = try g.fmt("{s}({s})", .{ invoke, args.written() });
        if (m.async) {
            const code_of = if (m.signature.ret == .result) try g.fmt("{s}.CodeOf", .{try g.errorRef(m)}) else sal ++ "Promises.CodeOf";
            const cancel = try g.fmt("{s}{s}Threading.CancellationToken.None", .{ if (m.signature.params.len > 0) ", " else "", sys });
            const async_call = try g.fmt("{s}({s}{s})", .{ invoke, args.written(), cancel });
            const ok: ?Ref = if (m.signature.ret == .result) resultOk(m.signature.ret) else if (isVoid(m.signature.ret)) null else m.signature.ret;
            const o = ok orelse return g.print("            return {s}Promises.MakeVoid({s}, {s});\n        }}\n", .{ sal, async_call, code_of });
            const w = try g.ty(o);
            const pointer = std.mem.endsWith(u8, w, "*");
            const lowered = try g.lower(o, "__x", "true");
            return g.print("            return {s}Promises.Make<{s}, {s}>({s}, static ({s} __x, {s}IAllocator __a) => {s}, {s});\n        }}\n", .{
                sal, if (pointer) "nint" else w, try g.plain(o, .ret), async_call, try g.plain(o, .ret), sal, if (pointer) try g.fmt("(nint)({s})", .{lowered}) else lowered, code_of,
            });
        }
        if (m.signature.ret == .result) {
            try g.print("            try\n            {{\n", .{});
            if (resultOk(m.signature.ret)) |ok| {
                try g.print("                var __r = {s};\n{s}                *@out = {s};\n", .{ call, after.written(), try g.lower(ok, "__r", "true") });
            } else try g.print("                {s};\n{s}", .{ call, after.written() });
            try g.print("                return 0;\n            }}\n            catch ({s}Exception __e)\n            {{\n                return {s}.CodeOf(__e);\n            }}\n        }}\n", .{ sys, try g.errorRef(m) });
            return;
        }
        if (isVoid(m.signature.ret)) return g.print("            {s};\n{s}        }}\n", .{ call, after.written() });
        try g.print("            var __r = {s};\n{s}            return {s};\n        }}\n", .{ call, after.written(), try g.lower(m.signature.ret, "__r", "true") });
    }

    /// The arenas an adapter keeps what it gives back in, one per method.
    fn adapterArenas(g: *Gen, count: usize) Error!void {
        try g.print(
            \\
            \\        readonly {s}Arena?[] salamander_arenas = new {s}Arena?[{d}];
            \\
            \\        {s}Arena salamander_keep(int i)
            \\        {{
            \\            var a = salamander_arenas[i] ??= new();
            \\            a.Reset();
            \\            return a;
            \\        }}
            \\
        , .{ sal, sal, @max(count, 1), sal });
    }

    /// The plugin's instance, for a `[Root]` trait and the traits its methods give. The root's is set as the plugin starts.
    fn instance(g: *Gen, t: *const Schema.Trait, n: []const u8) Error!void {
        if (t.root) return g.print(
            \\
            \\    /// <summary>The plugin's own, set as it starts. Null before then.</summary>
            \\    public static {s}? Instance {{ get; internal set; }}
            \\
        , .{n});
        for (g.o.singletons) |s| if (std.mem.eql(u8, s, t.name)) return g.print(
            \\
            \\    /// <summary>The one the host gives this plugin, like a plugin it depends on offers. Throws if there's none.</summary>
            \\    public static {s} Instance => global::Salamander.Singletons.Get<{s}>();
            \\
        , .{ n, n });
        const a = g.s.accessorOf(t.name) orelse return;
        const root = try g.plainRef(a.root.name);
        const method = (try g.plainSig(a.method, a.method.name, null)).name;
        try g.print(
            \\
            \\    /// <summary>The plugin's own, the same as {s}.Instance.{s}().</summary>
            \\    public static {s} Instance => {s}.Instance?.{s}() ?? throw new {s}InvalidOperationException("There's no {s} till the plugin's started");
            \\
        , .{ try g.leaf(a.root.name), method, n, root, method, sys, t.name });
    }

    /// A trait's class, wrapping its raw object, and its interface.
    fn wrapper(g: *Gen, t: *const Schema.Trait) Error!void {
        const n = try g.leaf(t.name);
        const raw = try g.rawRef(try g.bare(t.name));
        const raw_i = try g.fmt("{s}.I{s}", .{ try g.rawNs(), try g.bare(t.name) });
        var buf: [plan.max_methods]*const Schema.Method = undefined;
        const ms = plan.methods(g.s, t, &buf);
        for (ms) |m| {
            const pn = (try g.plainSig(m, m.name, null)).name;
            // The core's classes don't have Provided and Provide
            const taken = if (g.o.core) contains(wrapper_members[0..6], pn) or std.mem.eql(u8, pn, "Adapter") else contains(&wrapper_members, pn);
            if (taken or std.mem.eql(u8, pn, n)) {
                g.diag.print("{s}.{s}: C#'s {s} class has its own member called {s}", .{ t.name, m.name, n, pn });
                return error.NameClash;
            }
        }
        try g.print(
            \\
            \\public sealed unsafe partial class {s} : {s}IDisposable, {s}ITrait<{s}>
            \\{{
            \\    /// <summary>What it wraps, which crosses as it is.</summary>
            \\    public {s} Raw;
            \\
            \\    // 0 when it's lent, 1 when it's ours to let go of, 2 when it was made here
            \\    readonly byte how;
            \\
            \\    {s}({s} raw, byte how)
            \\    {{
            \\        Raw = raw;
            \\        this.how = how;
            \\    }}
            \\
            \\    /// <summary>Null without a table. owned when it came from a return or a keep parameter.</summary>
            \\    public static {s}? FromRaw({s} raw, bool owned = false) => raw.table == null ? null : new(raw, owned ? (byte)1 : (byte)0);
            \\
            \\    public static string TraitName => "{s}";
            \\
            \\    public static {s}? FromObject({s}AnyObject o, bool owned = false) => FromRaw({s}.FromObject(o), owned);
            \\
            \\    /// <summary>One that calls impl. Dispose it once nothing's going to call it, unless it went to a keep parameter.</summary>
            \\    public static {s} From(I{s} impl) => new({s}.Of(new Adapter(impl)), 2);
            \\
            \\    /// <summary>Lets go of it: frees one made with From, or releases one that was the caller's.</summary>
            \\    public void Dispose()
            \\    {{
            \\        var r = Raw;
            \\        Raw = default;
            \\        if (r.table == null) return;
            \\        if (how == 2) {s}.Free(r);
            \\        else if (how == 1) {s}Runtime.Release(r.AsObject());
            \\    }}
            \\
        , .{ n, sys, sal, n, raw, n, raw, n, raw, t.name, n, sal, raw, n, n, raw, raw, sal });
        if (!g.o.core) try g.print(
            \\
            \\    /// <summary>The one the host has as name, or null.</summary>
            \\    public static {s}? Provided(string name, uint major)
            \\    {{
            \\        using var __s = {s}Scratch.Enter();
            \\        return FromRaw({s}.FromObject({s}Runtime.Host.get({s}Str.From(name, __s.Allocator), major, {s}.Info)));
            \\    }}
            \\
            \\    /// <summary>Has the host give it out as name. Made with From after Runtime.Init, so it has an owner.</summary>
            \\    public void Provide(string name, uint major)
            \\    {{
            \\        using var __s = {s}Scratch.Enter();
            \\        var code = {s}Runtime.Host.provide({s}Str.From(name, __s.Allocator), major, Raw.AsObject());
            \\        if (code != 0) throw new {s}InvalidOperationException(code switch
            \\        {{
            \\            1 => $"{{name}} is taken",
            \\            2 => "out of memory",
            \\            _ => "it has no owner, so make it with From after Runtime.Init",
            \\        }});
            \\    }}
            \\
        , .{ n, sal, raw, sal, sal, raw, sal, sal, sal, sys });
        if (!g.o.core) try g.instance(t, n);

        for (ms) |m| {
            try g.print("\n    public {s}\n    {{\n", .{(try g.methodDecl(m, " = default")).text.?});
            try g.callBody(m, "Raw", "        ");
            try g.print("    }}\n", .{});
        }

        try g.print("\n    sealed class Adapter : {s}\n    {{\n        readonly I{s} impl;\n\n        public Adapter(I{s} impl) => this.impl = impl;\n", .{ raw_i, n, n });
        try g.adapterArenas(ms.len);
        for (ms, 0..) |m, i| if (!m.static) try g.adapterMethod(m, try g.fmt("impl.{s}", .{(try g.plainSig(m, m.name, null)).name}), i);
        try g.print("    }}\n}}\n", .{});

        try g.print("\npublic unsafe interface I{s}", .{n});
        var first = true;
        for (t.bases) |b| if (g.s.findTrait(b) != null) {
            try g.print("{s}{s}", .{ if (first) " : " else ", ", try g.plainRefWith(b, "I") });
            first = false;
        };
        try g.print("\n{{\n", .{});
        for (ms) |m| {
            if (m.static or !g.ownMethod(m, t.bases)) continue;
            const d = try g.methodDecl(m, "");
            try g.print("    {s}{s}\n", .{ d.text.?, try g.plainDefault(m, d.type.?) });
        }
        try g.print("}}\n", .{});
    }

    /// A struct that holds what needs converting, as a class with its raw twin in `Raw`.
    fn twinDef(g: *Gen, t: *const Schema.Type) Error!void {
        const n = try g.leaf(t.name);
        const raw = try g.rawRef(try g.bare(t.name));
        const raw_n = try g.ident(try g.bare(t.name));
        try g.print("\npublic sealed unsafe partial class {s}\n{{\n", .{n});
        var fields: std.ArrayList(Schema.Field) = .empty;
        var it: plan.Slots = .init(g.s, t);
        while (it.next()) |slot| if (slot == .field) {
            const f = slot.field.field;
            if (f.type == .array and (f.type.array.count != null or f.type.array.len == 0)) continue;
            try fields.append(g.a, f);
            const d = try g.fieldDecl(t, f);
            const p = d.type.?;
            const initial: []const u8 = if (optional(p)) "" else if (std.mem.endsWith(u8, p, "[]")) " = [];" else if (std.mem.eql(u8, p, "string")) " = \"\";" else if (f.type == .named and g.kindOf(f.type.named) == .twin) " = new();" else "";
            try g.print("    public {s} {{ get; set; }}{s}\n", .{ d.text.?, initial });
        };
        try g.print("\n    public unsafe {s} ToRaw({s}IAllocator __a, bool __keep = false) => new()\n    {{\n", .{ raw, sal });
        for (fields.items) |f| try g.print("        {s} = {s},\n", .{ try g.member(raw_n, f.name), try g.lower(f.type, try g.member(n, try g.pascal(f.name)), "__keep") });
        try g.print("    }};\n\n    public static unsafe {s} FromRaw(in {s} __r) => new()\n    {{\n", .{ try g.plainRef(t.name), raw });
        for (fields.items) |f| try g.print("        {s} = {s},\n", .{ try g.member(n, try g.pascal(f.name)), try g.lift(f.type, try g.fmt("__r.{s}", .{try g.member(raw_n, f.name)}), "false") });
        try g.print("    }};\n}}\n", .{});
    }

    fn delegateDef(g: *Gen, n: []const u8, sig: Schema.Signature) Error!void {
        const m: Schema.Method = .{ .name = "call", .signature = sig };
        const ps = try g.plainSig(&m, "call", null);
        try g.print("\npublic unsafe delegate {s} {s}({s});\n", .{ ps.ret, n, ps.decl });
    }

    /// Converting slices, arrays and function values, which need more than an expression.
    fn converters(g: *Gen) Error!void {
        try g.print("\ninternal static unsafe class SalamanderConvert\n{{\n", .{});
        for (g.slices.items) |x| {
            const r: Ref = .{ .slice = &x.ref };
            if (try g.asIs(r)) continue;
            const raw = try g.rawRef(x.name);
            const t = try g.ty(x.ref);
            if (g.same(x.ref)) {
                try g.print(
                    \\    public static {s} Lower_{s}({s}ReadOnlySpan<{s}> s, {s}IAllocator __a, bool __keep) => new() {{ ptr = {s}AllocatorExtensions.Copy(__a, s), len = (nuint)s.Length }};
                    \\
                    \\    public static {s}[] Lift_{s}({s} s) => s.len == 0 ? [] : new {s}ReadOnlySpan<{s}>(s.ptr, checked((int)s.len)).ToArray();
                    \\
                    \\
                , .{ raw, x.name, sys, t, sal, sal, t, x.name, raw, sys, t });
                continue;
            }
            const p = try g.plain(x.ref, .field);
            try g.print(
                \\    public static {s} Lower_{s}({s}Collections.Generic.IReadOnlyList<{s}>? s, {s}IAllocator __a, bool __keep)
                \\    {{
                \\        if (s == null || s.Count == 0) return default;
                \\        var p = ({s}*)__a.Alloc((nuint)(sizeof({s}) * s.Count), 16);
                \\        for (var i = 0; i < s.Count; i++) p[i] = {s};
                \\        return new() {{ ptr = p, len = (nuint)s.Count }};
                \\    }}
                \\
                \\    public static {s}[] Lift_{s}({s} s)
                \\    {{
                \\        var r = new {s}[checked((int)s.len)];
                \\        for (var i = 0; i < r.Length; i++) r[i] = {s};
                \\        return r;
                \\    }}
                \\
                \\
            , .{ raw, x.name, sys, p, sal, t, t, try g.lower(x.ref, "s[i]", "__keep"), p, x.name, raw, arrayOf(p), try g.lift(x.ref, "s.ptr[i]", "false") });
        }
        for (g.arrays.items) |x| {
            if (try g.asIs(x.ref)) continue;
            const raw = try g.rawRef(x.name);
            const child = x.ref.array.child.*;
            const p = try g.plain(child, .field);
            try g.print(
                \\    public static {s} Lower_{s}({s}[]? s, {s}IAllocator __a, bool __keep)
                \\    {{
                \\        {s} r = default;
                \\        if (s != null) for (var i = 0; i < {s}Math.Min(s.Length, {d}); i++) r[i] = {s};
                \\        return r;
                \\    }}
                \\
                \\    public static {s}[] Lift_{s}({s} s)
                \\    {{
                \\        var r = new {s}[{d}];
                \\        for (var i = 0; i < {d}; i++) r[i] = {s};
                \\        return r;
                \\    }}
                \\
                \\
            , .{ raw, x.name, p, sal, raw, sys, x.ref.array.len, try g.lower(child, "s[i]", "__keep"), p, x.name, raw, arrayOf(p), x.ref.array.len, x.ref.array.len, try g.lift(child, "s[i]", "false") });
        }
        if (!g.o.core) for (g.fns.list.items) |f| if (!f.base) try g.fnConverters(f);
        try g.print("}}\n", .{});
    }

    /// `new T[n]` for an array of `p`, which C# writes with the length before a `?`.
    fn arrayOf(p: []const u8) []const u8 {
        return p;
    }

    fn fnConverters(g: *Gen, f: Extra) Error!void {
        const d = try g.delegateRef(f);
        const raw = try g.rawRef(f.name);
        const m: Schema.Method = .{ .name = "call", .signature = g.sigOf(f) };
        try g.print(
            \\    public static {s} Lower_{s}({s}? __d, {s}IAllocator __a, bool __keep)
            \\    {{
            \\        if (__d == null) return default;
            \\        var __o = __keep ? {s}.Of(new Adapter_{s}(__d)) : {s}.Unowned(new Adapter_{s}(__d));
            \\        if (!__keep) __a.Defer(__o.data);
            \\        return __o;
            \\    }}
            \\
            \\    public static {s}? Lift_{s}({s} __f)
            \\    {{
            \\        if (__f.table == null) return null;
            \\
        , .{ raw, f.name, d, sal, raw, f.name, raw, f.name, d, f.name, raw });
        const sig = try g.plainSig(&m, "call", null);
        try g.print("        return ({s}) =>\n        {{\n", .{sig.decl});
        try g.callBody(&m, "__f", "            ");
        try g.print("        }};\n    }}\n", .{});
        try g.print("\n    sealed class Adapter_{s} : {s}.I{s}\n    {{\n        readonly {s} f;\n\n        public Adapter_{s}({s} f) => this.f = f;\n", .{ f.name, try g.rawNs(), f.name, d, f.name, d });
        try g.adapterArenas(1);
        try g.adapterMethod(&m, "f", 0);
        try g.print("    }}\n\n", .{});
    }
};

//// How C# names and declares each thing, from the same builders the writer uses. `a` should be an arena.
pub const Names = struct {
    g: *Gen,

    pub fn init(a: std.mem.Allocator, s: Schema, options: Options, diagnostic: ?*Schema.Diagnostic) Error!Names {
        const g = try a.create(Gen);
        g.* = .init(s, try lang.sink(a), a, options, diagnostic orelse try a.create(Schema.Diagnostic));
        try g.file();
        return .{ .g = g };
    }

    /// Without the `global::` generated code roots names with.
    fn tidy(n: *const Names, d: lang.Decl) Error!?lang.Decl {
        return try lang.tidied(n.g.a, d, lang.unrooted);
    }

    fn named(n: *const Names, full: []const u8) Error!?lang.Decl {
        return n.tidy(.{ .name = try n.g.leaf(full), .path = try n.g.plainRef(full) });
    }

    pub fn typeName(n: *const Names, t: *const Schema.Type) Error!?lang.Decl {
        return n.named(t.name);
    }

    pub fn traitName(n: *const Names, t: *const Schema.Trait) Error!?lang.Decl {
        return n.named(t.name);
    }

    pub fn method(n: *const Names, _: *const Schema.Trait, m: *const Schema.Method) Error!?lang.Decl {
        return n.tidy(try n.g.methodDecl(m, " = default"));
    }

    pub fn field(n: *const Names, t: *const Schema.Type, f: *const Schema.Field) Error!?lang.Decl {
        return n.tidy(try n.g.fieldDecl(t, f.*));
    }

    /// An enum's value or an error's code, `Type.Name`, or a bitfield's property.
    pub fn member(n: *const Names, t: *const Schema.Type, name: []const u8) Error!?lang.Decl {
        const g = n.g;
        const leaf = try g.leaf(t.name);
        if (t.kind == .bitfield) return .{ .name = try g.member(leaf, try g.pascal(name)) };
        const v = try g.pascal(name);
        return n.tidy(.{ .name = v, .path = try g.fmt("{s}.{s}", .{ try g.plainRef(t.name), v }) });
    }

    pub fn function(n: *const Names, in: ?*const Schema.Type, m: *const Schema.Method) Error!?lang.Decl {
        return n.tidy(try n.g.declaredDecl(in, m));
    }

    pub fn static(n: *const Names, in: ?*const Schema.Type, v: *const Schema.Static) Error!?lang.Decl {
        return n.tidy(try n.g.staticDecl(in, v));
    }

    pub fn constant(n: *const Names, c: *const Schema.Constant) Error!?lang.Decl {
        return n.tidy(try n.g.constantDecl(c.*));
    }
};

test "writes C#" {
    var diag: Schema.Diagnostic = .{};
    var parsed = try salamander_schema.parse(std.testing.allocator,
        \\struct Vec3 { f32 x; f32 y; f32 z; }
        \\struct Party { u8 size; [0x8] u32[4] ids; bool open; }
        \\struct Tagged { string tag; []u32 ids; Vec3 at; }
        \\error LoadError { NotFound, Corrupt = 7 }
        \\enum Job : u8 { warrior = 1, mage }
        \\bitfield Flags : u32 { bool alive; [Bit(4)] u8 level; Job job : 2; }
        \\const f32 gravity = -9.8;
        \\namespace Scene { struct Node { u32 id; } }
        \\trait Mover {
        \\    [Thiscall] Vec3 move(Vec3 by, string int);
        \\    Vec3!LoadError load();
        \\    void each(fn(u32 n) bool visit);
        \\    ?u32 find();
        \\    async string fetch(string url);
        \\    u32 sum([]u32 ids);
        \\    void bump(inout Vec3 v);
        \\}
    , .{ .pointer_size = 8 }, &diag);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, parsed.schema, &out.writer, .{ .label = "test.sal", .namespace = "Game" }, &diag);
    const text = out.written();
    const want = [_][]const u8{
        "public const float Gravity = -9.8f;",
        // Shared structs are PascalCase, in the plain namespace
        "[global::System.Runtime.InteropServices.FieldOffset(0x8)] public float Z;",
        "[global::System.Runtime.InteropServices.FieldOffset(0x8)] public global::Game.Raw.u32x4 Ids;",
        "[global::System.Runtime.InteropServices.FieldOffset(0x18)] public global::Salamander.Bool Open;",
        "    Corrupt = 7,",
        "public enum Job : byte",
        "readonly get => (global::Game.Job)(((ulong)Raw >> 12) & 0x3UL);",
        // A schema namespace is its own, not inside the home one
        "namespace Scene\n{\n",
        // Tagged holds a string and a slice, so it's a class with a raw twin
        "public sealed unsafe partial class Tagged\n{\n    public string Tag { get; set; } = \"\";\n    public uint[] Ids { get; set; } = [];",
        "        tag = global::Salamander.Str.From(Tag, __a),",
        "public sealed class LoadErrorException : global::Salamander.SalamanderException",
        "        7 => new LoadErrorException(global::Game.LoadError.Corrupt, global::Salamander.Runtime.Explanation(\"Corrupt\")),",
        // The raw layer keeps the schema's names
        "namespace Game.Raw\n{\n",
        "public delegate* unmanaged[Thiscall]<nuint, global::Game.Vec3, global::Salamander.Str, global::Game.Vec3> move;",
        "public delegate* unmanaged[Cdecl]<nuint, global::Game.Vec3*, uint> load;",
        "public readonly global::Game.Vec3 move(global::Game.Vec3 by, global::Salamander.Str @int)",
        // The plain class converts
        "    public global::Game.Vec3 Move(global::Game.Vec3 by, string @int)",
        "        var __r = Raw.move(by, global::Salamander.Str.From(@int, __a));",
        "        if (__code != 0) throw global::Game.LoadErrorException.Raise(__code);",
        "    public uint? Find()",
        "    public global::System.Threading.Tasks.Task<string> FetchAsync(string url, global::System.Threading.CancellationToken cancel = default)",
        "    public uint Sum(global::System.ReadOnlySpan<uint> ids)",
        "    public void Bump(ref global::Game.Vec3 v)",
        "    public void Each(global::Game.MoverEachVisit? visit)",
        "public unsafe delegate bool MoverEachVisit(uint n);",
        // What an implementation leaves out gives what a missing method does
        "public unsafe interface IMover\n{\n    global::Game.Vec3 Move(global::Game.Vec3 by, string @int) => default!;",
        "    global::System.Threading.Tasks.Task<string> FetchAsync(string url, global::System.Threading.CancellationToken cancel) => global::System.Threading.Tasks.Task.FromResult<string>(\"\");",
    };
    for (want) |part| if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing:\n{s}\n\nin:\n{s}\n", .{ part, text });
        return error.TestUnexpectedResult;
    };
}

test "a root's traits each have their Instance" {
    var diag: Schema.Diagnostic = .{};
    var parsed = try salamander_schema.parse(std.testing.allocator,
        \\namespace Host;
        \\trait Tweaks { u32 count(); }
        \\trait Ui { void draw(); }
        \\[Root] trait Api { Tweaks tweaks(); Ui ui(); u32 version(); }
    , .{ .pointer_size = 8 }, &diag);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, parsed.schema, &out.writer, .{ .namespace = "Host" }, &diag);
    const text = out.written();
    for ([_][]const u8{
        "namespace Host\n{\n",
        "public static Api? Instance { get; internal set; }",
        "public static Tweaks Instance => global::Host.Api.Instance?.Tweaks() ?? throw new global::System.InvalidOperationException(\"There's no Host.Tweaks till the plugin's started\");",
        "public static Ui Instance => global::Host.Api.Instance?.Ui() ??",
    }) |part| if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing:\n{s}\n\nin:\n{s}\n", .{ part, text });
        return error.TestUnexpectedResult;
    };
}

test "a singleton trait's Instance reads what the host set" {
    var diag: Schema.Diagnostic = .{};
    var parsed = try salamander_schema.parse(std.testing.allocator, "namespace Freecam;\ntrait Camera { void reset(); }\ntrait Other { void go(); }", .{ .pointer_size = 8 }, &diag);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, parsed.schema, &out.writer, .{ .namespace = "Plugin", .singletons = &.{"Freecam.Camera"} }, &diag);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "public static Camera Instance => global::Salamander.Singletons.Get<Camera>();") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Other Instance") == null);
}

test "types from an aliased file are used from its namespace" {
    const source =
        \\file "host/api.sal";
        \\struct Vec3 { f32 x; f32 y; f32 z; }
        \\struct Named { string name; }
        \\trait Settings { u32 count(); }
        \\file "pose.sal";
        \\struct Pose { Vec3 at; Named who; }
        \\trait Poser { void watch(keep Settings s); Vec3 where(); }
    ;
    var diag: Schema.Diagnostic = .{};
    var parsed = try salamander_schema.parse(std.testing.allocator, source, .{ .pointer_size = 8 }, &diag);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, parsed.schema, &out.writer, .{ .namespace = "Plugin", .source = source, .aliases = &.{.{ .prefix = "host/", .namespace = "Host.Api" }} }, &diag);
    const text = out.written();
    for ([_][]const u8{
        "public global::Host.Api.Vec3 At { get; set; }",
        "[global::System.Runtime.InteropServices.FieldOffset(0x10)] public global::Host.Api.Raw.Named who;",
        "public global::Host.Api.Named Who { get; set; } = new();",
        "public void Watch(global::Host.Api.Settings? s)",
        "public delegate* unmanaged[Cdecl]<nuint, global::Host.Api.Raw.Settings, void> watch;",
    }) |part| if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing:\n{s}\n\nin:\n{s}\n", .{ part, text });
        return error.TestUnexpectedResult;
    };
    // Written once, where the alias says
    for ([_][]const u8{ "struct Vec3", "class Named", "class Settings", "struct Settings" }) |part| try std.testing.expect(std.mem.indexOf(u8, text, part) == null);
}

test "what existing code declares is found by name, called, and hooked" {
    var diag: Schema.Diagnostic = .{};
    var parsed = try salamander_schema.parse(std.testing.allocator,
        \\struct Player {
        \\    usize vt;
        \\    [game.Sig("90")] void heal(f32 amount);
        \\    [Virtual(3)] i32 damage(i32 amount);
        \\    [game.Sig("91")] static Player* local;
        \\    [game.Sig("92")] static u32 count;
        \\}
        \\[game.Sig("93")] i32 spawn(u32 kind, string name);
    , .{ .pointer_size = 8, .any_namespace = true }, &diag);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, parsed.schema, &out.writer, .{ .namespace = "Game" }, &diag);
    const text = out.written();
    for ([_][]const u8{
        "public static nuint Heal() => global::Salamander.Declared.Address(\"Player.heal\");",
        "public static delegate* unmanaged[Cdecl]<global::Game.Player*, float, void> HealAt(nuint at)",
        "        var __self = (Player*)global::System.Runtime.CompilerServices.Unsafe.AsPointer(ref this);\n        HealAt(global::Salamander.Declared.Address(\"Player.heal\"))(__self, amount);",
        "DamageAt(global::Salamander.Declared.Virtual(__self, 3))(__self, amount);",
        "public static global::Game.Player* Local() => *(global::Game.Player**)global::Salamander.Declared.Address(\"Player.local\");",
        "public static uint* Count() => (uint*)global::Salamander.Declared.Address(\"Player.count\");",
        "public static global::Salamander.AnyObject HealHandler(",
        // Each as a value, with handlers of its type
        "        public static readonly HealFn Heal = new();",
        "        public sealed class HealFn : global::Salamander.DeclaredFunction<",
        "            internal HealFn() : base(\"Player.heal\") { }",
        "                public delegate* unmanaged[Cdecl]<global::Game.Player*, float, void> Original() =>",
        "            public delegate void HookedHandler(Hooked hook, global::Game.Player* self, float amount);",
        "=> HealHandler((global::Game.Player* self, float amount) => handler(new Hooked(cell), self, amount));",
        // Top-level ones go in the schema's class, with strings converted
        "    public static int Spawn(uint kind, string name)",
        "SpawnAt(global::Salamander.Declared.Address(\"spawn\"))(kind, global::Salamander.Str.From(name, __a));",
    }) |part| if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing:\n{s}\n\nin:\n{s}\n", .{ part, text });
        return error.TestUnexpectedResult;
    };
}

test "Names give what the writer declares" {
    const make = struct {
        fn make(a: std.mem.Allocator, s: Schema) anyerror!Names {
            return .init(a, s, .{}, null);
        }
    }.make;
    try lang.expectNames(Names, make, .{
        .method = "uint Count(string who)",
        .field = "uint Hp",
        .function = "bool Heal(uint amount)",
        .static = "static G.Player* Instance()",
        .constant = "const uint GMaxPlayers",
    });
}
