//! TypeScript typings. `globals` declares what schemas give scripts, with each namespace at the top a
//! global, and `builtins` declares `salamander`.

const std = @import("std");
const Schema = @import("salamander_schema").Schema;

const types = @import("root.zig");

const Writer = std.Io.Writer;
const Error = Writer.Error;
const Ref = Schema.Ref;
const Entry = types.Entry;

const header = "// Made from .sal files by Salamander. Don't change it, since it's made again.\n\n";

/// Where a type's used, which changes what scripts see.
const Use = enum {
    /// Given to scripts, like a return.
    out,
    /// Taken from scripts, like a parameter.
    in,
    /// Live in memory, like a view's field.
    view,
    /// A plain struct's field, which goes both ways.
    field,
};

/// Everything in `s` as global declarations, or as what `module` exports, like `import { Wraith } from "wraith"`.
/// Each top namespace is also a value while scripts run. `singletons` are whole trait names the host gives one of, like `Freecam.Camera`.
pub fn globals(w: *Writer, s: Schema, source: []const u8, singletons: []const []const u8, module: ?[]const u8) Error!void {
    types.singletons = singletons;
    defer types.singletons = &.{};
    // An ambient module's already declared, so what's in it isn't again
    declare_word = if (module == null) "declare " else "";
    defer declare_word = "declare ";
    const live: types.Live = .init(s);
    try w.writeAll(header);
    if (module) |m| try w.print("declare module \"{s}\" {{\n", .{m});
    defer if (module != null) w.writeAll("}\n") catch {};
    var all: types.Entries = .{ .s = s };
    while (all.next()) |e| if (e.parent.len == 0 and e.isType()) try declareType(w, s, source, &live, e, 0);
    var namespaces: types.Children = .init(s, "", .type);
    while (namespaces.next()) |ns| try typeNamespace(w, s, source, &live, ns, 0);

    all = .{ .s = s };
    while (all.next()) |e| if (e.parent.len == 0 and e.isValue(s)) switch (e.what) {
        .function, .accessor => |m| {
            try methodDoc(w, s, source, m.*, "");
            try w.print("{s}function {s}", .{ declare_word, e.leaf });
            try signature(w, s, m.signature, m.async);
            try w.writeAll(";\n");
        },
        .singleton => |t| try singleton(w, t, "", if (module == null) "declare function " else "function "),
        .type, .trait => {
            try w.print("{s}const {s}: ", .{ declare_word, e.leaf });
            try object(w, s, source, e.leaf, 0);
            try w.writeAll(";\n");
        },
        .static => {},
    };
    var values: types.Children = .init(s, "", .value);
    while (values.next()) |ns| if (types.holder(s, ns) == null) {
        try w.print("{s}const {s}: ", .{ declare_word, ns });
        try object(w, s, source, ns, 0);
        try w.writeAll(";\n");
    };
}

/// What goes before what's at the top, "" in a module.
var declare_word: []const u8 = "declare ";

const spaces: [64]u8 = @splat(' ');

fn indentOf(depth: usize) []const u8 {
    return spaces[0..@min(depth * 2, spaces.len)];
}

/// `namespace` with the types in `path`, and the namespaces in it.
fn typeNamespace(w: *Writer, s: Schema, source: []const u8, live: *const types.Live, path: []const u8, depth: usize) Error!void {
    const indent = indentOf(depth);
    try w.print("{s}{s}namespace ", .{ indent, if (depth == 0) declare_word else "" });
    try Schema.writeFlatName(w, types.leafOf(path));
    try w.writeAll(" {\n");
    var all: types.Entries = .{ .s = s };
    while (all.next()) |e| if (e.isType() and std.mem.eql(u8, e.parent, path)) try declareType(w, s, source, live, e, depth + 1);
    var inner: types.Children = .init(s, path, .type);
    while (inner.next()) |ns| try typeNamespace(w, s, source, live, ns, depth + 1);
    try w.print("{s}}}\n", .{indent});
}

/// The value at `path` while scripts run, as an object type: what a struct's class, enum or trait has itself, then its namespace's.
fn object(w: *Writer, s: Schema, source: []const u8, path: []const u8, depth: usize) Error!void {
    const indent = indentOf(depth + 1);
    try w.writeAll("{\n");
    if (types.holder(s, path)) |h| switch (h.what) {
        .type => |t| switch (t.kind) {
            .@"struct" => |st| try classMembers(w, s, source, t, st, indent),
            .@"enum" => |en| for (en.values) |v| {
                try doc(w, source, v.at, indent);
                try w.print("{s}readonly ", .{indent});
                try propertyName(w, v.name);
                try w.writeAll(": number;\n");
            },
            else => {},
        },
        .trait => {
            try w.print("{s}/** The one scripts are given. */\n{s}instance(): ", .{ indent, indent });
            try types.writeTypeName(w, path);
            try w.writeAll(";\n");
        },
        else => {},
    };
    var all: types.Entries = .{ .s = s };
    while (all.next()) |e| if (e.isValue(s) and std.mem.eql(u8, e.parent, path)) switch (e.what) {
        .function, .accessor => |m| {
            try methodDoc(w, s, source, m.*, indent);
            try w.writeAll(indent);
            try methodText(w, s, e.leaf, m);
            try w.writeAll(";\n");
        },
        .static => |v| {
            try doc(w, source, v.at, indent);
            try w.writeAll(indent);
            try staticText(w, s, e.leaf, v);
            try w.writeAll(";\n");
        },
        .singleton => |t| try singleton(w, t, indent, ""),
        .type => |t| try objectProperty(w, s, source, e.leaf, t.name, depth + 1),
        .trait => |t| try objectProperty(w, s, source, e.leaf, t.name, depth + 1),
    };

    var inner: types.Children = .init(s, path, .value);
    while (inner.next()) |ns| if (types.holder(s, ns) == null) try objectProperty(w, s, source, types.leafOf(ns), ns, depth + 1);
    // A struct's class has its own already
    const has_class_addresses = if (types.holder(s, path)) |h| h.what == .type and h.what.type.kind == .@"struct" and
        h.what.type.kind.@"struct".methods.len + h.what.type.kind.@"struct".statics.len > 0 else false;
    if (!has_class_addresses) {
        var started = false;
        all = .{ .s = s };
        while (all.next()) |e| if (e.isValue(s) and std.mem.eql(u8, e.parent, path) and (e.what == .function or e.what == .static)) {
            if (!started) try w.print("{s}/** Where each is, found by name the first time it's asked for. */\n{s}addresses: {{\n", .{ indent, indent });
            started = true;
            try addressLine(w, e.leaf, indent);
        };
        if (started) try w.print("{s}}};\n", .{indent});
    }
    try w.print("{s}}}", .{indentOf(depth)});
}

/// The function giving a singleton of `t`, like `camera(): Freecam.Camera;`.
fn singleton(w: *Writer, t: *const Schema.Trait, indent: []const u8, prefix: []const u8) Error!void {
    var buf: [128]u8 = undefined;
    try w.print("{s}/** The one scripts are given. */\n{s}{s}", .{ indent, indent, prefix });
    try propertyName(w, types.singletonName(&buf, t.name));
    try w.writeAll("(): ");
    try types.writeTypeName(w, t.name);
    try w.writeAll(";\n");
}

fn objectProperty(w: *Writer, s: Schema, source: []const u8, name: []const u8, path: []const u8, depth: usize) Error!void {
    try w.writeAll(indentOf(depth));
    try propertyName(w, name);
    try w.writeAll(": ");
    try object(w, s, source, path, depth);
    try w.writeAll(";\n");
}

/// A struct's class: `at`, its methods taking the view first unless static, and its statics.
fn classMembers(w: *Writer, s: Schema, source: []const u8, t: *const Schema.Type, st: Schema.Struct, indent: []const u8) Error!void {
    if (s.findFunction(nameDot(t.name, "at")) == null) {
        try w.print("{s}/** A live view of one at `address`. Null at 0. */\n{s}at(address: number | bigint): ", .{ indent, indent });
        try types.writeTypeName(w, t.name);
        try w.writeAll(" | null;\n");
    }
    for (st.methods) |*m| {
        try methodDoc(w, s, source, m.*, indent);
        try w.writeAll(indent);
        try propertyName(w, m.name);
        try w.writeByte('(');
        if (!m.static) {
            try w.writeAll("self: ");
            try types.writeTypeName(w, t.name);
            if (m.signature.params.len > 0) try w.writeAll(", ");
        }
        try params(w, s, m.signature, .in);
        try w.writeAll("): ");
        try returns(w, s, m.signature.ret, m.async);
        try w.writeAll(";\n");
    }
    for (st.statics) |*v| {
        try doc(w, source, v.at, indent);
        try w.writeAll(indent);
        try staticText(w, s, v.name, v);
        try w.writeAll(";\n");
    }
    if (st.methods.len + st.statics.len == 0) return;
    try w.print("{s}/** Where each is, found by name the first time it's asked for. */\n{s}addresses: {{\n", .{ indent, indent });
    for (st.methods) |m| if (m.virtual == null) try addressLine(w, m.name, indent);
    for (st.statics) |v| try addressLine(w, v.name, indent);
    try w.print("{s}}};\n", .{indent});
}

fn addressLine(w: *Writer, name: []const u8, indent: []const u8) Error!void {
    try w.print("{s}  ", .{indent});
    try propertyName(w, name);
    try w.writeAll("(): number;\n");
}

/// `salamander`, as the module and a global.
pub fn builtins(w: *Writer) Error!void {
    try w.writeAll(header ++
        \\declare module "salamander" {
        \\  /** `f`, typed by `signature` like `"fn i32 (i32 a)"`, a declared name like `"Player.heal"` or a declared function itself, so native code taking an object gets it as that function type. */
        \\  export function fn<F extends (...args: any[]) => any>(signature: string | F, f: F): F;
        \\  /** The native function at `address`, callable, typed like a declared function given for `signature`. */
        \\  export function native<F extends (...args: any[]) => any>(signature: F, address: number | bigint): F;
        \\  /** The native function at `address`, callable, typed by `signature` like `fn` takes. */
        \\  export function native(signature: string, address: number | bigint): (...args: any[]) => any;
        \\  /** The full name of a declared function, like `"Kai.Player.heal"`, or undefined for anything else. */
        \\  export function nameOf(f: unknown): string | undefined;
        \\  /** A function's parameter names, as written. One that isn't a plain name, like `{ a }`, is `""`. */
        \\  export function params(f: (...args: any[]) => any): string[];
        \\  /** A live view of `type`, like `"Player"` or `"u32[4]"`, at `address`. Null at 0. */
        \\  export function at(type: string, address: number | bigint): any;
        \\  /** Where a view is. */
        \\  export function addressOf(view: object): number;
        \\  /** A view's type, like `"Player"` or `"u32[4]"`. */
        \\  export function typeOf(view: object): string;
        \\  /** How many bytes a type or a view takes. */
        \\  export function sizeOf(typeOrView: string | object): number;
        \\  /** A plain copy of a view, to change and `save`. */
        \\  export function snapshot<T extends object>(view: T): T;
        \\  /** Writes back what changed in a snapshot, giving how many parts did. */
        \\  export function save(copy: object): number;
        \\  /** Snapshots `view`, calls `f` with the copy, then saves it, once `f`'s promise resolves if it gives one. Nothing's saved if it throws. */
        \\  export function edit<T extends object>(view: T, f: (copy: T) => void | Promise<void>): void;
        \\  /** A `.sal` written while running, in place of what was loaded as `name` before. Gives what it declares, like the globals have. */
        \\  export function load(name: string, text: string): any;
        \\  /** What a struct can be given as: any of its fields, and the same for the structs in them. */
        \\  export type Given<T> = T extends (...args: any[]) => any ? T : T extends Uint8Array ? T : T extends ReadonlyArray<infer E> ? Array<Given<E>> : T extends object ? { [K in keyof T]?: Given<T[K]> } : T;
        \\}
        \\
        \\declare const salamander: typeof import("salamander");
        \\declare function require(name: string): any;
        \\
    );
}

// Declarations

/// A type by its name in its namespace. Structs in memory have live view fields, other values' fields go both ways.
fn declareType(w: *Writer, s: Schema, source: []const u8, live: *const types.Live, e: Entry, depth: usize) Error!void {
    const indent = indentOf(depth);
    const inner = indentOf(depth + 1);
    const t = switch (e.what) {
        .trait => |t| return trait(w, s, source, t, e.leaf, depth),
        .type => |t| t,
        else => return,
    };
    switch (t.kind) {
        .@"struct", .@"union" => |st| {
            const is_live = live.has(s, t);
            try doc(w, source, t.at, indent);
            try w.print("{s}interface ", .{indent});
            try Schema.writeFlatName(w, e.leaf);
            if (st.base) |b| {
                try w.writeAll(" extends ");
                try types.writeTypeName(w, b);
            }
            try w.writeAll(" {\n");
            const optional = t.kind == .@"union" and !is_live;
            for (st.fields) |f| {
                try doc(w, source, f.at, inner);
                try w.writeAll(inner);
                try fieldText(w, s, f, optional, is_live);
                try w.writeAll(";\n");
            }
            for (st.methods) |m| if (!m.static) try method(w, s, source, m, inner);
            try w.print("{s}}}\n", .{indent});
        },
        .@"enum" => |en| {
            try doc(w, source, t.at, indent);
            try w.print("{s}type ", .{indent});
            try Schema.writeFlatName(w, e.leaf);
            try w.writeAll(" = number;\n");
            try w.print("{s}/** What `{s}` can also be given as. */\n{s}type ", .{ indent, e.leaf, indent });
            try Schema.writeFlatName(w, e.leaf);
            try w.writeAll("Name =");
            if (en.values.len == 0) try w.writeAll(" never");
            for (en.values, 0..) |v, i| try w.print("{s} \"{s}\"", .{ if (i == 0) "" else " |", v.name });
            try w.writeAll(";\n");
        },
        .bitfield => |bf| {
            try doc(w, source, t.at, indent);
            try w.print("{s}interface ", .{indent});
            try Schema.writeFlatName(w, e.leaf);
            try w.writeAll(" {\n");
            for (bf.members) |m| {
                try doc(w, source, m.at, inner);
                try w.print("{s}{s}: {s};\n", .{ inner, m.name, if (m.type == .bool) "boolean" else "number" });
            }
            try w.print("{s}}}\n", .{indent});
        },
        .@"error" => |es| {
            try doc(w, source, t.at, indent);
            try w.print("{s}/** What it can throw, by name. */\n{s}type ", .{ indent, indent });
            try Schema.writeFlatName(w, e.leaf);
            try w.writeAll(" =");
            for (es.errors, 0..) |x, i| try w.print("{s} \"{s}\"", .{ if (i == 0) "" else " |", x.name });
            for (Schema.builtin_errors) |x| try w.print(" | \"{s}\"", .{x});
            try w.writeAll(";\n");
        },
        .@"opaque" => {},
        .func => |sig| {
            try doc(w, source, t.at, indent);
            try w.print("{s}type ", .{indent});
            try Schema.writeFlatName(w, e.leaf);
            try w.writeAll(" = ");
            try funcType(w, s, sig);
            try w.writeAll(";\n");
        },
    }
}

fn bitsNumber(bf: Schema.Bitfield) []const u8 {
    return if (bf.backing == .u64 or bf.backing == .i64) "bigint" else "number";
}

/// An interface scripts can implement too.
fn trait(w: *Writer, s: Schema, source: []const u8, t: *const Schema.Trait, leaf: []const u8, depth: usize) Error!void {
    const indent = indentOf(depth);
    try doc(w, source, t.at, indent);
    try w.print("{s}interface ", .{indent});
    try Schema.writeFlatName(w, leaf);
    for (t.bases, 0..) |b, i| {
        try w.writeAll(if (i == 0) " extends " else ", ");
        try types.writeTypeName(w, b);
    }
    try w.writeAll(" {\n");
    for (t.methods) |m| try method(w, s, source, m, indentOf(depth + 1));
    try w.print("{s}}}\n", .{indent});
}

fn method(w: *Writer, s: Schema, source: []const u8, m: Schema.Method, indent: []const u8) Error!void {
    try methodDoc(w, s, source, m, indent);
    try w.writeAll(indent);
    try methodText(w, s, m.name, &m);
    try w.writeAll(";\n");
}

// How each is declared, which `Names` gives docs too

/// `name(a: T): R`, a method as an object has it.
fn methodText(w: *Writer, s: Schema, name: []const u8, m: *const Schema.Method) Error!void {
    try propertyName(w, name);
    try signature(w, s, m.signature, m.async);
}

/// `name: T`, a static as a live view.
fn staticText(w: *Writer, s: Schema, name: []const u8, v: *const Schema.Static) Error!void {
    try propertyName(w, name);
    try w.writeAll(": ");
    try typeRef(w, s, v.type, .view);
}

/// `name?: T`, a live view's field or a plain one's, optional in a plain union.
fn fieldText(w: *Writer, s: Schema, f: Schema.Field, optional: bool, live: bool) Error!void {
    try w.print("{s}{s}: ", .{ f.name, if (optional) "?" else "" });
    try typeRef(w, s, f.type, if (live) .view else .field);
}

/// `Name.member`, for looking things up. Long names just don't find anything.
fn nameDot(name: []const u8, member_name: []const u8) []const u8 {
    const S = struct {
        threadlocal var buf: [256]u8 = undefined;
    };
    return std.fmt.bufPrint(&S.buf, "{s}.{s}", .{ name, member_name }) catch "";
}

/// A property's name, quoted if it isn't one on its own.
fn propertyName(w: *Writer, n: []const u8) Error!void {
    const plain = n.len > 0 and !std.ascii.isDigit(n[0]) and for (n) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '$') break false;
    } else true;
    if (plain) try w.writeAll(n) else try w.print("\"{s}\"", .{n});
}

// Signatures

fn signature(w: *Writer, s: Schema, sig: Schema.Signature, async: bool) Error!void {
    try w.writeByte('(');
    try params(w, s, sig, .in);
    try w.writeAll("): ");
    try returns(w, s, sig.ret, async);
}

/// `use` is `.in` for a method's, which scripts pass, and `.out` for a fn value's, which they get.
fn params(w: *Writer, s: Schema, sig: Schema.Signature, use: Use) Error!void {
    for (sig.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try paramName(w, p.name);
        try w.writeAll(": ");
        try paramType(w, s, p, use);
    }
}

fn paramType(w: *Writer, s: Schema, p: Schema.Param, use: Use) Error!void {
    if (p.inoutType()) |inner| {
        // Objects are written back, other values go in a box
        if (types.isRecord(s, inner)) try typeRef(w, s, inner, use) else {
            try w.writeAll("{ value: ");
            try typeRef(w, s, inner, use);
            try w.writeAll(" }");
        }
        if (p.nullable()) try w.writeAll(" | null");
    } else try typeRef(w, s, p.type, use);
}

fn returns(w: *Writer, s: Schema, ret: Ref, async: bool) Error!void {
    if (async) try w.writeAll("Promise<");
    try typeRef(w, s, ret, .out);
    if (async) try w.writeByte('>');
}

fn funcType(w: *Writer, s: Schema, sig: Schema.Signature) Error!void {
    try w.writeByte('(');
    try params(w, s, sig, .out);
    try w.writeAll(") => ");
    // Scripts write fn values, so what one gives back is taken from them, like a reply's fields
    try typeRef(w, s, sig.ret, .in);
}

fn methodDoc(w: *Writer, s: Schema, source: []const u8, m: Schema.Method, indent: []const u8) Error!void {
    var lines = types.docLines(source, m.at);
    const err = errorOf(m.signature.ret);
    if (lines.empty() and err == null) return;
    try w.print("{s}/**\n", .{indent});
    while (lines.next()) |l| try docLine(w, indent, l);
    if (err) |e| {
        _ = s;
        try w.print("{s} * @throws `{s}`\n", .{ indent, e });
    }
    try w.print("{s} */\n", .{indent});
}

fn errorOf(r: Ref) ?[]const u8 {
    return switch (r) {
        .result => |res| res.err,
        else => null,
    };
}

// Types

fn typeRef(w: *Writer, s: Schema, r: Ref, use: Use) Error!void {
    switch (r) {
        .prim => |p| try w.writeAll(switch (p) {
            .u8, .u16, .u32, .i8, .i16, .i32, .usize, .isize, .f32, .f64 => if (use == .in and (p == .usize or p == .isize)) "number | bigint" else "number",
            .u64, .i64 => if (use == .in) "number | bigint" else "bigint",
            .bool => "boolean",
            .utf8, .utf16, .string => "string",
            .cstring => "string | null",
            .object => "object | null",
            .void => "void",
            .blob => "Uint8Array | null",
        }),
        .named => |n| {
            if (s.findTrait(n) != null) {
                try types.writeTypeName(w, n);
                if (use == .in) try w.writeAll(" | null");
                return;
            }
            const t = s.findType(n) orelse return w.writeAll("unknown");
            switch (t.kind) {
                .@"enum" => {
                    try types.writeTypeName(w, n);
                    if (use == .in or use == .field) {
                        try w.writeAll(" | ");
                        try types.writeTypeName(w, n);
                        try w.writeAll("Name");
                    }
                },
                .bitfield => |bf| if (use == .view) try types.writeTypeName(w, n) else try w.writeAll(bitsNumber(bf)),
                .@"opaque" => try w.writeAll("number"),
                else => {
                    if (use == .in and (t.kind == .@"struct" or t.kind == .@"union")) {
                        try w.writeAll("import(\"salamander\").Given<");
                        try types.writeTypeName(w, n);
                        return w.writeByte('>');
                    }
                    try types.writeTypeName(w, n);
                },
            }
        },
        .pointer => |child| {
            if (types.isTextPointer(r)) return w.writeAll(if (use == .in) "number | bigint" else "string | null");
            if (types.isRecord(s, child.*)) {
                if (use == .in) try w.writeAll("number | bigint | ");
                try types.writeTypeName(w, child.named);
                return w.writeAll(" | null");
            }
            try w.writeAll(if (use == .in) "number | bigint" else "number");
        },
        .array => |a| {
            if (types.isTextArray(r)) return w.writeAll("string");
            try arrayOf(w, s, a.child.*, use);
        },
        .slice => |child| try arrayOf(w, s, child.*, use),
        .optional => |child| {
            try typeRef(w, s, child.*, use);
            try w.writeAll(" | null");
        },
        .result => |res| try typeRef(w, s, res.ok.*, use),
        .func => |sig| {
            try w.writeByte('(');
            try funcType(w, s, sig.*);
            try w.writeByte(')');
        },
    }
}

/// `Array<T>`, since `A | B[]` would only make the last one an array.
fn arrayOf(w: *Writer, s: Schema, child: Ref, use: Use) Error!void {
    try w.writeAll("Array<");
    try typeRef(w, s, child, use);
    try w.writeByte('>');
}

// Text

fn doc(w: *Writer, source: []const u8, at: usize, indent: []const u8) Error!void {
    var lines = types.docLines(source, at);
    if (lines.empty()) return;
    try w.print("{s}/**\n", .{indent});
    while (lines.next()) |l| try docLine(w, indent, l);
    try w.print("{s} */\n", .{indent});
}

fn docLine(w: *Writer, indent: []const u8, line: []const u8) Error!void {
    try w.print("{s} *", .{indent});
    if (line.len > 0) try w.writeByte(' ');
    // `*/` would end the comment
    var rest = line;
    while (std.mem.indexOf(u8, rest, "*/")) |i| {
        try w.writeAll(rest[0 .. i + 1]);
        try w.writeAll("\\/");
        rest = rest[i + 2 ..];
    }
    try w.writeAll(rest);
    try w.writeByte('\n');
}

const reserved = std.StaticStringMap(void).initComptime(.{
    .{"break"},    .{"case"},      .{"catch"},  .{"class"},      .{"const"},     .{"continue"},
    .{"debugger"}, .{"default"},   .{"delete"}, .{"do"},         .{"else"},      .{"enum"},
    .{"export"},   .{"extends"},   .{"false"},  .{"finally"},    .{"for"},       .{"function"},
    .{"if"},       .{"import"},    .{"in"},     .{"instanceof"}, .{"new"},       .{"null"},
    .{"return"},   .{"super"},     .{"switch"}, .{"this"},       .{"throw"},     .{"true"},
    .{"try"},      .{"typeof"},    .{"var"},    .{"void"},       .{"while"},     .{"with"},
    .{"yield"},    .{"let"},       .{"static"}, .{"implements"}, .{"interface"}, .{"package"},
    .{"private"},  .{"protected"}, .{"public"}, .{"await"},      .{"arguments"}, .{"eval"},
});

fn paramName(w: *Writer, name: []const u8) Error!void {
    try w.writeAll(name);
    if (reserved.has(name)) try w.writeByte('_');
}

// Names

const lang = @import("salamander_lang");
const NamesError = Writer.Error || error{OutOfMemory};

/// How scripts name and declare each thing, from the same pieces the typings are written with.
pub const Names = struct {
    a: std.mem.Allocator,
    s: Schema,
    live: types.Live,

    pub fn init(a: std.mem.Allocator, s: Schema) Names {
        return .{ .a = a, .s = s, .live = .init(s) };
    }

    /// What `f` writes, on its own.
    fn text(n: *const Names, comptime f: anytype, args: anytype) NamesError![]const u8 {
        var out: Writer.Allocating = .init(n.a);
        try @call(.auto, f, .{&out.writer} ++ args);
        return out.written();
    }

    fn named(n: *const Names, full: []const u8) NamesError!lang.Decl {
        return .{ .name = try n.text(Schema.writeFlatName, .{types.leafOf(full)}), .path = try n.text(types.writeTypeName, .{full}) };
    }

    /// A method's parameters and what it gives, as an object has it.
    fn method_(n: *const Names, name: []const u8, path: ?[]const u8, m: *const Schema.Method) NamesError!lang.Decl {
        const ps = try n.a.alloc(lang.Param, m.signature.params.len);
        for (m.signature.params, ps) |p, *q| {
            const pn = try n.text(paramName, .{p.name});
            const pt = try n.text(paramType, .{ n.s, p, Use.in });
            q.* = .{ .name = pn, .type = pt, .text = try std.fmt.allocPrint(n.a, "{s}: {s}", .{ pn, pt }) };
        }
        return .{
            .name = try n.text(propertyName, .{name}),
            .path = path,
            .params = ps,
            .type = try n.text(returns, .{ n.s, m.signature.ret, m.async }),
            .text = try n.text(methodText, .{ n.s, name, m }),
        };
    }

    pub fn typeName(n: *const Names, t: *const Schema.Type) NamesError!?lang.Decl {
        if (t.kind == .@"opaque") return null;
        return try n.named(t.name);
    }

    pub fn traitName(n: *const Names, t: *const Schema.Trait) NamesError!?lang.Decl {
        return try n.named(t.name);
    }

    pub fn method(n: *const Names, _: *const Schema.Trait, m: *const Schema.Method) NamesError!?lang.Decl {
        return try n.method_(m.name, null, m);
    }

    pub fn field(n: *const Names, t: *const Schema.Type, f: *const Schema.Field) NamesError!?lang.Decl {
        const is_live = n.live.has(n.s, t);
        const optional = t.kind == .@"union" and !is_live;
        return .{
            .name = f.name,
            .type = try n.text(typeRef, .{ n.s, f.type, if (is_live) Use.view else Use.field }),
            .text = try n.text(fieldText, .{ n.s, f.*, optional, is_live }),
        };
    }

    /// An enum's value on its object, an error's name, or a bitfield's member.
    pub fn member(n: *const Names, t: *const Schema.Type, name: []const u8) NamesError!?lang.Decl {
        if (t.kind == .@"error") return .{ .name = try std.fmt.allocPrint(n.a, "\"{s}\"", .{name}) };
        if (t.kind == .@"enum") return .{ .name = name, .path = try std.fmt.allocPrint(n.a, "{s}.{s}", .{ try n.text(types.writeTypeName, .{t.name}), name }) };
        return .{ .name = name };
    }

    /// A struct's method on a view, or a static one on its class, or one in its namespace.
    pub fn function(n: *const Names, in: ?*const Schema.Type, m: *const Schema.Method) NamesError!?lang.Decl {
        if (in != null) return try n.method_(m.name, null, m);
        return try n.method_(types.leafOf(m.name), try n.text(types.writeTypeName, .{m.name}), m);
    }

    pub fn static(n: *const Names, in: ?*const Schema.Type, v: *const Schema.Static) NamesError!?lang.Decl {
        const name = if (in != null) v.name else types.leafOf(v.name);
        return .{
            .name = name,
            .path = if (in != null) null else try n.text(types.writeTypeName, .{v.name}),
            .type = try n.text(typeRef, .{ n.s, v.type, Use.view }),
            .text = try n.text(staticText, .{ n.s, name, v }),
        };
    }
};

const testing = std.testing;

/// Fails showing `text` if a piece of `want` isn't in it.
fn expectPieces(text: []const u8, want: []const []const u8) !void {
    for (want) |piece| if (std.mem.indexOf(u8, text, piece) == null) {
        std.debug.print("missing:\n{s}\nin:\n{s}\n", .{ piece, text });
        return error.TestUnexpectedResult;
    };
}

fn generate(source: []const u8, options: @import("salamander_schema").Options, singletons: []const []const u8, out: *Writer.Allocating) !void {
    return generateIn(source, options, singletons, null, out);
}

fn generateIn(source: []const u8, options: @import("salamander_schema").Options, singletons: []const []const u8, module: ?[]const u8, out: *Writer.Allocating) !void {
    var parsed = try @import("salamander_schema").parse(testing.allocator, source, options, null);
    defer parsed.deinit();
    try globals(&out.writer, parsed.schema, source, singletons, module);
}

test "as a module, what's at the top is exported without declare" {
    const source =
        \\namespace Game {
        \\    struct Box { u32 n; }
        \\    [Root] trait App { u32 version(); }
        \\}
    ;
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try generateIn(source, .{}, &.{}, "game", &out);
    const text = out.written();
    try expectPieces(text, &.{ "declare module \"game\" {\n", "namespace Game {", "const Game: {" });
    try testing.expect(std.mem.indexOf(u8, text, "declare namespace") == null);
    try testing.expect(std.mem.indexOf(u8, text, "declare const") == null);
    try testing.expect(std.mem.endsWith(u8, text, "}\n"));
}

test "traits, plain types and docs, with a root at the top" {
    const source =
        \\error Shy { Early = 1 }
        \\enum Mode : u8 { off, on }
        \\// A greeting
        \\struct Greeting { u32 times; u8[8] name; u64 big; Mode mode; }
        \\fn void Tick(u32 n);
        \\trait Greeter {
        \\    // Says hi
        \\    Greeting!Shy greet(Mode mode, inout u32 count, Greeting in);
        \\    async u64 later(Tick tick);
        \\    ?u32 maybe();
        \\}
        \\[Root] trait App {
        \\    // The greeter
        \\    Greeter greeter();
        \\    u32 version();
        \\}
    ;
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try generate(source, .{}, &.{}, &out);
    const text = out.written();
    try expectPieces(text, &.{
        "type Shy = \"Early\" | \"Cancelled\" | \"Unsupported\" | \"Gone\";",
        "type Mode = number;",
        "type ModeName = \"off\" | \"on\";",
        "/**\n * A greeting\n */\ninterface Greeting {",
        "  name: string;",
        "  big: bigint;",
        "  mode: Mode | ModeName;",
        "  maybe(): number | null;",
        "type Tick = (n: number) => void;",
        "   * Says hi\n   * @throws `Shy`\n",
        "  greet(mode: Mode | ModeName, count: { value: number }, in_: import(\"salamander\").Given<Greeting>): Greeting;",
        "  later(tick: Tick): Promise<bigint>;",
        "/**\n * The greeter\n */\ndeclare function greeter(): Greeter;",
        "declare const Greeter: {\n  /** The one scripts are given. */\n  instance(): Greeter;\n};",
        "declare const App: {\n  /** The one scripts are given. */\n  instance(): App;\n};",
        "declare const Mode: {\n  readonly off: number;",
    });
    try testing.expect(std.mem.indexOf(u8, text, "declare module") == null);
    try testing.expect(std.mem.indexOf(u8, text, "function version") == null);
}

test "structs in memory have live classes" {
    const source =
        \\enum Mode : u8 { off, on }
        \\struct Base { u32 id; }
        \\struct Player : Base {
        \\    u32 health;
        \\    u8 flags { u8 speed : 3; bool paused; }
        \\    Mode mode;
        \\    Player* next;
        \\    [Virtual(2)] f32 heal(u32 amount);
        \\    [game.Sig("48")] static Player* create();
        \\    [game.Sig("48")] static Player* instance;
        \\}
        \\[game.Sig("48")] u32 spawn(Mode mode);
    ;
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try generate(source, .{ .any_namespace = true }, &.{}, &out);
    try expectPieces(out.written(), &.{
        "interface Player extends Base {\n  health: number;\n  flags: Player.flags;\n  mode: Mode;\n  next: Player | null;\n",
        "  heal(amount: number): number;",
        "declare namespace Player {\n  interface flags {\n    speed: number;\n    paused: boolean;",
        "declare const Player: {",
        "  at(address: number | bigint): Player | null;",
        "  heal(self: Player, amount: number): number;",
        "  create(): Player | null;",
        "  instance: Player | null;",
        "declare const Mode: {\n  readonly off: number;",
        "declare function spawn(mode: Mode | ModeName): number;",
    });
}

test "namespaces are globals, with a root's accessors and names in a trait's namespace" {
    const source =
        \\namespace World {
        \\    struct Counter { u32 n; Counter* next; [game.Sig("48")] static Counter* main; }
        \\    namespace Inner { enum Mode : u8 { off, on } }
        \\    [game.Sig("48")] u32 twice(u32 n);
        \\    [game.Sig("48")] static u32 ticks;
        \\}
        \\namespace Wraith {
        \\    trait Tweaks { void add(Definition d); Mode currentMode(); }
        \\    namespace Tweaks {
        \\        enum Mode : u8 { off, toggle }
        \\        struct Definition { u8[16] id; Mode mode; }
        \\    }
        \\    trait Vfs { void close(); }
        \\    [Root] trait Api { Tweaks tweaks(); u32 version(); }
        \\}
    ;
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try generate(source, .{ .any_namespace = true }, &.{}, &out);
    const text = out.written();
    try expectPieces(text, &.{
        "declare namespace World {\n  interface Counter {\n    n: number;\n    next: World.Counter | null;\n  }",
        "  namespace Inner {\n    type Mode = number;",
        "declare namespace Wraith {",
        "  interface Tweaks {\n    add(d: import(\"salamander\").Given<Wraith.Tweaks.Definition>): void;\n    currentMode(): Wraith.Tweaks.Mode;\n  }",
        "  interface Vfs {\n    close(): void;\n  }",
        "  namespace Tweaks {\n    type Mode = number;",
        "    interface Definition {\n      id: string;\n      mode: Wraith.Tweaks.Mode | Wraith.Tweaks.ModeName;\n    }",
        "declare const World: {\n  Counter: {\n    /** A live view of one at `address`. Null at 0. */\n    at(address: number | bigint): World.Counter | null;\n    main: World.Counter | null;\n    /** Where each is, found by name the first time it's asked for. */\n    addresses: {\n      main(): number;\n    };\n  };",
        "  twice(n: number): number;\n  ticks: number;\n  Inner: {\n    Mode: {\n      readonly off: number;",
        "declare const Wraith: {\n  Tweaks: {\n    /** The one scripts are given. */\n    instance(): Wraith.Tweaks;\n    Mode: {\n      readonly off: number;\n      readonly toggle: number;\n    };\n    Definition: {",
        "  Api: {\n    /** The one scripts are given. */\n    instance(): Wraith.Api;\n  };\n  tweaks(): Wraith.Tweaks;\n};",
    });
    try testing.expect(std.mem.indexOf(u8, text, "Vfs: {") == null);
}

test "singletons are functions on their namespace, with instance()" {
    const source =
        \\namespace Freecam { [wraith.Service] trait Camera { void move(f32 x); } }
        \\trait Pad { void rumble(); }
        \\trait Other { void no(); }
    ;
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try generate(source, .{ .any_namespace = true }, &.{ "Freecam.Camera", "Pad", "Missing" }, &out);
    const text = out.written();
    try expectPieces(text, &.{
        "declare const Freecam: {\n  Camera: {\n    /** The one scripts are given. */\n    instance(): Freecam.Camera;\n  };\n  /** The one scripts are given. */\n  camera(): Freecam.Camera;\n};",
        "/** The one scripts are given. */\ndeclare function pad(): Pad;",
        "declare const Pad: {\n  /** The one scripts are given. */\n  instance(): Pad;\n};",
    });
    try testing.expect(std.mem.indexOf(u8, text, "declare const Other") == null);
}

test "Names give what the typings declare" {
    const make = struct {
        fn make(a: std.mem.Allocator, s: Schema) anyerror!Names {
            return .init(a, s);
        }
    }.make;
    try lang.expectNames(Names, make, .{
        .method = "count(who: string): number",
        .field = "hp: number",
        .function = "heal(amount: number): boolean",
        .static = "instance: G.Player | null",
        .constant = null,
    });
}
