//! A schema as JSON: every type, trait, constant and existing function, with docs, where each is, and layouts.
//! Types are objects with their `.sal` text in `sal` and what they're made of, so docs can link each name.
//! With `langs`, each thing also has `langs`: how each language writes it, by its id.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const types = @import("salamander_types");
const lang = @import("salamander_lang");

const Schema = salamander_schema.Schema;
const Ref = Schema.Ref;
const Stringify = std.json.Stringify;

/// Goes up when what's written changes in a way readers would notice.
pub const format_version = 1;

pub const Error = std.Io.Writer.Error || error{OutOfMemory};

pub const Options = struct {
    /// Names the file when the source isn't a bundle.
    label: []const u8 = "schema.sal",
    /// What was parsed, for docs and where things are. Without it there are neither.
    source: []const u8 = "",
    /// How each language names and declares things, in the order docs show them.
    langs: []const lang.Names = &.{},
};

pub fn write(gpa: std.mem.Allocator, s: Schema, w: *std.Io.Writer, options: Options) Error!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var j: Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    var g: Gen = .{ .s = s, .j = &j, .a = arena.allocator(), .o = options };
    try g.root();
    try w.writeByte('\n');
}

const Gen = struct {
    s: Schema,
    j: *Stringify,
    a: std.mem.Allocator,
    o: Options,

    fn field(g: *Gen, key: []const u8, v: anytype) Error!void {
        try g.j.objectField(key);
        try g.j.write(v);
    }

    fn root(g: *Gen) Error!void {
        try g.j.beginObject();
        try g.field("salamander", format_version);
        try g.field("pointerSize", g.s.pointer_size);
        try g.j.objectField("languages");
        try g.j.beginArray();
        for (g.o.langs) |l| {
            try g.j.beginObject();
            try g.field("id", l.id);
            try g.field("label", l.label);
            try g.j.endObject();
        }
        try g.j.endArray();
        try g.files();

        try g.j.objectField("builtinErrors");
        try g.j.beginArray();
        const codes = [_]u32{ Schema.cancelled_code, Schema.unsupported_code, Schema.gone_code };
        for (Schema.builtin_errors, codes) |n, c| {
            try g.j.beginObject();
            try g.field("name", n);
            try g.field("code", c);
            try g.j.endObject();
        }
        try g.j.endArray();

        try g.j.objectField("types");
        try g.j.beginArray();
        for (g.s.types) |*t| if (!std.mem.eql(u8, t.name, Schema.signature_name)) try g.typeDecl(t);
        try g.j.endArray();

        try g.j.objectField("traits");
        try g.j.beginArray();
        for (g.s.traits) |*t| try g.trait(t);
        try g.j.endArray();

        try g.j.objectField("constants");
        try g.j.beginArray();
        for (g.s.constants) |*c| try g.constant(c);
        try g.j.endArray();

        try g.j.objectField("functions");
        try g.j.beginArray();
        for (g.s.functions) |*m| try g.method(m, .top);
        try g.j.endArray();

        try g.j.objectField("statics");
        try g.j.beginArray();
        for (g.s.statics) |*v| try g.static(v, null);
        try g.j.endArray();

        try g.j.objectField("impls");
        try g.j.beginArray();
        for (g.s.impls) |*i| try g.impl(i);
        try g.j.endArray();
        try g.j.endObject();
    }

    // Files

    /// Each file with the comment at its top, when a blank line keeps it off the first thing.
    fn files(g: *Gen) Error!void {
        try g.j.objectField("files");
        try g.j.beginArray();
        const src = g.o.source;
        var any = false;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, src, i, Schema.bundle_marker)) |m| : (i = m + 1) {
            if (m != 0 and src[m - 1] != '\n') continue;
            const name_start = m + Schema.bundle_marker.len;
            const name_end = std.mem.indexOfScalarPos(u8, src, name_start, '"') orelse continue;
            const line_end = std.mem.indexOfScalarPos(u8, src, name_end, '\n') orelse src.len;
            const text_start = @min(line_end + 1, src.len);
            const next = std.mem.indexOfPos(u8, src, text_start, "\n" ++ Schema.bundle_marker);
            try g.file(src[name_start..name_end], src[text_start..if (next) |n| n + 1 else src.len]);
            any = true;
        }
        if (!any) try g.file(g.o.label, src);
        try g.j.endArray();
    }

    fn file(g: *Gen, name: []const u8, text: []const u8) Error!void {
        try g.j.beginObject();
        try g.field("name", name);
        var out: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        const header = while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "//")) break line.len == 0;
            if (out.items.len > 0) try out.append(g.a, '\n');
            try out.appendSlice(g.a, std.mem.trim(u8, line[2..], " \t"));
        } else true;
        if (header and out.items.len > 0) try g.field("doc", out.items);
        try g.j.endObject();
    }

    /// `file`, `line` and `doc`, for something at `at`.
    fn place(g: *Gen, at: usize) Error!void {
        const src = g.o.source;
        if (src.len == 0 or at > src.len) return;
        const text = Schema.fileText(src, at);
        const start = @intFromPtr(text.ptr) - @intFromPtr(src.ptr);
        const name = Schema.fileOf(src, at);
        try g.field("file", if (name.len > 0) name else g.o.label);
        try g.field("line", std.mem.count(u8, src[start..at], "\n") + 1);
        var lines = types.docLines(src, at);
        var out: std.ArrayList(u8) = .empty;
        while (lines.next()) |l| {
            if (out.items.len > 0) try out.append(g.a, '\n');
            try out.appendSlice(g.a, l);
        }
        if (out.items.len > 0) try g.field("doc", out.items);
    }

    /// The full name and the namespace it's in, "" at the top.
    fn names(g: *Gen, full: []const u8) Error!void {
        try g.field("name", full);
        try g.field("namespace", if (Schema.namespaceEnd(full)) |d| full[0..d] else "");
    }

    /// `langs`, each language's `Decl` from `lang.Names.VTable`'s `f`. One that doesn't have it is left out.
    fn spell(g: *Gen, comptime f: []const u8, with: anytype) Error!void {
        if (g.o.langs.len == 0) return;
        try g.j.objectField("langs");
        try g.j.beginObject();
        for (g.o.langs) |l| {
            const got = @call(.auto, @field(l.vt, f), .{l.ptr} ++ with) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            const d = got orelse continue;
            try g.j.objectField(l.id);
            try g.decl(d);
        }
        try g.j.endObject();
    }

    /// `{ name, path?, type?, params?, text? }`, the parameters as `{ name, type }`.
    fn decl(g: *Gen, d: lang.Decl) Error!void {
        try g.j.beginObject();
        try g.field("name", d.name);
        if (d.path) |p| try g.field("path", p);
        if (d.type) |t| try g.field("type", t);
        if (d.params.len > 0) {
            try g.j.objectField("params");
            try g.j.beginArray();
            for (d.params) |p| {
                try g.j.beginObject();
                try g.field("name", p.name);
                try g.field("type", p.type);
                try g.j.endObject();
            }
            try g.j.endArray();
        }
        if (d.text) |t| try g.field("text", t);
        try g.j.endObject();
    }

    // Declarations

    fn typeDecl(g: *Gen, t: *const Schema.Type) Error!void {
        try g.j.beginObject();
        try g.names(t.name);
        try g.field("kind", @tagName(t.kind));
        try g.place(t.at);
        if (t.alignment != 0 and t.size != Schema.Type.auto) {
            try g.field("size", t.size);
            try g.field("align", t.alignment);
        }
        if (t.nested) try g.field("nested", true);
        try g.annotations(t.annotations);
        try g.spell("typeName", .{t});
        switch (t.kind) {
            .@"struct", .@"union" => |st| {
                if (st.base) |b| try g.field("base", b);
                try g.j.objectField("fields");
                try g.j.beginArray();
                for (st.fields) |*f| {
                    try g.j.beginObject();
                    try g.field("name", f.name);
                    try g.j.objectField("type");
                    try g.ref(f.type);
                    if (f.offset != Schema.Type.auto) try g.field("offset", f.offset);
                    if (g.s.memory(f.type)) |m| {
                        try g.field("size", m.size);
                        try g.field("align", m.alignment);
                    }
                    try g.place(f.at);
                    try g.annotations(f.annotations);
                    try g.spell("field", .{ t, f });
                    try g.j.endObject();
                }
                try g.j.endArray();
                if (st.methods.len > 0) {
                    try g.j.objectField("methods");
                    try g.j.beginArray();
                    for (st.methods) |*m| try g.method(m, .{ .type = t });
                    try g.j.endArray();
                }
                if (st.statics.len > 0) {
                    try g.j.objectField("statics");
                    try g.j.beginArray();
                    for (st.statics) |*v| try g.static(v, t);
                    try g.j.endArray();
                }
            },
            .@"enum" => |e| {
                try g.field("backing", @tagName(e.backing));
                try g.j.objectField("values");
                try g.j.beginArray();
                for (e.values) |v| {
                    try g.j.beginObject();
                    try g.field("name", v.name);
                    try g.j.objectField("value");
                    try g.int(v.value);
                    try g.place(v.at);
                    try g.spell("member", .{ t, v.name });
                    try g.j.endObject();
                }
                try g.j.endArray();
            },
            .bitfield => |bf| {
                try g.field("backing", @tagName(bf.backing));
                try g.j.objectField("members");
                try g.j.beginArray();
                for (bf.members) |m| {
                    try g.j.beginObject();
                    try g.field("name", m.name);
                    try g.field("bit", m.bit);
                    try g.field("bits", m.bits);
                    try g.field("type", @tagName(m.type));
                    if (m.type == .@"enum") try g.field("enum", m.type.@"enum");
                    try g.place(m.at);
                    try g.spell("member", .{ t, m.name });
                    try g.j.endObject();
                }
                try g.j.endArray();
            },
            .@"error" => |es| {
                try g.j.objectField("errors");
                try g.j.beginArray();
                for (es.errors) |e| {
                    try g.j.beginObject();
                    try g.field("name", e.name);
                    try g.field("code", e.code);
                    try g.place(e.at);
                    try g.spell("member", .{ t, e.name });
                    try g.j.endObject();
                }
                try g.j.endArray();
            },
            .@"opaque" => {},
            .func => |sig| try g.signature(sig),
        }
        try g.j.endObject();
    }

    fn trait(g: *Gen, t: *const Schema.Trait) Error!void {
        try g.j.beginObject();
        try g.names(t.name);
        try g.place(t.at);
        try g.hash("hash", g.s.traitHash(t));
        if (t.root) try g.field("root", true);
        if (t.bases.len > 0) try g.field("bases", t.bases);
        try g.annotations(t.annotations);
        try g.spell("traitName", .{t});
        try g.j.objectField("methods");
        try g.j.beginArray();
        for (t.methods) |*m| try g.method(m, .{ .trait = t });
        try g.j.endArray();
        try g.j.endObject();
    }

    /// What has a method: a trait, a struct's existing code, or the top's.
    const Owner = union(enum) {
        trait: *const Schema.Trait,
        type: *const Schema.Type,
        top,
    };

    fn method(g: *Gen, m: *const Schema.Method, owner: Owner) Error!void {
        const in: ?*const Schema.Trait = if (owner == .trait) owner.trait else null;
        try g.j.beginObject();
        try g.field("name", m.name);
        try g.place(m.at);
        if (m.static) try g.field("static", true);
        if (m.async) try g.field("async", true);
        if (m.virtual) |v| try g.field("virtual", v);
        if (in) |t| if (t.root and g.s.isAccessor(m)) try g.field("accessor", true);
        try g.hash("hash", Schema.methodHash(m));
        try g.annotations(m.annotations);
        switch (owner) {
            .trait => |t| try g.spell("method", .{ t, m }),
            .type => |t| try g.spell("function", .{ @as(?*const Schema.Type, t), m }),
            .top => try g.spell("function", .{ @as(?*const Schema.Type, null), m }),
        }
        try g.signature(m.signature);
        try g.j.endObject();
    }

    fn constant(g: *Gen, c: *const Schema.Constant) Error!void {
        try g.j.beginObject();
        try g.names(c.name);
        try g.place(c.at);
        try g.j.objectField("type");
        try g.ref(c.type);
        try g.j.objectField("value");
        switch (c.value) {
            .int => |v| try g.int(v),
            inline .float, .bool, .string => |v| try g.j.write(v),
        }
        try g.annotations(c.annotations);
        try g.spell("constant", .{c});
        try g.j.endObject();
    }

    /// A global, a struct's when `in` is set.
    fn static(g: *Gen, v: *const Schema.Static, in: ?*const Schema.Type) Error!void {
        try g.j.beginObject();
        try g.names(v.name);
        try g.place(v.at);
        try g.j.objectField("type");
        try g.ref(v.type);
        try g.annotations(v.annotations);
        try g.spell("static", .{ in, v });
        try g.j.endObject();
    }

    fn impl(g: *Gen, i: *const Schema.Impl) Error!void {
        try g.j.beginObject();
        try g.field("trait", i.trait);
        try g.field("for", i.@"for");
        if (i.conv) |c| try g.field("conv", @tagName(c));
        try g.place(i.at);
        try g.annotations(i.annotations);
        try g.j.objectField("items");
        try g.j.beginArray();
        for (i.items) |item| {
            try g.j.beginObject();
            try g.field("method", item.method);
            switch (item.source) {
                .virtual => |n| try g.field("virtual", n),
                .field => |f| try g.field("field", f),
                .alias => |a| try g.field("alias", a),
                .external => try g.field("external", true),
            }
            if (item.conv) |c| try g.field("conv", @tagName(c));
            try g.place(item.at);
            try g.annotations(item.annotations);
            try g.j.endObject();
        }
        try g.j.endArray();
        try g.j.endObject();
    }

    // Parts

    /// `params`, `returns`, and `error` when it can fail.
    fn signature(g: *Gen, sig: Schema.Signature) Error!void {
        if (sig.conv != .c) try g.field("conv", @tagName(sig.conv));
        try g.j.objectField("params");
        try g.j.beginArray();
        for (sig.params) |p| {
            try g.j.beginObject();
            try g.field("name", p.name);
            try g.j.objectField("type");
            try g.ref(if (p.inoutType()) |t| t else p.type);
            if (p.keep) try g.field("keep", true);
            if (p.inout) try g.field("inout", true);
            if (p.nullable()) try g.field("nullable", true);
            try g.j.endObject();
        }
        try g.j.endArray();
        try g.j.objectField("returns");
        try g.ref(sig.ret);
        if (sig.ret == .result) try g.field("error", sig.ret.result.err);
    }

    /// `{ "sal": text, <tag>: what it's made of }`. Named ones say what they name in `of`.
    fn ref(g: *Gen, r: Ref) Error!void {
        try g.j.beginObject();
        try g.field("sal", try std.fmt.allocPrint(g.a, "{f}", .{r}));
        switch (r) {
            .prim => |p| try g.field("prim", @tagName(p)),
            .named => |n| {
                try g.field("named", n);
                if (g.s.findType(n)) |t| {
                    try g.field("of", @tagName(t.kind));
                } else if (g.s.findTrait(n) != null) try g.field("of", "trait");
            },
            .pointer, .slice, .optional => |c| {
                try g.j.objectField(@tagName(r));
                try g.ref(c.*);
            },
            .array => |a| {
                try g.j.objectField("array");
                try g.ref(a.child.*);
                if (a.count) |n| try g.field("count", n) else try g.field("len", a.len);
            },
            .result => |res| {
                try g.j.objectField("result");
                try g.ref(res.ok.*);
                try g.field("error", res.err);
            },
            .func => |sig| {
                try g.j.objectField("fn");
                try g.j.beginObject();
                try g.signature(sig.*);
                try g.j.endObject();
            },
        }
        try g.j.endObject();
    }

    fn annotations(g: *Gen, list: []const Schema.Annotation) Error!void {
        if (list.len == 0) return;
        try g.j.objectField("annotations");
        try g.j.beginArray();
        for (list) |an| {
            try g.j.beginObject();
            try g.field("namespace", an.namespace);
            try g.field("name", an.name);
            try g.args(an.args);
            try g.j.endObject();
        }
        try g.j.endArray();
    }

    /// Numbers and strings as themselves, names as `{ "ident" }` and calls as `{ "call", "args" }`.
    fn args(g: *Gen, list: []const Schema.Arg) Error!void {
        try g.j.objectField("args");
        try g.j.beginArray();
        for (list) |arg| switch (arg) {
            .int => |v| try g.int(v),
            .float => |v| try g.j.write(v),
            .string => |v| try g.j.write(v),
            .ident => |v| {
                try g.j.beginObject();
                try g.field("ident", v);
                try g.j.endObject();
            },
            .call => |c| {
                try g.j.beginObject();
                try g.field("call", c.name);
                try g.args(c.args);
                try g.j.endObject();
            },
        };
        try g.j.endArray();
    }

    /// A number when JavaScript keeps it exact, otherwise its digits as a string.
    fn int(g: *Gen, v: i128) Error!void {
        const safe = (1 << 53) - 1;
        if (v >= -safe and v <= safe) return g.j.write(@as(i64, @intCast(v)));
        try g.j.write(try std.fmt.allocPrint(g.a, "{d}", .{v}));
    }

    fn hash(g: *Gen, key: []const u8, h: u64) Error!void {
        try g.field(key, try std.fmt.allocPrint(g.a, "0x{x:0>16}", .{h}));
    }
};

test "types, docs and layouts" {
    const source =
        \\// What the test has.
        \\
        \\namespace T;
        \\
        \\error E { Bad = 1 }
        \\
        \\// A point.
        \\struct P {
        \\    // Across
        \\    f32 x;
        \\    u64 big;
        \\}
        \\
        \\enum Big : u64 { small = 1, huge = 18446744073709551615 }
        \\
        \\// Greets.
        \\trait G {
        \\    // Says hi
        \\    async string!E hi(P* p, []u32 xs);
        \\}
    ;
    var parsed = try salamander_schema.parse(std.testing.allocator, source, .{}, null);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, parsed.schema, &out.writer, .{ .label = "t.sal", .source = source });

    const v = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer v.deinit();
    const o = v.value.object;
    try std.testing.expectEqualStrings("What the test has.", o.get("files").?.array.items[0].object.get("doc").?.string);

    var p: ?std.json.ObjectMap = null;
    var big: ?std.json.ObjectMap = null;
    for (o.get("types").?.array.items) |t| {
        if (std.mem.eql(u8, t.object.get("name").?.string, "T.P")) p = t.object;
        if (std.mem.eql(u8, t.object.get("name").?.string, "T.Big")) big = t.object;
    }
    try std.testing.expectEqualStrings("T", p.?.get("namespace").?.string);
    try std.testing.expectEqualStrings("A point.", p.?.get("doc").?.string);
    try std.testing.expectEqual(16, p.?.get("size").?.integer);
    const big_field = p.?.get("fields").?.array.items[1].object;
    try std.testing.expectEqual(8, big_field.get("offset").?.integer);
    try std.testing.expectEqualStrings("Across", p.?.get("fields").?.array.items[0].object.get("doc").?.string);
    try std.testing.expectEqualStrings("18446744073709551615", big.?.get("values").?.array.items[1].object.get("value").?.string);

    const hi = o.get("traits").?.array.items[0].object.get("methods").?.array.items[0].object;
    try std.testing.expectEqualStrings("Says hi", hi.get("doc").?.string);
    try std.testing.expect(hi.get("async").?.bool);
    try std.testing.expectEqualStrings("T.E", hi.get("error").?.string);
    try std.testing.expectEqual(19, hi.get("line").?.integer);
    const param = hi.get("params").?.array.items[0].object.get("type").?.object;
    try std.testing.expectEqualStrings("T.P", param.get("pointer").?.object.get("named").?.string);
    try std.testing.expectEqualStrings("struct", param.get("pointer").?.object.get("of").?.string);
}

test "each language's names, from its Names" {
    const source =
        \\namespace T;
        \\
        \\trait G {
        \\    u32 count(string who);
        \\}
    ;
    var parsed = try salamander_schema.parse(std.testing.allocator, source, .{}, null);
    defer parsed.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ts: types.ts.Names = .init(arena.allocator(), parsed.schema);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, parsed.schema, &out.writer, .{ .source = source, .langs = &.{.of(types.ts.Names, "ts", "TypeScript", &ts)} });

    const v = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer v.deinit();
    const trait = v.value.object.get("traits").?.array.items[0].object;
    try std.testing.expectEqualStrings("T.G", trait.get("langs").?.object.get("ts").?.object.get("path").?.string);
    const count = trait.get("methods").?.array.items[0].object.get("langs").?.object.get("ts").?.object;
    try std.testing.expectEqualStrings("count", count.get("name").?.string);
    try std.testing.expectEqualStrings("count(who: string): number", count.get("text").?.string);
    try std.testing.expectEqualStrings("string", count.get("params").?.array.items[0].object.get("type").?.string);
}
