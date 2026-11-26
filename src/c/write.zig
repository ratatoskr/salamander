//! A schema as a C header over `salamander.h`, laid out by the same plan as Zig and checked with `_Static_assert`s.
//! Ints, enums, error sets and bitfields are backing ints with `#define`d values, since C's own differ between compilers.

const std = @import("std");
const salamander_schema = @import("salamander_schema");

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
    /// Goes in front of every name, since C has no namespaces.
    prefix: []const u8 = "",
    /// Writing the runtime's own `core.sal`, so it doesn't include itself.
    core: bool = false,
};

/// What files starting with `prefix` declare comes from `include`, like `wraith/` from `wraith.h`.
pub const Alias = struct {
    prefix: []const u8,
    include: []const u8,
};

/// The runtime's traits, from `core.sal`, have this in front.
pub const core_prefix = "sal_";

pub fn write(gpa: std.mem.Allocator, s: Schema, w: *std.Io.Writer, options: Options, diagnostic: ?*Schema.Diagnostic) Error!void {
    var scratch: Schema.Diagnostic = .{};
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var g: Gen = .{ .s = s, .w = w, .a = arena.allocator(), .o = options, .diag = diagnostic orelse &scratch };
    try g.file();
}

const keywords = [_][]const u8{
    "auto",     "break",   "case",     "char",   "const",  "continue", "default", "do",      "double",  "else",
    "enum",     "extern",  "float",    "for",    "goto",   "if",       "inline",  "int",     "long",    "register",
    "restrict", "return",  "short",    "signed", "sizeof", "static",   "struct",  "switch",  "typedef", "union",
    "unsigned", "void",    "volatile", "while",  "bool",   "true",     "false",   "alignas", "alignof", "_Bool",
    "NULL",     "nullptr", "typeof",
};

/// What the helpers call their own locals, so parameters don't.
const helper_locals = [_][]const u8{ "self", "r", "out" };

fn contains(list: []const []const u8, n: []const u8) bool {
    for (list) |o| if (std.mem.eql(u8, o, n)) return true;
    return false;
}

/// Something C needs its own typedef of.
const Extra = struct {
    name: []const u8,
    ref: Ref,
    /// A function value's, so the same signature in two places is one type.
    hash: u64 = 0,
};

const Gen = struct {
    s: Schema,
    w: *std.Io.Writer,
    a: std.mem.Allocator,
    o: Options,
    diag: *Schema.Diagnostic,
    top: std.ArrayList([]const u8) = .empty,
    slices: std.ArrayList(Extra) = .empty,
    opts: std.ArrayList(Extra) = .empty,
    fns: std.ArrayList(Extra) = .empty,

    fn print(g: *Gen, comptime f: []const u8, args: anytype) Error!void {
        try g.w.print(f, args);
    }

    fn fmt(g: *Gen, comptime f: []const u8, args: anytype) Error![]const u8 {
        return std.fmt.allocPrint(g.a, f, args);
    }

    /// Whether what's declared at `at` comes from an aliased header.
    fn aliased(g: *const Gen, at: Schema.Pos) bool {
        if (g.o.aliases.len == 0) return false;
        const file_name = Schema.fileOf(g.o.source, at);
        for (g.o.aliases) |a| if (std.mem.startsWith(u8, file_name, a.prefix)) return true;
        return false;
    }

    fn aliasedType(g: *const Gen, n: []const u8) bool {
        const t = g.s.findType(n) orelse return false;
        return g.aliased(t.at);
    }

    fn claim(g: *Gen, n: []const u8) Error!void {
        if (contains(g.top.items, n)) {
            g.diag.print("{s}: C can't have two things called that", .{n});
            return error.NameClash;
        }
        try g.top.append(g.a, n);
    }

    /// A parameter's name, kept off C's keywords and the helpers' locals.
    fn local(g: *Gen, n: []const u8) Error![]const u8 {
        return if (contains(&keywords, n) or contains(&helper_locals, n)) g.fmt("{s}_", .{n}) else n;
    }

    fn field(g: *Gen, n: []const u8) Error![]const u8 {
        return if (contains(&keywords, n)) g.fmt("{s}_", .{n}) else n;
    }

    fn name(g: *Gen, n: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(g.a, "{s}{s}", .{ g.o.prefix, try Schema.flatName(g.a, n) });
    }

    /// One of `core.sal`'s, which always has the core prefix.
    fn core(_: *Gen, comptime n: []const u8) []const u8 {
        return core_prefix ++ n;
    }

    // Names for what C needs a typedef of

    fn mangle(g: *Gen, r: Ref) Error![]const u8 {
        return switch (r) {
            .prim => |p| @tagName(p),
            .named => |n| g.name(n),
            .pointer => |c| g.fmt("{s}Ptr", .{try g.mangle(c.*)}),
            .array => |a| g.fmt("{s}x{d}", .{ try g.mangle(a.child.*), a.len }),
            .slice => |c| g.fmt("Slice_{s}", .{try g.mangle(c.*)}),
            .optional => |c| g.fmt("Opt_{s}", .{try g.mangle(c.*)}),
            .func => |sig| g.fnName(sig.*),
            .result => |res| g.fmt("{s}Or{s}", .{ try g.mangle(res.ok.*), res.err }),
        };
    }

    fn sliceName(g: *Gen, child: Ref) Error![]const u8 {
        return g.fmt("{s}Slice_{s}", .{ g.o.prefix, try g.mangle(child) });
    }

    fn optName(g: *Gen, child: Ref) Error![]const u8 {
        return g.fmt("{s}Opt_{s}", .{ g.o.prefix, try g.mangle(child) });
    }

    /// An unnamed `fn(...)` is named for where it's first used, like `Freecam_onLand_listener`.
    fn fnName(g: *Gen, sig: Schema.Signature) Error![]const u8 {
        const h = Schema.signatureHash(sig);
        for (g.fns.items) |f| if (f.hash == h and f.ref == .func) return f.name;
        unreachable;
    }

    fn addFn(g: *Gen, r: Ref, site: []const u8) Error!void {
        const h = Schema.signatureHash(r.func.*);
        for (g.fns.items) |f| if (f.hash == h and f.ref == .func) return;
        try g.fns.append(g.a, .{ .name = try g.name(site), .ref = r, .hash = h });
    }

    /// Finds every slice, value optional and function value, so each gets one typedef.
    fn collect(g: *Gen, r: Ref, site: []const u8) Error!void {
        switch (r) {
            .prim, .named => {},
            .pointer => |c| try g.collect(c.*, site),
            .array => |a| try g.collect(a.child.*, site),
            .slice => |c| {
                try g.collect(c.*, site);
                try add(g, &g.slices, try g.sliceName(c.*), c.*);
            },
            .optional => |c| {
                try g.collect(c.*, site);
                // Pointers and objects have their own null
                if (c.* != .pointer and !g.s.isObject(c.*)) try add(g, &g.opts, try g.optName(c.*), c.*);
            },
            .result => |res| try g.collect(res.ok.*, site),
            .func => |sig| {
                for (sig.params) |p| try g.collect(p.type, try g.fmt("{s}_{s}", .{ site, p.name }));
                try g.collect(sig.ret, site);
                try g.addFn(r, site);
            },
        }
    }

    fn add(g: *Gen, list: *std.ArrayList(Extra), n: []const u8, r: Ref) Error!void {
        for (list.items) |e| if (std.mem.eql(u8, e.name, n)) return;
        try list.append(g.a, .{ .name = n, .ref = r });
    }

    // Declarators, inside out like C reads them

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
            .utf16 => "uint16_t",
            .string => "sal_string",
            .object, .blob => "sal_object",
            .cstring => "const char*",
            .void => "void",
        };
    }

    /// `inner` is what's being declared so far, like a name.
    fn decl(g: *Gen, r: Ref, inner: []const u8) Error![]const u8 {
        const sp: []const u8 = if (inner.len == 0) "" else " ";
        return switch (r) {
            .prim => |p| g.fmt("{s}{s}{s}", .{ prim(p), sp, inner }),
            .named => |n| g.fmt("{s}{s}{s}", .{ try g.name(n), sp, inner }),
            .pointer => |c| if (c.* == .array) g.decl(c.*, try g.fmt("(*{s})", .{inner})) else g.decl(c.*, try g.fmt("*{s}", .{inner})),
            .array => |a| g.decl(a.child.*, try g.fmt("{s}[{d}]", .{ inner, a.len })),
            .slice => |c| g.fmt("{s}{s}{s}", .{ try g.sliceName(c.*), sp, inner }),
            .optional => |c| if (c.* == .pointer or g.s.isObject(c.*)) g.decl(c.*, inner) else g.fmt("{s}{s}{s}", .{ try g.optName(c.*), sp, inner }),
            .func => |sig| g.fmt("{s}{s}{s}", .{ try g.fnName(sig.*), sp, inner }),
            .result => unreachable,
        };
    }

    fn conv(c: Schema.Conv) []const u8 {
        return switch (c) {
            .c => "",
            .cdecl => "SAL_CDECL ",
            .stdcall => "SAL_STDCALL ",
            .thiscall => "SAL_THISCALL ",
            .fastcall => "SAL_FASTCALL ",
            .winapi => "SAL_WINAPI ",
        };
    }

    fn resultOk(r: Ref) ?Ref {
        return switch (r) {
            .result => |res| if (res.ok.* == .prim and res.ok.prim == .void) null else res.ok.*,
            else => null,
        };
    }

    /// `(uintptr_t, float, Vec3 *)`, the C entry's parameters.
    fn entryParams(g: *Gen, m: *const Schema.Method) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(g.a);
        const w = &out.writer;
        try w.writeAll("(");
        var first = true;
        if (!m.static) {
            try w.writeAll("uintptr_t");
            first = false;
        }
        for (m.signature.params) |p| {
            if (!first) try w.writeAll(", ");
            first = false;
            try w.writeAll(try g.decl(p.type, ""));
        }
        if (!m.async) if (resultOk(m.signature.ret)) |ok| {
            if (!first) try w.writeAll(", ");
            first = false;
            try w.writeAll(try g.decl(.{ .pointer = &ok }, ""));
        };
        if (first) try w.writeAll("void");
        try w.writeAll(")");
        return out.written();
    }

    /// A code for results, a promise for async.
    fn retDecl(g: *Gen, m: *const Schema.Method, inner: []const u8) Error![]const u8 {
        if (m.async) return g.fmt("{s} {s}", .{ g.core("Promise"), inner });
        if (m.signature.ret == .result) return g.fmt("uint32_t {s}", .{inner});
        return g.decl(m.signature.ret, inner);
    }

    // The file

    fn file(g: *Gen) Error!void {
        const s = g.s;
        const guard = try std.fmt.allocPrint(g.a, "SALAMANDER_{s}{s}_H", .{ g.o.prefix, g.o.label });
        for (guard) |*c| c.* = if (std.ascii.isAlphanumeric(c.*)) std.ascii.toUpper(c.*) else '_';
        try g.print(
            \\/* Generated by salamander from {s}. Don't edit it, it's written again every build. */
            \\
            \\#ifndef {s}
            \\#define {s}
            \\
            \\#include "salamander.h"
            \\
        , .{ g.o.label, guard, guard });
        if (!g.o.core) try g.print("#include \"salamander_core.h\"\n", .{});
        for (g.o.aliases, 0..) |a, i| {
            const seen = for (g.o.aliases[0..i]) |b| {
                if (std.mem.eql(u8, a.include, b.include)) break true;
            } else false;
            if (!seen) try g.print("#include \"{s}\"\n", .{a.include});
        }

        const laid_out = for (s.types) |t| {
            if (t.kind == .@"struct" or t.kind == .@"union") break true;
        } else false;
        if (laid_out) try g.print("\n_Static_assert(sizeof(void *) == {d}, \"these types are for {d}-bit code\");\n", .{ s.pointer_size, @as(usize, s.pointer_size) * 8 });

        // Named function types first, so their signatures keep their own names
        for (s.types) |t| if (t.kind == .func and !g.aliased(t.at)) {
            for (t.kind.func.params) |p| try g.collect(p.type, try g.fmt("{s}_{s}", .{ t.name, p.name }));
            try g.collect(t.kind.func.ret, t.name);
            try g.fns.append(g.a, .{ .name = try g.name(t.name), .ref = .{ .named = t.name }, .hash = Schema.signatureHash(t.kind.func) });
        };
        for (s.types) |t| if (!g.aliased(t.at)) {
            try g.claim(try g.name(t.name));
            switch (t.kind) {
                .@"struct", .@"union" => |st| for (st.fields) |f| try g.collect(f.type, try g.fmt("{s}_{s}", .{ t.name, f.name })),
                else => {},
            }
        };
        for (s.traits) |*t| if (!g.aliased(t.at)) {
            try g.claim(try g.name(t.name));
            for (t.methods) |m| {
                for (m.signature.params) |p| try g.collect(p.type, try g.fmt("{s}_{s}_{s}", .{ t.name, m.name, p.name }));
                try g.collect(m.signature.ret, try g.fmt("{s}_{s}", .{ t.name, m.name }));
            }
        };
        for (s.constants) |k| if (!g.aliased(k.at)) try g.claim(try g.name(k.name));
        for (s.types) |t| if (t.kind == .@"struct" and !g.aliased(t.at)) for (t.kind.@"struct".methods) |m| {
            for (m.signature.params) |p| try g.collect(p.type, try g.fmt("{s}_{s}_{s}", .{ t.name, m.name, p.name }));
            try g.collect(m.signature.ret, try g.fmt("{s}_{s}", .{ t.name, m.name }));
        };
        for (s.functions) |m| {
            for (m.signature.params) |p| try g.collect(p.type, try g.fmt("{s}_{s}", .{ m.name, p.name }));
            try g.collect(m.signature.ret, m.name);
        }

        // Everything with a name first, so order doesn't matter for pointers
        try g.print("\n", .{});
        for (s.types) |t| if (!g.aliased(t.at)) switch (t.kind) {
            .@"struct", .@"opaque" => try g.print("typedef struct {s} {s};\n", .{ try g.name(t.name), try g.name(t.name) }),
            .@"union" => try g.print("typedef union {s} {s};\n", .{ try g.name(t.name), try g.name(t.name) }),
            else => {},
        };
        for (s.traits) |t| if (!g.aliased(t.at)) {
            const n = try g.name(t.name);
            try g.print("typedef struct {s} {s};\ntypedef struct {s}_table {s}_table;\n", .{ n, n, n, n });
        };
        for (g.fns.items) |f| try g.print("typedef struct {s} {s};\ntypedef struct {s}_table {s}_table;\n", .{ f.name, f.name, f.name, f.name });

        for (s.types) |*t| if (!g.aliased(t.at)) switch (t.kind) {
            .@"enum" => |e| try g.enumDef(t, e),
            .bitfield => |b| try g.bitfieldDef(t, b),
            .@"error" => |e| try g.errorDef(t, e),
            else => {},
        };
        if (s.constants.len > 0) try g.print("\n", .{});
        for (s.constants) |k| if (!g.aliased(k.at)) try g.constant(k);

        // Guarded, since a header this one includes can have the same one
        for (g.slices.items) |x| try g.print("\n#ifndef SAL_HAVE_{s}\n#define SAL_HAVE_{s}\ntypedef struct {s} {{\n    const {s};\n    uintptr_t len;\n}} {s};\n#endif\n", .{ x.name, x.name, x.name, try g.decl(x.ref, "*ptr"), x.name });

        // Objects are two words, and structs can hold them by value
        for (s.traits) |t| if (!g.aliased(t.at)) try g.objectDef(try g.name(t.name));
        for (g.fns.items) |f| try g.objectDef(f.name);

        var done: std.ArrayList([]const u8) = .empty;
        for (s.types) |*t| if (!g.aliased(t.at)) try g.structInOrder(t, &done, 0);

        for (g.opts.items) |x| try g.print("\n#ifndef SAL_HAVE_{s}\n#define SAL_HAVE_{s}\ntypedef struct {s} {{\n    {s};\n    bool some;\n}} {s};\n#endif\n", .{ x.name, x.name, x.name, try g.decl(x.ref, "value"), x.name });

        for (g.fns.items) |f| {
            const sig = switch (f.ref) {
                .func => |sig| sig.*,
                .named => |n| s.findType(n).?.kind.func,
                else => unreachable,
            };
            try g.fnValue(f.name, sig);
        }
        for (s.traits) |*t| if (!g.aliased(t.at)) try g.trait(t);
        try g.declared();

        try g.print("\n#endif\n", .{});
    }

    /// Existing code the schema declares: each one's full name, and a pointer type for functions, `self` first for methods.
    fn declared(g: *Gen) Error!void {
        const s = g.s;
        for (s.types) |*t| if (t.kind == .@"struct" and !g.aliased(t.at)) {
            const st = t.kind.@"struct";
            for (st.methods) |*m| try g.declaredFn(t, m);
            for (st.statics) |st_| try g.declaredStatic(try g.fmt("{s}.{s}", .{ t.name, st_.name }), st_);
        };
        for (s.functions) |*m| if (!g.aliased(m.at)) try g.declaredFn(null, m);
        for (s.statics) |st| if (!g.aliased(st.at)) try g.declaredStatic(st.name, st);
    }

    fn declaredFn(g: *Gen, in: ?*const Schema.Type, m: *const Schema.Method) Error!void {
        const full = if (in) |t| try g.fmt("{s}.{s}", .{ t.name, m.name }) else m.name;
        const n = try g.name(full);
        try g.claim(try g.fmt("{s}_name", .{n}));
        try g.print("\n/* {s}{s} */\n#define {s}_name \"{s}\"\n", .{ full, if (m.virtual) |slot| try g.fmt(", slot {d} of its vtable", .{slot}) else "", n, full });
        // Results and promises are Salamander's own, not existing code's
        if (m.async or m.signature.ret == .result) return;
        var params: std.Io.Writer.Allocating = .init(g.a);
        const w = &params.writer;
        var first = true;
        if (in) |t| if (!m.static) {
            try w.print("{s} *self", .{try g.name(t.name)});
            first = false;
        };
        for (m.signature.params) |p| {
            if (p.type == .result) return;
            if (!first) try w.writeAll(", ");
            first = false;
            try w.writeAll(try g.decl(p.type, try g.local(p.name)));
        }
        if (first) try w.writeAll("void");
        const fn_name = try g.fmt("{s}_fn", .{n});
        try g.claim(fn_name);
        try g.print("typedef {s};\n", .{try g.decl(m.signature.ret, try g.fmt("({s}*{s})({s})", .{ conv(m.signature.conv), fn_name, params.written() }))});
    }

    fn declaredStatic(g: *Gen, full: []const u8, st: Schema.Static) Error!void {
        const n = try g.name(full);
        try g.claim(try g.fmt("{s}_name", .{n}));
        try g.print("\n/* {s}, a {s} */\n#define {s}_name \"{s}\"\n", .{ full, try g.decl(st.type, ""), n, full });
    }

    fn objectDef(g: *Gen, n: []const u8) Error!void {
        try g.print("\nstruct {s} {{\n    uintptr_t data;\n    const {s}_table *table;\n}};\n", .{ n, n });
    }

    fn intDefine(g: *Gen, ty: []const u8, n: []const u8, value: i128, unsigned: bool) Error!void {
        if (unsigned) try g.print("#define {s} (({s}){d}ull)\n", .{ n, ty, value }) else try g.print("#define {s} (({s}){d}ll)\n", .{ n, ty, value });
    }

    fn enumDef(g: *Gen, t: *const Schema.Type, e: Schema.Enum) Error!void {
        const n = try g.name(t.name);
        try g.print("\ntypedef {s} {s};\n", .{ prim(e.backing), n });
        for (e.values) |v| {
            const vn = try g.fmt("{s}_{s}", .{ n, v.name });
            try g.claim(vn);
            try g.intDefine(n, vn, v.value, !e.backing.isSigned());
        }
    }

    fn errorDef(g: *Gen, t: *const Schema.Type, e: Schema.ErrorSet) Error!void {
        const n = try g.name(t.name);
        try g.print("\n/* Codes a result can give, besides SAL_CANCELLED, SAL_UNSUPPORTED and SAL_GONE. */\ntypedef uint32_t {s};\n", .{n});
        for (e.errors) |x| {
            const vn = try g.fmt("{s}_{s}", .{ n, x.name });
            try g.claim(vn);
            try g.intDefine(n, vn, x.code, true);
        }
    }

    fn bitfieldDef(g: *Gen, t: *const Schema.Type, b: Schema.Bitfield) Error!void {
        const n = try g.name(t.name);
        try g.print("\ntypedef {s} {s};\n", .{ prim(b.backing), n });
        for (b.members) |m| {
            // As a literal, and shifted as 64 bits, so small types don't turn into signed ints first
            const mask = try g.fmt("0x{x}ull", .{(@as(u128, 1) << @intCast(m.bits)) - 1});
            const T: []const u8 = switch (m.type) {
                .bool => if (m.bits == 1) "bool" else n,
                .uint => n,
                .@"enum" => |en| try g.name(en),
            };
            const get = try g.fmt("{s}_{s}", .{ n, m.name });
            const with = try g.fmt("{s}_with_{s}", .{ n, m.name });
            try g.claim(get);
            try g.claim(with);
            try g.print("static inline {s} {s}({s} v) {{ return ({s})(((uint64_t)v >> {d}) & {s}); }}\n", .{ T, get, n, T, m.bit, mask });
            try g.print("static inline {s} {s}({s} v, {s} x) {{ return ({s})(((uint64_t)v & ~({s} << {d})) | (((uint64_t)x & {s}) << {d})); }}\n", .{ n, with, n, T, n, mask, m.bit, mask, m.bit });
        }
    }

    fn constant(g: *Gen, k: Schema.Constant) Error!void {
        const n = try g.name(k.name);
        const p = k.type.prim;
        switch (k.value) {
            .int => |v| if (p.isFloat()) try g.print("#define {s} (({s}){d})\n", .{ n, prim(p), v }) else try g.intDefine(prim(p), n, v, !p.isSigned()),
            .float => |v| try g.print("#define {s} (({s}){d})\n", .{ n, prim(p), v }),
            .bool => |v| try g.print("#define {s} {}\n", .{ n, v }),
            .string => |v| try g.print("#define {s} \"{s}\"\n", .{ n, v }),
        }
    }

    /// C needs a struct's by-value fields defined first.
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
            else => null,
        };
    }

    fn structDef(g: *Gen, t: *const Schema.Type) Error!void {
        // Nothing known inside, so it stays opaque. C has no empty structs
        if (t.size == 0) return;
        const n = try g.name(t.name);
        const is_union = t.kind == .@"union";
        // C can't lower one field's alignment, so a struct with any like that is packed with all its padding written out
        var packed_ = false;
        var check: plan.Slots = .init(g.s, t);
        while (check.next()) |slot| if (slot == .field and slot.field.alignment < slot.field.natural) {
            packed_ = true;
        };
        if (packed_) try g.print("\n#pragma pack(push, 1)", .{});
        try g.print("\n{s} {s} {{\n", .{ if (is_union) "union" else "struct", n });
        var it: plan.Slots = .init(g.s, t);
        var fields: std.ArrayList(Schema.Field) = .empty;
        while (it.next()) |slot| switch (slot) {
            .pad => |p| if (is_union) try g.print("    uint8_t _bytes[0x{x}];\n", .{p.len}) else try g.print("    uint8_t _pad_0x{x}[0x{x}];\n", .{ p.offset, p.len }),
            .field => |f| {
                try g.print("    {s};\n", .{try g.decl(f.field.type, try g.field(f.field.name))});
                try fields.append(g.a, f.field);
            },
        };
        try g.print("}};\n", .{});
        if (packed_) try g.print("#pragma pack(pop)\n", .{});
        try g.print("_Static_assert(sizeof({s}) == 0x{x}, \"{s}'s size\");\n", .{ n, t.size, t.name });
        if (!packed_) try g.print("_Static_assert(_Alignof({s}) == {d}, \"{s}'s alignment\");\n", .{ n, t.alignment, t.name });
        if (!is_union) for (fields.items) |f| {
            try g.print("_Static_assert(offsetof({s}, {s}) == 0x{x}, \"{s}.{s}'s offset\");\n", .{ n, try g.field(f.name), f.offset, t.name, f.name });
        };
    }

    fn infoDef(g: *Gen, n: []const u8, hash: u64, label: []const u8, ms: []const *const Schema.Method, sigs: []const u64) Error!void {
        // Under `sal_`, so a method called `info` doesn't clash
        const info = try g.fmt("sal_info_{s}", .{n});
        try g.claim(info);
        if (ms.len > 0) {
            try g.print("\nstatic const sal_MethodInfo {s}_methods[] = {{\n", .{info});
            for (ms, sigs) |m, sig| try g.print("    {{ {{ \"{s}\", {d} }}, 0x{x:0>16}ull }},\n", .{ m.name, m.name.len, sig });
            try g.print("}};\n", .{});
        }
        try g.print("static const sal_Info {s} = {{ 0x{x:0>16}ull, SAL_ABI_VERSION, {{ \"{s}\", {d} }}, {{ {s}, {d} }} }};\n", .{
            info,                                                          hash,   label, label.len,
            if (ms.len > 0) try g.fmt("{s}_methods", .{info}) else "NULL", ms.len,
        });
    }

    fn tableDef(g: *Gen, n: []const u8, ms: []const *const Schema.Method) Error!void {
        try g.print("\n/* A null method is one this table doesn't have. */\nstruct {s}_table {{\n    const sal_Info *salamander_info;\n    sal_Owner *salamander_owner;\n", .{n});
        for (ms) |m| {
            const inner = try g.fmt("({s}*{s}){s}", .{ conv(m.signature.conv), m.name, try g.entryParams(m) });
            try g.print("    {s};\n", .{try g.retDecl(m, inner)});
        }
        try g.print("}};\n", .{});
    }

    /// `static inline R Trait_method(Trait obj, ...)`, which enters the owner around the call.
    fn helper(g: *Gen, n: []const u8, helper_name: []const u8, m: *const Schema.Method) Error!void {
        var params: std.Io.Writer.Allocating = .init(g.a);
        var args: std.Io.Writer.Allocating = .init(g.a);
        try params.writer.print("{s} self", .{n});
        if (!m.static) try args.writer.writeAll("self.data");
        for (m.signature.params) |p| {
            const pn = try g.local(p.name);
            try params.writer.print(", {s}", .{try g.decl(p.type, pn)});
            try args.writer.print("{s}{s}", .{ if (args.written().len > 0) ", " else "", pn });
        }
        const ok = if (m.async) null else resultOk(m.signature.ret);
        if (ok) |o| {
            try params.writer.print(", {s}", .{try g.decl(.{ .pointer = &o }, "out")});
            try args.writer.print("{s}out", .{if (args.written().len > 0) ", " else ""});
        }
        const is_void = !m.async and m.signature.ret == .prim and m.signature.ret.prim == .void;
        const is_result = !m.async and m.signature.ret == .result;
        try g.print("\nstatic inline {s} {{\n", .{try g.retDecl(m, try g.fmt("{s}({s})", .{ helper_name, params.written() }))});
        if (is_void) {
            try g.print("    if (!self.table || !self.table->{s} || !sal_enter(self.table->salamander_owner)) return;\n", .{m.name});
            try g.print("    self.table->{s}({s});\n    sal_leave(self.table->salamander_owner);\n}}\n", .{ m.name, args.written() });
            return;
        }
        if (is_result) {
            try g.print("    if (!self.table) return SAL_GONE;\n    if (!self.table->{s}) return SAL_UNSUPPORTED;\n    if (!sal_enter(self.table->salamander_owner)) return SAL_GONE;\n    uint32_t r", .{m.name});
        } else {
            try g.print("    {s} = {{0}};\n    if (!self.table || !self.table->{s} || !sal_enter(self.table->salamander_owner)) return r;\n    r", .{ try g.retDecl(m, "r"), m.name });
        }
        try g.print(" = self.table->{s}({s});\n    sal_leave(self.table->salamander_owner);\n    return r;\n}}\n", .{ m.name, args.written() });
    }

    /// `sal_get_Trait`, `sal_provide_Trait` and `sal_own_Trait` over the host's, prefixed so they can't clash with the trait's methods.
    fn hostHelpers(g: *Gen, n: []const u8) Error!void {
        const host = g.core("Host");
        for ([_][]const u8{ "get", "provide", "own" }) |h| try g.claim(try g.fmt("sal_{s}_{s}", .{ h, n }));
        try g.print(
            \\
            \\/* The one provided as name, laid out like this header's {s}. No table if there isn't one. */
            \\static inline {s} sal_get_{s}({s} host, sal_string name, uint32_t major) {{
            \\    sal_object o = {s}_get(host, name, major, (sal_Info *)&sal_info_{s});
            \\    {s} r = {{ o.data, (const {s}_table *)o.table }};
            \\    return r;
            \\}}
            \\
            \\/* 0, or 1 when the name's taken, 2 out of memory, 3 when its table has no owner. */
            \\static inline uint32_t sal_provide_{s}({s} host, sal_string name, uint32_t major, {s} obj) {{
            \\    sal_object o = {{ obj.data, obj.table }};
            \\    return {s}_provide(host, name, major, o);
            \\}}
            \\
            \\/* The host's copy of obj's table, which stops calling into it once owner closes. */
            \\static inline {s} sal_own_{s}({s} host, {s} obj, sal_Owner *owner) {{
            \\    sal_object o = {{ obj.data, obj.table }};
            \\    o = {s}_adopt(host, o, owner);
            \\    {s} r = {{ o.data, (const {s}_table *)o.table }};
            \\    return r;
            \\}}
            \\
        , .{ n, n, n, host, host, n, n, n, n, host, n, host, n, n, host, n, host, n, n });
    }

    fn trait(g: *Gen, t: *const Schema.Trait) Error!void {
        const n = try g.name(t.name);
        var buf: [plan.max_methods]*const Schema.Method = undefined;
        const ms = plan.methods(g.s, t, &buf);
        var sigs = try g.a.alloc(u64, ms.len);
        for (ms, 0..) |m, i| sigs[i] = Schema.methodHash(m);
        try g.print("\n/* {s} */\n", .{t.name});
        try g.tableDef(n, ms);
        try g.infoDef(n, g.s.traitHash(t), t.name, ms, sigs);
        for (ms) |m| {
            const hn = try g.fmt("{s}_{s}", .{ n, m.name });
            try g.claim(hn);
            try g.helper(n, hn, m);
        }
        // The core header defines the host these use
        if (!g.o.core) try g.hostHelpers(n);
    }

    /// A function value, a trait object with one method, `call`.
    fn fnValue(g: *Gen, n: []const u8, sig: Schema.Signature) Error!void {
        const m: Schema.Method = .{ .name = "call", .signature = sig };
        const ms = [_]*const Schema.Method{&m};
        try g.print("\n/* fn{f} */\n", .{sig});
        try g.tableDef(n, &ms);
        try g.infoDef(n, 0, "fn", &ms, &.{Schema.signatureHash(sig)});
        const call = try g.fmt("{s}_call", .{n});
        try g.claim(call);
        try g.helper(n, call, &m);
    }
};

test "declared code gets its name and a pointer type, and an empty struct stays opaque" {
    var diag: Schema.Diagnostic = .{};
    var parsed = try salamander_schema.parse(std.testing.allocator,
        \\struct Player {
        \\    [Offset(0x10)] f32 health;
        \\    [Sig("E8")] bool heal(u32 amount);
        \\    [Sig("48")] static Player* instance;
        \\}
        \\struct World {
        \\    [Sig("E9")] static World* spawn(Player* who);
        \\}
        \\[Sig("76")] static u8 seen;
    , .{ .pointer_size = 8, .any_namespace = true, .uses = &.{"game"} }, &diag);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, parsed.schema, &out.writer, .{ .label = "game.sal" }, &diag);
    const text = out.written();
    const want = [_][]const u8{
        "#define Player_heal_name \"Player.heal\"",
        "typedef bool (*Player_heal_fn)(Player *self, uint32_t amount);",
        "#define Player_instance_name \"Player.instance\"",
        "typedef World *(*World_spawn_fn)(Player *who);",
        "#define seen_name \"seen\"",
    };
    for (want) |part| if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing:\n{s}\n\nin:\n{s}\n", .{ part, text });
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, text, "struct World {") == null);
}

test "aliased files' types come from their header" {
    const a = std.testing.allocator;
    const source = try salamander_schema.bundle(a, &.{
        .{ .name = "wraith/math.sal", .text = "namespace Wraith;\nstruct Vec3 { f32 x; f32 y; f32 z; }\ntrait Log { void info(string text); }\n" },
        .{ .name = "game.sal", .text = "namespace Game;\nstruct Player { [Offset(0x10)] Vec3 pos; []Vec3 path; }\n" },
    });
    defer a.free(source);
    var diag: Schema.Diagnostic = .{};
    var parsed = try salamander_schema.parse(a, source, .{ .pointer_size = 8, .global_uses = &.{"Wraith"} }, &diag);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try write(a, parsed.schema, &out.writer, .{ .label = "schema.sal", .source = source, .aliases = &.{.{ .prefix = "wraith/", .include = "wraith.h" }} }, &diag);
    const text = out.written();
    for ([_][]const u8{ "#include \"wraith.h\"", "    Wraith_Vec3 pos;", "#ifndef SAL_HAVE_Slice_Wraith_Vec3" }) |part| if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing:\n{s}\n\nin:\n{s}\n", .{ part, text });
        return error.TestUnexpectedResult;
    };
    for ([_][]const u8{ "struct Wraith_Vec3 {", "Wraith_Log_info" }) |part| try std.testing.expect(std.mem.indexOf(u8, text, part) == null);
}

test "writes a header" {
    var diag: Schema.Diagnostic = .{};
    var parsed = try salamander_schema.parse(std.testing.allocator,
        \\struct Vec3 { f32 x; f32 y; f32 z; }
        \\error LoadError { NotFound, Corrupt = 7 }
        \\trait Mover { [Thiscall] Vec3 move(Vec3 by, string int); Vec3!LoadError load(); void each(fn(u32 n) bool visit); }
    , .{ .pointer_size = 8 }, &diag);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, parsed.schema, &out.writer, .{ .label = "test.sal", .prefix = "t_" }, &diag);
    const text = out.written();
    const want = [_][]const u8{
        "struct t_Vec3 {\n    float x;\n    float y;\n    float z;\n};",
        "_Static_assert(offsetof(t_Vec3, z) == 0x8, \"Vec3.z's offset\");",
        "#define t_LoadError_Corrupt ((t_LoadError)7ull)",
        "t_Vec3 (SAL_THISCALL *move)(uintptr_t, t_Vec3, sal_string);",
        "uint32_t (*load)(uintptr_t, t_Vec3 *);",
        // `int` is C's, so the parameter gets a _
        "static inline t_Vec3 t_Mover_move(t_Mover self, t_Vec3 by, sal_string int_) {",
        "    if (!self.table->load) return SAL_UNSUPPORTED;",
        // Named for where it's used, not its hash
        "typedef struct t_Mover_each_visit t_Mover_each_visit;",
        "static inline t_Mover sal_get_t_Mover(sal_Host host, sal_string name, uint32_t major) {",
    };
    for (want) |part| if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing:\n{s}\n\nin:\n{s}\n", .{ part, text });
        return error.TestUnexpectedResult;
    };
}
