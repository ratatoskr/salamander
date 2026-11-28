//! LuaLS annotations. `globals` declares what schemas give scripts, each top namespace a global, and `builtins` declares `salamander`.

const std = @import("std");
const Schema = @import("salamander_schema").Schema;

const types = @import("root.zig");

const Writer = std.Io.Writer;
const Error = Writer.Error;
const Ref = Schema.Ref;
const Entry = types.Entry;

const header = "-- Made from .sal files by Salamander. Don't change it, since it's made again.\n\n";

const Use = enum { out, in, view, field };

/// Everything in `s`, for a `---@meta` file, each top namespace a global table, or on what `require(module)` gives with `module`.
/// `singletons` are whole trait names the host gives one of, like `Freecam.Camera`, got from `Freecam.camera()`.
pub fn globals(w: *Writer, s: Schema, source: []const u8, singletons: []const []const u8, module: ?[]const u8) Error!void {
    types.singletons = singletons;
    defer types.singletons = &.{};
    const live: types.Live = .init(s);
    if (module) |m| try w.print("---@meta {s}\n" ++ header, .{m}) else try w.writeAll("---@meta\n" ++ header);
    var all: types.Entries = .{ .s = s };
    while (all.next()) |e| if (e.isType()) try declareType(w, s, source, &live, e);
    all = .{ .s = s };
    while (all.next()) |e| if (e.holds(s)) try table(w, s, source, fullName(e));
    try namespaceTables(w, s, source, "");

    if (module) |m| {
        try w.print("---@class {s}\n", .{m});
        all = .{ .s = s };
        while (all.next()) |e| if (e.parent.len == 0 and e.isValue(s) and (e.what == .type or e.what == .trait)) try field(w, s, e.leaf);
        var tops: types.Children = .init(s, "", .value);
        while (tops.next()) |ns| if (types.holder(s, ns) == null) try field(w, s, ns);
        try w.writeAll("local m = {}\n\n");
    }
    const on = if (module != null) "m" else "";
    all = .{ .s = s };
    while (all.next()) |e| if (e.parent.len == 0 and e.isValue(s)) switch (e.what) {
        .function, .accessor => |m| try function(w, s, source, m.*, on, e.leaf),
        .singleton => |t| try singleton(w, t, on),
        .type, .trait => if (module == null) try global(w, s, e.leaf),
        .static => {},
    };
    if (module != null) return w.writeAll("return m\n");
    var tops: types.Children = .init(s, "", .value);
    while (tops.next()) |ns| if (types.holder(s, ns) == null) try global(w, s, ns);
}

fn field(w: *Writer, s: Schema, name: []const u8) Error!void {
    try w.print("---@field {s} ", .{name});
    try tableName(w, s, name);
    try w.writeByte('\n');
}

/// The function giving a singleton of `t` on the table `on`, or a global for "".
fn singleton(w: *Writer, t: *const Schema.Trait, on: []const u8) Error!void {
    var buf: [128]u8 = undefined;
    const name = types.singletonName(&buf, t.name);
    try w.writeAll("---The one scripts are given.\n---@return ");
    try types.writeTypeName(w, t.name);
    if (on.len == 0) {
        try w.print("\nfunction {s}() end\n\n", .{name});
    } else if (keywords.has(name)) {
        try w.print("\n{s}[\"{s}\"] = function() end\n\n", .{ on, name });
    } else try w.print("\nfunction {s}.{s}() end\n\n", .{ on, name });
}

fn fullName(e: Entry) []const u8 {
    return switch (e.what) {
        .type => |t| t.name,
        .trait, .singleton => |t| t.name,
        .function => |f| f.name,
        .static => |v| v.name,
        .accessor => |m| m.name,
    };
}

fn global(w: *Writer, s: Schema, name: []const u8) Error!void {
    try w.writeAll("---@type ");
    try tableName(w, s, name);
    try w.print("\n{s} = {{}}\n\n", .{name});
}

/// A table class for each namespace in `path` that isn't a struct's, enum's or trait's, however deep.
fn namespaceTables(w: *Writer, s: Schema, source: []const u8, path: []const u8) Error!void {
    var inner: types.Children = .init(s, path, .value);
    while (inner.next()) |ns| {
        if (types.holder(s, ns) == null) try table(w, s, source, ns);
        try namespaceTables(w, s, source, ns);
    }
}

/// The class at `path` while scripts run, like `World.CounterClass`, or `World` for a plain namespace.
fn tableName(w: *Writer, s: Schema, path: []const u8) Error!void {
    try types.writeTypeName(w, path);
    if (s.findType(path) != null or s.findTrait(path) != null) try w.writeAll("Class");
}

/// The table at `path`: what a struct's class, enum or trait has itself, then what's in its namespace.
fn table(w: *Writer, s: Schema, source: []const u8, path: []const u8) Error!void {
    const h = types.holder(s, path);
    try w.writeAll("do\n---@class ");
    try tableName(w, s, path);
    try w.writeByte('\n');
    if (h) |e| if (e.what == .type) switch (e.what.type.kind) {
        .@"struct" => |st| for (st.statics) |v| {
            try doc(w, source, v.at);
            try w.print("---@field {s} ", .{v.name});
            try typeRef(w, s, v.type, .view);
            try w.writeByte('\n');
        },
        .@"enum" => |en| for (en.values) |v| {
            try doc(w, source, v.at);
            try w.print("---@field {s} integer\n", .{v.name});
        },
        else => {},
    };
    var all: types.Entries = .{ .s = s };
    while (all.next()) |e| if (e.isValue(s) and std.mem.eql(u8, e.parent, path)) switch (e.what) {
        .type, .trait => {
            try w.print("---@field {s} ", .{e.leaf});
            try tableName(w, s, fullName(e));
            try w.writeByte('\n');
        },
        .static => |v| {
            try doc(w, source, v.at);
            try w.print("---@field {s} ", .{e.leaf});
            try typeRef(w, s, v.type, .view);
            try w.writeByte('\n');
        },
        .function, .accessor, .singleton => {},
    };
    var inner: types.Children = .init(s, path, .value);
    while (inner.next()) |ns| if (types.holder(s, ns) == null) {
        try w.print("---@field {s} ", .{types.leafOf(ns)});
        try tableName(w, s, ns);
        try w.writeByte('\n');
    };
    try w.writeAll("local c = {}\n\n");
    if (h) |e| switch (e.what) {
        .type => |t| if (t.kind == .@"struct") {
            if (s.findFunction(nameDot(t.name, "at")) == null) {
                try w.writeAll("---A live view of one at `address`. Nil at 0.\n---@param address integer\n---@return ");
                try types.writeTypeName(w, t.name);
                try w.writeAll("|nil\nfunction c.at(address) end\n\n");
            }
            for (t.kind.@"struct".methods) |m| try methodOn(w, s, source, m, "c", false, if (m.static) null else t.name);
        },
        .trait => {
            try w.writeAll("---The one scripts are given.\n---@return ");
            try types.writeTypeName(w, path);
            try w.writeAll("\nfunction c.instance() end\n\n");
        },
        else => {},
    };
    all = .{ .s = s };
    while (all.next()) |e| if (e.isValue(s) and std.mem.eql(u8, e.parent, path)) switch (e.what) {
        .function, .accessor => |m| try function(w, s, source, m.*, "c", e.leaf),
        .singleton => |t| try singleton(w, t, "c"),
        else => {},
    };
    try addresses(w, s, path, h);
    try w.writeAll("end\n\n");
}

/// `c.addresses`, where each function and static in `path` is, like Zig's and C#'s.
fn addresses(w: *Writer, s: Schema, path: []const u8, h: ?Entry) Error!void {
    var started = false;
    if (h) |e| if (e.what == .type and e.what.type.kind == .@"struct") {
        const st = e.what.type.kind.@"struct";
        for (st.methods) |m| if (m.virtual == null) try addressLine(w, &started, m.name);
        for (st.statics) |v| try addressLine(w, &started, v.name);
    };
    var all: types.Entries = .{ .s = s };
    while (all.next()) |e| if (e.isValue(s) and std.mem.eql(u8, e.parent, path) and (e.what == .function or e.what == .static)) try addressLine(w, &started, e.leaf);
}

fn addressLine(w: *Writer, started: *bool, name: []const u8) Error!void {
    if (!started.*) try w.writeAll("---Where each is, found by name the first time it's asked for.\nc.addresses = {}\n\n");
    started.* = true;
    try w.writeAll("---@return integer\n");
    if (keywords.has(name)) try w.print("c.addresses[\"{s}\"] = function() end\n\n", .{name}) else try w.print("function c.addresses.{s}() end\n\n", .{name});
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
        \\---`f`, typed by `signature` like `"fn i32 (i32 a)"`, a declared name like `"Player.heal"` or a declared function itself, so native code taking an object gets it as that function type.
        \\---@generic F: function
        \\---@param signature string|F
        \\---@param f F
        \\---@return F
        \\function salamander.fn(signature, f) end
        \\
        \\---The native function at `address`, callable, typed by `signature` like `fn` takes, or like a declared function given for it.
        \\---@generic F: function
        \\---@param signature string|F
        \\---@param address integer
        \\---@return F
        \\function salamander.native(signature, address) end
        \\
        \\---`t`, named as implementing the trait by its full name like `"Wraith.WorkbenchTab"` or its own if only one schema has it, so it can be handed over where any object goes.
        \\---@param trait string
        \\---@param t table
        \\---@return any
        \\function salamander.implement(trait, t) end
        \\
        \\---Any object, like one a plugin's slot holds, as the trait it is, by name like `implement` takes, so its methods can be called.
        \\---@param trait string
        \\---@param obj any
        \\---@return any
        \\function salamander.as(trait, obj) end
        \\
        \\---The full name of a declared function, like `"Kai.Player.heal"`, or nil for anything else.
        \\---@param f any
        \\---@return string|nil
        \\function salamander.nameOf(f) end
        \\
        \\---For an `any` parameter: `value` as the type named, like `Vec3`.
        \\---@param type string
        \\---@param value any
        \\---@return {type: string, value: any}
        \\function salamander.any(type, value) end
        \\
        \\---A Lua function's parameter names, in order.
        \\---@param f function
        \\---@return string[]
        \\function salamander.params(f) end
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
        \\---A `.sal` written while running, in place of what was loaded as `name` before. Gives what it declares, like the globals have.
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

/// A type by its whole name. Structs in memory have live view fields, other values' fields go both ways.
fn declareType(w: *Writer, s: Schema, source: []const u8, live: *const types.Live, e: Entry) Error!void {
    const t = switch (e.what) {
        .trait => |t| return trait(w, s, source, t),
        .type => |t| t,
        else => return,
    };
    switch (t.kind) {
        .@"struct", .@"union" => |st| {
            const is_live = live.has(s, t);
            // A tagged union is one member keyed to its value, or its name when it holds nothing
            if (st.tagged) |tg| if (!is_live) {
                try doc(w, source, t.at);
                try w.writeAll("---@alias ");
                try types.writeTypeName(w, t.name);
                for (tg.members, 0..) |m, i| {
                    try w.writeAll(if (i == 0) " " else "|");
                    if (m.type == .prim and m.type.prim == .void) {
                        try w.print("\"{s}\"", .{m.name});
                    } else {
                        try w.print("{{{s}: ", .{m.name});
                        try typeRef(w, s, m.type, .field);
                        try w.writeAll("}");
                    }
                }
                return w.writeAll("\n\n");
            };
            const methods = for (st.methods) |m| {
                if (!m.static) break true;
            } else false;
            // In a block of its own, so the class is the local that has its methods
            if (methods) try w.writeAll("do\n");
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
                try w.print("---@field {s}{s} ", .{ f.name, if (t.kind == .@"union" and !is_live) "?" else "" });
                try typeRef(w, s, f.type, if (is_live) .view else .field);
                try w.writeByte('\n');
            }
            if (!methods) return w.writeByte('\n');
            try w.writeAll("local c = {}\n\n");
            for (st.methods) |m| if (!m.static) try methodOn(w, s, source, m, "c", true, null);
            try w.writeAll("end\n\n");
        },
        .@"enum" => |en| {
            try doc(w, source, t.at);
            try w.writeAll("---@alias ");
            try types.writeTypeName(w, t.name);
            try w.writeAll(" integer\n");
            try w.print("---What `{s}` can also be given as.\n---@alias ", .{e.leaf});
            try types.writeTypeName(w, t.name);
            try w.writeAll("Name");
            if (en.values.len == 0) try w.writeAll(" string");
            for (en.values, 0..) |v, i| try w.print("{s}\"{s}\"", .{ if (i == 0) " " else "|", v.name });
            try w.writeAll("\n\n");
        },
        .bitfield => |bf| {
            try doc(w, source, t.at);
            try w.writeAll("---@class ");
            try types.writeTypeName(w, t.name);
            try w.writeByte('\n');
            for (bf.members) |m| {
                try doc(w, source, m.at);
                try w.print("---@field {s} {s}\n", .{ m.name, if (m.type == .bool) "boolean" else "integer" });
            }
            try w.writeByte('\n');
        },
        .@"error" => |es| {
            try doc(w, source, t.at);
            try w.writeAll("---What it can raise, by name.\n---@alias ");
            try types.writeTypeName(w, t.name);
            for (es.errors, 0..) |x, i| try w.print("{s}\"{s}\"", .{ if (i == 0) " " else "|", x.name });
            for (Schema.builtin_errors) |x| try w.print("|\"{s}\"", .{x});
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

/// A trait's class, by its whole name, with its methods.
fn trait(w: *Writer, s: Schema, source: []const u8, t: *const Schema.Trait) Error!void {
    try w.writeAll("do\n");
    try doc(w, source, t.at);
    try w.writeAll("---@class ");
    try types.writeTypeName(w, t.name);
    for (t.bases, 0..) |b, i| {
        try w.writeAll(if (i == 0) " : " else ", ");
        try types.writeTypeName(w, b);
    }
    try w.writeAll("\nlocal c = {}\n\n");
    for (t.methods) |m| try methodOn(w, s, source, m, "c", true, null);
    try w.writeAll("end\n\n");
}

/// A function on the table `on`, called with a dot, or a global for "".
fn function(w: *Writer, s: Schema, source: []const u8, f: Schema.Method, on: []const u8, name: []const u8) Error!void {
    try methodDocs(w, s, source, f, null);
    if (on.len == 0) {
        try w.print("function {s}(", .{name});
    } else if (keywords.has(name)) {
        try w.print("{s}[\"{s}\"] = function(", .{ on, name });
    } else try w.print("function {s}.{s}(", .{ on, name });
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
        try w.writeAll("---@param self ");
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
            .any => "{type: string, value: any}",
            .void => "nil",
        }),
        .named => |n| {
            if (s.findTrait(n) != null) {
                try types.writeTypeName(w, n);
                if (use == .in) try w.writeAll("|nil");
                return;
            }
            const t = s.findType(n) orelse return w.writeAll("any");
            switch (t.kind) {
                .@"enum" => {
                    try types.writeTypeName(w, n);
                    if (use != .in and use != .field) return;
                    try w.writeByte('|');
                    try types.writeTypeName(w, n);
                    try w.writeAll("Name");
                },
                .bitfield => if (use == .view) try types.writeTypeName(w, n) else try w.writeAll("integer"),
                .@"opaque" => try w.writeAll("integer"),
                else => try types.writeTypeName(w, n),
            }
        },
        .pointer => |child| {
            if (types.isTextPointer(r)) return w.writeAll(if (use == .in) "integer" else "string|nil");
            if (types.isRecord(s, child.*)) {
                if (use == .in) try w.writeAll("integer|");
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

// Names

const lang = @import("salamander_lang");
const NamesError = Writer.Error || error{OutOfMemory};

/// How scripts name and declare each thing, from the same pieces the annotations are written with. LuaLS
/// has no declarations of its own, so methods read like `name(a: T): R`, called with a colon.
pub const Names = struct {
    a: std.mem.Allocator,
    s: Schema,
    live: types.Live,

    pub fn init(a: std.mem.Allocator, s: Schema) Names {
        return .{ .a = a, .s = s, .live = .init(s) };
    }

    fn text(n: *const Names, comptime f: anytype, args: anytype) NamesError![]const u8 {
        var out: Writer.Allocating = .init(n.a);
        try @call(.auto, f, .{&out.writer} ++ args);
        return out.written();
    }

    fn named(n: *const Names, full: []const u8) NamesError!lang.Decl {
        return .{ .name = try n.text(Schema.writeFlatName, .{types.leafOf(full)}), .path = try n.text(types.writeTypeName, .{full}) };
    }

    fn method_(n: *const Names, name: []const u8, path: ?[]const u8, m: *const Schema.Method) NamesError!lang.Decl {
        const ps = try n.a.alloc(lang.Param, m.signature.params.len);
        for (m.signature.params, ps) |p, *q| {
            const pn = try n.text(paramName, .{p.name});
            const pt = try n.text(paramType, .{ n.s, p });
            q.* = .{ .name = pn, .type = pt, .text = try std.fmt.allocPrint(n.a, "{s}: {s}", .{ pn, pt }) };
        }
        const ok = switch (m.signature.ret) {
            .result => |r| r.ok.*,
            else => m.signature.ret,
        };
        const ret: ?[]const u8 = if (m.async) "salamander.Promise" else if (lang.isVoid(ok)) null else try n.text(typeRef, .{ n.s, ok, Use.out });
        const list = try lang.paramList(n.a, ps);
        return .{
            .name = name,
            .path = path,
            .params = ps,
            .type = ret,
            .text = if (ret) |r| try std.fmt.allocPrint(n.a, "{s}({s}): {s}", .{ name, list, r }) else try std.fmt.allocPrint(n.a, "{s}({s})", .{ name, list }),
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
        const ty = try n.text(typeRef, .{ n.s, f.type, if (is_live) Use.view else Use.field });
        return .{ .name = f.name, .type = ty, .text = try std.fmt.allocPrint(n.a, "{s}{s}: {s}", .{ f.name, if (t.kind == .@"union" and !is_live) "?" else "", ty }) };
    }

    /// An enum's value on its table, an error's name, or a bitfield's member.
    pub fn member(n: *const Names, t: *const Schema.Type, name: []const u8) NamesError!?lang.Decl {
        if (t.kind == .@"error") return .{ .name = try std.fmt.allocPrint(n.a, "\"{s}\"", .{name}) };
        if (t.kind == .@"enum") return .{ .name = name, .path = try std.fmt.allocPrint(n.a, "{s}.{s}", .{ try n.text(types.writeTypeName, .{t.name}), name }) };
        return .{ .name = name };
    }

    pub fn function(n: *const Names, in: ?*const Schema.Type, m: *const Schema.Method) NamesError!?lang.Decl {
        if (in != null) return try n.method_(m.name, null, m);
        return try n.method_(types.leafOf(m.name), try n.text(types.writeTypeName, .{m.name}), m);
    }

    pub fn static(n: *const Names, in: ?*const Schema.Type, v: *const Schema.Static) NamesError!?lang.Decl {
        const name = if (in != null) v.name else types.leafOf(v.name);
        const ty = try n.text(typeRef, .{ n.s, v.type, Use.view });
        return .{
            .name = name,
            .path = if (in != null) null else try n.text(types.writeTypeName, .{v.name}),
            .type = ty,
            .text = try std.fmt.allocPrint(n.a, "{s}: {s}", .{ name, ty }),
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
    var parsed = try @import("salamander_schema").parse(testing.allocator, source, options, null);
    defer parsed.deinit();
    try globals(&out.writer, parsed.schema, source, singletons, null);
}

test "as a module, what's at the top is on what require gives" {
    const source =
        \\namespace Game {
        \\    struct Box { u32 n; }
        \\    [Root] trait App { u32 version(); }
        \\}
    ;
    var parsed = try @import("salamander_schema").parse(testing.allocator, source, .{}, null);
    defer parsed.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try globals(&out.writer, parsed.schema, source, &.{}, "game");
    const text = out.written();
    try testing.expect(std.mem.startsWith(u8, text, "---@meta game\n"));
    try testing.expect(std.mem.indexOf(u8, text, "---@class game\n---@field Game Game\nlocal m = {}\n") != null);
    try testing.expect(std.mem.endsWith(u8, text, "return m\n"));
    try testing.expect(std.mem.indexOf(u8, text, "\nGame = {}") == null);
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
        \\    void end();
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
    try expectPieces(out.written(), &.{
        "---@meta\n",
        "---@alias Mode integer",
        "---@alias ModeName \"off\"|\"on\"",
        "---A greeting\n---@class Greeting\n",
        "---@field name string",
        "---@field big integer",
        "---@field mode Mode|ModeName",
        "---@return integer|nil\nfunction c:maybe() end",
        "---@alias Tick fun(n: integer)",
        "---Says hi\n---Raises `Shy` if it fails.\n---@param mode Mode|ModeName\n---@param count { value: integer }\n---@param in_ Greeting\n---@return Greeting\nfunction c:greet(mode, count, in_) end",
        "---@return salamander.Promise\nfunction c:later(tick) end",
        "c[\"end\"] = function(self) end",
        "do\n---@class GreeterClass\nlocal c = {}\n\n---The one scripts are given.\n---@return Greeter\nfunction c.instance() end",
        "---@class ModeClass\n---@field off integer",
        "---The greeter\n---@return Greeter\nfunction greeter() end",
        "---@type GreeterClass\nGreeter = {}",
        "---@type AppClass\nApp = {}",
    });
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
        "do\n---@class Player : Base\n---@field health integer\n---@field flags Player.flags\n---@field mode Mode\n---@field next Player|nil\nlocal c = {}\n",
        "---@param amount integer\n---@return number\nfunction c:heal(amount) end",
        "---@class PlayerClass\n---@field instance Player|nil\n",
        "---@return Player|nil\nfunction c.at(address) end",
        "---@param self Player\n---@param amount integer\n---@return number\nfunction c.heal(self, amount) end",
        "function c.create() end",
        "---@class Player.flags\n---@field speed integer\n---@field paused boolean",
        "---@param mode Mode|ModeName\n---@return integer\nfunction spawn(mode) end",
        "---@type PlayerClass\nPlayer = {}",
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
        "---@class World.Counter\n---@field n integer\n---@field next World.Counter|nil\n",
        "---@class World.CounterClass\n---@field main World.Counter|nil\n",
        "do\n---@class World\n---@field Counter World.CounterClass\n---@field ticks integer\n---@field Inner World.Inner\nlocal c = {}\n\n---@param n integer\n---@return integer\nfunction c.twice(n) end",
        "---@class World.Inner\n---@field Mode World.Inner.ModeClass\n",
        "---@alias Wraith.Tweaks.Mode integer",
        "---@class Wraith.Tweaks.Definition\n---@field id string\n---@field mode Wraith.Tweaks.Mode|Wraith.Tweaks.ModeName\n",
        "do\n---@class Wraith.Tweaks\nlocal c = {}\n\n---@param d Wraith.Tweaks.Definition\nfunction c:add(d) end",
        "---@class Wraith.Vfs\n",
        "do\n---@class Wraith.TweaksClass\n---@field Mode Wraith.Tweaks.ModeClass\n---@field Definition Wraith.Tweaks.DefinitionClass\nlocal c = {}\n\n---The one scripts are given.\n---@return Wraith.Tweaks\nfunction c.instance() end",
        "do\n---@class Wraith\n---@field Tweaks Wraith.TweaksClass\n---@field Api Wraith.ApiClass\nlocal c = {}\n\n---@return Wraith.Tweaks\nfunction c.tweaks() end",
        "---@type World\nWorld = {}",
        "---@type Wraith\nWraith = {}",
    });
    try testing.expect(std.mem.indexOf(u8, text, "Wraith.VfsClass") == null);
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
        "do\n---@class Freecam\n---@field Camera Freecam.CameraClass\nlocal c = {}\n\n---The one scripts are given.\n---@return Freecam.Camera\nfunction c.camera() end",
        "do\n---@class Freecam.CameraClass\nlocal c = {}\n\n---The one scripts are given.\n---@return Freecam.Camera\nfunction c.instance() end",
        "---The one scripts are given.\n---@return Pad\nfunction pad() end",
        "---@type PadClass\nPad = {}",
        "---@type Freecam\nFreecam = {}",
    });
    try testing.expect(std.mem.indexOf(u8, text, "OtherClass") == null);
}

test "Names give what the typings declare" {
    const make = struct {
        fn make(a: std.mem.Allocator, s: Schema) anyerror!Names {
            return .init(a, s);
        }
    }.make;
    try lang.expectNames(Names, make, .{
        .method = "count(who: string): integer",
        .field = "hp: integer",
        .function = "heal(amount: integer): boolean",
        .static = "instance: G.Player|nil",
        .constant = null,
    });
}
