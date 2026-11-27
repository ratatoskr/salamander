//! A schema as Rust over the `salamander` crate, laid out by the same plan as Zig and C, checked with const asserts.
//! Namespaces are modules. What crosses is `#[repr(C)]`. Trait objects get methods taking plain Rust, and any
//! type implements a trait through its `...Impl` trait. It has no inner attributes, so it can be `include!`d.

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
    /// What was parsed, so `aliases` can tell which file each thing's in.
    source: []const u8 = "",
    /// Files whose types come from another module, used from there instead of written again.
    aliases: []const Alias = &.{},
    /// The module what has no namespace goes in, like `game`. The top if empty.
    namespace: []const u8 = "",
    /// Writing the runtime's own `core.sal`, as the `salamander` crate's `sal_core.rs`.
    core: bool = false,
};

/// What files starting with `prefix` declare comes from `path`, like `wraith/` from `::wraith_api`.
pub const Alias = struct {
    prefix: []const u8,
    path: []const u8,
};

pub fn write(gpa: std.mem.Allocator, s: Schema, w: *std.Io.Writer, options: Options, diagnostic: ?*Schema.Diagnostic) Error!void {
    var scratch: Schema.Diagnostic = .{};
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var g: Gen = .init(s, w, arena.allocator(), options, diagnostic orelse &scratch);
    try g.file();
}

const keywords = [_][]const u8{
    "as",      "async",    "await",  "break",  "const",  "continue", "dyn",   "else",     "enum",   "extern", "false",
    "fn",      "for",      "if",     "impl",   "in",     "let",      "loop",  "match",    "mod",    "move",   "mut",
    "pub",     "ref",      "return", "static", "struct", "trait",    "true",  "type",     "unsafe", "use",    "where",
    "while",   "abstract", "become", "box",    "do",     "final",    "macro", "override", "priv",   "typeof", "unsized",
    "virtual", "yield",    "try",    "gen",
};

/// Raw identifiers can't be these.
const unraw = [_][]const u8{ "self", "Self", "super", "crate", "_" };

/// What generated bodies call their own locals, so parameters don't.
const helper_locals = [_][]const u8{ "sal_this", "sal_out", "sal_t", "sal_f", "sal_g", "sal_r", "sal_c", "sal_v", "sal_at" };

/// What a trait object gets besides its methods, skipped when a method has the name.
const helpers = [_][]const u8{ "from_static", "borrowed", "keep" };

const contains = lang.contains;
const isVoid = lang.isVoid;
const resultOk = lang.resultOk;
pub const snake = lang.snake;
const screaming = lang.screaming;
const camel = lang.camel;
/// Named like `Scene.Picker_pick_visit` for an unnamed one, so it goes in its site's module.
const Extra = lang.Extra;

const Scope = struct {
    /// Like `scene` or `wraith::slot`.
    ns: []const u8,
    /// Unconverted, like `Player_relation`.
    leaf: []const u8,
    /// Where it's used from instead, if its file's aliased.
    alias: ?[]const u8 = null,
};

/// An ABI a convention is on some targets, with what picks them.
const Abi = struct { cfg: []const u8, abi: []const u8 };

const Gen = struct {
    s: Schema,
    w: *std.Io.Writer,
    a: std.mem.Allocator,
    o: Options,
    diag: *Schema.Diagnostic,
    top: std.ArrayList([]const u8) = .empty,
    fns: lang.Fns = .{},
    /// Each module's text, written once the file's done, since a module can only be opened once.
    mods: std.StringArrayHashMapUnmanaged(std.Io.Writer.Allocating) = .empty,
    cur: []const u8 = "",
    camels: std.StringHashMapUnmanaged(u32) = .empty,

    fn init(s: Schema, w: *std.Io.Writer, a: std.mem.Allocator, options: Options, diag: *Schema.Diagnostic) Gen {
        var g: Gen = .{ .s = s, .w = w, .a = a, .o = options, .diag = diag };
        if (options.core) g.o.namespace = "";
        return g;
    }

    fn out(g: *Gen) Error!*std.Io.Writer {
        const e = try g.mods.getOrPut(g.a, g.cur);
        if (!e.found_existing) e.value_ptr.* = .init(g.a);
        return &e.value_ptr.writer;
    }

    fn print(g: *Gen, comptime f: []const u8, args: anytype) Error!void {
        try (try g.out()).print(f, args);
    }

    fn fmt(g: *Gen, comptime f: []const u8, args: anytype) Error![]const u8 {
        return std.fmt.allocPrint(g.a, f, args);
    }

    fn sal(g: *const Gen) []const u8 {
        return if (g.o.core) "crate" else "::salamander";
    }

    fn aliasOf(g: *const Gen, at: Schema.Pos) ?[]const u8 {
        if (g.o.aliases.len == 0) return null;
        const file_name = Schema.fileOf(g.o.source, at);
        for (g.o.aliases) |a| if (std.mem.startsWith(u8, file_name, a.prefix)) return a.path;
        return null;
    }

    fn aliased(g: *const Gen, at: Schema.Pos) bool {
        return g.aliasOf(at) != null;
    }

    fn claim(g: *Gen, n: []const u8) Error!void {
        try lang.claim(g.a, &g.top, g.diag, try g.fmt("{s}::{s}", .{ g.cur, n }), "Rust");
    }

    // Names

    fn ident(g: *Gen, n: []const u8) Error![]const u8 {
        if (contains(&unraw, n)) return g.fmt("{s}_", .{n});
        return if (contains(&keywords, n)) g.fmt("r#{s}", .{n}) else n;
    }

    /// A parameter's name, kept off the bodies' locals.
    fn local(g: *Gen, n: []const u8) Error![]const u8 {
        const sn = try snake(g.a, n);
        return if (contains(&helper_locals, sn)) g.fmt("{s}_", .{sn}) else g.ident(sn);
    }

    fn field(g: *Gen, n: []const u8) Error![]const u8 {
        return g.ident(try snake(g.a, n));
    }

    /// Namespaces up to the first type or trait, then what's left as one name.
    fn scopeOf(g: *Gen, name: []const u8) Error!Scope {
        var alias: ?[]const u8 = null;
        if (g.s.findType(name)) |t| alias = g.aliasOf(t.at) else if (g.s.findTrait(name)) |t| alias = g.aliasOf(t.at);
        const home = try g.modPath(g.o.namespace);
        const end = Schema.namespaceEnd(name) orelse return .{ .ns = home, .leaf = try Schema.flatName(g.a, name), .alias = alias };
        var ns: std.ArrayList(u8) = .empty;
        var start: usize = 0;
        while (start < end) {
            const dot = std.mem.indexOfScalarPos(u8, name[0..end], start, '.') orelse end;
            const prefix = name[0..dot];
            if (g.s.findType(prefix) != null or g.s.findTrait(prefix) != null) break;
            if (ns.items.len > 0) try ns.appendSlice(g.a, "::");
            try ns.appendSlice(g.a, try g.ident(try snake(g.a, name[start..dot])));
            start = dot + 1;
        }
        return .{ .ns = if (ns.items.len == 0) home else ns.items, .leaf = try Schema.flatName(g.a, name[@min(start, name.len)..]), .alias = alias };
    }

    fn modPath(g: *Gen, ns: []const u8) Error![]const u8 {
        if (ns.len == 0) return "";
        var o: std.ArrayList(u8) = .empty;
        var it = std.mem.tokenizeAny(u8, ns, ".:");
        while (it.next()) |seg| {
            if (o.items.len > 0) try o.appendSlice(g.a, "::");
            try o.appendSlice(g.a, try g.ident(try snake(g.a, seg)));
        }
        return o.items;
    }

    /// `item` in module `ns`, from the module being written.
    fn pathTo(g: *Gen, ns: []const u8, item: []const u8, alias: ?[]const u8) Error![]const u8 {
        var o: std.ArrayList(u8) = .empty;
        if (alias) |a| {
            try o.appendSlice(g.a, a);
            try o.appendSlice(g.a, "::");
            if (ns.len > 0) {
                try o.appendSlice(g.a, ns);
                try o.appendSlice(g.a, "::");
            }
            try o.appendSlice(g.a, item);
            return o.items;
        }
        // Up past what the two don't share, then down
        var from: std.ArrayList([]const u8) = .empty;
        var to: std.ArrayList([]const u8) = .empty;
        var fi = std.mem.tokenizeSequence(u8, g.cur, "::");
        while (fi.next()) |seg| try from.append(g.a, seg);
        var ti = std.mem.tokenizeSequence(u8, ns, "::");
        while (ti.next()) |seg| try to.append(g.a, seg);
        var shared: usize = 0;
        while (shared < from.items.len and shared < to.items.len and std.mem.eql(u8, from.items[shared], to.items[shared])) shared += 1;
        for (from.items[shared..]) |_| try o.appendSlice(g.a, "super::");
        for (to.items[shared..]) |seg| {
            try o.appendSlice(g.a, seg);
            try o.appendSlice(g.a, "::");
        }
        try o.appendSlice(g.a, item);
        return o.items;
    }

    /// A type's name in Rust, like `PlayerRelation`.
    fn typeName(g: *Gen, name: []const u8) Error![]const u8 {
        return g.typeLeaf(try g.scopeOf(name));
    }

    /// A type from where it's used.
    fn qual(g: *Gen, name: []const u8) Error![]const u8 {
        const sc = try g.scopeOf(name);
        return g.pathTo(sc.ns, try g.typeLeaf(sc), sc.alias);
    }

    /// CamelCase, unless another type in its module would be the same. Then one written otherwise keeps how
    /// it's written, like C's `lua_State` beside `LuaState`.
    fn typeLeaf(g: *Gen, sc: Scope) Error![]const u8 {
        const c = try camel(g.a, sc.leaf);
        if (!std.mem.eql(u8, c, sc.leaf) and (g.camels.get(try g.fmt("{s}::{s}", .{ sc.ns, c })) orelse 0) > 1) return g.ident(sc.leaf);
        return g.ident(c);
    }

    /// How many types and traits each module would have by each CamelCase name, for `typeLeaf`.
    fn countCamels(g: *Gen) Error!void {
        for (g.s.types) |t| if (!t.nested) try g.countCamel(t.name);
        for (g.s.traits) |t| try g.countCamel(t.name);
    }

    fn countCamel(g: *Gen, name: []const u8) Error!void {
        const sc = try g.scopeOf(name);
        const e = try g.camels.getOrPut(g.a, try g.fmt("{s}::{s}", .{ sc.ns, try camel(g.a, sc.leaf) }));
        e.value_ptr.* = if (e.found_existing) e.value_ptr.* + 1 else 1;
    }

    /// Rust warns about a type name that isn't CamelCase, which `typeLeaf` can give.
    fn caseAllow(n: []const u8) []const u8 {
        const camel_case = n.len > 0 and std.ascii.isUpper(n[0]) and std.mem.indexOfScalar(u8, n, '_') == null;
        return if (camel_case) "" else "#[allow(non_camel_case_types)]\n";
    }

    /// Writes into the module `name` goes in, giving its scope.
    fn enterFor(g: *Gen, name: []const u8) Error!Scope {
        const sc = try g.scopeOf(name);
        g.cur = sc.ns;
        return sc;
    }

    // Function values

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

    fn prim(g: *Gen, p: Schema.Prim) Error![]const u8 {
        return switch (p) {
            .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .f32, .f64, .bool, .usize, .isize => @tagName(p),
            .utf8 => "u8",
            .utf16 => "u16",
            .string => g.fmt("{s}::Str", .{g.sal()}),
            .object => g.fmt("{s}::Object", .{g.sal()}),
            .blob => g.fmt("{s}::Blob", .{g.sal()}),
            .cstring => "*const u8",
            .void => "()",
        };
    }

    fn decl(g: *Gen, r: Ref) Error![]const u8 {
        return switch (r) {
            .prim => |p| g.prim(p),
            .named => |n| g.qual(n),
            .pointer => |c| if (c.* == .prim and c.prim == .void) "*mut ::core::ffi::c_void" else g.fmt("*mut {s}", .{try g.decl(c.*)}),
            .array => |a| g.fmt("[{s}; {d}]", .{ try g.decl(a.child.*), a.len }),
            .slice => |c| g.fmt("{s}::Slice<{s}>", .{ g.sal(), try g.decl(c.*) }),
            .optional => |c| if (c.* == .pointer or g.s.isObject(c.*)) g.decl(c.*) else g.fmt("{s}::Opt<{s}>", .{ g.sal(), try g.decl(c.*) }),
            .func => |sig| g.qual(g.fnOf(sig.*).name),
            .result => unreachable,
        };
    }

    fn converts(g: *Gen, r: Ref) bool {
        return switch (r) {
            .prim => |p| p == .string,
            .slice => true,
            .optional => |c| c.* != .pointer and !g.s.isObject(c.*),
            else => false,
        };
    }

    /// What methods take and give: `&str`, slices and `Option`s for what converts, the rest as it crosses.
    fn plain(g: *Gen, r: Ref) Error![]const u8 {
        if (!g.converts(r)) return g.decl(r);
        return switch (r) {
            .prim => "&str",
            .slice => |c| g.fmt("&[{s}]", .{try g.decl(c.*)}),
            .optional => |c| g.fmt("Option<{s}>", .{try g.plain(c.*)}),
            else => unreachable,
        };
    }

    fn lower(g: *Gen, r: Ref, e: []const u8) Error![]const u8 {
        if (!g.converts(r)) return e;
        return switch (r) {
            .prim => g.fmt("{s}::Str::new({s})", .{ g.sal(), e }),
            .slice => g.fmt("{s}::Slice::of({s})", .{ g.sal(), e }),
            .optional => |c| if (g.converts(c.*)) g.fmt("{s}::Opt::of({s}.map(|v| {s}))", .{ g.sal(), e, try g.lower(c.*, "v") }) else g.fmt("{s}::Opt::of({s})", .{ g.sal(), e }),
            else => unreachable,
        };
    }

    /// Inside `unsafe`, since it trusts what it points at.
    fn lift(g: *Gen, r: Ref, e: []const u8) Error![]const u8 {
        if (!g.converts(r)) return e;
        return switch (r) {
            .prim, .slice => g.fmt("{s}.get()", .{e}),
            .optional => |c| if (g.converts(c.*)) g.fmt("{s}.get().map(|v| {s})", .{ e, try g.lift(c.*, "v") }) else g.fmt("{s}.get()", .{e}),
            else => unreachable,
        };
    }

    /// A value of plain `r` for when there's nothing to call, written inside `unsafe` or not.
    fn zero(g: *Gen, r: Ref, in_unsafe: bool) []const u8 {
        if (r == .prim and r.prim == .void) return "()";
        if (r == .prim and r.prim == .string) return "\"\"";
        if (r == .slice) return "&[]";
        if (g.converts(r)) return "None";
        return if (in_unsafe) "::core::mem::zeroed()" else "unsafe { ::core::mem::zeroed() }";
    }

    fn abis(c: Schema.Conv) []const Abi {
        const x86 = "target_arch = \"x86\"";
        const not_x86 = "not(target_arch = \"x86\")";
        return switch (c) {
            .c, .cdecl => &.{.{ .cfg = "", .abi = "C" }},
            .stdcall => &.{ .{ .cfg = x86, .abi = "stdcall" }, .{ .cfg = not_x86, .abi = "C" } },
            .thiscall => &.{ .{ .cfg = x86, .abi = "thiscall" }, .{ .cfg = not_x86, .abi = "C" } },
            .fastcall => &.{ .{ .cfg = x86, .abi = "fastcall" }, .{ .cfg = not_x86, .abi = "C" } },
            .winapi => &.{
                .{ .cfg = "all(target_arch = \"x86_64\", not(windows))", .abi = "win64" },
                .{ .cfg = "not(all(target_arch = \"x86_64\", not(windows)))", .abi = "system" },
            },
        };
    }

    fn cfgOf(g: *Gen, a: Abi, indent: []const u8) Error![]const u8 {
        return if (a.cfg.len == 0) "" else g.fmt("{s}#[cfg({s})]\n", .{ indent, a.cfg });
    }

    /// `(usize, f32, *mut Vec3)`, a table entry's parameters, named if `named`.
    fn entryParams(g: *Gen, m: *const Schema.Method, named: bool) Error![]const u8 {
        var o: std.Io.Writer.Allocating = .init(g.a);
        const w = &o.writer;
        try w.writeAll("(");
        var first = true;
        if (!m.static) {
            try w.writeAll(if (named) "sal_this: usize" else "usize");
            first = false;
        }
        for (m.signature.params) |p| {
            if (!first) try w.writeAll(", ");
            first = false;
            const t = try g.decl(p.type);
            if (named) try w.print("{s}: {s}", .{ try g.local(p.name), t }) else try w.writeAll(t);
        }
        if (!m.async) if (resultOk(m.signature.ret)) |ok| {
            if (!first) try w.writeAll(", ");
            const t = try g.fmt("*mut {s}", .{try g.decl(ok)});
            if (named) try w.print("sal_out: {s}", .{t}) else try w.writeAll(t);
        };
        try w.writeAll(")");
        return o.written();
    }

    /// ` -> u32`, what a table entry gives, nothing for void.
    fn entryRet(g: *Gen, m: *const Schema.Method) Error![]const u8 {
        if (m.async) return g.fmt(" -> {s}::Promise", .{g.sal()});
        if (m.signature.ret == .result) return " -> u32";
        if (isVoid(m.signature.ret)) return "";
        return g.fmt(" -> {s}", .{try g.decl(m.signature.ret)});
    }

    fn errorOf(g: *Gen, m: *const Schema.Method) Error![]const u8 {
        return switch (m.signature.ret) {
            .result => |res| g.qual(res.err),
            else => g.fmt("{s}::Code", .{g.sal()}),
        };
    }

    /// What a method gives back in plain Rust.
    fn plainRet(g: *Gen, m: *const Schema.Method) Error![]const u8 {
        const err = try g.errorOf(m);
        if (m.async) {
            const ok: Ref = switch (m.signature.ret) {
                .result => |res| res.ok.*,
                else => m.signature.ret,
            };
            return g.fmt("{s}::Future<{s}, {s}>", .{ g.sal(), try g.decl(ok), err });
        }
        return switch (m.signature.ret) {
            .result => |res| g.fmt("Result<{s}, {s}>", .{ try g.plain(res.ok.*), err }),
            else => g.plain(m.signature.ret),
        };
    }

    fn arrow(ret: []const u8) []const u8 {
        return if (std.mem.eql(u8, ret, "()")) "" else " -> ";
    }

    fn retText(ret: []const u8) []const u8 {
        return if (std.mem.eql(u8, ret, "()")) "" else ret;
    }

    // How each thing's declared, which `Names` gives docs too. Paths are from the module being written.

    /// A method's parameters as plain Rust, `self` and `this` aside.
    fn paramDecls(g: *Gen, m: *const Schema.Method, plain_: bool) Error![]const lang.Param {
        const list = try g.a.alloc(lang.Param, m.signature.params.len);
        for (m.signature.params, list) |p, *q| {
            const pn = try g.local(p.name);
            const t = if (plain_) try g.plain(p.type) else try g.decl(p.type);
            q.* = .{ .name = pn, .type = t, .text = try g.fmt("{s}: {s}", .{ pn, t }) };
        }
        return list;
    }

    fn params(g: *Gen, m: *const Schema.Method) Error![]const u8 {
        return lang.paramList(g.a, try g.paramDecls(m, true));
    }

    /// `&self` or `&mut self`, then the rest.
    fn selfList(g: *Gen, this: []const u8, ps: []const lang.Param) Error![]const u8 {
        const rest = try lang.paramList(g.a, ps);
        if (this.len == 0) return rest;
        return if (rest.len > 0) g.fmt("{s}, {s}", .{ this, rest }) else this;
    }

    /// A trait object's method, like `pub fn heal(&self, amount: u32) -> Result<(), E>`.
    fn methodDecl(g: *Gen, m: *const Schema.Method) Error!lang.Decl {
        const n = try g.field(m.name);
        const ret = try g.plainRet(m);
        const ps = try g.paramDecls(m, true);
        return .{ .name = n, .params = ps, .type = retText(ret), .text = try g.fmt("pub fn {s}({s}){s}{s}", .{ n, try g.selfList("&self", ps), arrow(ret), retText(ret) }) };
    }

    fn fieldDecl(g: *Gen, f: Schema.Field) Error!lang.Decl {
        const n = try g.field(f.name);
        const t = try g.decl(f.type);
        return .{ .name = n, .type = t, .text = try g.fmt("pub {s}: {s}", .{ n, t }) };
    }

    /// Existing code's function, a struct's when `in` is set. Null when it can't be called.
    fn declaredDecl(g: *Gen, in: ?*const Schema.Type, m: *const Schema.Method) Error!?lang.Decl {
        if (!callable(m)) return null;
        const sc = try g.scopeOf(m.name);
        const n = try g.field(if (in != null) m.name else sc.leaf);
        const ps = try g.paramDecls(m, false);
        const ret = if (isVoid(m.signature.ret)) "" else try g.decl(m.signature.ret);
        return .{
            .name = n,
            .path = if (in != null) null else try g.pathTo(sc.ns, n, sc.alias),
            .params = ps,
            .type = ret,
            .text = try g.fmt("pub unsafe fn {s}({s}){s}{s}", .{ n, try g.selfList(if (in != null and !m.static) "&mut self" else "", ps), if (ret.len > 0) " -> " else "", ret }),
        };
    }

    /// A static's getter: what a pointer one stores, or where it is.
    fn staticDecl(g: *Gen, in: ?*const Schema.Type, v: Schema.Static) Error!lang.Decl {
        const sc = try g.scopeOf(v.name);
        const n = try g.field(if (in != null) v.name else sc.leaf);
        const t = try g.decl(v.type);
        const ret = if (isStored(v)) t else try g.fmt("*mut {s}", .{t});
        return .{ .name = n, .path = if (in != null) null else try g.pathTo(sc.ns, n, sc.alias), .type = ret, .text = try g.fmt("pub unsafe fn {s}() -> {s}", .{ n, ret }) };
    }

    fn constantDecl(g: *Gen, k: Schema.Constant) Error!lang.Decl {
        const sc = try g.scopeOf(k.name);
        const n = try g.valueName(sc.leaf);
        const t: []const u8 = switch (k.value) {
            .bool => "bool",
            .string => "&str",
            else => @tagName(k.type.prim),
        };
        return .{ .name = n, .path = try g.pathTo(sc.ns, n, sc.alias), .type = t, .text = try g.fmt("pub const {s}: {s}", .{ n, t }) };
    }

    /// An enum's value, an error or a constant, like `SET_SPEED`.
    fn valueName(g: *Gen, n: []const u8) Error![]const u8 {
        return g.ident(try screaming(g.a, n));
    }

    // The file

    fn file(g: *Gen) Error!void {
        const s = g.s;
        g.cur = "";
        try g.countCamels();
        if (g.o.core) try g.print("#[allow(unused_imports)]\nuse crate::{{Info, Owner}};\n", .{});
        const laid_out = for (s.types) |t| {
            if (t.kind == .@"struct" or t.kind == .@"union") break true;
        } else false;
        if (laid_out) try g.print("\nconst _: () = assert!(::core::mem::size_of::<usize>() == {d}, \"these types are for {d}-bit code\");\n", .{ s.pointer_size, @as(usize, s.pointer_size) * 8 });

        for (s.types) |t| if (t.kind == .func and !g.aliased(t.at)) {
            for (t.kind.func.params) |p| try g.collect(p.type, try g.fmt("{s}_{s}", .{ t.name, p.name }));
            try g.collect(t.kind.func.ret, t.name);
            try g.fns.list.append(g.a, .{ .name = t.name, .ref = .{ .named = t.name }, .hash = Schema.signatureHash(t.kind.func) });
        };
        for (s.types) |t| if (!g.aliased(t.at)) switch (t.kind) {
            .@"struct", .@"union" => |st| for (st.fields) |f| try g.collect(f.type, try g.fmt("{s}_{s}", .{ t.name, f.name })),
            else => {},
        };
        for (s.traits) |*t| if (!g.aliased(t.at)) for (t.methods) |m| {
            for (m.signature.params) |p| try g.collect(p.type, try g.fmt("{s}_{s}_{s}", .{ t.name, m.name, p.name }));
            try g.collect(m.signature.ret, try g.fmt("{s}_{s}", .{ t.name, m.name }));
        };
        for (s.types) |t| if (t.kind == .@"struct" and !g.aliased(t.at)) for (t.kind.@"struct".methods) |m| {
            for (m.signature.params) |p| try g.collect(p.type, try g.fmt("{s}_{s}_{s}", .{ t.name, m.name, p.name }));
            try g.collect(m.signature.ret, try g.fmt("{s}_{s}", .{ t.name, m.name }));
        };
        for (s.functions) |m| {
            for (m.signature.params) |p| try g.collect(p.type, try g.fmt("{s}_{s}", .{ m.name, p.name }));
            try g.collect(m.signature.ret, m.name);
        }

        for (s.types) |*t| if (!g.aliased(t.at)) switch (t.kind) {
            .@"enum" => |e| try g.enumDef(t, e),
            .@"error" => |e| try g.errorDef(t, e),
            .bitfield => |b| try g.bitfieldDef(t, b),
            .@"struct", .@"union" => try g.structDef(t),
            // The crate has the runtime's own
            .@"opaque" => if (!g.o.core) try g.opaqueDef(t),
            .func => {},
        };
        for (s.constants) |k| if (!g.aliased(k.at)) try g.constant(k);
        for (g.fns.list.items) |f| {
            const m: Schema.Method = .{ .name = "call", .signature = g.sigOf(f) };
            const ms = [_]*const Schema.Method{&m};
            try g.object(f.name, null, &ms, 0, "fn", &.{Schema.signatureHash(m.signature)});
        }
        for (s.traits) |*t| if (!g.aliased(t.at)) {
            var buf: [plan.max_methods]*const Schema.Method = undefined;
            const ms = plan.methods(g.s, t, &buf);
            const sigs = try g.a.alloc(u64, ms.len);
            for (ms, 0..) |m, i| sigs[i] = Schema.methodHash(m);
            try g.object(t.name, t, ms, g.s.traitHash(t), t.name, sigs);
        };
        try g.declared();
        try g.finish();
    }

    /// Each module once, nested in the ones around it.
    fn finish(g: *Gen) Error!void {
        try g.w.print(
            \\// Generated by salamander from {s}. Don't edit it, it's written again every build.
            \\// Use it as a module, like `mod schema {{ include!(concat!(env!("OUT_DIR"), "/schema.rs")); }}`.
            \\
        , .{g.o.label});
        var all: std.ArrayList([]const u8) = .empty;
        for (g.mods.keys()) |k| {
            var at = k;
            while (true) {
                if (!contains(all.items, at)) try all.append(g.a, at);
                at = at[0 .. std.mem.lastIndexOf(u8, at, "::") orelse break];
            }
        }
        if (!contains(all.items, "")) try all.append(g.a, "");
        std.mem.sort([]const u8, all.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        try g.writeMod("", all.items);
    }

    fn writeMod(g: *Gen, path: []const u8, all: []const []const u8) Error!void {
        if (g.mods.getPtr(path)) |text| try g.w.writeAll(text.written());
        for (all) |child| {
            if (child.len == 0 or std.mem.eql(u8, child, path)) continue;
            const parent = child[0 .. std.mem.lastIndexOf(u8, child, "::") orelse 0];
            if (!std.mem.eql(u8, parent, path)) continue;
            const seg = if (std.mem.lastIndexOf(u8, child, "::")) |i| child[i + 2 ..] else child;
            try g.w.print("\npub mod {s} {{\n", .{seg});
            try g.writeMod(child, all);
            try g.w.print("}}\n", .{});
        }
    }

    fn enumDef(g: *Gen, t: *const Schema.Type, e: Schema.Enum) Error!void {
        _ = try g.enterFor(t.name);
        const n = try g.typeName(t.name);
        try g.claim(n);
        try g.print("\n{s}#[repr(transparent)]\n#[derive(Clone, Copy, Default, PartialEq, Eq, Hash, Debug)]\npub struct {s}(pub {s});\n\nimpl {s} {{\n", .{ caseAllow(n), n, try g.prim(e.backing), n });
        for (e.values) |v| try g.print("    pub const {s}: {s} = {s}({d});\n", .{ try g.valueName(v.name), n, n, v.value });
        try g.print("}}\n", .{});
    }

    fn errorDef(g: *Gen, t: *const Schema.Type, e: Schema.ErrorSet) Error!void {
        _ = try g.enterFor(t.name);
        const n = try g.typeName(t.name);
        const sal_ = g.sal();
        try g.claim(n);
        try g.print("\n// Codes a result can give, with the ones every result can.\n{s}#[repr(transparent)]\n#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]\npub struct {s}(pub u32);\n\nimpl {s} {{\n", .{ caseAllow(n), n, n });
        for (e.errors) |x| try g.print("    pub const {s}: {s} = {s}({d});\n", .{ try g.valueName(x.name), n, n, x.code });
        try g.print(
            \\    pub const CANCELLED: {s} = {s}({s}::CANCELLED);
            \\    pub const UNSUPPORTED: {s} = {s}({s}::UNSUPPORTED);
            \\    pub const GONE: {s} = {s}({s}::GONE);
            \\}}
            \\
            \\impl {s}::ErrorCode for {s} {{
            \\    const CANCELLED: Self = {s}::CANCELLED;
            \\    const UNSUPPORTED: Self = {s}::UNSUPPORTED;
            \\    const GONE: Self = {s}::GONE;
            \\    fn from_code(code: u32) -> Self {{
            \\        {s}(code)
            \\    }}
            \\    fn code(self) -> u32 {{
            \\        self.0
            \\    }}
            \\}}
            \\
            \\impl ::core::fmt::Display for {s} {{
            \\    fn fmt(&self, f: &mut ::core::fmt::Formatter<'_>) -> ::core::fmt::Result {{
            \\        match self.0 {{
            \\
        , .{ n, n, sal_, n, n, sal_, n, n, sal_, sal_, n, n, n, n, n, n });
        for (e.errors) |x| try g.print("            {d} => f.write_str(\"{s}\"),\n", .{ x.code, x.name });
        try g.print(
            \\            {s}::CANCELLED => f.write_str("Cancelled"),
            \\            {s}::UNSUPPORTED => f.write_str("Unsupported"),
            \\            {s}::GONE => f.write_str("Gone"),
            \\            c => write!(f, "code {{c}}"),
            \\        }}
            \\    }}
            \\}}
            \\
            \\impl ::std::error::Error for {s} {{}}
            \\
        , .{ sal_, sal_, sal_, n });
    }

    fn bitfieldDef(g: *Gen, t: *const Schema.Type, b: Schema.Bitfield) Error!void {
        _ = try g.enterFor(t.name);
        const n = try g.typeName(t.name);
        const back = try g.prim(b.backing);
        try g.claim(n);
        try g.print("\n{s}#[repr(transparent)]\n#[derive(Clone, Copy, Default, PartialEq, Eq, Hash, Debug)]\npub struct {s}(pub {s});\n\n#[allow(clippy::all, unused_unsafe)]\nimpl {s} {{\n", .{ caseAllow(n), n, back, n });
        var seen: std.ArrayList([]const u8) = .empty;
        for (b.members) |m| {
            const mask = try g.fmt("0x{x}u64", .{(@as(u128, 1) << @intCast(m.bits)) - 1});
            const get = try g.field(m.name);
            const with = try g.fmt("with_{s}", .{try snake(g.a, m.name)});
            for ([_][]const u8{ get, with }) |x| {
                if (contains(seen.items, x)) {
                    g.diag.print("{s}.{s}: Rust can't have two members called that", .{ t.name, x });
                    return error.NameClash;
                }
                try seen.append(g.a, x);
            }
            const read = try g.fmt("(((self.0 as u64) >> {d}) & {s})", .{ m.bit, mask });
            const put = try g.fmt("Self((((self.0 as u64) & !({s} << {d})) | ((X & {s}) << {d})) as {s})", .{ mask, m.bit, mask, m.bit, back });
            switch (m.type) {
                .bool => if (m.bits == 1) {
                    try g.print("    pub const fn {s}(self) -> bool {{\n        {s} != 0\n    }}\n", .{ get, read });
                    try g.print("    pub const fn {s}(self, x: bool) -> Self {{\n        {s}\n    }}\n", .{ with, try std.mem.replaceOwned(u8, g.a, put, "X", "(x as u64)") });
                } else try g.uintMember(get, with, back, read, put),
                .uint => try g.uintMember(get, with, back, read, put),
                .@"enum" => |en| {
                    const et = try g.qual(en);
                    const eb = try g.prim(g.s.findType(en).?.kind.@"enum".backing);
                    try g.print("    pub const fn {s}(self) -> {s} {{\n        {s}({s} as {s})\n    }}\n", .{ get, et, et, read, eb });
                    try g.print("    pub const fn {s}(self, x: {s}) -> Self {{\n        {s}\n    }}\n", .{ with, et, try std.mem.replaceOwned(u8, g.a, put, "X", "(x.0 as u64)") });
                },
            }
        }
        try g.print("}}\n\nconst _: () = assert!(::core::mem::size_of::<{s}>() == ::core::mem::size_of::<{s}>(), \"{s}'s size\");\n", .{ n, back, t.name });
    }

    fn uintMember(g: *Gen, get: []const u8, with: []const u8, back: []const u8, read: []const u8, put: []const u8) Error!void {
        try g.print("    pub const fn {s}(self) -> {s} {{\n        {s} as {s}\n    }}\n", .{ get, back, read, back });
        try g.print("    pub const fn {s}(self, x: {s}) -> Self {{\n        {s}\n    }}\n", .{ with, back, try std.mem.replaceOwned(u8, g.a, put, "X", "(x as u64)") });
    }

    fn constant(g: *Gen, k: Schema.Constant) Error!void {
        _ = try g.enterFor(k.name);
        const d = try g.constantDecl(k);
        try g.claim(d.name);
        const p = k.type.prim;
        const value = switch (k.value) {
            .int => |v| if (p.isFloat()) try g.fmt("{d}_{s}", .{ v, @tagName(p) }) else try g.fmt("{d}", .{v}),
            .float => |v| try g.fmt("{d}_{s}", .{ v, @tagName(p) }),
            .bool => |v| try g.fmt("{}", .{v}),
            .string => |v| try g.fmt("\"{s}\"", .{v}),
        };
        try g.print("{s} = {s};\n", .{ d.text.?, value });
    }

    fn opaqueDef(g: *Gen, t: *const Schema.Type) Error!void {
        _ = try g.enterFor(t.name);
        const n = try g.typeName(t.name);
        try g.claim(n);
        try g.print("\n// Only ever behind a pointer\n{s}#[repr(C)]\npub struct {s} {{\n    _opaque: [u8; 0],\n}}\n", .{ caseAllow(n), n });
    }

    fn structDef(g: *Gen, t: *const Schema.Type) Error!void {
        _ = try g.enterFor(t.name);
        const n = try g.typeName(t.name);
        try g.claim(n);
        // Nothing known inside, so it's only ever behind a pointer
        if (t.size == 0) {
            try g.print("\n{s}#[repr(C)]\npub struct {s} {{\n    _opaque: [u8; 0],\n}}\n", .{ caseAllow(n), n });
            return;
        }
        const is_union = t.kind == .@"union";
        // Rust can't lower one field's alignment, so a struct with any like that is packed with all its padding written out
        const repr = if (plan.packing(g.s, t)) |p| (if (p == 1) "C, packed" else try g.fmt("C, packed({d})", .{p})) else "C";
        try g.print("\n{s}#[repr({s})]\n#[derive(Clone, Copy)]\npub {s} {s} {{\n", .{ caseAllow(n), repr, if (is_union) "union" else "struct", n });
        var it: plan.Slots = .init(g.s, t);
        var fields: std.ArrayList(Schema.Field) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        while (it.next()) |slot| switch (slot) {
            .pad => |p| if (is_union) try g.print("    pub _bytes: [u8; 0x{x}],\n", .{p.len}) else try g.print("    pub _pad_0x{x}: [u8; 0x{x}],\n", .{ p.offset, p.len }),
            .field => |f| {
                const d = try g.fieldDecl(f.field);
                if (contains(names.items, d.name)) {
                    g.diag.print("{s}.{s}: Rust can't have two fields called that", .{ t.name, d.name });
                    return error.NameClash;
                }
                try names.append(g.a, d.name);
                try g.print("    {s},\n", .{d.text.?});
                try fields.append(g.a, f.field);
            },
        };
        try g.print(
            \\}}
            \\
            \\impl ::core::default::Default for {s} {{
            \\    fn default() -> Self {{
            \\        // Plain data, which zero is a value of
            \\        unsafe {{ ::core::mem::zeroed() }}
            \\    }}
            \\}}
            \\
            \\const _: () = assert!(::core::mem::size_of::<{s}>() == 0x{x}, "{s}'s size");
            \\
        , .{ n, n, t.size, t.name });
        if (plan.keepsAlignment(g.s, t)) try g.print("const _: () = assert!(::core::mem::align_of::<{s}>() == {d}, \"{s}'s alignment\");\n", .{ n, t.alignment, t.name });
        if (!is_union) for (fields.items) |f| {
            try g.print("const _: () = assert!(::core::mem::offset_of!({s}, {s}) == 0x{x}, \"{s}.{s}'s offset\");\n", .{ n, try g.field(f.name), f.offset, t.name, f.name });
        };
    }

    // Objects

    /// Its struct, table, info, methods, `...Impl` trait and the thunks a table made from one calls.
    fn object(g: *Gen, name: []const u8, t: ?*const Schema.Trait, ms: []const *const Schema.Method, hash: u64, label: []const u8, sigs: []const u64) Error!void {
        const sc = try g.enterFor(name);
        const n = try g.typeLeaf(sc);
        const up = try screaming(g.a, sc.leaf);
        const sal_ = g.sal();
        const is_fn = t == null;
        for ([_][]const u8{ n, try g.fmt("{s}Table", .{n}), try g.fmt("{s}Impl", .{n}), try g.fmt("{s}Thunks", .{n}), try g.fmt("{s}_INFO", .{up}), try g.fmt("{s}_METHODS", .{up}) }) |x| try g.claim(x);
        var mnames: std.ArrayList([]const u8) = .empty;
        for (ms) |m| {
            const mn = try g.field(m.name);
            if (contains(&.{ "data", "table" }, mn) or contains(mnames.items, mn)) {
                g.diag.print("{s}.{s}: Rust trait objects can't have two of that", .{ name, m.name });
                return error.NameClash;
            }
            try mnames.append(g.a, mn);
        }

        try g.print(
            \\
            \\// {s}
            \\#[repr(C)]
            \\#[derive(Clone, Copy)]
            \\pub struct {s} {{
            \\    pub data: usize,
            \\    pub table: *const {s}Table,
            \\}}
            \\
            \\unsafe impl ::core::marker::Send for {s} {{}}
            \\unsafe impl ::core::marker::Sync for {s} {{}}
            \\
            \\impl ::core::default::Default for {s} {{
            \\    fn default() -> Self {{
            \\        Self {{ data: 0, table: ::core::ptr::null() }}
            \\    }}
            \\}}
            \\
            \\// A null method is one this table doesn't have.
            \\#[repr(C)]
            \\pub struct {s}Table {{
            \\    pub salamander_info: *const {s}::Info,
            \\    pub salamander_owner: *mut {s}::Owner,
            \\
        , .{ label, n, n, n, n, n, n, sal_, sal_ });
        for (ms) |m| for (abis(m.signature.conv)) |a| {
            try g.print("{s}    pub {s}: Option<unsafe extern \"{s}\" fn{s}{s}>,\n", .{ try g.cfgOf(a, "    "), try g.field(m.name), a.abi, try g.entryParams(m, false), try g.entryRet(m) });
        };
        try g.print("}}\n\nunsafe impl ::core::marker::Sync for {s}Table {{}}\n", .{n});

        if (ms.len > 0) {
            try g.print("\npub static {s}_METHODS: [{s}::MethodInfo; {d}] = [\n", .{ up, sal_, ms.len });
            for (ms, sigs) |m, sig| try g.print("    {s}::MethodInfo {{ name: {s}::Str::new(\"{s}\"), sig: 0x{x:0>16} }},\n", .{ sal_, sal_, m.name, sig });
            try g.print("];\n", .{});
        }
        try g.print("\npub static {s}_INFO: {s}::Info = {s}::Info {{\n    hash: 0x{x:0>16},\n    abi: {s}::ABI_VERSION,\n    name: {s}::Str::new(\"{s}\"),\n    methods: {s},\n    methods_len: {d},\n}};\n", .{
            up,                                                                                  sal_,   sal_, hash, sal_, sal_, label,
            if (ms.len > 0) try g.fmt("{s}_METHODS.as_ptr()", .{up}) else "::core::ptr::null()", ms.len,
        });

        try g.print(
            \\
            \\unsafe impl {s}::TraitObject for {s} {{
            \\    const INFO: &'static {s}::Info = &{s}_INFO;
            \\    fn object(self) -> {s}::Object {{
            \\        {s}::Object {{ data: self.data, table: self.table as *const ::core::ffi::c_void }}
            \\    }}
            \\    fn from_object(o: {s}::Object) -> Self {{
            \\        Self {{ data: o.data, table: o.table as *const {s}Table }}
            \\    }}
            \\}}
            \\
        , .{ sal_, n, sal_, up, sal_, sal_, sal_, n });
        if (t) |tr| {
            var bases: std.ArrayList([]const u8) = .empty;
            try g.addBases(tr, &bases, 0);
            for (bases.items) |b| try g.print("impl {s}::Extends<{s}> for {s} {{}}\n", .{ sal_, try g.qual(b), n });
        }

        // Calling it
        try g.print("\n#[allow(clippy::all, unused_unsafe)]\nimpl {s} {{\n", .{n});
        for (helpers) |h| {
            if (contains(mnames.items, h)) continue;
            if (std.mem.eql(u8, h, "from_static")) {
                try g.print("    // One calling imp, which lives as long as the program\n    pub fn from_static<T: {s}Impl>(imp: &'static T) -> Self {{\n        {s}::from_static(imp)\n    }}\n\n", .{ n, sal_ });
            } else if (std.mem.eql(u8, h, "borrowed")) {
                try g.print("    // One calling imp, which has to outlive it\n    pub unsafe fn borrowed<T: {s}Impl>(imp: &T) -> Self {{\n        unsafe {{ {s}::borrowed(imp) }}\n    }}\n\n", .{ n, sal_ });
            } else {
                try g.print("    // A heap copy of imp, which the host lets go of. Needs salamander::init\n    pub fn keep<T: {s}Impl + ::core::marker::Send + ::core::marker::Sync + 'static>(imp: T) -> Self {{\n        {s}::keep(imp)\n    }}\n\n", .{ n, sal_ });
            }
        }
        for (ms) |m| try g.caller(m);
        try g.print("}}\n", .{});

        try g.implTrait(n, ms, is_fn);
        try g.thunks(n, up, ms, is_fn);
    }

    fn addBases(g: *Gen, t: *const Schema.Trait, all: *std.ArrayList([]const u8), depth: usize) Error!void {
        if (depth > g.s.traits.len) return;
        for (t.bases) |b| {
            if (contains(all.items, b)) continue;
            try all.append(g.a, b);
            if (g.s.findTrait(b)) |base| try g.addBases(base, all, depth + 1);
        }
    }

    /// A method calling through the table, entering its owner around the call.
    fn caller(g: *Gen, m: *const Schema.Method) Error!void {
        const d = try g.methodDecl(m);
        const mn = d.name;
        const sal_ = g.sal();
        var args: std.Io.Writer.Allocating = .init(g.a);
        if (!m.static) try args.writer.writeAll("self.data");
        for (m.signature.params) |p| {
            if (args.written().len > 0) try args.writer.writeAll(", ");
            try args.writer.writeAll(try g.lower(p.type, try g.local(p.name)));
        }
        try g.print("    {s} {{\n        unsafe {{\n", .{d.text.?});
        if (!m.async and m.signature.ret == .result) {
            const res = m.signature.ret.result;
            const err = try g.qual(res.err);
            try g.print(
                \\            let Some(sal_t) = self.table.as_ref() else {{ return Err(<{s} as {s}::ErrorCode>::GONE) }};
                \\            let Some(sal_f) = sal_t.{s} else {{ return Err(<{s} as {s}::ErrorCode>::UNSUPPORTED) }};
                \\            let Some(_sal_g) = {s}::Entered::new(sal_t.salamander_owner) else {{ return Err(<{s} as {s}::ErrorCode>::GONE) }};
                \\
            , .{ err, sal_, mn, err, sal_, sal_, err, sal_ });
            if (isVoid(res.ok.*)) {
                try g.print("            let sal_c = sal_f({s});\n            if sal_c == {s}::OK {{ Ok(()) }} else {{ Err(<{s} as {s}::ErrorCode>::from_code(sal_c)) }}\n", .{ args.written(), sal_, err, sal_ });
            } else {
                const sep: []const u8 = if (args.written().len > 0) ", " else "";
                try g.print("            let mut sal_out: {s} = ::core::mem::zeroed();\n            let sal_c = sal_f({s}{s}&mut sal_out);\n            if sal_c == {s}::OK {{ Ok({s}) }} else {{ Err(<{s} as {s}::ErrorCode>::from_code(sal_c)) }}\n", .{ try g.decl(res.ok.*), args.written(), sep, sal_, try g.lift(res.ok.*, "sal_out"), err, sal_ });
            }
        } else {
            const none = if (m.async) try g.fmt("{s}::Future::none()", .{sal_}) else g.zero(m.signature.ret, true);
            try g.print(
                \\            let Some(sal_t) = self.table.as_ref() else {{ return {s} }};
                \\            let Some(sal_f) = sal_t.{s} else {{ return {s} }};
                \\            let Some(_sal_g) = {s}::Entered::new(sal_t.salamander_owner) else {{ return {s} }};
                \\
            , .{ none, mn, none, sal_, none });
            if (m.async) {
                try g.print("            {s}::Future::from_promise(sal_f({s}))\n", .{ sal_, args.written() });
            } else if (isVoid(m.signature.ret)) {
                try g.print("            sal_f({s})\n", .{args.written()});
            } else {
                try g.print("            let sal_r = sal_f({s});\n            {s}\n", .{ args.written(), try g.lift(m.signature.ret, "sal_r") });
            }
        }
        try g.print("        }}\n    }}\n\n", .{});
    }

    /// `...Impl`, what a type implements it with. Every method has a default, so it needs only the ones it has.
    fn implTrait(g: *Gen, n: []const u8, ms: []const *const Schema.Method, is_fn: bool) Error!void {
        const sal_ = g.sal();
        try g.print("\n// What implements {s}. Ones left out give zero, or Unsupported for a result\n#[allow(clippy::all, unused_unsafe)]\npub trait {s}Impl {{\n", .{ n, n });
        for (ms) |m| {
            var ret = try g.plainRet(m);
            // Nothing for an elided lifetime to come from
            if (m.static and std.mem.indexOfScalar(u8, ret, '&') != null) ret = try std.mem.replaceOwned(u8, g.a, ret, "&", "&'static ");
            var names: std.ArrayList(u8) = .empty;
            for (m.signature.params, 0..) |p, i| {
                if (i > 0) try names.appendSlice(g.a, ", ");
                try names.appendSlice(g.a, try g.local(p.name));
            }
            const recv: []const u8 = if (m.static) "" else if (m.signature.params.len > 0) "&self, " else "&self";
            const body = if (m.async)
                try g.fmt("{s}::Future::none()", .{sal_})
            else if (m.signature.ret == .result)
                try g.fmt("Err(<{s} as {s}::ErrorCode>::UNSUPPORTED)", .{ try g.errorOf(m), sal_ })
            else
                g.zero(m.signature.ret, false);
            const unused = if (m.signature.params.len > 0) try g.fmt("let _ = ({s},);\n        ", .{names.items}) else "";
            try g.print("    fn {s}({s}{s}){s}{s} {{\n        {s}{s}\n    }}\n", .{ try g.field(m.name), recv, try g.params(m), arrow(ret), retText(ret), unused, body });
        }
        try g.print("}}\n", .{});
        // Closures are function values
        if (is_fn) {
            const m = ms[0];
            const ret = try g.plainRet(m);
            if (std.mem.indexOfScalar(u8, ret, '&') == null) {
                var tys: std.ArrayList(u8) = .empty;
                var names: std.ArrayList(u8) = .empty;
                for (m.signature.params, 0..) |p, i| {
                    if (i > 0) {
                        try tys.appendSlice(g.a, ", ");
                        try names.appendSlice(g.a, ", ");
                    }
                    try tys.appendSlice(g.a, try g.plain(p.type));
                    try names.appendSlice(g.a, try g.local(p.name));
                }
                try g.print("\n#[allow(clippy::all, unused_unsafe)]\nimpl<F: Fn({s}){s}{s}> {s}Impl for F {{\n    fn call(&self{s}{s}){s}{s} {{\n        self({s})\n    }}\n}}\n", .{ tys.items, arrow(ret), retText(ret), n, if (m.signature.params.len > 0) ", " else "", try g.params(m), arrow(ret), retText(ret), names.items });
            }
        }
    }

    fn thunks(g: *Gen, n: []const u8, up: []const u8, ms: []const *const Schema.Method, is_fn: bool) Error!void {
        _ = is_fn;
        const sal_ = g.sal();
        try g.print("\n// What a table made from T calls\npub struct {s}Thunks<T>(::core::marker::PhantomData<T>);\n\n#[allow(clippy::all, unused_unsafe)]\nimpl<T: {s}Impl> {s}Thunks<T> {{\n    pub const TABLE: {s}Table = {s}Table {{\n        salamander_info: &{s}_INFO,\n        salamander_owner: ::core::ptr::null_mut(),\n", .{ n, n, n, n, n, up });
        for (ms) |m| for (abis(m.signature.conv)) |a| {
            const mn = try g.field(m.name);
            try g.print("{s}        {s}: Some(Self::{s}),\n", .{ try g.cfgOf(a, "        "), mn, mn });
        };
        try g.print("    }};\n", .{});
        for (ms) |m| {
            const mn = try g.field(m.name);
            var args: std.Io.Writer.Allocating = .init(g.a);
            for (m.signature.params, 0..) |p, i| {
                if (i > 0) try args.writer.writeAll(", ");
                try args.writer.writeAll(try g.lift(p.type, try g.local(p.name)));
            }
            const call = if (m.static)
                try g.fmt("T::{s}({s})", .{ mn, args.written() })
            else
                try g.fmt("(*(sal_this as *const T)).{s}({s})", .{ mn, args.written() });
            const body = if (m.async)
                try g.fmt("{s}::guard(|| unsafe {{ {s}.into_promise() }})", .{ sal_, call })
            else if (m.signature.ret == .result) blk: {
                const ok_arm = if (resultOk(m.signature.ret)) |ok|
                    try g.fmt("Ok(sal_v) => {{\n                    if !sal_out.is_null() {{\n                        *sal_out = {s};\n                    }}\n                    {s}::OK\n                }}", .{ try g.lower(ok, "sal_v"), sal_ })
                else
                    try g.fmt("Ok(()) => {s}::OK,", .{sal_});
                break :blk try g.fmt("{s}::guard_code(|| unsafe {{\n            match {s} {{\n                {s}\n                Err(e) => {s}::ErrorCode::code(e),\n            }}\n        }})", .{ sal_, call, ok_arm, sal_ });
            } else if (isVoid(m.signature.ret))
                try g.fmt("{s}::guard(|| unsafe {{ {s} }})", .{ sal_, call })
            else
                try g.fmt("{s}::guard(|| unsafe {{\n            let sal_v = {s};\n            {s}\n        }})", .{ sal_, call, try g.lower(m.signature.ret, "sal_v") });
            for (abis(m.signature.conv)) |a| {
                try g.print("\n{s}    unsafe extern \"{s}\" fn {s}{s}{s} {{\n        {s}\n    }}\n", .{ try g.cfgOf(a, "    "), a.abi, mn, try g.entryParams(m, true), try g.entryRet(m), body });
            }
        }
        try g.print(
            \\}}
            \\
            \\unsafe impl<T: {s}Impl> {s}::Implements<T> for {s} {{
            \\    fn table() -> *const ::core::ffi::c_void {{
            \\        (const {{ &{s}Thunks::<T>::TABLE }}) as *const {s}Table as *const ::core::ffi::c_void
            \\    }}
            \\}}
            \\
        , .{ n, sal_, n, n, n });
    }

    // Existing code the schema declares: each one's full name, a pointer type for functions, and calls.

    fn declared(g: *Gen) Error!void {
        const s = g.s;
        for (s.types) |*t| if (t.kind == .@"struct" and !g.aliased(t.at)) {
            const st = t.kind.@"struct";
            if (st.methods.len == 0 and st.statics.len == 0) continue;
            for (st.methods) |*m| try g.declaredFn(t, m, false);
            for (st.statics) |v| try g.declaredStatic(t, v, false);
            _ = try g.enterFor(t.name);
            try g.print("\n#[allow(clippy::all, unused_unsafe)]\nimpl {s} {{\n", .{try g.typeName(t.name)});
            var seen: std.ArrayList([]const u8) = .empty;
            for (st.methods) |*m| {
                try g.memberName(t, &seen, try g.field(m.name));
                try g.declaredFn(t, m, true);
            }
            for (st.statics) |v| {
                try g.memberName(t, &seen, try g.field(v.name));
                try g.declaredStatic(t, v, true);
            }
            try g.print("}}\n", .{});
        };
        for (s.functions) |*m| if (!g.aliased(m.at)) {
            try g.declaredFn(null, m, false);
            try g.declaredFn(null, m, true);
        };
        for (s.statics) |v| if (!g.aliased(v.at)) {
            try g.declaredStatic(null, v, false);
            try g.declaredStatic(null, v, true);
        };
    }

    fn memberName(g: *Gen, t: *const Schema.Type, seen: *std.ArrayList([]const u8), n: []const u8) Error!void {
        if (contains(seen.items, n)) {
            g.diag.print("{s}.{s}: Rust can't have two methods called that", .{ t.name, n });
            return error.NameClash;
        }
        try seen.append(g.a, n);
    }

    fn callable(m: *const Schema.Method) bool {
        if (m.async or m.signature.ret == .result) return false;
        for (m.signature.params) |p| if (p.type == .result) return false;
        return true;
    }

    /// `PLAYER_HEAL` and `PlayerHeal`, in Player's module.
    fn declaredNames(g: *Gen, in: ?*const Schema.Type, name: []const u8) Error!struct { []const u8, []const u8 } {
        const site = if (in) |t| try g.fmt("{s}_{s}", .{ t.name, name }) else name;
        const sc = try g.enterFor(site);
        return .{ try screaming(g.a, sc.leaf), try camel(g.a, sc.leaf) };
    }

    /// Its name and pointer type when not `wrap`, else its call, in the struct's `impl` for a struct's.
    fn declaredFn(g: *Gen, in: ?*const Schema.Type, m: *const Schema.Method, wrap: bool) Error!void {
        const up, const cam = try g.declaredNames(in, m.name);
        const full = if (in) |t| try g.fmt("{s}.{s}", .{ t.name, m.name }) else m.name;
        const name_id = try g.fmt("{s}_NAME", .{up});
        const fn_id = try g.fmt("{s}Fn", .{cam});
        const has_this = in != null and !m.static;
        if (!wrap) {
            try g.claim(name_id);
            try g.print("\n// {s}{s}\npub const {s}: &str = \"{s}\";\n", .{ full, if (m.virtual) |slot| try g.fmt(", slot {d} of its vtable", .{slot}) else "", name_id, full });
            if (!callable(m)) return;
            try g.claim(fn_id);
            var ps: std.ArrayList(u8) = .empty;
            if (has_this) try ps.appendSlice(g.a, try g.fmt("*mut {s}", .{try g.qual(in.?.name)}));
            for (m.signature.params) |p| {
                if (ps.items.len > 0) try ps.appendSlice(g.a, ", ");
                try ps.appendSlice(g.a, try g.decl(p.type));
            }
            const ret = if (isVoid(m.signature.ret)) "" else try g.fmt(" -> {s}", .{try g.decl(m.signature.ret)});
            for (abis(m.signature.conv)) |a| try g.print("{s}pub type {s} = unsafe extern \"{s}\" fn({s}){s};\n", .{ try g.cfgOf(a, ""), fn_id, a.abi, ps.items, ret });
            return;
        }
        if (!callable(m)) return;
        const indent: []const u8 = if (in != null) "    " else "";
        // A top-level one goes in its namespace's module by its last name
        const fname = try g.field(if (in != null) m.name else (try g.scopeOf(m.name)).leaf);
        if (in == null) try g.claim(fname);
        var args: std.ArrayList(u8) = .empty;
        if (has_this) try args.appendSlice(g.a, "self");
        for (m.signature.params) |p| {
            if (args.items.len > 0) try args.appendSlice(g.a, ", ");
            try args.appendSlice(g.a, try g.local(p.name));
        }
        const sal_ = g.sal();
        try g.print("\n{s}// {s}, found by name the first time\n{s}#[allow(clippy::all, unused_unsafe)]\n{s}{s} {{\n{s}    unsafe {{\n", .{ indent, full, indent, indent, (try g.declaredDecl(in, m)).?.text.?, indent });
        if (m.virtual) |slot| {
            try g.print("{s}        let sal_at = {s}::declared::slot(self as *const Self as *const ::core::ffi::c_void, {d});\n", .{ indent, sal_, slot });
        } else {
            try g.print("{s}        static SAL_SITE: {s}::declared::Site = {s}::declared::Site::new({s});\n{s}        let sal_at = SAL_SITE.get();\n", .{ indent, sal_, sal_, name_id, indent });
        }
        try g.print("{s}        if sal_at == 0 {{\n{s}            {s}::declared::missing({s});\n{s}        }}\n", .{ indent, indent, sal_, name_id, indent });
        try g.print("{s}        let sal_f: {s} = ::core::mem::transmute(sal_at);\n{s}        sal_f({s})\n{s}    }}\n{s}}}\n", .{ indent, fn_id, indent, args.items, indent, indent });
    }

    fn isStored(v: Schema.Static) bool {
        return v.type == .pointer or (v.type == .optional and v.type.optional.* == .pointer);
    }

    fn declaredStatic(g: *Gen, in: ?*const Schema.Type, v: Schema.Static, wrap: bool) Error!void {
        const up, _ = try g.declaredNames(in, v.name);
        const full = if (in) |t| try g.fmt("{s}.{s}", .{ t.name, v.name }) else v.name;
        const name_id = try g.fmt("{s}_NAME", .{up});
        if (!wrap) {
            try g.claim(name_id);
            try g.print("\n// {s}, a {s}\npub const {s}: &str = \"{s}\";\n", .{ full, try g.decl(v.type), name_id, full });
            return;
        }
        const stored = isStored(v);
        const t = try g.decl(v.type);
        const ret = if (stored) t else try g.fmt("*mut {s}", .{t});
        const indent: []const u8 = if (in != null) "    " else "";
        const fname = try g.field(if (in != null) v.name else (try g.scopeOf(v.name)).leaf);
        if (in == null) try g.claim(fname);
        const sal_ = g.sal();
        try g.print("\n{s}// {s}, null till it's found\n{s}#[allow(clippy::all, unused_unsafe)]\n{s}{s} {{\n{s}    unsafe {{\n{s}        static SAL_SITE: {s}::declared::Site = {s}::declared::Site::new({s});\n{s}        let sal_at = SAL_SITE.get();\n", .{ indent, if (stored) "What's stored there" else "Where it is", indent, indent, (try g.staticDecl(in, v)).text.?, indent, indent, sal_, sal_, name_id, indent });
        if (stored) {
            try g.print("{s}        if sal_at == 0 {{\n{s}            return ::core::ptr::null_mut();\n{s}        }}\n{s}        *(sal_at as *const {s})\n", .{ indent, indent, indent, indent, ret });
        } else try g.print("{s}        sal_at as {s}\n", .{ indent, ret });
        try g.print("{s}    }}\n{s}}}\n", .{ indent, indent });
    }
};

//// How Rust names and declares each thing, from the same builders the writer uses. `a` should be an arena.
pub const Names = struct {
    g: *Gen,

    pub fn init(a: std.mem.Allocator, s: Schema, options: Options, diagnostic: ?*Schema.Diagnostic) Error!Names {
        const g = try a.create(Gen);
        g.* = .init(s, try lang.sink(a), a, options, diagnostic orelse try a.create(Schema.Diagnostic));
        try g.file();
        return .{ .g = g };
    }

    /// Paths from the crate's top, like `wraith::memory::Region`.
    fn top(n: *const Names) *Gen {
        n.g.cur = "";
        return n.g;
    }

    fn tidy(n: *const Names, d: lang.Decl) Error!?lang.Decl {
        return try lang.tidied(n.g.a, d, lang.unrooted);
    }

    fn named(n: *const Names, full: []const u8) Error!?lang.Decl {
        const g = n.top();
        return n.tidy(.{ .name = try g.typeName(full), .path = try g.qual(full) });
    }

    pub fn typeName(n: *const Names, t: *const Schema.Type) Error!?lang.Decl {
        return n.named(t.name);
    }

    pub fn traitName(n: *const Names, t: *const Schema.Trait) Error!?lang.Decl {
        return n.named(t.name);
    }

    pub fn method(n: *const Names, _: *const Schema.Trait, m: *const Schema.Method) Error!?lang.Decl {
        return n.tidy(try n.top().methodDecl(m));
    }

    pub fn field(n: *const Names, _: *const Schema.Type, f: *const Schema.Field) Error!?lang.Decl {
        return n.tidy(try n.top().fieldDecl(f.*));
    }

    /// An enum's value or an error, `Type::NAME`, or a bitfield's getter.
    pub fn member(n: *const Names, t: *const Schema.Type, name: []const u8) Error!?lang.Decl {
        const g = n.top();
        if (t.kind == .bitfield) return .{ .name = try g.fmt("{s}()", .{try g.field(name)}) };
        const v = try g.valueName(name);
        return n.tidy(.{ .name = v, .path = try g.fmt("{s}::{s}", .{ try g.qual(t.name), v }) });
    }

    pub fn function(n: *const Names, in: ?*const Schema.Type, m: *const Schema.Method) Error!?lang.Decl {
        return n.tidy(try n.top().declaredDecl(in, m) orelse return null);
    }

    pub fn static(n: *const Names, in: ?*const Schema.Type, v: *const Schema.Static) Error!?lang.Decl {
        return n.tidy(try n.top().staticDecl(in, v.*));
    }

    pub fn constant(n: *const Names, c: *const Schema.Constant) Error!?lang.Decl {
        return n.tidy(try n.top().constantDecl(c.*));
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

test "names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("set_speed", try snake(a, "setSpeed"));
    try std.testing.expectEqualStrings("http_server", try snake(a, "HTTPServer"));
    try std.testing.expectEqualStrings("max_players", try snake(a, "max_players"));
    try std.testing.expectEqualStrings("MAX_PLAYERS", try screaming(a, "maxPlayers"));
    try std.testing.expectEqualStrings("ListSceneNodePtr", try camel(a, "List_Scene_NodePtr"));
}

test "writes a module" {
    const text = try writeFor(
        \\struct Vec3 { f32 x; f32 y; f32 z; }
        \\error LoadError { NotFound, Corrupt = 7 }
        \\enum Job : u8 { warrior = 1, mage }
        \\bitfield Flags : u32 { bool alive; Job job : 4; }
        \\const u32 maxPlayers = 4;
        \\namespace Scene { struct Node { u32 id; Node* parent; } }
        \\trait Mover { [Thiscall] Vec3 move(Vec3 by, string type); Vec3!LoadError load(); void each(fn(u32 n) bool visit); }
    , .{ .label = "test.sal" });
    defer std.testing.allocator.free(text);
    try expectParts(text, &.{
        "#[repr(C)]\n#[derive(Clone, Copy)]\npub struct Vec3 {\n    pub x: f32,",
        "const _: () = assert!(::core::mem::offset_of!(Vec3, z) == 0x8, \"Vec3.z's offset\");",
        "pub struct Job(pub u8);",
        "    pub const WARRIOR: Job = Job(1);",
        "    pub const CORRUPT: LoadError = LoadError(7);",
        "    pub const fn job(self) -> Job {",
        "pub const MAX_PLAYERS: u32 = 4;",
        "pub mod scene {\n",
        "    pub parent: *mut Node,",
        "    #[cfg(target_arch = \"x86\")]\n    pub r#move: Option<unsafe extern \"thiscall\" fn(usize, Vec3, ::salamander::Str) -> Vec3>,",
        "    pub load: Option<unsafe extern \"C\" fn(usize, *mut Vec3) -> u32>,",
        "    pub fn r#move(&self, by: Vec3, r#type: &str) -> Vec3 {",
        "    pub fn load(&self) -> Result<Vec3, LoadError> {",
        "impl<F: Fn(u32) -> bool> MoverEachVisitImpl for F {",
        "pub trait MoverImpl {",
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
        "pub const PLAYER_HEAL_NAME: &str = \"Player.heal\";",
        "pub type PlayerHealFn = unsafe extern \"C\" fn(*mut Player, u32) -> bool;",
        "    pub unsafe fn heal(&mut self, amount: u32) -> bool {",
        "    pub unsafe fn instance() -> *mut Player {",
        "pub struct World {\n    _opaque: [u8; 0],\n}",
        "pub type WorldSpawnFn = unsafe extern \"C\" fn(*mut Player) -> *mut World;",
        "pub unsafe fn seen() -> *mut u8 {",
    });
}

test "top-level game code in a namespace goes in its module by its last name" {
    const text = try writeFor("namespace Game { [Sig(\"76\")] static u8 seen; [Sig(\"E8\")] i32 entry(u32 a); }", .{});
    defer std.testing.allocator.free(text);
    try expectParts(text, &.{ "pub mod game {\n", "pub unsafe fn seen() -> *mut u8 {", "pub unsafe fn entry(a: u32) -> i32 {", "pub const SEEN_NAME: &str = \"Game.seen\";" });
}

test "Names give what the writer declares" {
    const make = struct {
        fn make(a: std.mem.Allocator, s: Schema) anyerror!Names {
            return .init(a, s, .{}, null);
        }
    }.make;
    try lang.expectNames(Names, make, .{
        .method = "pub fn count(&self, who: &str) -> u32",
        .field = "pub hp: u32",
        .function = "pub unsafe fn heal(&mut self, amount: u32) -> bool",
        .static = "pub unsafe fn instance() -> *mut g::Player",
        .constant = "pub const MAX_PLAYERS: u32",
    });
}

test "a type whose CamelCase name another has keeps how it's written" {
    const text = try writeFor(
        \\struct lua_State { u32 top; }
        \\struct LuaState { lua_State* state; }
    , .{});
    defer std.testing.allocator.free(text);
    try expectParts(text, &.{
        "#[allow(non_camel_case_types)]\n#[repr(C)]\n#[derive(Clone, Copy)]\npub struct lua_State {",
        "\n#[repr(C)]\n#[derive(Clone, Copy)]\npub struct LuaState {\n    pub state: *mut lua_State,",
    });
}

test "a field that can't have its alignment packs the struct only as far as it needs" {
    const text = try writeFor(
        \\[Size(0xC)] struct Info { u32 id; [0x4] u64 at; }
        \\struct Outer { [0x10] Info info; }
    , .{});
    defer std.testing.allocator.free(text);
    try expectParts(text, &.{
        "#[repr(C, packed(4))]\n#[derive(Clone, Copy)]\npub struct Info {",
        "align_of::<Info>() == 4",
        "align_of::<Outer>() == 4",
    });
}
