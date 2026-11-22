//! A schema as a `.zig` file. Structs holding text or slices come as plain Zig at the top and the
//! wire layout under `raw`, and methods convert between them. Only needs `salamander_runtime`.

const std = @import("std");
const salamander_schema = @import("salamander_schema");

const plan = salamander_schema.plan;

const Schema = salamander_schema.Schema;
const Ref = Schema.Ref;
const id = std.zig.fmtId;

pub const Error = std.Io.Writer.Error || error{ OutOfMemory, NameClash };

pub const Options = struct {
    /// Where it came from, for the header.
    label: []const u8 = "a .sal file",
    runtime: []const u8 = "salamander_runtime",
    /// What was parsed, so `aliases` can tell which file each thing's in.
    source: []const u8 = "",
    aliases: []const Alias = &.{},
};

/// Everything declared in bundled files whose names start with `prefix`, like `wraith/`, comes from
/// the Zig module `import` instead, which has the same names. Structs are checked against the
/// schema's layout as they compile.
pub const Alias = struct {
    prefix: []const u8,
    import: []const u8,
};

/// Two things Zig can't tell apart are `error.NameClash`.
pub fn write(gpa: std.mem.Allocator, s: Schema, w: *std.Io.Writer, options: Options, diagnostic: ?*Schema.Diagnostic) Error!void {
    var scratch: Schema.Diagnostic = .{};
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var g: Gen = .{ .s = s, .w = w, .a = arena.allocator(), .diag = diagnostic orelse &scratch, .source = options.source, .aliases = options.aliases };
    try g.file(options);
}

const Gen = struct {
    s: Schema,
    w: *std.Io.Writer,
    a: std.mem.Allocator,
    diag: *Schema.Diagnostic,
    source: []const u8 = "",
    aliases: []const Alias = &.{},
    top: std.ArrayList([]const u8) = .empty,
    /// Every `addresses` function, for `resolve`.
    finds: std.ArrayList([]const u8) = .empty,
    /// Structs with a plain version, since they hold text or slices.
    lifted: std.ArrayList([]const u8) = .empty,
    /// Writing `raw`, where every name's qualified.
    in_raw: bool = false,

    fn isLifted(g: *const Gen, n: []const u8) bool {
        return contains(g.lifted.items, n);
    }

    /// The module what's declared at `at` comes from, if its file's aliased.
    fn aliasOf(g: *const Gen, at: Schema.Pos) ?[]const u8 {
        if (g.aliases.len == 0) return null;
        const file_name = Schema.fileOf(g.source, at);
        for (g.aliases) |a| if (std.mem.startsWith(u8, file_name, a.prefix)) return a.import;
        return null;
    }

    /// `pub const T = @import("m").T;`, and for structs a check it's laid out as the schema says.
    fn aliasDef(g: *Gen, t: *const Schema.Type, import: []const u8) Error!void {
        const w = g.w;
        const n = try g.typeName(t.name);
        try w.print("pub const {f} = @import(\"{s}\").{f};\n", .{ id(n), import, id(n) });
        if (t.kind == .@"error") {
            const c = try g.codeName(t.name);
            try w.print("pub const {f} = @import(\"{s}\").{f};\n", .{ id(c), import, id(c) });
        }
        if (t.kind != .@"struct" and t.kind != .@"union") return;
        // The wire one, which plain structs have in `raw`
        const T = if (g.isLifted(t.name))
            try std.fmt.allocPrint(g.a, "@import(\"{s}\").raw.{f}", .{ import, id(n) })
        else
            try std.fmt.allocPrint(g.a, "{f}", .{id(n)});
        try w.print("comptime {{\n    if (@sizeOf({s}) != {d}) @compileError(\"salamander: {s} from {s} isn't {d} bytes like the schema says\");\n", .{ T, t.size, t.name, import, t.size });
        if (t.kind == .@"struct") {
            var it: plan.Slots = .init(g.s, t);
            while (it.next()) |slot| switch (slot) {
                .pad => {},
                .field => |f| try w.print("    if (@offsetOf({s}, \"{s}\") != {d}) @compileError(\"salamander: {s}.{s} from {s} isn't at {d} like the schema says\");\n", .{ T, f.field.name, f.field.offset, t.name, f.field.name, import, f.field.offset }),
            };
        }
        try w.writeAll("}\n");
    }

    /// Whether `r`'s plain type differs from its wire one.
    fn differs(g: *const Gen, r: Ref) bool {
        return switch (r) {
            .prim => |p| p == .string,
            .slice => true,
            .named => |n| g.isLifted(n),
            .array => |a| g.differs(a.child.*),
            .optional => |c| c.* != .pointer and g.differs(c.*),
            else => false,
        };
    }

    fn findLifted(g: *Gen) Error!void {
        var changed = true;
        while (changed) {
            changed = false;
            for (g.s.types) |t| {
                if (t.kind != .@"struct" or g.isLifted(t.name)) continue;
                for (t.kind.@"struct".fields) |f| if (g.differs(f.type)) {
                    try g.lifted.append(g.a, t.name);
                    changed = true;
                    break;
                };
            }
        }
    }

    /// Whether a parameter or return's plain type differs. Text and slices of what doesn't differ
    /// cross as they are.
    fn argDiffers(g: *const Gen, r: Ref) bool {
        return switch (r) {
            .prim => false,
            .slice => |c| g.differs(c.*),
            .optional => |c| c.* != .pointer and g.argDiffers(c.*),
            .result => |res| g.argDiffers(res.ok.*),
            else => g.differs(r),
        };
    }

    fn touches(g: *const Gen, sig: Schema.Signature) bool {
        for (sig.params) |p| if (g.argDiffers(p.type)) return true;
        return g.argDiffers(sig.ret);
    }

    fn file(g: *Gen, options: Options) Error!void {
        const s = g.s;
        try g.w.print(
            \\//! Generated by salamander from {s}. Don't edit it, it's written again every build.
            \\
            \\const rt = @import("{s}");
            \\const generated = @This();
            \\
        , .{ options.label, options.runtime });
        // Only layouts depend on pointer size, so a file of traits works for any
        const laid_out = for (s.types) |t| {
            if (t.kind == .@"struct" or t.kind == .@"union") break true;
        } else false;
        try g.w.writeAll("const std = @import(\"std\");\n");
        if (laid_out) try g.w.print(
            \\
            \\comptime {{
            \\    if (@sizeOf(usize) != {d}) @compileError("salamander: these types are for {d}-bit code");
            \\}}
            \\
        , .{ s.pointer_size, @as(usize, s.pointer_size) * 8 });

        for (plan.reserved) |n| try g.claim(&g.top, "", n);
        try g.claim(&g.top, "", "std");
        for (s.types) |t| {
            try g.claim(&g.top, "", try g.typeName(t.name));
            if (t.kind == .@"error") try g.claim(&g.top, "", try g.codeName(t.name));
        }
        for (s.traits) |t| try g.claim(&g.top, "", t.name);
        for (s.constants) |k| try g.claim(&g.top, "", k.name);
        for (s.functions) |f| try g.claim(&g.top, "", f.name);
        for (s.statics) |v| {
            try g.claim(&g.top, "", v.name);
            if (v.type == .pointer) try g.claim(&g.top, "", try std.fmt.allocPrint(g.a, "{s}OrFail", .{v.name}));
        }
        if (s.functions.len + s.statics.len > 0) {
            try g.claim(&g.top, "", "addresses");
            if (s.functions.len > 0) try g.claim(&g.top, "", "Fns");
        }
        if (hasGameCode(s)) try g.claim(&g.top, "", "resolve");
        try g.claim(&g.top, "", "raw");
        try g.claim(&g.top, "", "generated");
        try g.findLifted();

        for (s.types) |*t| {
            try g.w.writeAll("\n");
            if (g.aliasOf(t.at)) |import| {
                try g.aliasDef(t, import);
                continue;
            }
            switch (t.kind) {
                .@"struct", .@"union" => if (g.isLifted(t.name)) try g.plainDef(t) else try g.structDef(t),
                .@"enum" => |e| {
                    try g.w.print("pub const {f} = ", .{id(try g.typeName(t.name))});
                    try g.enumBody(@intCast(e.backing.size(s.pointer_size) * 8), e.backing.isSigned(), e.values);
                    try g.w.writeAll(";\n");
                },
                .bitfield => try g.bitfieldDef(t),
                .@"error" => |e| try g.errorDef(t, e),
                .@"opaque" => try g.w.print("pub const {f} = opaque {{}};\n", .{id(t.name)}),
                .func => |sig| {
                    try g.w.print("pub const {f} = ", .{id(t.name)});
                    try g.fnValue(sig);
                    try g.w.writeAll(";\n");
                },
            }
        }
        if (s.constants.len > 0) try g.w.writeAll("\n");
        for (s.constants) |k| {
            if (g.aliasOf(k.at)) |import| {
                try g.w.print("pub const {f} = @import(\"{s}\").{f};\n", .{ id(k.name), import, id(k.name) });
            } else try g.constant(k);
        }
        for (s.traits) |*t| {
            if (g.aliasOf(t.at)) |import| {
                try g.w.print("\npub const {f} = @import(\"{s}\").{f};\n", .{ id(t.name), import, id(t.name) });
            } else try g.trait(t);
        }
        if (s.impls.len > 0) try g.impls();
        try g.globals();
        if (g.finds.items.len > 0) try g.resolveFn();
        try g.rawNamespace();
    }

    /// Every type as it crosses: the wire structs, and the rest as they are.
    fn rawNamespace(g: *Gen) Error!void {
        const w = g.w;
        try w.writeAll("\n/// Every type as it crosses, for implementing traits and passing tables around.\npub const raw = struct {\n");
        for (g.s.types) |*t| {
            const n = try g.typeName(t.name);
            if (g.isLifted(t.name)) {
                if (g.aliasOf(t.at)) |import| {
                    try w.print("pub const {f} = @import(\"{s}\").raw.{f};\n", .{ id(n), import, id(n) });
                    continue;
                }
                g.in_raw = true;
                defer g.in_raw = false;
                try g.structDef(t);
            } else {
                try w.print("pub const {f} = generated.{f};\n", .{ id(n), id(n) });
                if (t.kind == .@"error") {
                    const c = try g.codeName(t.name);
                    try w.print("pub const {f} = generated.{f};\n", .{ id(c), id(c) });
                }
            }
        }
        for (g.s.traits) |t| try w.print("pub const {f} = generated.{f};\n", .{ id(t.name), id(t.name) });
        try w.writeAll("};\n");
    }

    /// A struct with text or slices as plain Zig, with defaults.
    fn plainDef(g: *Gen, t: *const Schema.Type) Error!void {
        const w = g.w;
        try w.print("pub const {f} = struct {{\n", .{id(try g.typeName(t.name))});
        var names: std.ArrayList([]const u8) = .empty;
        var chain: std.ArrayList(*const Schema.Type) = .empty;
        var at: ?*const Schema.Type = t;
        while (at) |cur| : (at = g.s.baseOf(cur)) try chain.insert(g.a, 0, cur);
        for (chain.items) |cur| for (cur.kind.@"struct".fields) |f| {
            try g.claim(&names, t.name, f.name);
            try w.print("    {f}: ", .{id(f.name)});
            try g.plainType(f.type);
            try w.writeAll(" = ");
            try g.plainDefault(f.type);
            try w.writeAll(",\n");
        };
        try w.writeAll("};\n");
    }

    fn plainType(g: *Gen, r: Ref) Error!void {
        switch (r) {
            .prim => |p| if (p == .string) try g.w.writeAll("[]const u8") else try g.prim(p),
            .named => |n| if (g.isLifted(n)) try g.w.print("{f}", .{id(try g.typeName(n))}) else try g.named(n),
            .slice => |c| {
                try g.w.writeAll("[]const ");
                try g.plainType(c.*);
            },
            .array => |a| {
                try g.w.print("[{d}]", .{a.len});
                try g.plainType(a.child.*);
            },
            .optional => |c| if (c.* == .pointer) try g.memType(r) else try g.plainType(c.*),
            else => try g.memType(r),
        }
    }

    fn plainDefault(g: *Gen, r: Ref) Error!void {
        switch (r) {
            .prim => |p| if (p == .string) return g.w.writeAll("\"\""),
            .slice => return g.w.writeAll("&.{}"),
            .named => |n| if (g.isLifted(n)) return g.w.writeAll(".{}"),
            .array => |a| if (g.differs(a.child.*)) {
                try g.w.writeAll("@splat(");
                try g.plainDefault(a.child.*);
                return g.w.writeAll(")");
            },
            else => {},
        }
        try g.w.writeAll("std.mem.zeroes(");
        try g.plainType(r);
        try g.w.writeAll(")");
    }

    /// A method's parameter as callers write it.
    fn plainParam(g: *Gen, r: Ref) Error!void {
        if (!g.argDiffers(r)) return g.paramType(r);
        switch (r) {
            .optional => |c| {
                try g.w.writeAll("?");
                try g.plainParam(c.*);
            },
            else => try g.plainType(r),
        }
    }

    fn plainReturn(g: *Gen, r: Ref) Error!void {
        switch (r) {
            .result => |res| {
                try g.w.print("({f} || rt.Failure)!", .{id(res.err)});
                try g.plainReturn(res.ok.*);
            },
            else => if (g.argDiffers(r)) try g.plainParam(r) else try g.returnType(r),
        }
    }

    fn claim(g: *Gen, list: *std.ArrayList([]const u8), owner: []const u8, n: []const u8) Error!void {
        for (list.items) |o| if (std.mem.eql(u8, o, n)) {
            if (owner.len == 0) g.diag.print("{s}: Zig can't have two things called that at the top", .{n}) else g.diag.print("{s}.{s}: Zig can't have two things called that in one type", .{ owner, n });
            return error.NameClash;
        };
        try list.append(g.a, n);
    }

    fn typeName(g: *Gen, n: []const u8) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, n, '.') == null) return n;
        const out = try g.a.dupe(u8, n);
        std.mem.replaceScalar(u8, out, '.', '_');
        return out;
    }

    fn codeName(g: *Gen, n: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(g.a, "{s}" ++ plan.code_suffix, .{n});
    }

    // Types

    fn prim(g: *Gen, p: Schema.Prim) Error!void {
        try g.w.writeAll(switch (p) {
            .utf8 => "u8",
            .utf16 => "u16",
            .string => "rt.String",
            .object => "rt.AnyObject",
            .blob => "rt.Blob",
            .cstring => "?[*:0]const u8",
            .void => "anyopaque",
            else => @tagName(p),
        });
    }

    /// A wire type's name. Plain ones' wire versions are in `raw`, and inside it everything's qualified.
    fn named(g: *Gen, n: []const u8) Error!void {
        const prefix = if (g.in_raw or g.isLifted(n)) "raw." else "";
        try g.w.print("{s}{f}", .{ prefix, id(try g.typeName(n)) });
    }

    fn memType(g: *Gen, r: Ref) Error!void {
        switch (r) {
            .prim => |p| try g.prim(p),
            .named => |n| try g.named(n),
            .pointer => |c| try g.pointerTo(c.*, true),
            .array => |a| {
                try g.w.print("[{d}]", .{a.len});
                try g.memType(a.child.*);
            },
            .slice => |c| {
                try g.w.writeAll("rt.Slice(");
                try g.memType(c.*);
                try g.w.writeAll(")");
            },
            .optional => |c| switch (c.*) {
                .pointer => |pc| try g.pointerTo(pc.*, true),
                else => try g.memType(c.*),
            },
            .func => |sig| try g.fnValue(sig.*),
            .result => unreachable,
        }
    }

    fn pointerTo(g: *Gen, c: Ref, nullable: bool) Error!void {
        if (nullable) try g.w.writeAll("?");
        if (c == .prim) switch (c.prim) {
            .utf8 => return g.w.writeAll("[*:0]u8"),
            .utf16 => return g.w.writeAll("[*:0]u16"),
            else => {},
        };
        try g.w.writeAll("*");
        try g.memType(c);
    }

    fn paramType(g: *Gen, r: Ref) Error!void {
        switch (r) {
            .prim => |p| if (p == .string) try g.w.writeAll("[]const u8") else try g.prim(p),
            .pointer => |c| try g.pointerTo(c.*, false),
            .slice => |c| {
                try g.w.writeAll("[]const ");
                try g.memType(c.*);
            },
            .optional => |c| switch (c.*) {
                .pointer => |pc| try g.pointerTo(pc.*, true),
                .named => {
                    try g.w.writeAll("?");
                    if (g.s.isObject(c.*)) try g.memType(c.*) else try g.paramType(c.*);
                },
                else => {
                    try g.w.writeAll("?");
                    try g.paramType(c.*);
                },
            },
            else => try g.memType(r),
        }
    }

    fn returnType(g: *Gen, r: Ref) Error!void {
        switch (r) {
            .prim => |p| if (p == .void) try g.w.writeAll("void") else try g.paramType(r),
            .result => |res| {
                try g.w.print("({f} || rt.Failure)!", .{id(res.err)});
                try g.returnType(res.ok.*);
            },
            else => try g.paramType(r),
        }
    }

    /// `fn (f32, []const u8) bool`, without names so they can't shadow anything.
    fn fnType(g: *Gen, sig: Schema.Signature, is_async: bool) Error!void {
        try g.w.writeAll("fn (");
        for (sig.params, 0..) |p, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.paramType(p.type);
        }
        try g.w.writeAll(") ");
        try g.wrapAsync(sig.ret, is_async);
    }

    fn wrapAsync(g: *Gen, ret: Ref, is_async: bool) Error!void {
        if (is_async) try g.w.writeAll("rt.Promise(");
        try g.returnType(ret);
        if (!is_async) return;
        if (ret == .result) try g.w.print(", {f})", .{id(try g.codeName(ret.result.err))}) else try g.w.writeAll(", null)");
    }

    /// `.conv`, `.static` and `.Errors` after `.Fn`, when they aren't the defaults.
    fn methodExtras(g: *Gen, sig: Schema.Signature, static: bool, is_async: bool) Error!void {
        if (sig.conv != .c) try g.w.print(", .conv = .{t}", .{sig.conv});
        if (static) try g.w.writeAll(", .static = true");
        // An async method's errors go with its promise
        if (sig.ret == .result and !is_async) try g.w.print(", .Errors = {f}", .{id(try g.codeName(sig.ret.result.err))});
    }

    fn fnValue(g: *Gen, sig: Schema.Signature) Error!void {
        try g.w.writeAll("rt.Fn(.{ .name = \"fn\", .Fn = ");
        try g.fnType(sig, false);
        try g.methodExtras(sig, false, false);
        try g.w.print(", .sig = 0x{x:0>16} }})", .{Schema.signatureHash(sig)});
    }

    // Declarations

    fn structDef(g: *Gen, t: *const Schema.Type) Error!void {
        const w = g.w;
        try w.print("pub const {f} = extern {s} {{\n", .{ id(try g.typeName(t.name)), if (t.kind == .@"union") "union" else "struct" });
        var names: std.ArrayList([]const u8) = .empty;
        var counted: std.ArrayList(Counted) = .empty;
        var it: plan.Slots = .init(g.s, t);
        while (it.next()) |slot| switch (slot) {
            .pad => |p| if (t.kind == .@"union")
                try w.print("    _bytes: [0x{x}]u8,\n", .{p.len})
            else
                try w.print("    _pad_0x{x}: [0x{x}]u8 = @splat(0),\n", .{ p.offset, p.len }),
            .field => |f| {
                try g.claim(&names, t.name, f.field.name);
                if (f.field.type == .array) if (f.field.type.array.count) |n| try counted.append(g.a, .{ .field = f.field.name, .count = n, .child = f.field.type.array.child.*, .alignment = if (f.alignment < f.natural) f.alignment else null });
                try w.print("    {f}: ", .{id(f.field.name)});
                try g.memType(f.field.type);
                if (f.alignment < f.natural) try w.print(" align({d})", .{f.alignment});
                // Zero, like the comptime types, outside unions
                if (t.kind != .@"union") {
                    try w.writeAll(" = std.mem.zeroes(");
                    try g.memType(f.field.type);
                    try w.writeAll(")");
                }
                try w.writeAll(",\n");
            },
        };
        // `T[count]` fields are empty arrays, with these for what's there
        for (counted.items) |c| {
            const fn_name = try std.fmt.allocPrint(g.a, "{s}Slice", .{c.field});
            try g.claim(&names, t.name, fn_name);
            try w.print("\n    /// `{s}`, as long as `{s}` says now.\n", .{ c.field, c.count });
            const elem = try g.typeText(c.child);
            const al = if (c.alignment) |n| try std.fmt.allocPrint(g.a, "align({d}) ", .{n}) else "";
            try w.print("    pub fn {f}(self: *@This()) []{s}{s} {{\n", .{ id(fn_name), al, elem });
            try w.print("        return @as([*]{s}{s}, @ptrCast(&self.{f}))[0..@intCast(@max(self.{f}, 0))];\n    }}\n", .{ al, elem, id(c.field), id(c.count) });
        }
        if (t.kind == .@"struct") try g.gameCode(t, &names);
        try w.writeAll("};\n");
    }

    const Counted = struct {
        field: []const u8,
        count: []const u8,
        child: Ref,
        alignment: ?usize,
    };

    /// `memType`'s text on its own.
    fn typeText(g: *Gen, r: Ref) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(g.a);
        const saved = g.w;
        g.w = &out.writer;
        defer g.w = saved;
        try g.memType(r);
        return out.written();
    }

    // Existing code, found through `rt.declared`

    /// A struct's code and its bases', and its statics.
    fn gameCode(g: *Gen, t: *const Schema.Type, names: *std.ArrayList([]const u8)) Error!void {
        const w = g.w;
        var methods: std.ArrayList(*const Schema.Method) = .empty;
        var statics: std.ArrayList(*const Schema.Static) = .empty;
        var at: ?*const Schema.Type = t;
        var depth: usize = 0;
        while (at) |cur| : (at = g.s.baseOf(cur)) {
            depth += 1;
            if (depth > g.s.types.len) break;
            const st = cur.kind.@"struct";
            outer: for (st.methods) |*m| {
                for (methods.items) |o| if (std.mem.eql(u8, o.name, m.name)) continue :outer;
                try methods.append(g.a, m);
            }
            outer: for (st.statics) |*v| {
                for (statics.items) |o| if (std.mem.eql(u8, o.name, v.name)) continue :outer;
                try statics.append(g.a, v);
            }
        }
        if (methods.items.len + statics.items.len == 0) return;
        const has_virtual = for (methods.items) |m| {
            if (m.virtual != null) break true;
        } else false;
        for (statics.items) |v| {
            try g.claim(names, t.name, v.name);
            if (v.type == .pointer) try g.claim(names, t.name, try std.fmt.allocPrint(g.a, "{s}OrFail", .{v.name}));
        }
        for (methods.items) |m| try g.claim(names, t.name, m.name);
        try g.claim(names, t.name, "addresses");
        if (methods.items.len > 0) try g.claim(names, t.name, "Fns");
        if (has_virtual) try g.claim(names, t.name, "slots");
        var scope: std.ArrayList([]const u8) = .empty;
        try scope.appendSlice(g.a, g.top.items);
        try scope.appendSlice(g.a, names.items);
        const self_type = try g.typeName(t.name);

        for (statics.items) |v| try g.staticFn("    ", t.name, v);
        for (methods.items) |m| try g.methodFn("    ", t.name, self_type, m, scope.items);

        if (methods.items.len > 0) {
            try w.writeAll("\n    pub const Fns = struct {\n");
            for (methods.items) |m| {
                try w.print("        pub const {f} = ", .{id(m.name)});
                try g.gameFnType(m, if (m.static) null else self_type);
                try w.writeAll(";\n");
            }
            try w.writeAll("    };\n");
        }
        if (has_virtual) {
            try w.writeAll("\n    pub const slots = struct {\n");
            for (methods.items) |m| if (m.virtual) |n| try w.print("        pub const {f} = {d};\n", .{ id(m.name), n });
            try w.writeAll("    };\n");
        }
        try w.writeAll("\n    pub const addresses = struct {\n");
        for (statics.items) |v| try g.foundFn("        ", t.name, v.name, v.name);
        for (methods.items) |m| {
            if (m.virtual == null) {
                try g.foundFn("        ", t.name, m.name, m.name);
                continue;
            }
            try w.print("        /// Slot `{s}` in the vtable every `{s}` shares. Slot hook it to hook them all.\n", .{ m.name, t.name });
            try w.print("        pub fn {f}() anyerror!usize {{\n            return try vtable() + {f}.slots.{f} * @sizeOf(usize);\n        }}\n", .{ id(m.name), id(self_type), id(m.name) });
        }
        if (has_virtual) try g.foundFn("        ", t.name, "", "vtable");
        try w.writeAll("    };\n");
    }

    fn globals(g: *Gen) Error!void {
        const w = g.w;
        const s = g.s;
        if (s.functions.len + s.statics.len == 0) return;
        try w.writeAll("\n// Existing code\n");
        for (s.statics) |*v| try g.staticFn("", "", v);
        for (s.functions) |*f| try g.methodFn("", "", "", f, g.top.items);
        if (s.functions.len > 0) {
            try w.writeAll("\npub const Fns = struct {\n");
            for (s.functions) |*f| {
                try w.print("    pub const {f} = ", .{id(f.name)});
                try g.gameFnType(f, null);
                try w.writeAll(";\n");
            }
            try w.writeAll("};\n");
        }
        try w.writeAll("\npub const addresses = struct {\n");
        for (s.statics) |v| try g.foundFn("    ", "", v.name, v.name);
        for (s.functions) |f| try g.foundFn("    ", "", f.name, f.name);
        try w.writeAll("};\n");
    }

    fn resolveFn(g: *Gen) Error!void {
        const w = g.w;
        try w.writeAll(
            \\
            \\/// Finds every static, function and vtable now, instead of on first use. Gives the first error,
            \\/// after trying them all.
            \\pub fn resolve() anyerror!void {
            \\    var first: ?anyerror = null;
            \\    inline for (.{
            \\
        );
        for (g.finds.items) |f| try w.print("        {s},\n", .{f});
        try w.writeAll(
            \\    }) |find| {
            \\        _ = find() catch |err| {
            \\            if (first == null) first = err;
            \\        };
            \\    }
            \\    if (first) |err| return err;
            \\}
            \\
        );
    }

    /// `addresses.<fn_name>`, finding `owner.name`, or `owner` for "".
    fn foundFn(g: *Gen, indent: []const u8, owner: []const u8, name: []const u8, fn_name: []const u8) Error!void {
        const full = if (owner.len == 0) name else if (name.len == 0) owner else try std.fmt.allocPrint(g.a, "{s}.{s}", .{ owner, name });
        try g.w.print("{s}pub fn {f}() anyerror!usize {{\n{s}    return rt.declared.Found(\"{f}\").get();\n{s}}}\n", .{
            indent, id(fn_name), indent, std.zig.fmtString(full), indent,
        });
        const path = if (owner.len == 0) try std.fmt.allocPrint(g.a, "addresses.{f}", .{id(fn_name)}) else try std.fmt.allocPrint(g.a, "{f}.addresses.{f}", .{ id(try g.typeName(owner)), id(fn_name) });
        try g.finds.append(g.a, path);
    }

    /// A pointer static gives what's stored there, anything else a pointer to it.
    fn staticFn(g: *Gen, indent: []const u8, owner: []const u8, v: *const Schema.Static) Error!void {
        const w = g.w;
        const full = if (owner.len == 0) v.name else try std.fmt.allocPrint(g.a, "{s}.{s}", .{ owner, v.name });
        if (v.type == .pointer) {
            try w.print("\n{s}/// `{s}`, what's stored there.\n{s}pub fn {f}() anyerror!", .{ indent, full, indent, id(v.name) });
            try g.memType(v.type);
            try w.print(" {{\n{s}    const at: *align(1) const ", .{indent});
            try g.memType(v.type);
            try w.print(" = @ptrFromInt(try {s}addresses.{f}());\n{s}    return at.*;\n{s}}}\n", .{ try g.qual(owner), id(v.name), indent, indent });
            // The same, for when null means it's too early
            const or_fail = try std.fmt.allocPrint(g.a, "{s}OrFail", .{v.name});
            try w.print("\n{s}/// `{s}`, or `error.NotThereYet` while it's null.\n{s}pub fn {f}() anyerror!*", .{ indent, full, indent, id(or_fail) });
            try g.memType(v.type.pointer.*);
            try w.print(" {{\n{s}    return (try {s}{f}()) orelse error.NotThereYet;\n{s}}}\n", .{ indent, try g.qual(owner), id(v.name), indent });
            return;
        }
        // Methods need a struct's own alignment. Anything else could be anywhere
        const whole = v.type == .named and switch (g.s.findType(v.type.named).?.kind) {
            .@"struct", .@"union" => true,
            else => false,
        };
        try w.print("\n{s}/// `{s}`, the global itself.\n{s}pub fn {f}() anyerror!{s}", .{ indent, full, indent, id(v.name), if (whole) "*" else "*align(1) " });
        try g.memType(v.type);
        try w.print(" {{\n{s}    return @ptrFromInt(try {s}addresses.{f}());\n{s}}}\n", .{ indent, try g.qual(owner), id(v.name), indent });
    }

    /// Calls it where it's found, or through `self`'s vtable for a [Virtual(n)] one.
    fn methodFn(g: *Gen, indent: []const u8, owner: []const u8, self_type: []const u8, m: *const Schema.Method, scope: []const []const u8) Error!void {
        const w = g.w;
        const full = if (owner.len == 0) m.name else try std.fmt.allocPrint(g.a, "{s}.{s}", .{ owner, m.name });
        const has_this = owner.len > 0 and !m.static;
        try w.print("\n{s}/// `{s}`{s}.\n{s}pub fn {f}(", .{ indent, full, if (m.virtual != null) ", through the vtable" else "", indent, id(m.name) });
        var used: std.ArrayList([]const u8) = .empty;
        try used.appendSlice(g.a, scope);
        if (has_this) {
            try used.append(g.a, "self");
            try w.print("self: *{f}", .{id(self_type)});
        }
        var params: std.ArrayList([]const u8) = .empty;
        for (m.signature.params, 0..) |p, i| {
            var n = p.name;
            while (contains(used.items, n)) n = try std.fmt.allocPrint(g.a, "{s}_", .{n});
            try used.append(g.a, n);
            try params.append(g.a, n);
            if (has_this or i > 0) try w.writeAll(", ");
            try w.print("{f}: ", .{id(n)});
            try g.memType(p.type);
        }
        try w.writeAll(") ");
        try g.gameReturn(m.signature.ret);
        const q = try g.qual(owner);
        try w.print(" {{\n{s}    const f: *const {s}Fns.{f} = @ptrFromInt(", .{ indent, q, id(m.name) });
        if (m.virtual != null) {
            try w.print("rt.declared.virtualAt(self, {s}slots.{f})", .{ q, id(m.name) });
        } else {
            try w.print("{s}addresses.{f}() catch |err| rt.declared.missing(\"{f}\", err)", .{ q, id(m.name), std.zig.fmtString(full) });
        }
        try w.print(");\n{s}    return f(", .{indent});
        if (has_this) try w.writeAll("self");
        for (params.items, 0..) |n, i| {
            if (has_this or i > 0) try w.writeAll(", ");
            try w.print("{f}", .{id(n)});
        }
        try w.print(");\n{s}}}\n", .{indent});
    }

    /// As it's called, with `this` first if there's one.
    fn gameFnType(g: *Gen, m: *const Schema.Method, this: ?[]const u8) Error!void {
        const w = g.w;
        try w.writeAll("fn (");
        if (this) |t| try w.print("*{f}", .{id(t)});
        for (m.signature.params, 0..) |p, i| {
            if (this != null or i > 0) try w.writeAll(", ");
            try g.memType(p.type);
        }
        try w.print(") callconv(rt.callingConvention(.{t})) ", .{m.signature.conv});
        try g.gameReturn(m.signature.ret);
    }

    /// `Player.`, so a struct's decls aren't mistaken for the top's of the same name.
    fn qual(g: *Gen, owner: []const u8) Error![]const u8 {
        if (owner.len == 0) return "";
        return std.fmt.allocPrint(g.a, "{f}.", .{id(try g.typeName(owner))});
    }

    fn gameReturn(g: *Gen, r: Ref) Error!void {
        if (r == .prim and r.prim == .void) return g.w.writeAll("void");
        try g.memType(r);
    }

    fn enumBody(g: *Gen, bits: u16, signed: bool, values: []const Schema.Enum.Value) Error!void {
        try g.w.print("enum({c}{d}) {{ ", .{ @as(u8, if (signed) 'i' else 'u'), bits });
        for (values, 0..) |v, i| {
            if (i > 0) try g.w.writeAll(", ");
            try g.w.print("{f} = {d}", .{ id(v.name), v.value });
        }
        if (!plan.exhaustive(bits, values.len)) try g.w.writeAll(if (values.len > 0) ", _" else "_");
        try g.w.writeAll(" }");
    }

    fn bitfieldDef(g: *Gen, t: *const Schema.Type) Error!void {
        const w = g.w;
        const b = t.kind.bitfield;
        try w.print("pub const {f} = bitpack struct(u{d}) {{\n", .{ id(try g.typeName(t.name)), b.backing.size(g.s.pointer_size) * 8 });
        var it: plan.Bits = .init(g.s, b);
        while (it.next()) |bit| switch (bit) {
            .pad => |p| try w.print("    _bit_{d}: u{d} = 0,\n", .{ p.bit, p.bits }),
            .member => |m| {
                try w.print("    {f}: ", .{id(m.name)});
                switch (m.type) {
                    .bool => if (m.bits == 1) try w.writeAll("bool = false") else try w.print("u{d} = 0", .{m.bits}),
                    .uint => try w.print("u{d} = 0", .{m.bits}),
                    .@"enum" => |n| {
                        const values = g.s.findType(n).?.kind.@"enum".values;
                        try g.enumBody(m.bits, false, values);
                        // Zero like the comptime types, unless it's an enum with no zero
                        if (plan.hasZero(m.bits, values)) try w.writeAll(" = @enumFromInt(0)");
                    },
                }
                try w.writeAll(",\n");
            },
        };
        try w.writeAll("};\n");
    }

    fn errorDef(g: *Gen, t: *const Schema.Type, e: Schema.ErrorSet) Error!void {
        const w = g.w;
        try w.print("pub const {f} = error{{", .{id(t.name)});
        for (e.errors, 0..) |x, i| try w.print("{s}{f}", .{ if (i > 0) ", " else " ", id(x.name) });
        try w.writeAll(" };\n");
        try w.print("pub const {f} = enum(u32) {{", .{id(try g.codeName(t.name))});
        for (e.errors) |x| try w.print(" {f} = {d},", .{ id(x.name), x.code });
        try w.writeAll(" _ };\n");
    }

    fn constant(g: *Gen, k: Schema.Constant) Error!void {
        const w = g.w;
        try w.print("pub const {f}: ", .{id(k.name)});
        try g.paramType(k.type);
        switch (k.value) {
            .int => |n| try w.print(" = {d};\n", .{n}),
            .float => |f| try w.print(" = {d};\n", .{f}),
            .bool => |b| try w.print(" = {};\n", .{b}),
            .string => |str| try w.print(" = \"{s}\";\n", .{str}),
        }
    }

    fn trait(g: *Gen, t: *const Schema.Trait) Error!void {
        const w = g.w;
        const name = t.name;
        var buf: [plan.max_methods]*const Schema.Method = undefined;
        const ms = plan.methods(g.s, t, &buf);

        // Fields and decls share one namespace
        var members: std.ArrayList([]const u8) = .empty;
        for ([_][]const u8{ "data", "table", "salamander", "init", "self" }) |n| try members.append(g.a, n);
        for (ms) |m| try g.claim(&members, name, m.name);

        try w.print(
            \\
            \\pub const {f} = extern struct {{
            \\    data: usize = 0,
            \\    table: ?*const anyopaque = null,
            \\
            \\    pub const salamander = struct {{
            \\        pub const name = "{s}";
            \\        pub const hash: u64 = 0x{x:0>16};
            \\        pub const methods: []const rt.Method = &.{{
            \\
        , .{ id(name), name, g.s.traitHash(t) });
        for (ms) |m| {
            try w.print("            .{{ .name = \"{s}\", .Fn = ", .{m.name});
            try g.fnType(m.signature, m.async);
            try g.methodExtras(m.signature, m.static, m.async);
            try w.print(", .sig = 0x{x:0>16} }},\n", .{Schema.methodHash(m)});
        }
        try w.print(
            \\        }};
            \\    }};
            \\
            \\    pub fn init(data: anytype, table: *const rt.Table({f})) {f} {{
            \\        return .{{ .data = rt.toData(data), .table = table }};
            \\    }}
            \\
        , .{ id(name), id(name) });
        // Unless it has its own
        const has_release = for (ms) |m| {
            if (std.mem.eql(u8, m.name, "release")) break true;
        } else false;
        if (!has_release) try w.print(
            \\
            \\    /// Done holding it, after getting it through a `keep` parameter or a return.
            \\    pub fn release(self: {f}) void {{
            \\        rt.host().release(self);
            \\    }}
            \\
        , .{id(name)});

        for (ms) |m| {
            // A parameter can't shadow anything in scope
            var taken: std.ArrayList([]const u8) = .empty;
            try taken.appendSlice(g.a, g.top.items);
            try taken.appendSlice(g.a, members.items);
            // And a plain method's locals
            try taken.appendSlice(g.a, &.{ "arena", "args", "got", "T" });
            var params: std.ArrayList([]const u8) = .empty;
            for (m.signature.params) |p| {
                var n = p.name;
                while (contains(taken.items, n)) n = try std.fmt.allocPrint(g.a, "{s}_", .{n});
                try taken.append(g.a, n);
                try params.append(g.a, n);
            }

            if (!m.async and g.touches(m.signature)) {
                try g.plainMethod(name, m, params.items);
                continue;
            }
            try w.print("\n    pub fn {f}(self: {f}", .{ id(m.name), id(name) });
            for (m.signature.params, params.items) |p, n| {
                try w.print(", {f}: ", .{id(n)});
                try g.paramType(p.type);
            }
            try w.writeAll(") ");
            try g.wrapAsync(m.signature.ret, m.async);
            try w.print(" {{\n        return rt.invoke({f}, \"{s}\", self, .{{", .{ id(name), m.name });
            // Spaced like zig fmt, which only pads two or more
            const pad = params.items.len > 1;
            for (params.items, 0..) |n, i| try w.print("{s}{f}", .{ if (i > 0) ", " else if (pad) " " else "", id(n) });
            try w.writeAll(if (pad) " });\n    }\n" else "});\n    }\n");
        }
        try w.writeAll("};\n");
    }

    /// A method taking and giving plain types, converting them for the call.
    fn plainMethod(g: *Gen, name: []const u8, m: *const Schema.Method, params: []const []const u8) Error!void {
        const w = g.w;
        const sig = m.signature;
        try w.print("\n    pub fn {f}(self: {f}", .{ id(m.name), id(name) });
        for (sig.params, params) |p, n| {
            try w.print(", {f}: ", .{id(n)});
            try g.plainParam(p.type);
        }
        try w.writeAll(") ");
        try g.plainReturn(sig.ret);
        try w.writeAll(" {\n");
        try w.writeAll("        var arena: @import(\"std\").heap.ArenaAllocator = .init(@import(\"std\").heap.smp_allocator);\n        defer arena.deinit();\n");
        try w.print("        const args: rt.Args({f}, \"{s}\") = .{{", .{ id(name), m.name });
        for (sig.params, params, 0..) |p, n, i| {
            try w.writeAll(if (i > 0) ", " else " ");
            if (g.argDiffers(p.type))
                try w.print("rt.toWire(@FieldType(rt.Args({f}, \"{s}\"), \"{d}\"), arena.allocator(), {f}) catch @panic(\"salamander: out of memory\")", .{ id(name), m.name, i, id(n) })
            else
                try w.print("{f}", .{id(n)});
        }
        try w.writeAll(if (sig.params.len > 0) " };\n" else "};\n");
        try w.print("        const got = rt.invoke({f}, \"{s}\", self, args);\n", .{ id(name), m.name });
        const ok: Ref = if (sig.ret == .result) sig.ret.result.ok.* else sig.ret;
        if (!g.argDiffers(ok)) return w.writeAll("        return got;\n    }\n");
        try w.writeAll("        const T = ");
        try g.plainParam(ok);
        try w.writeAll(";\n");
        if (sig.ret == .result)
            try w.writeAll("        return rt.fromWire(T, rt.lifting(), try got) catch error.Unsupported;\n    }\n")
        else
            try w.writeAll("        return rt.fromWire(T, rt.lifting(), got) catch @panic(\"salamander: out of memory\");\n    }\n");
    }

    fn impls(g: *Gen) Error!void {
        const w = g.w;
        try w.writeAll("\n/// Tables for game structs' impls. Tools fill in what their annotations find.\npub const impl = struct {\n");
        for (g.s.impls, 0..) |*im, i| {
            if (i > 0) try w.writeAll("\n");
            const t = g.s.findTrait(im.trait).?;
            var buf: [plan.max_methods]*const Schema.Method = undefined;
            const ms = plan.methods(g.s, t, &buf);
            const label = try std.fmt.allocPrint(g.a, "{s} for {s}", .{ im.trait, im.@"for" });
            try w.print("    pub fn {f}() *rt.Table({f}) {{\n        return rt.mapped({f}, &.{{\n", .{ id(label), id(im.trait), id(im.trait) });
            for (ms) |m| {
                try w.print("            .{{ .method = \"{s}\", .how = ", .{m.name});
                switch (plan.how(g.s, im, m)) {
                    .virtual => |v| try w.print(".{{ .virtual = .{{ .slot = {d}, .conv = .{t} }} }}", .{ v.slot, v.conv }),
                    .get => |o| try w.print(".{{ .get = 0x{x} }}", .{o}),
                    .set => |o| try w.print(".{{ .set = 0x{x} }}", .{o}),
                    .missing => try w.writeAll(".missing"),
                }
                try w.writeAll(" },\n");
            }
            try w.writeAll("        });\n    }\n");
        }
        try w.writeAll("};\n");
    }
};

fn hasGameCode(s: Schema) bool {
    if (s.functions.len + s.statics.len > 0) return true;
    for (s.types) |t| switch (t.kind) {
        .@"struct" => |st| if (st.methods.len + st.statics.len > 0) return true,
        else => {},
    };
    return false;
}

fn contains(list: []const []const u8, n: []const u8) bool {
    for (list) |o| if (std.mem.eql(u8, o, n)) return true;
    return false;
}

test "writes the types" {
    var diag: Schema.Diagnostic = .{};
    var parsed = try salamander_schema.parse(std.testing.allocator,
        \\struct Vec3 { f32 x; f32 y; f32 z; }
        \\error LoadError { NotFound, Corrupt = 7 }
        \\trait Mover { [Thiscall] Vec3 move(Vec3 by, string why); Vec3!LoadError load(string self); }
    , .{ .pointer_size = 8 }, &diag);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, parsed.schema, &out.writer, .{}, &diag);
    const text = out.written();
    const want = [_][]const u8{
        "pub const Vec3 = extern struct {\n    x: f32 = std.mem.zeroes(f32),\n    y: f32 = std.mem.zeroes(f32),\n    z: f32 = std.mem.zeroes(f32),\n};",
        "pub const LoadError = error{ NotFound, Corrupt };",
        "pub const LoadErrorCode = enum(u32) { NotFound = 1, Corrupt = 7, _ };",
        ".{ .name = \"move\", .Fn = fn (Vec3, []const u8) Vec3, .conv = .thiscall, .sig = 0x",
        "pub fn move(self: Mover, by: Vec3, why: []const u8) Vec3 {",
        // `self` is taken, so the parameter gets a _
        "pub fn load(self: Mover, self_: []const u8) (LoadError || rt.Failure)!Vec3 {",
    };
    for (want) |part| if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing:\n{s}\n\nin:\n{s}\n", .{ part, text });
        return error.TestUnexpectedResult;
    };
}

test "names Zig can't tell apart" {
    var diag: Schema.Diagnostic = .{};
    var parsed = try salamander_schema.parse(std.testing.allocator, "struct rt { u32 x; }", .{}, &diag);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.NameClash, write(std.testing.allocator, parsed.schema, &out.writer, .{}, &diag));
}

test "aliased files come from another module" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try salamander_schema.bundle(a, &.{
        .{ .name = "math/math.sal", .text = "struct Vec3 { f32 x; f32 y; f32 z; }\nstruct Named { string name; f32 w; }\ntrait Shape { f32 area(); }\nconst u32 dims = 3;" },
        .{ .name = "game.sal", .text = "struct Player { Vec3 at; }\ntrait Mover { Vec3 move(Vec3 by, Named n); }" },
    });
    var diag: Schema.Diagnostic = .{};
    var parsed = try salamander_schema.parse(a, source, .{ .pointer_size = 8 }, &diag);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    try write(a, parsed.schema, &out.writer, .{ .source = source, .aliases = &.{.{ .prefix = "math/", .import = "tuft_math" }} }, &diag);
    const text = out.written();
    const want = [_][]const u8{
        "pub const Vec3 = @import(\"tuft_math\").Vec3;",
        "if (@sizeOf(Vec3) != 12)",
        "if (@offsetOf(Vec3, \"z\") != 8)",
        // Plain structs are checked by their wire layout
        "pub const Named = @import(\"tuft_math\").Named;",
        "if (@sizeOf(@import(\"tuft_math\").raw.Named) != 24)",
        "pub const Shape = @import(\"tuft_math\").Shape;",
        "pub const dims = @import(\"tuft_math\").dims;",
        // Everything else is written as usual, using them
        "pub const Player = extern struct {\n    at: Vec3 = std.mem.zeroes(Vec3),",
        "pub fn move(self: Mover, by: Vec3, n: Named) Vec3 {",
    };
    for (want) |part| if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing:\n{s}\n\nin:\n{s}\n", .{ part, text });
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(std.mem.indexOf(u8, text, "pub const Vec3 = extern struct") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pub const Named = @import(\"tuft_math\").raw.Named;") != null);
}
