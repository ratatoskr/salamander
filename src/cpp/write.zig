//! A schema as a C++20 header over `salamander.hpp`, laid out by the same plan as Zig and C, checked with `static_assert`s.
//! Types go in the schema's namespaces. What crosses is an aggregate, so it's passed like C's. Trait objects get
//! methods taking plain C++, and any class implements a trait with the methods it has.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const lang = @import("salamander_lang");

const Schema = salamander_schema.Schema;
const plan = salamander_schema.plan;
const Ref = Schema.Ref;

pub const Error = std.Io.Writer.Error || error{ OutOfMemory, NameClash };

pub const Options = struct {
    /// Where it came from, for the header. Also names the include guard.
    label: []const u8 = "schema.sal",
    /// What was parsed, so `aliases` can tell which file each thing's in.
    source: []const u8 = "",
    /// Files whose types come from another header, included instead of written again.
    aliases: []const Alias = &.{},
    /// Where what has no schema namespace goes, like `Game` or `Game::Raw`. The top if empty.
    namespace: []const u8 = "",
    /// Writing the runtime's own `core.sal`, into `sal`.
    core: bool = false,
};

/// What files starting with `prefix` declare comes from `include`, like `wraith/` from `wraith.hpp`.
pub const Alias = struct {
    prefix: []const u8,
    include: []const u8,
};

pub fn write(gpa: std.mem.Allocator, s: Schema, w: *std.Io.Writer, options: Options, diagnostic: ?*Schema.Diagnostic) Error!void {
    var scratch: Schema.Diagnostic = .{};
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var g: Gen = .init(s, w, arena.allocator(), options, diagnostic orelse &scratch);
    try g.file();
}

const keywords = [_][]const u8{
    "alignas",     "alignof",   "and",              "and_eq",       "asm",      "auto",         "bitand",    "bitor",    "bool",     "break",
    "case",        "catch",     "char",             "char8_t",      "char16_t", "char32_t",     "class",     "compl",    "concept",  "const",
    "consteval",   "constexpr", "constinit",        "const_cast",   "continue", "co_await",     "co_return", "co_yield", "decltype", "default",
    "delete",      "do",        "double",           "dynamic_cast", "else",     "enum",         "explicit",  "export",   "extern",   "false",
    "float",       "for",       "friend",           "goto",         "if",       "inline",       "int",       "long",     "mutable",  "namespace",
    "new",         "noexcept",  "not",              "not_eq",       "nullptr",  "operator",     "or",        "or_eq",    "private",  "protected",
    "public",      "register",  "reinterpret_cast", "requires",     "return",   "short",        "signed",    "sizeof",   "static",   "static_assert",
    "static_cast", "struct",    "switch",           "template",     "this",     "thread_local", "throw",     "true",     "try",      "typedef",
    "typeid",      "typename",  "union",            "unsigned",     "using",    "virtual",      "void",      "volatile", "wchar_t",  "while",
    "xor",         "xor_eq",    "NULL",             "offsetof",     "assert",
};

/// What generated bodies call their own locals, so parameters don't.
const helper_locals = [_][]const u8{ "data", "table", "self", "o", "sal_r", "sal_out", "sal_c", "sal_p", "sal_v", "sal_site", "sal_f", "sal_at" };

/// What every trait object has, so its methods can't be called that.
const object_members = [_][]const u8{ "data", "table", "Table", "Thunks", "table_of", "of", "from_object", "object", "extends" };

const contains = lang.contains;
const isVoid = lang.isVoid;
const resultOk = lang.resultOk;
const conv = lang.cConv;
/// A function value C++ needs its own object for, named like `Scene.Picker_pick_visit` so it goes in its site's namespace.
const Extra = lang.Extra;

/// Where a name goes: its C++ namespace, and one identifier in it.
const Scope = struct {
    ns: []const u8,
    leaf: []const u8,
};

const Gen = struct {
    s: Schema,
    w: *std.Io.Writer,
    a: std.mem.Allocator,
    o: Options,
    diag: *Schema.Diagnostic,
    top: std.ArrayList([]const u8) = .empty,
    fns: lang.Fns = .{},
    /// The namespace open in the file, so neighbours share one block.
    cur: []const u8 = "",

    fn init(s: Schema, w: *std.Io.Writer, a: std.mem.Allocator, options: Options, diag: *Schema.Diagnostic) Gen {
        var g: Gen = .{ .s = s, .w = w, .a = a, .o = options, .diag = diag };
        if (options.core) g.o.namespace = "sal";
        return g;
    }

    fn print(g: *Gen, comptime f: []const u8, args: anytype) Error!void {
        try g.w.print(f, args);
    }

    fn fmt(g: *Gen, comptime f: []const u8, args: anytype) Error![]const u8 {
        return std.fmt.allocPrint(g.a, f, args);
    }

    fn aliased(g: *const Gen, at: Schema.Pos) bool {
        if (g.o.aliases.len == 0) return false;
        const file_name = Schema.fileOf(g.o.source, at);
        for (g.o.aliases) |a| if (std.mem.startsWith(u8, file_name, a.prefix)) return true;
        return false;
    }

    fn claim(g: *Gen, n: []const u8) Error!void {
        try lang.claim(g.a, &g.top, g.diag, n, "C++");
    }

    fn ident(g: *Gen, n: []const u8) Error![]const u8 {
        return if (contains(&keywords, n)) g.fmt("{s}_", .{n}) else n;
    }

    /// A parameter's name, kept off C++'s keywords and the bodies' locals.
    fn local(g: *Gen, n: []const u8) Error![]const u8 {
        return if (contains(&keywords, n) or contains(&helper_locals, n)) g.fmt("{s}_", .{n}) else n;
    }

    // Names

    /// Namespaces up to the first type or trait, then what's left as one identifier, like `Player_relation`.
    fn scopeOf(g: *Gen, name: []const u8) Error!Scope {
        const home = try g.cppPath(g.o.namespace);
        const end = Schema.namespaceEnd(name) orelse return .{ .ns = home, .leaf = try g.ident(try Schema.flatName(g.a, name)) };
        var ns: std.ArrayList(u8) = .empty;
        var start: usize = 0;
        while (start < end) {
            const dot = std.mem.indexOfScalarPos(u8, name[0..end], start, '.') orelse end;
            const prefix = name[0..dot];
            if (g.s.findType(prefix) != null or g.s.findTrait(prefix) != null) break;
            if (ns.items.len > 0) try ns.appendSlice(g.a, "::");
            try ns.appendSlice(g.a, name[start..dot]);
            start = dot + 1;
        }
        const leaf = try g.ident(try Schema.flatName(g.a, name[@min(start, name.len)..]));
        return .{ .ns = if (ns.items.len == 0) home else ns.items, .leaf = leaf };
    }

    fn cppPath(g: *Gen, ns: []const u8) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, ns, '.') == null) return ns;
        return std.mem.replaceOwned(u8, g.a, ns, ".", "::");
    }

    /// `::Scene::Node`, from anywhere.
    fn qual(g: *Gen, name: []const u8) Error![]const u8 {
        const sc = try g.scopeOf(name);
        return if (sc.ns.len == 0) g.fmt("::{s}", .{sc.leaf}) else g.fmt("::{s}::{s}", .{ sc.ns, sc.leaf });
    }

    /// Opens `ns` if it isn't already, closing the one before.
    fn enter(g: *Gen, ns: []const u8) Error!void {
        if (std.mem.eql(u8, g.cur, ns)) return;
        try g.close();
        if (ns.len > 0) try g.print("\nnamespace {s} {{\n", .{ns});
        g.cur = ns;
    }

    fn close(g: *Gen) Error!void {
        if (g.cur.len > 0) try g.print("\n}} // namespace {s}\n", .{g.cur});
        g.cur = "";
    }

    /// Opens where `name` goes and gives its identifier there.
    fn enterFor(g: *Gen, name: []const u8) Error![]const u8 {
        const sc = try g.scopeOf(name);
        try g.enter(sc.ns);
        return sc.leaf;
    }

    // Function values, each with one object

    fn fnOf(g: *Gen, sig: Schema.Signature) Extra {
        return g.fns.of(sig);
    }

    fn sigOf(g: *Gen, f: Extra) Schema.Signature {
        return lang.sigOf(g.s, f);
    }

    fn collect(g: *Gen, r: Ref, site: []const u8) Error!void {
        try lang.collect(g, g.a, g.s, r, site);
    }

    pub fn onFunc(g: *Gen, r: Ref, site: []const u8) Error!void {
        try g.fns.add(g.a, r, site);
    }

    // Types

    fn prim(p: Schema.Prim) []const u8 {
        return switch (p) {
            .u8 => "uint8_t",
            .u16 => "uint16_t",
            .u32 => "uint32_t",
            .u64 => "uint64_t",
            .i8 => "int8_t",
            .i16 => "int16_t",
            .i32 => "int32_t",
            .i64 => "int64_t",
            .f32 => "float",
            .f64 => "double",
            .bool => "bool",
            .usize => "uintptr_t",
            .isize => "intptr_t",
            .utf8 => "char",
            .utf16 => "char16_t",
            .string => "::sal::String",
            .object => "::sal::Object",
            .blob => "::sal::Blob",
            .any => "::sal::Any",
            .cstring => "const char *",
            .void => "void",
        };
    }

    fn bitfieldOf(g: *Gen, r: Ref) ?Schema.Bitfield {
        if (r != .named) return null;
        const t = g.s.findType(r.named) orelse return null;
        return if (t.kind == .bitfield) t.kind.bitfield else null;
    }

    /// `inner` is what's being declared so far, like a name. `abi` passes a bitfield as its backing int, since
    /// some ABIs pass even a one-int struct differently.
    fn decl(g: *Gen, r: Ref, inner: []const u8, abi: bool) Error![]const u8 {
        const sp: []const u8 = if (inner.len == 0) "" else " ";
        return switch (r) {
            .prim => |p| g.fmt("{s}{s}{s}", .{ prim(p), sp, inner }),
            .named => |n| if (abi and g.bitfieldOf(r) != null)
                g.fmt("{s}{s}{s}", .{ prim(g.bitfieldOf(r).?.backing), sp, inner })
            else
                g.fmt("{s}{s}{s}", .{ try g.qual(n), sp, inner }),
            .pointer => |c| if (c.* == .array) g.decl(c.*, try g.fmt("(*{s})", .{inner}), false) else g.decl(c.*, try g.fmt("*{s}", .{inner}), false),
            .array => |a| g.decl(a.child.*, try g.fmt("{s}[{d}]", .{ inner, a.len }), false),
            .slice => |c| g.fmt("::sal::Slice<{s}>{s}{s}", .{ try g.decl(c.*, "", false), sp, inner }),
            .optional => |c| if (c.* == .pointer or g.s.isObject(c.*)) g.decl(c.*, inner, abi) else g.fmt("::sal::Opt<{s}>{s}{s}", .{ try g.decl(c.*, "", false), sp, inner }),
            .func => |sig| g.fmt("{s}{s}{s}", .{ try g.qual(g.fnOf(sig.*).name), sp, inner }),
            .result => unreachable,
        };
    }

    /// Whether methods take and give it as plain C++ instead.
    fn converts(g: *Gen, r: Ref) bool {
        return switch (r) {
            .prim => |p| p == .string,
            .slice => true,
            .optional => |c| c.* != .pointer and !g.s.isObject(c.*),
            .named => g.bitfieldOf(r) != null,
            else => false,
        };
    }

    /// What methods take and give: views, spans and optionals for what converts, the rest as it crosses.
    fn plain(g: *Gen, r: Ref, inner: []const u8) Error![]const u8 {
        const sp: []const u8 = if (inner.len == 0) "" else " ";
        if (!g.converts(r)) return g.decl(r, inner, false);
        return switch (r) {
            .prim => g.fmt("std::string_view{s}{s}", .{ sp, inner }),
            .slice => |c| g.fmt("std::span<const {s}>{s}{s}", .{ try g.decl(c.*, "", false), sp, inner }),
            .optional => |c| g.fmt("std::optional<{s}>{s}{s}", .{ try g.plain(c.*, ""), sp, inner }),
            .named => |n| g.fmt("{s}{s}{s}", .{ try g.qual(n), sp, inner }),
            else => unreachable,
        };
    }

    /// Plain `e` as what crosses.
    fn lower(g: *Gen, r: Ref, e: []const u8) Error![]const u8 {
        if (!g.converts(r)) return e;
        if (r == .named) return g.fmt("{s}.bits", .{e});
        return g.fmt("::sal::lower({s})", .{e});
    }

    /// What crossed as plain.
    fn lift(g: *Gen, r: Ref, e: []const u8) Error![]const u8 {
        if (!g.converts(r)) return e;
        if (r == .named) return g.fmt("{s}{{{s}}}", .{ try g.qual(r.named), e });
        return g.fmt("::sal::lift({s})", .{e});
    }

    /// An async method's value and error set.
    fn asyncParts(g: *Gen, m: *const Schema.Method) Error!struct { []const u8, []const u8 } {
        const ok, const err = switch (m.signature.ret) {
            .result => |res| .{ res.ok.*, try g.qual(res.err) },
            else => .{ m.signature.ret, "::sal::Code" },
        };
        return .{ if (isVoid(ok)) "void" else try g.decl(ok, "", false), err };
    }

    /// What a method gives back in plain C++.
    fn plainRet(g: *Gen, m: *const Schema.Method) Error![]const u8 {
        if (m.async) {
            const ok, const err = try g.asyncParts(m);
            return g.fmt("::sal::Future<{s}, {s}>", .{ ok, err });
        }
        return switch (m.signature.ret) {
            .result => |res| g.fmt("::sal::Result<{s}, {s}>", .{ if (isVoid(res.ok.*)) "void" else try g.plain(res.ok.*, ""), try g.qual(res.err) }),
            else => g.plain(m.signature.ret, ""),
        };
    }

    /// `(uintptr_t, float, Vec3 *)`, a table entry's parameters, named if `named`.
    fn entryParams(g: *Gen, m: *const Schema.Method, named: bool) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(g.a);
        const w = &out.writer;
        try w.writeAll("(");
        var first = true;
        if (!m.static) {
            try w.writeAll(if (named) "uintptr_t self" else "uintptr_t");
            first = false;
        }
        for (m.signature.params) |p| {
            if (!first) try w.writeAll(", ");
            first = false;
            try w.writeAll(try g.decl(p.type, if (named) try g.local(p.name) else "", true));
        }
        if (!m.async) if (resultOk(m.signature.ret)) |ok| {
            if (!first) try w.writeAll(", ");
            first = false;
            try w.writeAll(try g.decl(.{ .pointer = &ok }, if (named) "sal_out" else "", false));
        };
        try w.writeAll(")");
        return out.written();
    }

    /// What a table entry gives: a code for results, a promise for async.
    fn retDecl(g: *Gen, m: *const Schema.Method, inner: []const u8) Error![]const u8 {
        if (m.async) return g.fmt("::sal::Promise {s}", .{inner});
        if (m.signature.ret == .result) return g.fmt("uint32_t {s}", .{inner});
        return g.decl(m.signature.ret, inner, true);
    }

    // The file

    fn file(g: *Gen) Error!void {
        const s = g.s;
        const guard = try std.fmt.allocPrint(g.a, "SALAMANDER_{s}_HPP", .{g.o.label});
        for (guard) |*c| c.* = if (std.ascii.isAlphanumeric(c.*)) std.ascii.toUpper(c.*) else '_';
        try g.print(
            \\// Generated by salamander from {s}. Don't edit it, it's written again every build.
            \\
            \\#ifndef {s}
            \\#define {s}
            \\
            \\
        , .{ g.o.label, guard, guard });
        try g.print("#include \"{s}\"\n", .{if (g.o.core) "salamander.hpp" else "salamander_runtime.hpp"});
        for (g.o.aliases, 0..) |a, i| {
            const seen = for (g.o.aliases[0..i]) |b| {
                if (std.mem.eql(u8, a.include, b.include)) break true;
            } else false;
            if (!seen) try g.print("#include \"{s}\"\n", .{a.include});
        }

        const laid_out = for (s.types) |t| {
            if (t.kind == .@"struct" or t.kind == .@"union") break true;
        } else false;
        if (laid_out) try g.print("\nstatic_assert(sizeof(void *) == {d}, \"these types are for {d}-bit code\");\n", .{ s.pointer_size, @as(usize, s.pointer_size) * 8 });

        // Named function types first, so their signatures keep their own names
        for (s.types) |t| if (t.kind == .func and !g.aliased(t.at)) {
            for (t.kind.func.params) |p| try g.collect(p.type, try g.fmt("{s}_{s}", .{ t.name, p.name }));
            try g.collect(t.kind.func.ret, t.name);
            try g.fns.list.append(g.a, .{ .name = t.name, .ref = .{ .named = t.name }, .hash = Schema.signatureHash(t.kind.func) });
        };
        for (s.types) |t| if (!g.aliased(t.at)) {
            try g.claim(try g.qual(t.name));
            switch (t.kind) {
                .@"struct", .@"union" => |st| for (st.fields) |f| try g.collect(f.type, try g.fmt("{s}_{s}", .{ t.name, f.name })),
                else => {},
            }
        };
        for (s.traits) |*t| if (!g.aliased(t.at)) {
            try g.claim(try g.qual(t.name));
            for (t.methods) |m| {
                for (m.signature.params) |p| try g.collect(p.type, try g.fmt("{s}_{s}_{s}", .{ t.name, m.name, p.name }));
                try g.collect(m.signature.ret, try g.fmt("{s}_{s}", .{ t.name, m.name }));
            }
        };
        for (s.constants) |k| if (!g.aliased(k.at)) try g.claim(try g.qual(k.name));
        for (s.types) |t| if (t.kind == .@"struct" and !g.aliased(t.at)) for (t.kind.@"struct".methods) |m| {
            for (m.signature.params) |p| try g.collect(p.type, try g.fmt("{s}_{s}_{s}", .{ t.name, m.name, p.name }));
            try g.collect(m.signature.ret, try g.fmt("{s}_{s}", .{ t.name, m.name }));
        };
        for (s.functions) |m| {
            for (m.signature.params) |p| try g.collect(p.type, try g.fmt("{s}_{s}", .{ m.name, p.name }));
            try g.collect(m.signature.ret, m.name);
        }
        for (g.fns.list.items) |f| if (f.ref == .func) try g.claim(try g.qual(f.name));

        // Everything with a name first, so order doesn't matter for pointers
        for (s.types) |t| if (!g.aliased(t.at)) switch (t.kind) {
            .@"struct", .@"opaque", .func => try g.print("struct {s};\n", .{try g.enterFor(t.name)}),
            .@"union" => try g.print("union {s};\n", .{try g.enterFor(t.name)}),
            else => {},
        };
        for (s.traits) |t| if (!g.aliased(t.at)) try g.print("struct {s};\n", .{try g.enterFor(t.name)});
        for (g.fns.list.items) |f| if (f.ref == .func) try g.print("struct {s};\n", .{try g.enterFor(f.name)});

        for (s.types) |*t| if (!g.aliased(t.at)) switch (t.kind) {
            .@"enum" => |e| try g.enumDef(t, e),
            .@"error" => |e| try g.errorDef(t, e),
            else => {},
        };
        for (s.types) |*t| if (!g.aliased(t.at) and t.kind == .bitfield) try g.bitfieldDef(t, t.kind.bitfield);
        for (s.constants) |k| if (!g.aliased(k.at)) try g.constant(k);

        // Objects are two words, and structs can hold them by value
        for (g.fns.list.items) |f| try g.objectDecl(f.name, null);
        for (s.traits) |*t| if (!g.aliased(t.at)) try g.objectDecl(t.name, t);

        var done: std.ArrayList([]const u8) = .empty;
        for (s.types) |*t| if (!g.aliased(t.at)) try g.structInOrder(t, &done, 0);

        for (g.fns.list.items) |f| {
            const m: Schema.Method = .{ .name = "call", .signature = g.sigOf(f) };
            const ms = [_]*const Schema.Method{&m};
            try g.objectDefs(f.name, &ms, 0, "fn", &.{Schema.signatureHash(m.signature)}, true);
        }
        for (s.traits) |*t| if (!g.aliased(t.at)) {
            var buf: [plan.max_methods]*const Schema.Method = undefined;
            const ms = plan.methods(g.s, t, &buf);
            const sigs = try g.a.alloc(u64, ms.len);
            for (ms, 0..) |m, i| sigs[i] = Schema.methodHash(m);
            try g.objectDefs(t.name, ms, g.s.traitHash(t), t.name, sigs, false);
        };
        try g.declared();
        try g.close();
        try g.typeInfos();

        try g.print("\n#endif\n", .{});
    }

    // Type info, `sal::TypeOf<T>::info` for each type, which `sal::Any` uses

    fn typeInfos(g: *Gen) Error!void {
        const s = g.s;
        var named: std.ArrayList(*const Schema.Type) = .empty;
        for (s.types) |*t| if (!g.aliased(t.at) and plan.ownsInfo(s, .{ .named = t.name })) try named.append(g.a, t);
        if (named.items.len == 0) return;
        try g.print("\n// Type info, for sal::Any\n", .{});
        for (named.items) |t| try g.print("template <> struct sal::TypeOf<{s}> {{\n    static const ::sal::TypeInfo info;\n}};\n", .{try g.qual(t.name)});
        var detail: std.Io.Writer.Allocating = .init(g.a);
        var o: InfoOut = .{ .g = g, .detail = &detail.writer };
        var defs: std.Io.Writer.Allocating = .init(g.a);
        for (named.items) |t| try defs.writer.print("inline const ::sal::TypeInfo sal::TypeOf<{s}>::info = {{ {s} }};\n", .{ try g.qual(t.name), try o.body(.{ .named = t.name }) });
        // Padding goes unnamed
        const quiet = "#if defined(__GNUC__) || defined(__clang__)\n#pragma GCC diagnostic push\n#pragma GCC diagnostic ignored \"-Wmissing-field-initializers\"\n#endif\n";
        const loud = "#if defined(__GNUC__) || defined(__clang__)\n#pragma GCC diagnostic pop\n#endif\n";
        try g.print("{s}{s}{s}{s}", .{ quiet, detail.written(), defs.written(), loud });
    }

    /// Info for what has no name of its own goes in `detail`, once per hash even across headers.
    const InfoOut = struct {
        g: *Gen,
        detail: *std.Io.Writer,
        seen: std.AutoHashMapUnmanaged(u64, void) = .empty,

        fn once(o: *InfoOut, h: u64) Error!bool {
            const gop = try o.seen.getOrPut(o.g.a, h);
            return !gop.found_existing;
        }

        fn ref(o: *InfoOut, r: Ref) Error![]const u8 {
            const g = o.g;
            if (plan.ownsInfo(g.s, r)) return g.fmt("const_cast<::sal::TypeInfo *>(&::sal::TypeOf<{s}>::info)", .{try g.qual(r.named)});
            const h = plan.info(g.s, r).hash;
            if (try o.once(h)) {
                const b = try o.body(r);
                try o.detail.print("#ifndef SAL_INFO_{X:0>16}\n#define SAL_INFO_{X:0>16}\nnamespace sal::detail {{\ninline const ::sal::TypeInfo info_{x:0>16} = {{ {s} }};\n}}\n#endif\n", .{ h, h, h, b });
            }
            return g.fmt("const_cast<::sal::TypeInfo *>(&::sal::detail::info_{x:0>16})", .{h});
        }

        fn body(o: *InfoOut, r: Ref) Error![]const u8 {
            const g = o.g;
            var out: std.Io.Writer.Allocating = .init(g.a);
            const w = &out.writer;
            const i = plan.info(g.s, r);
            try w.print(".kind = ::sal::TypeKind::{s}, .name = {{ \"{s}\", {d} }}, .hash = 0x{x:0>16}ull, .size = {d}, .alignment = {d}", .{ try g.ident(i.kind), i.name, i.name.len, i.hash, i.size, i.alignment });
            if (i.child) |c| try w.print(", .child = {s}", .{try o.ref(c)});
            if (i.len > 0) try w.print(", .len = {d}", .{i.len});
            var fields: plan.InfoFields = .init(g.s, r);
            var count: usize = 0;
            while (fields.next()) |_| count += 1;
            if (count > 0) {
                fields = .init(g.s, r);
                var items: std.Io.Writer.Allocating = .init(g.a);
                while (fields.next()) |f| try items.writer.print("    {{ .name = {{ \"{s}\", {d} }}, .type = {s}, .offset = {d}, .bit = {d}, .bits = {d} }},\n", .{ f.name, f.name.len, try o.ref(f.type), f.offset, f.bit, f.bits });
                try o.detail.print("#ifndef SAL_FIELDS_{X:0>16}\n#define SAL_FIELDS_{X:0>16}\nnamespace sal::detail {{\ninline const ::sal::FieldInfo fields_{x:0>16}[] = {{\n{s}}};\n}}\n#endif\n", .{ i.hash, i.hash, i.hash, items.written() });
                try w.print(", .fields = {{ ::sal::detail::fields_{x:0>16}, {d} }}", .{ i.hash, count });
            }
            var values: plan.InfoValues = .init(g.s, r);
            count = 0;
            while (values.next()) |_| count += 1;
            if (count > 0) {
                values = .init(g.s, r);
                var items: std.Io.Writer.Allocating = .init(g.a);
                while (values.next()) |v| try items.writer.print("    {{ .name = {{ \"{s}\", {d} }}, .value = {d}ll }},\n", .{ v.name, v.name.len, v.value });
                try o.detail.print("#ifndef SAL_VALUES_{X:0>16}\n#define SAL_VALUES_{X:0>16}\nnamespace sal::detail {{\ninline const ::sal::EnumValue values_{x:0>16}[] = {{\n{s}}};\n}}\n#endif\n", .{ i.hash, i.hash, i.hash, items.written() });
                try w.print(", .values = {{ ::sal::detail::values_{x:0>16}, {d} }}", .{ i.hash, count });
            }
            return out.written();
        }
    };

    fn intLiteral(g: *Gen, value: i128, unsigned: bool) Error![]const u8 {
        return if (unsigned) g.fmt("{d}ull", .{value}) else g.fmt("{d}ll", .{value});
    }

    fn enumDef(g: *Gen, t: *const Schema.Type, e: Schema.Enum) Error!void {
        const n = try g.enterFor(t.name);
        try g.print("\nenum class {s} : {s} {{\n", .{ n, prim(e.backing) });
        for (e.values) |v| try g.print("    {s} = {s},\n", .{ try g.ident(v.name), try g.intLiteral(v.value, !e.backing.isSigned()) });
        try g.print("}};\n", .{});
    }

    fn errorDef(g: *Gen, t: *const Schema.Type, e: Schema.ErrorSet) Error!void {
        const n = try g.enterFor(t.name);
        try g.print("\n// Codes a result can give, with the ones every result can.\nenum class {s} : uint32_t {{\n", .{n});
        for (e.errors) |x| try g.print("    {s} = {d}u,\n", .{ try g.ident(x.name), x.code });
        try g.print("    Cancelled = ::sal::cancelled,\n    Unsupported = ::sal::unsupported,\n    Gone = ::sal::gone,\n}};\n", .{});
    }

    /// A struct over its backing int, with a getter and a `with_` per member.
    fn bitfieldDef(g: *Gen, t: *const Schema.Type, b: Schema.Bitfield) Error!void {
        const n = try g.enterFor(t.name);
        const back = prim(b.backing);
        try g.print("\nstruct {s} {{\n    {s} bits;\n", .{ n, back });
        var members: std.ArrayList([]const u8) = .empty;
        try members.append(g.a, "bits");
        for (b.members) |m| {
            const mask = try g.fmt("0x{x}ull", .{(@as(u128, 1) << @intCast(m.bits)) - 1});
            const T: []const u8 = switch (m.type) {
                .bool => if (m.bits == 1) "bool" else back,
                .uint => back,
                .@"enum" => |en| try g.qual(en),
            };
            const get = try g.ident(m.name);
            const with = try g.fmt("with_{s}", .{m.name});
            for ([_][]const u8{ get, with }) |x| {
                if (contains(members.items, x)) {
                    g.diag.print("{s}.{s}: C++ can't have two members called that", .{ t.name, x });
                    return error.NameClash;
                }
                try members.append(g.a, x);
            }
            const read = try g.fmt("(((uint64_t)bits >> {d}) & {s})", .{ m.bit, mask });
            if (std.mem.eql(u8, T, "bool")) {
                try g.print("\n    constexpr bool {s}() const {{ return {s} != 0; }}\n", .{ get, read });
            } else try g.print("\n    constexpr {s} {s}() const {{ return ({s}){s}; }}\n", .{ T, get, T, read });
            try g.print("    constexpr {s} {s}({s} x) const {{ return {{({s})(((uint64_t)bits & ~({s} << {d})) | (((uint64_t)x & {s}) << {d}))}}; }}\n", .{ n, with, T, back, mask, m.bit, mask, m.bit });
        }
        try g.print("}};\nstatic_assert(sizeof({s}) == sizeof({s}), \"{s}'s size\");\n", .{ n, back, t.name });
    }

    fn constant(g: *Gen, k: Schema.Constant) Error!void {
        _ = try g.enterFor(k.name);
        const d = try g.constantDecl(k);
        const p = k.type.prim;
        const value = switch (k.value) {
            .int => |v| if (p.isFloat()) try g.fmt("static_cast<{s}>({d})", .{ prim(p), v }) else try g.intLiteral(v, !p.isSigned()),
            .float => |v| try g.fmt("static_cast<{s}>({d})", .{ prim(p), v }),
            .bool => |v| try g.fmt("{}", .{v}),
            // Still escaped as the schema wrote it, which C++ reads the same
            .string => |v| try g.fmt("\"{s}\"", .{v}),
        };
        try g.print("{s} = {s};\n", .{ d.text.?, value });
    }

    /// C++ needs a struct's by-value fields defined first.
    fn structInOrder(g: *Gen, t: *const Schema.Type, done: *std.ArrayList([]const u8), depth: usize) Error!void {
        if (t.kind != .@"struct" and t.kind != .@"union") return;
        if (contains(done.items, t.name) or depth > g.s.types.len) return;
        var it: plan.Slots = .init(g.s, t);
        while (it.next()) |slot| switch (slot) {
            .field => |f| if (byValue(f.field.type)) |dep| if (g.s.findType(dep)) |d| if (!g.aliased(d.at)) try g.structInOrder(d, done, depth + 1),
            .pad => {},
        };
        try done.append(g.a, t.name);
        try g.structDef(t);
    }

    fn byValue(r: Ref) ?[]const u8 {
        return switch (r) {
            .named => |n| n,
            .array => |a| byValue(a.child.*),
            .optional => |c| if (c.* == .pointer) null else byValue(c.*),
            else => null,
        };
    }

    fn structDef(g: *Gen, t: *const Schema.Type) Error!void {
        if (t.size == 0) {
            // Nothing known inside, so it stays opaque, unless it has game code to hold
            if (t.kind != .@"struct" or (t.kind.@"struct".methods.len == 0 and t.kind.@"struct".statics.len == 0)) return;
            const n = try g.enterFor(t.name);
            try g.print("\nstruct {s} {{\n    {s}() = delete;\n", .{ n, n });
            try g.declaredMembers(t, &.{});
            try g.nestedAliases(t.name, try g.structTaken(t, &.{}));
            try g.print("}};\n", .{});
            return;
        }
        const n = try g.enterFor(t.name);
        const q = try g.qual(t.name);
        const is_union = t.kind == .@"union";
        // C++ can't lower one field's alignment, so a struct with any like that is packed with all its padding written out
        const pack = plan.packing(g.s, t);
        const packed_ = pack != null;
        // An array as long as a field is a zero-length one, which MSVC warns about
        var counted = false;
        var check: plan.Slots = .init(g.s, t);
        while (check.next()) |slot| if (slot == .field) {
            if (slot.field.field.type == .array and slot.field.field.type.array.count != null) counted = true;
        };
        if (counted) try g.print("\n#ifdef _MSC_VER\n#pragma warning(push)\n#pragma warning(disable : 4200)\n#endif", .{});
        if (pack) |p| try g.print("\n#pragma pack(push, {d})", .{p});
        try g.print("\n{s} {s} {{\n", .{ if (is_union) "union" else "struct", n });
        var it: plan.Slots = .init(g.s, t);
        var fields: std.ArrayList(Schema.Field) = .empty;
        while (it.next()) |slot| switch (slot) {
            .pad => |p| if (is_union) try g.print("    uint8_t _bytes[0x{x}];\n", .{p.len}) else try g.print("    uint8_t _pad_0x{x}[0x{x}];\n", .{ p.offset, p.len }),
            .field => |f| {
                try g.print("    {s};\n", .{(try g.fieldDecl(f.field)).text.?});
                try fields.append(g.a, f.field);
            },
        };
        if (!is_union) {
            if (t.kind.@"struct".tagged) |tg| try g.taggedMembers(n, tg);
            try g.declaredMembers(t, fields.items);
            try g.nestedAliases(t.name, try g.structTaken(t, fields.items));
        }
        try g.print("}};\n", .{});
        if (packed_) try g.print("#pragma pack(pop)\n", .{});
        if (counted) try g.print("#ifdef _MSC_VER\n#pragma warning(pop)\n#endif\n", .{});
        try g.print("static_assert(sizeof({s}) == 0x{x}, \"{s}'s size\");\n", .{ q, t.size, t.name });
        if (plan.keepsAlignment(g.s, t)) try g.print("static_assert(alignof({s}) == {d}, \"{s}'s alignment\");\n", .{ q, t.alignment, t.name });
        if (!is_union) for (fields.items) |f| {
            try g.print("static_assert(offsetof({s}, {s}) == 0x{x}, \"{s}.{s}'s offset\");\n", .{ q, try g.ident(f.name), f.offset, t.name, f.name });
        };
    }

    /// For each member: what it holds if the tag says it's that one, or null, and `of_` ones that make one.
    fn taggedMembers(g: *Gen, n: []const u8, tg: Schema.Tagged) Error!void {
        const tag = try g.qual(tg.tag);
        try g.print("\n    // Its member, if the tag says it's that one\n", .{});
        for (tg.members) |m| {
            const id_ = try g.ident(m.name);
            if (m.type == .prim and m.type.prim == .void) {
                try g.print("    bool {s}() const {{ return tag == {s}::{s}; }}\n", .{ id_, tag, id_ });
                try g.print("    static {s} of_{s}() {{ {s} s{{}}; s.tag = {s}::{s}; return s; }}\n", .{ n, m.name, n, tag, id_ });
                continue;
            }
            const ty = try g.fmt("decltype(payload.{s})", .{id_});
            try g.print("    const {s} *{s}() const {{ return tag == {s}::{s} ? &payload.{s} : nullptr; }}\n", .{ ty, id_, tag, id_, id_ });
            if (m.type != .array) try g.print("    static {s} of_{s}(const {s} &v) {{ {s} s{{}}; s.tag = {s}::{s}; s.payload.{s} = v; return s; }}\n", .{ n, m.name, try g.decl(m.type, "", false), n, tag, id_, id_ });
        }
    }

    // Objects

    /// Its name, and what a parameter's called in C++, plain or as it crosses.
    fn params(g: *Gen, m: *const Schema.Method, plain_: bool) Error![]const u8 {
        return lang.paramList(g.a, try g.paramDecls(m, plain_));
    }

    // How each thing's declared, which `Names` gives docs too

    fn paramDecls(g: *Gen, m: *const Schema.Method, plain_: bool) Error![]const lang.Param {
        const out = try g.a.alloc(lang.Param, m.signature.params.len);
        for (m.signature.params, out) |p, *q| {
            const pn = try g.local(p.name);
            q.* = if (plain_)
                .{ .name = pn, .type = try g.plain(p.type, ""), .text = try g.plain(p.type, pn) }
            else
                .{ .name = pn, .type = try g.decl(p.type, "", true), .text = try g.decl(p.type, pn, true) };
        }
        return out;
    }

    /// A trait object's method, like `::sal::Result<void, E> heal(uint32_t amount) const`.
    fn methodDecl(g: *Gen, m: *const Schema.Method) Error!lang.Decl {
        const n = try g.ident(m.name);
        const ret = try g.plainRet(m);
        const ps = try g.paramDecls(m, true);
        return .{ .name = n, .params = ps, .type = ret, .text = try g.fmt("{s} {s}({s}) const", .{ ret, n, try lang.paramList(g.a, ps) }) };
    }

    fn fieldDecl(g: *Gen, f: Schema.Field) Error!lang.Decl {
        const n = try g.ident(f.name);
        return .{ .name = n, .type = try g.decl(f.type, "", false), .text = try g.decl(f.type, n, false) };
    }

    /// Existing code's function: a struct's member, or one in its namespace. Null when it can't be called.
    fn declaredDecl(g: *Gen, in: ?*const Schema.Type, m: *const Schema.Method) Error!?lang.Decl {
        if (!callable(m)) return null;
        const ret = try g.plain(m.signature.ret, "");
        const ps = try g.paramDecls(m, true);
        const list = try lang.paramList(g.a, ps);
        if (in != null) {
            const n = try g.ident(m.name);
            return .{ .name = n, .params = ps, .type = ret, .text = try g.fmt("{s}{s} {s}({s})", .{ if (m.static) "static " else "", ret, n, list }) };
        }
        const leaf = (try g.scopeOf(m.name)).leaf;
        return .{ .name = leaf, .path = try g.qual(m.name), .params = ps, .type = ret, .text = try g.fmt("{s} {s}({s})", .{ ret, leaf, list }) };
    }

    /// A static's getter: what a pointer one stores, or where it is.
    fn staticDecl(g: *Gen, in: ?*const Schema.Type, v: Schema.Static) Error!lang.Decl {
        const ret = try g.staticRet(v);
        if (in != null) {
            const n = try g.ident(v.name);
            return .{ .name = n, .type = ret, .text = try g.fmt("static auto {s}() -> {s}", .{ n, ret }) };
        }
        const leaf = (try g.scopeOf(v.name)).leaf;
        return .{ .name = leaf, .path = try g.qual(v.name), .type = ret, .text = try g.fmt("auto {s}() -> {s}", .{ leaf, ret }) };
    }

    fn constantDecl(g: *Gen, k: Schema.Constant) Error!lang.Decl {
        const t: []const u8 = switch (k.value) {
            .bool => "bool",
            .string => "std::string_view",
            else => prim(k.type.prim),
        };
        const leaf = (try g.scopeOf(k.name)).leaf;
        return .{ .name = leaf, .path = try g.qual(k.name), .type = t, .text = try g.fmt("inline constexpr {s} {s}", .{ t, leaf }) };
    }

    /// A struct's member names: its fields, and its game code's.
    fn structTaken(g: *Gen, t: *const Schema.Type, fields: []const Schema.Field) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (fields) |f| try out.append(g.a, try g.ident(f.name));
        for (t.kind.@"struct".methods) |m| try out.append(g.a, try g.ident(m.name));
        for (t.kind.@"struct".statics) |v| try out.append(g.a, try g.ident(v.name));
        return out.items;
    }

    /// `using Definition = ::Wraith::Tweaks_Definition;` for what's nested in it, unless a member has the name.
    fn nestedAliases(g: *Gen, parent: []const u8, taken: []const []const u8) Error!void {
        var names: std.ArrayList([]const u8) = .empty;
        for (g.s.types) |t| try names.append(g.a, t.name);
        for (g.s.traits) |t| try names.append(g.a, t.name);
        for (names.items) |name| {
            const end = Schema.namespaceEnd(name) orelse continue;
            if (end != parent.len or !std.mem.startsWith(u8, name, parent)) continue;
            const leaf = try g.ident(try Schema.flatName(g.a, name[end + 1 ..]));
            if (contains(taken, leaf)) continue;
            try g.print("    using {s} = {s};\n", .{ leaf, try g.qual(name) });
        }
    }

    /// `std::is_same_v<B, ::Transform> || ...` for each base, theirs too.
    fn basesOf(g: *Gen, t: ?*const Schema.Trait) Error![]const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        if (t) |tr| try g.addBases(tr, &all, 0);
        if (all.items.len == 0) return "false";
        var out: std.Io.Writer.Allocating = .init(g.a);
        for (all.items, 0..) |b, i| try out.writer.print("{s}std::is_same_v<B, {s}>", .{ if (i > 0) " || " else "", try g.qual(b) });
        return out.written();
    }

    fn addBases(g: *Gen, t: *const Schema.Trait, all: *std.ArrayList([]const u8), depth: usize) Error!void {
        if (depth > g.s.traits.len) return;
        for (t.bases) |b| {
            if (contains(all.items, b)) continue;
            try all.append(g.a, b);
            if (g.s.findTrait(b)) |base| try g.addBases(base, all, depth + 1);
        }
    }

    /// The struct, with its members declared. They're defined once everything they use is.
    fn objectDecl(g: *Gen, name: []const u8, t: ?*const Schema.Trait) Error!void {
        const n = try g.enterFor(name);
        try g.print(
            \\
            \\struct {s} {{
            \\    uintptr_t data;
            \\    struct Table;
            \\    const Table *table;
            \\
            \\    static const ::sal::Info salamander_info;
            \\    template <class T>
            \\    struct Thunks;
            \\    // A table calling T's methods, null for the ones it doesn't have
            \\    template <class T>
            \\    static const Table *table_of();
            \\    // One calling impl, which has to outlive it
            \\    template <class T>
            \\    static {s} of(T &&impl);
            \\    static {s} from_object(::sal::Object o);
            \\    ::sal::Object object() const;
            \\    explicit operator bool() const {{ return table != nullptr; }}
            \\    // Whether B is one of its bases, so sal::as can make it one
            \\    template <class B>
            \\    static constexpr bool extends = {s};
            \\
            \\
        , .{ n, n, n, try g.basesOf(t) });
        if (t) |tr| {
            var buf: [plan.max_methods]*const Schema.Method = undefined;
            var taken: std.ArrayList([]const u8) = .empty;
            try taken.appendSlice(g.a, &object_members);
            for (plan.methods(g.s, tr, &buf)) |m| {
                if (contains(&object_members, m.name)) {
                    g.diag.print("{s}.{s}: C++ trait objects have their own {s}", .{ tr.name, m.name, m.name });
                    return error.NameClash;
                }
                const d = try g.methodDecl(m);
                try taken.append(g.a, d.name);
                try g.print("    {s};\n", .{d.text.?});
            }
            try g.nestedAliases(tr.name, taken.items);
        } else {
            const f = for (g.fns.list.items) |f| {
                if (std.mem.eql(u8, f.name, name)) break f;
            } else unreachable;
            const m: Schema.Method = .{ .name = "call", .signature = g.sigOf(f) };
            const ret = try g.plainRet(&m);
            const ps = try g.params(&m, true);
            try g.print("    {s} call({s}) const;\n    {s} operator()({s}) const;\n", .{ ret, ps, ret, ps });
        }
        try g.print("}};\n", .{});
    }

    /// Its table, info, thunks and methods.
    fn objectDefs(g: *Gen, name: []const u8, ms: []const *const Schema.Method, hash: u64, label: []const u8, sigs: []const u64, is_fn: bool) Error!void {
        const n = try g.enterFor(name);
        try g.print("\n// {s}\n\n// A null method is one this table doesn't have.\nstruct {s}::Table {{\n    const ::sal::Info *salamander_info;\n    ::sal::Owner *salamander_owner;\n", .{ label, n });
        for (ms) |m| {
            const inner = try g.fmt("({s}*{s}){s}", .{ conv(m.signature.conv), try g.ident(m.name), try g.entryParams(m, false) });
            try g.print("    {s};\n", .{try g.retDecl(m, inner)});
        }
        try g.print("}};\n", .{});

        const methods = try g.fmt("{s}_methods", .{n});
        try g.claim(try g.fmt("{s}::sal_detail::{s}", .{ g.cur, methods }));
        if (ms.len > 0) {
            try g.print("\nnamespace sal_detail {{\ninline constexpr ::sal::MethodInfo {s}[] = {{\n", .{methods});
            for (ms, sigs) |m, sig| try g.print("    {{{{\"{s}\", {d}}}, 0x{x:0>16}ull}},\n", .{ m.name, m.name.len, sig });
            try g.print("}};\n}} // namespace sal_detail\n", .{});
        }
        try g.print("\ninline const ::sal::Info {s}::salamander_info = {{0x{x:0>16}ull, ::sal::abi_version, {{\"{s}\", {d}}}, {s}, {d}}};\n", .{
            n,                                                                       hash,   label, label.len,
            if (ms.len > 0) try g.fmt("sal_detail::{s}", .{methods}) else "nullptr", ms.len,
        });

        try g.thunks(n, ms, is_fn);
        try g.print(
            \\
            \\template <class T>
            \\inline const {s}::Table *{s}::table_of() {{
            \\    using Th = Thunks<T>;
            \\    static constexpr Table t = [] {{
            \\        Table r{{}};
            \\        r.salamander_info = &salamander_info;
            \\
        , .{ n, n });
        for (ms) |m| {
            const mn = try g.ident(m.name);
            try g.print("        if constexpr (Th::has_{s}) r.{s} = &Th::{s};\n", .{ m.name, mn, mn });
        }
        try g.print(
            \\        return r;
            \\    }}();
            \\    return &t;
            \\}}
            \\
            \\template <class T>
            \\inline {s} {s}::of(T &&impl) {{
            \\    using U = std::remove_cvref_t<T>;
            \\    return {{reinterpret_cast<uintptr_t>(const_cast<U *>(std::addressof(impl))), table_of<U>()}};
            \\}}
            \\
            \\inline {s} {s}::from_object(::sal::Object o) {{ return {{o.data, static_cast<const Table *>(o.table)}}; }}
            \\
            \\inline ::sal::Object {s}::object() const {{ return {{data, table}}; }}
            \\
        , .{ n, n, n, n, n });
        for (ms) |m| try g.member(n, m);
        if (is_fn) {
            const m = ms[0];
            try g.print("\ninline {s} {s}::operator()({s}) const {{ return call(", .{ try g.plainRet(m), n, try g.params(m, true) });
            for (m.signature.params, 0..) |p, i| try g.print("{s}{s}", .{ if (i > 0) ", " else "", try g.local(p.name) });
            try g.print("); }}\n", .{});
        }
    }

    /// What a table made from T calls: each turns what crossed into plain C++, calls T, and turns back what it gives.
    fn thunks(g: *Gen, n: []const u8, ms: []const *const Schema.Method, is_fn: bool) Error!void {
        try g.print("\ntemplate <class T>\nstruct {s}::Thunks {{\n", .{n});
        for (ms) |m| {
            var req: std.Io.Writer.Allocating = .init(g.a);
            var args: std.Io.Writer.Allocating = .init(g.a);
            var lifted: std.Io.Writer.Allocating = .init(g.a);
            if (!m.static) try req.writer.writeAll("T &o");
            for (m.signature.params, 0..) |p, i| {
                if (req.written().len > 0) try req.writer.writeAll(", ");
                try req.writer.writeAll(try g.plain(p.type, try g.fmt("a{d}", .{i})));
                if (i > 0) {
                    try args.writer.writeAll(", ");
                    try lifted.writer.writeAll(", ");
                }
                try args.writer.print("a{d}", .{i});
                try lifted.writer.writeAll(try g.lift(p.type, try g.local(p.name)));
            }
            const target = if (m.static) "T::" else if (is_fn) "o" else "o.";
            const callee = if (is_fn) "" else try g.ident(m.name);
            const req_params = if (req.written().len > 0) try g.fmt("({s}) ", .{req.written()}) else "";
            try g.print("    static constexpr bool has_{s} = requires {s}{{ {s}{s}({s}); }};\n", .{ m.name, req_params, target, callee, args.written() });

            // A trailing return, so the convention never lands after a `*`
            const ret = std.mem.trimEnd(u8, try g.retDecl(m, ""), " ");
            try g.print("    static auto {s}{s}{s} -> {s} {{\n", .{ conv(m.signature.conv), try g.ident(m.name), try g.entryParams(m, true), ret });
            if (!m.static) try g.print("        T &o = *reinterpret_cast<T *>(self);\n", .{});
            const call = try g.fmt("{s}{s}({s})", .{ target, callee, lifted.written() });
            try g.print("        SAL_TRY\n", .{});
            if (m.async) {
                try g.print("        return ::sal::promise_of({s});\n        SAL_CATCH({{}})\n", .{call});
            } else if (m.signature.ret == .result) {
                const res = m.signature.ret.result;
                const err = try g.qual(res.err);
                try g.print("        if constexpr (std::is_void_v<decltype({s})>) {{\n            {s};\n            return 0;\n        }} else {{\n", .{ call, call });
                if (isVoid(res.ok.*)) {
                    try g.print("            ::sal::Result<void, {s}> sal_r = {s};\n", .{ err, call });
                } else {
                    try g.print("            ::sal::Result<{s}, {s}> sal_r = {s};\n            if (sal_r) *sal_out = {s};\n", .{ try g.plain(res.ok.*, ""), err, call, try g.lower(res.ok.*, "*sal_r") });
                }
                try g.print("            return sal_r.code();\n        }}\n        SAL_CATCH(::sal::gone)\n", .{});
            } else if (isVoid(m.signature.ret)) {
                try g.print("        {s};\n        SAL_CATCH()\n", .{call});
            } else {
                try g.print("        {s} = {s};\n        return {s};\n        SAL_CATCH({{}})\n", .{ try g.plain(m.signature.ret, "sal_v"), call, try g.lower(m.signature.ret, "sal_v") });
            }
            try g.print("    }}\n", .{});
        }
        try g.print("}};\n", .{});
    }

    /// A method calling through the table, entering its owner around the call.
    fn member(g: *Gen, n: []const u8, m: *const Schema.Method) Error!void {
        const d = try g.methodDecl(m);
        const mn = d.name;
        var args: std.Io.Writer.Allocating = .init(g.a);
        if (!m.static) try args.writer.writeAll("data");
        for (m.signature.params) |p| {
            if (args.written().len > 0) try args.writer.writeAll(", ");
            try args.writer.writeAll(try g.lower(p.type, try g.local(p.name)));
        }
        const ret = d.type.?;
        try g.print("\ninline {s} {s}::{s}({s}) const {{\n", .{ ret, n, mn, try lang.paramList(g.a, d.params) });
        if (!m.async and m.signature.ret == .result) {
            const res = m.signature.ret.result;
            try g.print("    if (!table) return {s}::from_code(::sal::gone);\n    if (!table->{s}) return {s}::from_code(::sal::unsupported);\n    if (!::sal::enter(table->salamander_owner)) return {s}::from_code(::sal::gone);\n", .{ ret, mn, ret, ret });
            if (isVoid(res.ok.*)) {
                try g.print("    uint32_t sal_c = table->{s}({s});\n    ::sal::leave(table->salamander_owner);\n    return {s}::from_code(sal_c);\n}}\n", .{ mn, args.written(), ret });
            } else {
                const out_arg = if (args.written().len > 0) ", &sal_out" else "&sal_out";
                try g.print("    {s} sal_out{{}};\n    uint32_t sal_c = table->{s}({s}{s});\n    ::sal::leave(table->salamander_owner);\n    return {s}::from_code(sal_c, {s});\n}}\n", .{ try g.decl(res.ok.*, "", false), mn, args.written(), out_arg, ret, try g.lift(res.ok.*, "sal_out") });
            }
            return;
        }
        const is_void = !m.async and isVoid(m.signature.ret);
        try g.print("    if (!table || !table->{s} || !::sal::enter(table->salamander_owner)) return{s};\n", .{ mn, if (is_void) "" else " {}" });
        if (is_void) {
            try g.print("    table->{s}({s});\n    ::sal::leave(table->salamander_owner);\n}}\n", .{ mn, args.written() });
        } else if (m.async) {
            try g.print("    ::sal::Promise sal_p = table->{s}({s});\n    ::sal::leave(table->salamander_owner);\n    return {s}(sal_p);\n}}\n", .{ mn, args.written(), ret });
        } else {
            try g.print("    {s} = table->{s}({s});\n    ::sal::leave(table->salamander_owner);\n    return {s};\n}}\n", .{ try g.decl(m.signature.ret, "sal_r", true), mn, args.written(), try g.lift(m.signature.ret, "sal_r") });
        }
    }

    // Existing code the schema declares: each one's full name, and a pointer type for functions, `self` first for methods.

    fn declared(g: *Gen) Error!void {
        const s = g.s;
        for (s.types) |*t| if (t.kind == .@"struct" and !g.aliased(t.at)) {
            const st = t.kind.@"struct";
            for (st.methods) |*m| try g.declaredFn(t, m);
            for (st.statics) |st_| try g.declaredStatic(t, st_);
        };
        for (s.functions) |*m| if (!g.aliased(m.at)) try g.declaredFn(null, m);
        for (s.statics) |st| if (!g.aliased(st.at)) try g.declaredStatic(null, st);
    }

    /// `Player.heal` as `Player_heal`, in Player's namespace.
    fn declaredName(g: *Gen, full: []const u8, suffix: []const u8) Error![]const u8 {
        const end = Schema.namespaceEnd(full);
        // A struct's member, which goes beside the struct with an underscore
        const site = if (end) |e| if (g.s.findType(full[0..e]) != null) try g.fmt("{s}_{s}{s}", .{ full[0..e], full[e + 1 ..], suffix }) else try g.fmt("{s}{s}", .{ full, suffix }) else try g.fmt("{s}{s}", .{ full, suffix });
        try g.claim(try g.qual(site));
        return g.enterFor(site);
    }

    /// Whether it can be called: results and promises are Salamander's own, not existing code's.
    fn callable(m: *const Schema.Method) bool {
        if (m.async or m.signature.ret == .result) return false;
        for (m.signature.params) |p| if (p.type == .result) return false;
        return true;
    }

    fn isStored(st: Schema.Static) bool {
        return st.type == .pointer or (st.type == .optional and st.type.optional.* == .pointer);
    }

    /// A pointer static gives what's stored there, anything else a pointer to it.
    fn staticRet(g: *Gen, st: Schema.Static) Error![]const u8 {
        if (isStored(st)) return g.decl(st.type, "", false);
        const r = try g.a.create(Ref);
        r.* = st.type;
        return g.decl(.{ .pointer = r }, "", false);
    }

    /// A struct's game code as its members, which are defined with the rest of it.
    fn declaredMembers(g: *Gen, t: *const Schema.Type, fields: []const Schema.Field) Error!void {
        const st = t.kind.@"struct";
        if (st.methods.len == 0 and st.statics.len == 0) return;
        var seen: std.ArrayList([]const u8) = .empty;
        for (fields) |f| try seen.append(g.a, try g.ident(f.name));
        try g.print("\n    // Its game code, found by name\n", .{});
        for (st.methods) |*m| if (try g.declaredDecl(t, m)) |d| {
            try g.member_(t, &seen, d.name);
            try g.print("    {s};\n", .{d.text.?});
        };
        for (st.statics) |v| {
            const d = try g.staticDecl(t, v);
            try g.member_(t, &seen, d.name);
            try g.print("    {s};\n", .{d.text.?});
        }
    }

    fn member_(g: *Gen, t: *const Schema.Type, seen: *std.ArrayList([]const u8), n: []const u8) Error!void {
        if (contains(seen.items, n)) {
            g.diag.print("{s}.{s}: C++ can't have two members called that", .{ t.name, n });
            return error.NameClash;
        }
        try seen.append(g.a, n);
    }

    fn declaredFn(g: *Gen, in: ?*const Schema.Type, m: *const Schema.Method) Error!void {
        const full = if (in) |t| try g.fmt("{s}.{s}", .{ t.name, m.name }) else m.name;
        const name_id = try g.declaredName(full, "_name");
        try g.print("\n// {s}{s}\ninline constexpr std::string_view {s} = \"{s}\";\n", .{ full, if (m.virtual) |slot| try g.fmt(", slot {d} of its vtable", .{slot}) else "", name_id, full });
        if (!callable(m)) return;
        const has_this = in != null and !m.static;
        var ps: std.Io.Writer.Allocating = .init(g.a);
        var args: std.Io.Writer.Allocating = .init(g.a);
        if (has_this) {
            try ps.writer.print("{s} *self", .{try g.qual(in.?.name)});
            try args.writer.writeAll("this");
        }
        for (m.signature.params) |p| {
            const pn = try g.local(p.name);
            if (ps.written().len > 0) try ps.writer.writeAll(", ");
            if (args.written().len > 0) try args.writer.writeAll(", ");
            try ps.writer.writeAll(try g.decl(p.type, pn, true));
            try args.writer.writeAll(try g.lower(p.type, pn));
        }
        const fn_id = try g.declaredName(full, "_fn");
        try g.print("using {s} = {s};\n", .{ fn_id, try g.decl(m.signature.ret, try g.fmt("({s}*)({s})", .{ conv(m.signature.conv), ps.written() }), true) });

        // A struct's goes on it, the rest beside their names
        const owner = if (in) |t| try g.fmt("{s}::", .{(try g.scopeOf(t.name)).leaf}) else "";
        if (in == null) {
            _ = try g.enterFor(m.name);
            try g.claim(try g.qual(m.name));
        }
        const d = (try g.declaredDecl(in, m)).?;
        try g.print("\ninline {s} {s}{s}({s}) {{\n", .{ d.type.?, owner, d.name, try lang.paramList(g.a, d.params) });
        if (m.virtual) |slot| {
            try g.print("    auto sal_f = reinterpret_cast<{s}>(::sal::declared::slot(this, {d}));\n", .{ fn_id, slot });
        } else {
            try g.print("    static ::sal::declared::Site sal_site{{{s}}};\n    auto sal_f = reinterpret_cast<{s}>(sal_site.get());\n", .{ name_id, fn_id });
        }
        try g.print("    if (!sal_f) ::sal::declared::missing({s});\n", .{name_id});
        const call = try g.fmt("sal_f({s})", .{args.written()});
        if (isVoid(m.signature.ret)) {
            try g.print("    {s};\n}}\n", .{call});
        } else try g.print("    return {s};\n}}\n", .{try g.lift(m.signature.ret, call)});
    }

    fn declaredStatic(g: *Gen, in: ?*const Schema.Type, st: Schema.Static) Error!void {
        const full = if (in) |t| try g.fmt("{s}.{s}", .{ t.name, st.name }) else st.name;
        const id = try g.declaredName(full, "_name");
        try g.print("\n// {s}, a {s}\ninline constexpr std::string_view {s} = \"{s}\";\n", .{ full, try g.decl(st.type, "", false), id, full });
        const owner = if (in) |t| try g.fmt("{s}::", .{(try g.scopeOf(t.name)).leaf}) else "";
        if (in == null) {
            _ = try g.enterFor(st.name);
            try g.claim(try g.qual(st.name));
        }
        const d = try g.staticDecl(in, st);
        const ret = d.type.?;
        const stored = isStored(st);
        try g.print("\n// {s}, null till it's found\ninline auto {s}{s}() -> {s} {{\n    static ::sal::declared::Site sal_site{{{s}}};\n", .{ if (stored) "What's stored there" else "Where it is", owner, d.name, ret, id });
        if (stored) {
            try g.print("    uintptr_t sal_at = sal_site.get();\n    return sal_at ? *reinterpret_cast<{s} *>(sal_at) : nullptr;\n}}\n", .{ret});
        } else try g.print("    return reinterpret_cast<{s}>(sal_site.get());\n}}\n", .{ret});
    }
};

//// How C++ names and declares each thing, from the same builders the writer uses. `a` should be an arena.
pub const Names = struct {
    g: *Gen,

    pub fn init(a: std.mem.Allocator, s: Schema, options: Options, diagnostic: ?*Schema.Diagnostic) Error!Names {
        const g = try a.create(Gen);
        g.* = .init(s, try lang.sink(a), a, options, diagnostic orelse try a.create(Schema.Diagnostic));
        try g.file();
        return .{ .g = g };
    }

    /// Without the `::` generated code roots names with.
    fn tidy(n: *const Names, d: lang.Decl) Error!?lang.Decl {
        return try lang.tidied(n.g.a, d, lang.unrooted);
    }

    fn named(n: *const Names, full: []const u8) Error!?lang.Decl {
        return n.tidy(.{ .name = (try n.g.scopeOf(full)).leaf, .path = try n.g.qual(full) });
    }

    pub fn typeName(n: *const Names, t: *const Schema.Type) Error!?lang.Decl {
        return n.named(t.name);
    }

    pub fn traitName(n: *const Names, t: *const Schema.Trait) Error!?lang.Decl {
        return n.named(t.name);
    }

    pub fn method(n: *const Names, _: *const Schema.Trait, m: *const Schema.Method) Error!?lang.Decl {
        return n.tidy(try n.g.methodDecl(m));
    }

    pub fn field(n: *const Names, _: *const Schema.Type, f: *const Schema.Field) Error!?lang.Decl {
        return n.tidy(try n.g.fieldDecl(f.*));
    }

    /// An enum's value or an error, `Type::name`, or a bitfield's getter.
    pub fn member(n: *const Names, t: *const Schema.Type, name: []const u8) Error!?lang.Decl {
        const g = n.g;
        const id = try g.ident(name);
        if (t.kind == .bitfield) return .{ .name = try g.fmt("{s}()", .{id}) };
        return n.tidy(.{ .name = id, .path = try g.fmt("{s}::{s}", .{ try g.qual(t.name), id }) });
    }

    pub fn function(n: *const Names, in: ?*const Schema.Type, m: *const Schema.Method) Error!?lang.Decl {
        return n.tidy(try n.g.declaredDecl(in, m) orelse return null);
    }

    pub fn static(n: *const Names, in: ?*const Schema.Type, v: *const Schema.Static) Error!?lang.Decl {
        return n.tidy(try n.g.staticDecl(in, v.*));
    }

    pub fn constant(n: *const Names, c: *const Schema.Constant) Error!?lang.Decl {
        return n.tidy(try n.g.constantDecl(c.*));
    }
};

fn writeFor(source: []const u8, options: Options) ![]const u8 {
    const a = std.testing.allocator;
    var diag: Schema.Diagnostic = .{};
    var parsed = try salamander_schema.parse(a, source, .{ .pointer_size = 8, .any_namespace = true, .uses = &.{"game"} }, &diag);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try write(a, parsed.schema, &out.writer, options, &diag);
    return out.toOwnedSlice();
}

fn expectParts(text: []const u8, want: []const []const u8) !void {
    for (want) |part| if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing:\n{s}\n\nin:\n{s}\n", .{ part, text });
        return error.TestUnexpectedResult;
    };
}

test "writes a header" {
    const text = try writeFor(
        \\struct Vec3 { f32 x; f32 y; f32 z; }
        \\error LoadError { NotFound, Corrupt = 7 }
        \\enum Job : u8 { warrior = 1, mage }
        \\bitfield Flags : u32 { bool alive; Job job : 4; }
        \\const string hello = "a\"b";
        \\namespace Scene { struct Node { u32 id; Node* parent; } }
        \\trait Mover { [Thiscall] Vec3 move(Vec3 by, string int); Vec3!LoadError load(); void each(fn(u32 n) bool visit); Flags flags(); }
    , .{ .label = "test.sal" });
    defer std.testing.allocator.free(text);
    try expectParts(text, &.{
        "struct Vec3 {\n    float x;\n    float y;\n    float z;\n};",
        "static_assert(offsetof(::Vec3, z) == 0x8, \"Vec3.z's offset\");",
        "enum class Job : uint8_t {\n    warrior = 1ull,",
        "    Corrupt = 7u,\n    Cancelled = ::sal::cancelled,",
        "    constexpr ::Job job() const { return (::Job)(((uint64_t)bits >> 1) & 0xfull); }",
        "inline constexpr std::string_view hello = \"a\\\"b\";",
        "namespace Scene {\n",
        "    ::Scene::Node *parent;",
        "    ::Vec3 (SAL_THISCALL *move)(uintptr_t, ::Vec3, ::sal::String);",
        "    uint32_t (*load)(uintptr_t, ::Vec3 *);",
        // A bitfield crosses as its int
        "    uint32_t (*flags)(uintptr_t);",
        "    ::Vec3 move(::Vec3 by, std::string_view int_) const;",
        "    ::sal::Result<::Vec3, ::LoadError> load() const;",
        "    if (!table->load) return ::sal::Result<::Vec3, ::LoadError>::from_code(::sal::unsupported);",
        // Named for where it's used, not its hash
        "struct Mover_each_visit {",
        "    static constexpr bool has_move = requires (T &o, ::Vec3 a0, std::string_view a1) { o.move(a0, a1); };",
        "    return ::Flags{sal_r};",
    });
}

test "declared code gets its name, a pointer type and a call" {
    const text = try writeFor(
        \\struct Player {
        \\    [Offset(0x10)] f32 health;
        \\    [Sig("E8")] bool heal(u32 amount);
        \\    [Sig("48")] static Player* instance;
        \\}
        \\struct World {
        \\    [Sig("E9")] static World* spawn(Player* who);
        \\}
        \\[Sig("76")] static u8 seen;
    , .{ .label = "game.sal" });
    defer std.testing.allocator.free(text);
    try expectParts(text, &.{
        "inline constexpr std::string_view Player_heal_name = \"Player.heal\";",
        "using Player_heal_fn = bool (*)(::Player *self, uint32_t amount);",
        "inline constexpr std::string_view Player_instance_name = \"Player.instance\";",
        "using World_spawn_fn = ::World *(*)(::Player *who);",
        "inline constexpr std::string_view seen_name = \"seen\";",
        // Members on the struct, and one with nothing known inside holds only those
        "    bool heal(uint32_t amount);\n    static auto instance() -> ::Player *;",
        "struct World {\n    World() = delete;",
        "inline bool Player::heal(uint32_t amount) {",
        "    return sal_f(this, amount);",
        "inline auto seen() -> uint8_t * {",
    });
}

test "a struct with nothing known stays opaque" {
    const text = try writeFor("opaque Handle;\nstruct Empty { }", .{});
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "struct Empty {") == null);
}

test "a home namespace holds what has none, and methods can't take a trait object's own names" {
    const text = try writeFor("struct Vec3 { f32 x; }\nnamespace Scene { struct Node { Vec3 at; } }", .{ .namespace = "Game" });
    defer std.testing.allocator.free(text);
    try expectParts(text, &.{ "namespace Game {\n", "    ::Game::Vec3 at;" });

    try std.testing.expectError(error.NameClash, writeFor("trait Bad { void of(); }", .{}));
}

test "Names give what the writer declares" {
    const make = struct {
        fn make(a: std.mem.Allocator, s: Schema) anyerror!Names {
            return .init(a, s, .{}, null);
        }
    }.make;
    try lang.expectNames(Names, make, .{
        .method = "uint32_t count(std::string_view who) const",
        .field = "uint32_t hp",
        .function = "bool heal(uint32_t amount)",
        .static = "static auto instance() -> G::Player *",
        .constant = "inline constexpr uint32_t max_players",
    });
}

test "a field that can't have its alignment packs the struct only as far as it needs" {
    const text = try writeFor(
        \\[Size(0xC)] struct Info { u32 id; [0x4] u64 at; }
        \\struct Outer { [0x10] Info info; }
    , .{});
    defer std.testing.allocator.free(text);
    try expectParts(text, &.{
        "#pragma pack(push, 4)\nstruct Info {",
        "static_assert(alignof(::Info) == 4, \"Info's alignment\");",
        "static_assert(alignof(::Outer) == 4, \"Outer's alignment\");",
    });
}
