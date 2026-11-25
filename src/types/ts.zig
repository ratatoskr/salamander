//! TypeScript typings. `api` for a module of traits and plain types, `schema` for the live module,
//! `builtins` for `salamander`.

const std = @import("std");
const Schema = @import("salamander_schema").Schema;

const types = @import("root.zig");

const Writer = std.Io.Writer;
const Error = Writer.Error;
const Ref = Schema.Ref;

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

/// `api.module` declaring the schema's traits and types, and `api.root`'s exports.
pub fn api(w: *Writer, s: Schema, source: []const u8, options: types.Api) Error!void {
    try w.writeAll(header);
    try w.print("declare module \"{s}\" {{\n", .{options.module});
    for (s.types) |*t| try apiType(w, s, source, t);
    for (s.traits) |*t| try trait(w, s, source, t);
    const root = if (options.root) |r| s.findTrait(r) else null;
    if (root) |t| for (t.methods) |m| {
        try doc(w, source, m.at, "  ");
        try w.print("  export const {s}: ", .{m.name});
        try typeRef(w, s, m.signature.ret, .out);
        try w.writeAll(";\n");
    };
    try w.writeAll("}\n");
    if (options.globals) if (root) |t| {
        try w.writeByte('\n');
        for (t.methods) |m| {
            try doc(w, source, m.at, "");
            try w.print("declare const {s}: import(\"{s}\").", .{ m.name, options.module });
            try typeRef(w, s, m.signature.ret, .out);
            try w.writeAll(";\n");
        }
    };
}

/// The `schema` module. A live class per struct with its methods and statics, enum values, and the
/// schema's functions.
pub fn schema(w: *Writer, s: Schema, source: []const u8) Error!void {
    try w.writeAll(header);
    try w.writeAll("declare module \"schema\" {\n");
    for (s.types) |*t| switch (t.kind) {
        .@"struct", .@"union" => try viewClass(w, s, source, t),
        .@"enum" => |e| {
            try doc(w, source, t.at, "  ");
            try w.writeAll("  export const ");
            try types.writeTypeName(w, t.name);
            try w.writeAll(": {\n");
            for (e.values) |v| {
                try doc(w, source, v.at, "    ");
                try w.print("    readonly {s}: number;\n", .{v.name});
            }
            try w.writeAll("  };\n  export type ");
            try types.writeTypeName(w, t.name);
            try w.writeAll(" = number;\n");
            try enumNames(w, t.name, e);
        },
        .bitfield => |bf| try bitsView(w, s, source, t, bf),
        else => try apiType(w, s, source, t),
    };
    for (s.traits) |*t| try trait(w, s, source, t);
    for (s.functions) |*f| {
        try doc(w, source, f.at, "  ");
        try w.writeAll("  export function ");
        try types.writeTypeName(w, f.name);
        try signature(w, s, f.signature, f.async);
        try w.writeAll(";\n");
    }
    // What's in namespaces, by the names scripts use
    var namespaces: types.Namespaces = .init(s);
    while (namespaces.next()) |ns| {
        try w.print("  export namespace {s} {{\n", .{ns});
        var members: types.Members = .{ .s = s };
        while (members.next()) |m| if (std.mem.eql(u8, m.parent(), ns)) try member(w, s, source, m, "    ");
        try w.writeAll("  }\n");
    }
    // Statics are live, so they're only on the default export
    try w.writeAll("  const all: {\n");
    for (s.types) |t| if ((t.kind == .@"struct" or t.kind == .@"enum") and !t.nested and Schema.namespaceEnd(t.name) == null) {
        try propertyName(w, t.name);
        try w.writeAll(": typeof ");
        try types.writeTypeName(w, t.name);
        try w.writeAll(";\n");
    };
    for (s.functions) |f| if (Schema.namespaceEnd(f.name) == null) try w.print("    {s}: typeof {s};\n", .{ f.name, f.name });
    var roots: types.Namespaces = .init(s);
    while (roots.next()) |ns| if (std.mem.indexOfScalar(u8, ns, '.') == null) try w.print("    {s}: typeof {s};\n", .{ ns, ns });
    for (s.statics) |v| if (Schema.namespaceEnd(v.name) == null) {
        try doc(w, source, v.at, "    ");
        try w.print("    {s}: ", .{v.name});
        try typeRef(w, s, v.type, .view);
        try w.writeAll(";\n");
    };
    try w.writeAll("  };\n  export default all;\n}\n");
}

/// `salamander`, as the module and a global.
pub fn builtins(w: *Writer) Error!void {
    try w.writeAll(header ++
        \\declare module "salamander" {
        \\  /** `f`, typed by `signature` like `"fn i32 (i32 a)"` or a declared name like `"Player.heal"`, so native code taking an object gets it as that function type. */
        \\  export function fn<F extends (...args: any[]) => any>(signature: string, f: F): F;
        \\  /** The native function at `address`, callable, typed by `signature` like `fn` takes. */
        \\  export function native(signature: string, address: number | bigint): (...args: any[]) => any;
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
        \\  /** A `.sal` written while running, in place of what was loaded as `name` before. Gives what it declares, like the `schema` module. */
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

/// A type as a plain value, like a struct that's copied in and out.
fn apiType(w: *Writer, s: Schema, source: []const u8, t: *const Schema.Type) Error!void {
    switch (t.kind) {
        .@"struct", .@"union" => |st| {
            try doc(w, source, t.at, "  ");
            try w.writeAll("  export interface ");
            try types.writeTypeName(w, t.name);
            if (st.base) |b| {
                try w.writeAll(" extends ");
                try types.writeTypeName(w, b);
            }
            try w.writeAll(" {\n");
            const optional = t.kind == .@"union";
            for (st.fields) |f| {
                try doc(w, source, f.at, "    ");
                try w.print("    {s}{s}: ", .{ f.name, if (optional) "?" else "" });
                try typeRef(w, s, f.type, .field);
                try w.writeAll(";\n");
            }
            try w.writeAll("  }\n");
        },
        .@"enum" => |e| {
            try doc(w, source, t.at, "  ");
            try w.writeAll("  export type ");
            try types.writeTypeName(w, t.name);
            try w.writeAll(" = number;\n");
            try enumNames(w, t.name, e);
        },
        .bitfield => |bf| {
            try doc(w, source, t.at, "  ");
            try w.writeAll("  export type ");
            try types.writeTypeName(w, t.name);
            try w.print(" = {s};\n", .{if (bf.backing == .u64 or bf.backing == .i64) "bigint" else "number"});
        },
        .@"error" => |es| {
            try doc(w, source, t.at, "  ");
            try w.writeAll("  /** What it can throw, by name. */\n  export type ");
            try types.writeTypeName(w, t.name);
            try w.writeAll(" =");
            for (es.errors, 0..) |e, i| try w.print("{s} \"{s}\"", .{ if (i == 0) "" else " |", e.name });
            for (Schema.builtin_errors) |e| try w.print(" | \"{s}\"", .{e});
            try w.writeAll(";\n");
        },
        .@"opaque" => {},
        .func => |sig| {
            try doc(w, source, t.at, "  ");
            try w.writeAll("  export type ");
            try types.writeTypeName(w, t.name);
            try w.writeAll(" = ");
            try funcType(w, s, sig);
            try w.writeAll(";\n");
        },
    }
}

/// What an enum can also be given as.
fn enumNames(w: *Writer, name: []const u8, e: Schema.Enum) Error!void {
    try w.print("  /** What `{s}` can also be given as. */\n  export type ", .{name});
    try types.writeTypeName(w, name);
    try w.writeAll("Name =");
    if (e.values.len == 0) try w.writeAll(" never");
    for (e.values, 0..) |v, i| try w.print("{s} \"{s}\"", .{ if (i == 0) "" else " |", v.name });
    try w.writeAll(";\n");
}

fn trait(w: *Writer, s: Schema, source: []const u8, t: *const Schema.Trait) Error!void {
    try doc(w, source, t.at, "  ");
    try w.writeAll("  export interface ");
    try types.writeTypeName(w, t.name);
    for (t.bases, 0..) |b, i| {
        try w.writeAll(if (i == 0) " extends " else ", ");
        try types.writeTypeName(w, b);
    }
    try w.writeAll(" {\n");
    for (t.methods) |m| try method(w, s, source, m, "    ");
    try w.writeAll("  }\n");
}

fn method(w: *Writer, s: Schema, source: []const u8, m: Schema.Method, indent: []const u8) Error!void {
    try methodDoc(w, s, source, m, indent);
    try w.print("{s}{s}", .{ indent, m.name });
    try signature(w, s, m.signature, m.async);
    try w.writeAll(";\n");
}

/// A struct in memory. What its views have, and its class with `at`, methods and statics.
fn viewClass(w: *Writer, s: Schema, source: []const u8, t: *const Schema.Type) Error!void {
    const st = switch (t.kind) {
        .@"struct", .@"union" => |st| st,
        else => unreachable,
    };
    try doc(w, source, t.at, "  ");
    try w.writeAll("  export interface ");
    try types.writeTypeName(w, t.name);
    if (st.base) |b| {
        try w.writeAll(" extends ");
        try types.writeTypeName(w, b);
    }
    try w.writeAll(" {\n");
    for (st.fields) |f| {
        try doc(w, source, f.at, "    ");
        try w.print("    {s}: ", .{f.name});
        try typeRef(w, s, f.type, .view);
        try w.writeAll(";\n");
    }
    for (st.methods) |m| if (!m.static) try method(w, s, source, m, "    ");
    try w.writeAll("  }\n");
    if (t.nested) return;

    try w.writeAll("  export const ");
    try types.writeTypeName(w, t.name);
    try w.writeAll(": {\n");
    if (s.findFunction(nameDot(t.name, "at")) == null) {
        try w.writeAll("    /** A live view of one at `address`. Null at 0. */\n    at(address: number | bigint): ");
        try types.writeTypeName(w, t.name);
        try w.writeAll(" | null;\n");
    }
    for (st.methods) |m| {
        try methodDoc(w, s, source, m, "    ");
        try w.print("    {s}(", .{m.name});
        if (!m.static) {
            try w.writeAll("self: ");
            try types.writeTypeName(w, t.name);
            if (m.signature.params.len > 0) try w.writeAll(", ");
        }
        try params(w, s, m.signature);
        try w.writeAll("): ");
        try returns(w, s, m.signature.ret, m.async);
        try w.writeAll(";\n");
    }
    for (st.statics) |v| {
        try doc(w, source, v.at, "    ");
        try w.print("    {s}: ", .{v.name});
        try typeRef(w, s, v.type, .view);
        try w.writeAll(";\n");
    }
    var members: types.Members = .{ .s = s };
    while (members.next()) |m| if (std.mem.eql(u8, m.parent(), t.name)) try member(w, s, source, m, "    ");
    try w.writeAll("  };\n");
}

/// Bits in memory, an object with a member each.
fn bitsView(w: *Writer, s: Schema, source: []const u8, t: *const Schema.Type, bf: Schema.Bitfield) Error!void {
    _ = s;
    try doc(w, source, t.at, "  ");
    try w.writeAll("  export interface ");
    try types.writeTypeName(w, t.name);
    try w.writeAll(" {\n");
    for (bf.members) |m| {
        try doc(w, source, m.at, "    ");
        try w.print("    {s}: {s};\n", .{ m.name, switch (m.type) {
            .bool => "boolean",
            else => "number",
        } });
    }
    try w.writeAll("  }\n");
}

/// `Name.member`, for looking things up. Long names just don't find anything.
fn nameDot(name: []const u8, member_name: []const u8) []const u8 {
    const S = struct {
        threadlocal var buf: [256]u8 = undefined;
    };
    return std.fmt.bufPrint(&S.buf, "{s}.{s}", .{ name, member_name }) catch "";
}

/// What's in a namespace, as the name it has there. In a struct's class it's a property, otherwise
/// a type and a value of the same name.
fn member(w: *Writer, s: Schema, source: []const u8, m: types.Member, indent: []const u8) Error!void {
    const on_class = types.isRecordName(s, m.parent());
    switch (m.what) {
        .type, .function => {
            if (on_class) {
                try w.print("{s}{s}: typeof ", .{ indent, m.leaf() });
            } else {
                if (m.what == .type) {
                    try w.print("{s}export type {s} = ", .{ indent, m.leaf() });
                    try types.writeTypeName(w, m.name);
                    try w.writeAll(";\n");
                }
                try w.print("{s}export const {s}: typeof ", .{ indent, m.leaf() });
            }
            try types.writeTypeName(w, m.name);
            try w.writeAll(";\n");
        },
        .static => |v| {
            try doc(w, source, v.at, indent);
            try w.print("{s}{s}{s}: ", .{ indent, if (on_class) "" else "export const ", m.leaf() });
            try typeRef(w, s, v.type, .view);
            try w.writeAll(";\n");
        },
    }
}

/// A property's name, quoted if it isn't one on its own, like a generic's.
fn propertyName(w: *Writer, n: []const u8) Error!void {
    for (n) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return w.print("    \"{s}\"", .{n});
    }
    try w.print("    {s}", .{n});
}

// Signatures

fn signature(w: *Writer, s: Schema, sig: Schema.Signature, async: bool) Error!void {
    try w.writeByte('(');
    try params(w, s, sig);
    try w.writeAll("): ");
    try returns(w, s, sig.ret, async);
}

fn params(w: *Writer, s: Schema, sig: Schema.Signature) Error!void {
    for (sig.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try paramName(w, p.name);
        try w.writeAll(": ");
        if (p.inoutType()) |inner| {
            // Objects are written back, other values go in a box
            if (types.isRecord(s, inner)) try typeRef(w, s, inner, .in) else {
                try w.writeAll("{ value: ");
                try typeRef(w, s, inner, .in);
                try w.writeAll(" }");
            }
            if (p.nullable()) try w.writeAll(" | null");
        } else try typeRef(w, s, p.type, .in);
    }
}

fn returns(w: *Writer, s: Schema, ret: Ref, async: bool) Error!void {
    if (async) try w.writeAll("Promise<");
    try typeRef(w, s, ret, .out);
    if (async) try w.writeByte('>');
}

fn funcType(w: *Writer, s: Schema, sig: Schema.Signature) Error!void {
    try w.writeByte('(');
    try params(w, s, sig);
    try w.writeAll(") => ");
    try typeRef(w, s, sig.ret, .out);
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
                .bitfield => |bf| if (use == .view) try types.writeTypeName(w, n) else try w.writeAll(if (bf.backing == .u64 or bf.backing == .i64) "bigint" else "number"),
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
                try w.writeAll("import(\"schema\").");
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

const testing = std.testing;

test "a module's traits, types and exports, with docs" {
    const source =
        \\error Shy { Early = 1 }
        \\enum Mode : u8 { off, on }
        \\// A greeting
        \\struct Greeting { u32 times; u8[8] name; u64 big; }
        \\fn void Tick(u32 n);
        \\trait Greeter {
        \\    // Says hi
        \\    Greeting!Shy greet(Mode mode, inout u32 count, Greeting in);
        \\    async u64 later(Tick tick);
        \\    ?u32 maybe();
        \\}
        \\trait Root { Greeter greeter(); }
    ;
    var parsed = try @import("salamander_schema").parse(testing.allocator, source, .{}, null);
    defer parsed.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try api(&out.writer, parsed.schema, source, .{ .module = "app", .root = "Root", .globals = true });
    const text = out.written();
    const want = [_][]const u8{
        "declare module \"app\" {",
        "  export type Shy = \"Early\" | \"Cancelled\" | \"Unsupported\" | \"Gone\";",
        "  export type Mode = number;",
        "  export type ModeName = \"off\" | \"on\";",
        "  /**\n   * A greeting\n   */\n  export interface Greeting {",
        "    name: string;",
        "    big: bigint;",
        "    maybe(): number | null;",
        "  export type Tick = (n: number) => void;",
        "     * Says hi\n     * @throws `Shy`\n",
        "    greet(mode: Mode | ModeName, count: { value: number }, in_: import(\"salamander\").Given<Greeting>): Greeting;",
        "    later(tick: Tick): Promise<bigint>;",
        "  export const greeter: Greeter;",
        "declare const greeter: import(\"app\").Greeter;",
    };
    for (want) |piece| if (std.mem.indexOf(u8, text, piece) == null) {
        std.debug.print("missing:\n{s}\nin:\n{s}\n", .{ piece, text });
        return error.TestUnexpectedResult;
    };
}

test "the schema module's live classes" {
    const source =
        \\enum Mode : u8 { off, on }
        \\struct Base { u32 id; }
        \\struct Player : Base {
        \\    u32 health;
        \\    u8 flags { u8 speed : 3; bool paused; }
        \\    Player* next;
        \\    [Virtual(2)] f32 heal(u32 amount);
        \\    [game.Sig("48")] static Player* create();
        \\    [game.Sig("48")] static Player* instance;
        \\}
        \\[game.Sig("48")] u32 spawn(Mode mode);
        \\[game.Sig("48")] static u32 frames;
    ;
    var parsed = try @import("salamander_schema").parse(testing.allocator, source, .{ .any_namespace = true }, null);
    defer parsed.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try schema(&out.writer, parsed.schema, source);
    const text = out.written();
    const want = [_][]const u8{
        "  export interface Player extends Base {",
        "    health: number;",
        "    flags: Player_flags;",
        "    next: import(\"schema\").Player | null;",
        "    heal(amount: number): number;",
        "  export const Player: {",
        "    at(address: number | bigint): Player | null;",
        "    heal(self: Player, amount: number): number;",
        "    create(): import(\"schema\").Player | null;",
        "    instance: import(\"schema\").Player | null;",
        "  export interface Player_flags {\n    speed: number;\n    paused: boolean;",
        "  export const Mode: {\n    readonly off: number;",
        "  export function spawn(mode: Mode | ModeName): number;",
        "    frames: number;",
        "  export default all;",
    };
    for (want) |piece| if (std.mem.indexOf(u8, text, piece) == null) {
        std.debug.print("missing:\n{s}\nin:\n{s}\n", .{ piece, text });
        return error.TestUnexpectedResult;
    };
}

test "the schema module's namespaces" {
    const source =
        \\namespace World {
        \\    struct Counter { u32 n; Counter* next; [game.Sig("48")] static Counter* main; }
        \\    namespace Inner { enum Mode : u8 { off, on } }
        \\    [game.Sig("48")] u32 twice(u32 n);
        \\    [game.Sig("48")] static u32 ticks;
        \\}
    ;
    var parsed = try @import("salamander_schema").parse(testing.allocator, source, .{ .any_namespace = true }, null);
    defer parsed.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try schema(&out.writer, parsed.schema, source);
    const text = out.written();
    const want = [_][]const u8{
        "  export interface World_Counter {",
        "    next: import(\"schema\").World_Counter | null;",
        "  export function World_twice(n: number): number;",
        "  export namespace World {\n    export type Counter = World_Counter;\n    export const Counter: typeof World_Counter;\n    export const twice: typeof World_twice;\n    export const ticks: number;\n  }",
        "  export namespace World.Inner {\n    export type Mode = World_Inner_Mode;\n    export const Mode: typeof World_Inner_Mode;\n  }",
        "    World: typeof World;",
    };
    for (want) |piece| if (std.mem.indexOf(u8, text, piece) == null) {
        std.debug.print("missing:\n{s}\nin:\n{s}\n", .{ piece, text });
        return error.TestUnexpectedResult;
    };
}
