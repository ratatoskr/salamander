//! LuaLS annotations. `api` for a module of traits and plain types, `schema` for the live module,
//! `builtins` for `salamander`. Classes are global in LuaLS, so live ones are `schema.Name`.

const std = @import("std");
const Schema = @import("salamander_schema").Schema;

const types = @import("root.zig");

const Writer = std.Io.Writer;
const Error = Writer.Error;
const Ref = Schema.Ref;

const header = "-- Made from .sal files by Salamander. Don't change it, since it's made again.\n\n";

const Use = enum { out, in, view, field };

/// Set while writing the `schema` module, whose enums and records are all `schema.Name`.
threadlocal var live = false;

/// `api.module` declaring the schema's traits and types, and `api.root`'s exports.
pub fn api(w: *Writer, s: Schema, source: []const u8, options: types.Api) Error!void {
    try w.print("---@meta {s}\n" ++ header, .{options.module});
    for (s.types) |*t| try apiType(w, s, source, t);
    for (s.traits) |*t| try trait(w, s, source, t);
    const root = if (options.root) |r| s.findTrait(r) else null;
    try w.print("---@class {s}\n", .{options.module});
    if (root) |t| for (t.methods) |m| {
        try doc(w, source, m.at);
        try w.print("---@field {s} ", .{m.name});
        try typeRef(w, s, m.signature.ret, .out);
        try w.writeByte('\n');
    };
    try w.writeAll("local module = {}\nreturn module\n");
}

/// The exports as globals, for consoles. A file of its own, since a module's file has to return it.
pub fn globals(w: *Writer, s: Schema, source: []const u8, options: types.Api) Error!void {
    try w.writeAll("---@meta\n" ++ header);
    const root = s.findTrait(options.root orelse return) orelse return;
    for (root.methods) |m| {
        try doc(w, source, m.at);
        try w.writeAll("---@type ");
        try typeRef(w, s, m.signature.ret, .out);
        try w.print("\n{s} = nil\n\n", .{m.name});
    }
}

/// The `schema` module. A live class per struct with its methods and statics, enum values, and the
/// schema's functions and statics.
pub fn schema(w: *Writer, s: Schema, source: []const u8) Error!void {
    live = true;
    defer live = false;
    try w.writeAll("---@meta schema\n" ++ header);
    for (s.types) |*t| switch (t.kind) {
        .@"struct", .@"union" => try viewClass(w, s, source, t),
        .@"enum" => |e| {
            try doc(w, source, t.at);
            try w.writeAll("---@class schema.");
            try types.writeTypeName(w, t.name);
            try w.writeByte('\n');
            for (e.values) |v| {
                try doc(w, source, v.at);
                try w.print("---@field {s} integer\n", .{v.name});
            }
            try enumNames(w, "schema.", t.name, e);
        },
        .bitfield => |bf| {
            try doc(w, source, t.at);
            try w.writeAll("---@class schema.");
            try types.writeTypeName(w, t.name);
            try w.writeByte('\n');
            for (bf.members) |m| {
                try doc(w, source, m.at);
                try w.print("---@field {s} {s}\n", .{ m.name, if (m.type == .bool) "boolean" else "integer" });
            }
            try w.writeByte('\n');
        },
        else => {},
    };

    try w.writeAll("---@class schema\n");
    for (s.types) |t| if ((t.kind == .@"struct" or t.kind == .@"enum") and !t.nested) {
        try w.print("---@field {s} schema.", .{t.name});
        try types.writeTypeName(w, t.name);
        if (t.kind == .@"struct") try w.writeAll("Class");
        try w.writeByte('\n');
    };
    for (s.statics) |v| {
        try doc(w, source, v.at);
        try w.print("---@field {s} ", .{v.name});
        try typeRef(w, s, v.type, .view);
        try w.writeByte('\n');
    }
    try w.writeAll("local schema = {}\n\n");
    for (s.functions) |f| try function(w, s, source, f);
    try w.writeAll("return schema\n");
}

/// `salamander`, as the module and a global.
pub fn builtins(w: *Writer) Error!void {
    try w.writeAll("---@meta salamander\n" ++ header ++
        \\---What an async call gives. Await it from a task, like the script's own code.
        \\---@class salamander.Promise
        \\local Promise = {}
        \\
        \\---What it settles with, waiting for it if it hasn't yet.
        \\---@return any
        \\function Promise:await() end
        \\
        \\---@class salamander
        \\local salamander = {}
        \\
        \\---`f`, typed by `signature` like `"fn i32 (i32 a)"` or a declared name like `"Player.heal"`, so native code taking an object gets it as that function type.
        \\---@generic F: function
        \\---@param signature string
        \\---@param f F
        \\---@return F
        \\function salamander.fn(signature, f) end
        \\
        \\---The native function at `address`, callable, typed by `signature` like `fn` takes.
        \\---@param signature string
        \\---@param address integer
        \\---@return function
        \\function salamander.native(signature, address) end
        \\
        \\---A live view of `type`, like `"Player"` or `"u32[4]"`, at `address`. Nil at 0.
        \\---@param type string
        \\---@param address integer
        \\---@return any
        \\function salamander.at(type, address) end
        \\
        \\---Where a view is.
        \\---@param view table
        \\---@return integer
        \\function salamander.addressOf(view) end
        \\
        \\---A view's type, like `"Player"` or `"u32[4]"`.
        \\---@param view table
        \\---@return string
        \\function salamander.typeOf(view) end
        \\
        \\---How many bytes a type or a view takes.
        \\---@param type_or_view string|table
        \\---@return integer
        \\function salamander.sizeOf(type_or_view) end
        \\
        \\---A plain copy of a view, to change and `save`.
        \\---@generic T: table
        \\---@param view T
        \\---@return T
        \\function salamander.snapshot(view) end
        \\
        \\---Writes back what changed in a snapshot, giving how many parts did.
        \\---@param copy table
        \\---@return integer
        \\function salamander.save(copy) end
        \\
        \\---Snapshots `view`, calls `f` with the copy, then saves it. Nothing's saved if it raises.
        \\---@generic T: table
        \\---@param view T
        \\---@param f fun(copy: T)
        \\function salamander.edit(view, f) end
        \\
        \\---A `.sal` written while running, in place of what was loaded as `name` before. Gives what it declares, like the `schema` module.
        \\---@param name string
        \\---@param text string
        \\---@return table
        \\function salamander.load(name, text) end
        \\
        \\return salamander
        \\
    );
}

// Declarations

fn apiType(w: *Writer, s: Schema, source: []const u8, t: *const Schema.Type) Error!void {
    switch (t.kind) {
        .@"struct", .@"union" => |st| {
            try doc(w, source, t.at);
            try w.writeAll("---@class ");
            try types.writeTypeName(w, t.name);
            if (st.base) |b| {
                try w.writeAll(" : ");
                try types.writeTypeName(w, b);
            }
            try w.writeByte('\n');
            for (st.fields) |f| {
                try doc(w, source, f.at);
                try w.print("---@field {s}{s} ", .{ f.name, if (t.kind == .@"union") "?" else "" });
                try typeRef(w, s, f.type, .field);
                try w.writeByte('\n');
            }
            try w.writeByte('\n');
        },
        .@"enum" => |e| {
            try doc(w, source, t.at);
            try w.writeAll("---@alias ");
            try types.writeTypeName(w, t.name);
            try w.writeAll(" integer\n");
            try enumNames(w, "", t.name, e);
        },
        .bitfield => {
            try doc(w, source, t.at);
            try w.writeAll("---@alias ");
            try types.writeTypeName(w, t.name);
            try w.writeAll(" integer\n\n");
        },
        .@"error" => |es| {
            try doc(w, source, t.at);
            try w.writeAll("---What it can raise, by name.\n---@alias ");
            try types.writeTypeName(w, t.name);
            for (es.errors, 0..) |e, i| try w.print("{s}\"{s}\"", .{ if (i == 0) " " else "|", e.name });
            for (Schema.builtin_errors) |e| try w.print("|\"{s}\"", .{e});
            try w.writeAll("\n\n");
        },
        .@"opaque" => {},
        .func => |sig| {
            try doc(w, source, t.at);
            try w.writeAll("---@alias ");
            try types.writeTypeName(w, t.name);
            try w.writeByte(' ');
            try funcType(w, s, sig);
            try w.writeAll("\n\n");
        },
    }
}

fn enumNames(w: *Writer, prefix: []const u8, name: []const u8, e: Schema.Enum) Error!void {
    try w.print("---What `{s}` can also be given as.\n---@alias {s}", .{ name, prefix });
    try types.writeTypeName(w, name);
    try w.writeAll("Name");
    if (e.values.len == 0) try w.writeAll(" string");
    for (e.values, 0..) |v, i| try w.print("{s}\"{s}\"", .{ if (i == 0) " " else "|", v.name });
    try w.writeAll("\n\n");
}

/// A trait's class, by its own name, with its methods.
pub fn trait(w: *Writer, s: Schema, source: []const u8, t: *const Schema.Trait) Error!void {
    try doc(w, source, t.at);
    try w.print("---@class {s}", .{t.name});
    for (t.bases, 0..) |b, i| try w.print("{s}{s}", .{ if (i == 0) " : " else ", ", b });
    try w.writeAll("\ndo\nlocal c = {}\n\n");
    for (t.methods) |m| try methodOn(w, s, source, m, "c", true, null);
    try w.writeAll("end\n\n");
}

/// A struct in memory. `schema.Name` for its views, `schema.NameClass` with `at`, methods and statics.
fn viewClass(w: *Writer, s: Schema, source: []const u8, t: *const Schema.Type) Error!void {
    const st = switch (t.kind) {
        .@"struct", .@"union" => |st| st,
        else => unreachable,
    };
    try doc(w, source, t.at);
    try w.writeAll("---@class schema.");
    try types.writeTypeName(w, t.name);
    if (st.base) |b| {
        try w.writeAll(" : schema.");
        try types.writeTypeName(w, b);
    }
    try w.writeByte('\n');
    for (st.fields) |f| {
        try doc(w, source, f.at);
        try w.print("---@field {s} ", .{f.name});
        try typeRef(w, s, f.type, .view);
        try w.writeByte('\n');
    }
    try w.writeAll("do\nlocal c = {}\n\n");
    for (st.methods) |m| if (!m.static) try methodOn(w, s, source, m, "c", true, null);
    try w.writeAll("end\n\n");
    if (t.nested) return;

    try w.writeAll("---@class schema.");
    try types.writeTypeName(w, t.name);
    try w.writeAll("Class\n");
    for (st.statics) |v| {
        try doc(w, source, v.at);
        try w.print("---@field {s} ", .{v.name});
        try typeRef(w, s, v.type, .view);
        try w.writeByte('\n');
    }
    try w.writeAll("do\nlocal c = {}\n\n");
    if (s.findFunction(nameDot(t.name, "at")) == null) {
        try w.writeAll("---A live view of one at `address`. Nil at 0.\n---@param address integer\n---@return schema.");
        try types.writeTypeName(w, t.name);
        try w.writeAll("|nil\nfunction c.at(address) end\n\n");
    }
    for (st.methods) |m| try methodOn(w, s, source, m, "c", false, if (m.static) null else t.name);
    try w.writeAll("end\n\n");
}

fn function(w: *Writer, s: Schema, source: []const u8, f: Schema.Method) Error!void {
    try methodDocs(w, s, source, f, null);
    if (keywords.has(f.name)) {
        try w.print("schema[\"{s}\"] = function(", .{f.name});
    } else try w.print("function schema.{s}(", .{f.name});
    try paramNames(w, f.signature);
    try w.writeAll(") end\n\n");
}

/// `this_type` is set for a struct's method called through its class, which takes the view first.
fn methodOn(w: *Writer, s: Schema, source: []const u8, m: Schema.Method, on: []const u8, colon: bool, this_type: ?[]const u8) Error!void {
    try methodDocs(w, s, source, m, this_type);
    if (keywords.has(m.name)) {
        try w.print("{s}[\"{s}\"] = function(", .{ on, m.name });
        if (colon) try w.writeAll(if (m.signature.params.len > 0) "self, " else "self");
    } else try w.print("function {s}{s}{s}(", .{ on, if (colon) ":" else ".", m.name });
    if (this_type != null) try w.writeAll(if (m.signature.params.len > 0) "self, " else "self");
    try paramNames(w, m.signature);
    try w.writeAll(") end\n\n");
}

fn paramNames(w: *Writer, sig: Schema.Signature) Error!void {
    for (sig.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try paramName(w, p.name);
    }
}

fn methodDocs(w: *Writer, s: Schema, source: []const u8, m: Schema.Method, this_type: ?[]const u8) Error!void {
    try doc(w, source, m.at);
    switch (m.signature.ret) {
        .result => |r| try w.print("---Raises `{s}` if it fails.\n", .{r.err}),
        else => {},
    }
    if (this_type) |t| {
        try w.writeAll("---@param self schema.");
        try types.writeTypeName(w, t);
        try w.writeByte('\n');
    }
    for (m.signature.params) |p| {
        try w.writeAll("---@param ");
        try paramName(w, p.name);
        try w.writeByte(' ');
        try paramType(w, s, p);
        try w.writeByte('\n');
    }
    if (m.async) return w.writeAll("---@return salamander.Promise\n");
    const ret = switch (m.signature.ret) {
        .result => |r| r.ok.*,
        else => m.signature.ret,
    };
    if (ret == .prim and ret.prim == .void) return;
    try w.writeAll("---@return ");
    try typeRef(w, s, ret, .out);
    try w.writeByte('\n');
}

fn paramType(w: *Writer, s: Schema, p: Schema.Param) Error!void {
    const inner = p.inoutType() orelse return typeRef(w, s, p.type, .in);
    // Objects are written back, other values go in a box
    if (types.isRecord(s, inner)) try typeRef(w, s, inner, .in) else {
        try w.writeAll("{ value: ");
        try typeRef(w, s, inner, .in);
        try w.writeAll(" }");
    }
    if (p.nullable()) try w.writeAll("|nil");
}

fn funcType(w: *Writer, s: Schema, sig: Schema.Signature) Error!void {
    try w.writeAll("fun(");
    for (sig.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try paramName(w, p.name);
        try w.writeAll(": ");
        try paramType(w, s, p);
    }
    try w.writeByte(')');
    const ret = switch (sig.ret) {
        .result => |r| r.ok.*,
        else => sig.ret,
    };
    if (ret == .prim and ret.prim == .void) return;
    try w.writeAll(": ");
    try typeRef(w, s, ret, .out);
}

/// `Name.member`, for looking things up. Long names just don't find anything.
fn nameDot(name: []const u8, member: []const u8) []const u8 {
    const S = struct {
        threadlocal var buf: [256]u8 = undefined;
    };
    return std.fmt.bufPrint(&S.buf, "{s}.{s}", .{ name, member }) catch "";
}

// Types

fn typeRef(w: *Writer, s: Schema, r: Ref, use: Use) Error!void {
    switch (r) {
        .prim => |p| try w.writeAll(switch (p) {
            .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .usize, .isize => "integer",
            .f32, .f64 => "number",
            .bool => "boolean",
            .utf8, .utf16, .string, .blob => "string",
            .cstring => "string|nil",
            .object => "any",
            .void => "nil",
        }),
        .named => |n| {
            if (s.findTrait(n) != null) {
                try w.writeAll(n);
                if (use == .in) try w.writeAll("|nil");
                return;
            }
            const t = s.findType(n) orelse return w.writeAll("any");
            switch (t.kind) {
                .@"enum" => {
                    if (use != .in and use != .field) return w.writeAll(if (live) "integer" else n);
                    try w.writeAll(if (live) "integer|schema." else "");
                    if (!live) {
                        try types.writeTypeName(w, n);
                        try w.writeAll("|");
                    }
                    try types.writeTypeName(w, n);
                    try w.writeAll("Name");
                },
                .bitfield => if (use == .view) {
                    try w.writeAll("schema.");
                    try types.writeTypeName(w, n);
                } else try w.writeAll("integer"),
                .@"opaque" => try w.writeAll("integer"),
                .@"struct", .@"union" => {
                    if (use == .view or live) try w.writeAll("schema.");
                    try types.writeTypeName(w, n);
                },
                else => try types.writeTypeName(w, n),
            }
        },
        .pointer => |child| {
            if (types.isTextPointer(r)) return w.writeAll(if (use == .in) "integer" else "string|nil");
            if (types.isRecord(s, child.*)) {
                if (use == .in) try w.writeAll("integer|");
                try w.writeAll("schema.");
                try types.writeTypeName(w, child.named);
                return w.writeAll("|nil");
            }
            try w.writeAll("integer");
        },
        .array => |a| {
            if (types.isTextArray(r)) return w.writeAll("string");
            try arrayOf(w, s, a.child.*, use);
        },
        .slice => |child| try arrayOf(w, s, child.*, use),
        .optional => |child| {
            try typeRef(w, s, child.*, use);
            try w.writeAll("|nil");
        },
        .result => |res| try typeRef(w, s, res.ok.*, use),
        .func => |sig| {
            try w.writeByte('(');
            try funcType(w, s, sig.*);
            try w.writeByte(')');
        },
    }
}

fn arrayOf(w: *Writer, s: Schema, child: Ref, use: Use) Error!void {
    try w.writeByte('(');
    try typeRef(w, s, child, use);
    try w.writeAll(")[]");
}

// Text

fn doc(w: *Writer, source: []const u8, at: usize) Error!void {
    var lines = types.docLines(source, at);
    while (lines.next()) |l| try w.print("---{s}\n", .{l});
}

const keywords = std.StaticStringMap(void).initComptime(.{
    .{"and"},   .{"break"},    .{"do"},     .{"else"},   .{"elseif"}, .{"end"},   .{"false"},
    .{"for"},   .{"function"}, .{"goto"},   .{"if"},     .{"in"},     .{"local"}, .{"nil"},
    .{"not"},   .{"or"},       .{"repeat"}, .{"return"}, .{"then"},   .{"true"},  .{"until"},
    .{"while"},
});

fn paramName(w: *Writer, name: []const u8) Error!void {
    try w.writeAll(name);
    if (keywords.has(name)) try w.writeByte('_');
}

const testing = std.testing;

test "a module's traits, types and exports" {
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
        \\    void end();
        \\}
        \\trait Root { Greeter greeter(); }
    ;
    var parsed = try @import("salamander_schema").parse(testing.allocator, source, .{}, null);
    defer parsed.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try api(&out.writer, parsed.schema, source, .{ .module = "app", .root = "Root" });
    try globals(&out.writer, parsed.schema, source, .{ .module = "app", .root = "Root" });
    const text = out.written();
    const want = [_][]const u8{
        "---@meta app",
        "---@alias Mode integer",
        "---@alias ModeName \"off\"|\"on\"",
        "---A greeting\n---@class Greeting\n",
        "---@field name string",
        "---@field big integer",
        "---@return integer|nil\nfunction c:maybe() end",
        "---@alias Tick fun(n: integer)",
        "---Says hi\n---Raises `Shy` if it fails.\n---@param mode Mode|ModeName\n---@param count { value: integer }\n---@param in_ Greeting\n---@return Greeting\nfunction c:greet(mode, count, in_) end",
        "---@return salamander.Promise\nfunction c:later(tick) end",
        "c[\"end\"] = function(self) end",
        "---@class app\n---@field greeter Greeter\nlocal module = {}\nreturn module",
        "---@type Greeter\ngreeter = nil",
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
        "---@class schema.Player : schema.Base\n---@field health integer\n---@field flags schema.Player_flags\n---@field next schema.Player|nil\n",
        "---@param amount integer\n---@return number\nfunction c:heal(amount) end",
        "---@class schema.PlayerClass\n---@field instance schema.Player|nil\n",
        "---@return schema.Player|nil\nfunction c.at(address) end",
        "---@param self schema.Player\n---@param amount integer\n---@return number\nfunction c.heal(self, amount) end",
        "function c.create() end",
        "---@class schema.Player_flags\n---@field speed integer\n---@field paused boolean",
        "---@class schema.Mode\n---@field off integer",
        "---@field Player schema.PlayerClass",
        "---@field frames integer",
        "---@param mode integer|schema.ModeName\n---@return integer\nfunction schema.spawn(mode) end",
    };
    for (want) |piece| if (std.mem.indexOf(u8, text, piece) == null) {
        std.debug.print("missing:\n{s}\nin:\n{s}\n", .{ piece, text });
        return error.TestUnexpectedResult;
    };
}
