//! Checks names resolve, impls match their traits and nothing clashes or overlaps.
//! Read only, so it runs at comptime too.

const std = @import("std");

const Schema = @import("Schema.zig");

const Ref = Schema.Ref;

pub const Error = error{InvalidSchema};

/// Trait objects have `data`, `table` and `init`. Anything starting `salamander` is the runtime's.
const reserved_methods = [_][]const u8{ "data", "table", "init" };

pub fn check(s: Schema, source: []const u8, diag: *Schema.Diagnostic) Error!void {
    const c: Checker = .{ .s = s, .source = source, .diag = diag };
    try c.names();
    for (s.types) |*t| try c.typeDef(t);
    for (s.traits) |*t| try c.trait(t);
    for (s.impls, 0..) |*im, i| try c.impl(im, i);
    for (s.constants) |*k| try c.constant(k);
    for (s.functions, 0..) |*f, i| {
        try c.gameMethod(null, f);
        for (s.functions[0..i]) |o| if (std.mem.eql(u8, f.name, o.name)) return c.fail(f.at, "there's already a function named {s}", .{f.name});
        if (c.topLevel(f.name)) return c.fail(f.at, "there's already something named {s}", .{f.name});
    }
    for (s.statics, 0..) |*v, i| {
        try c.gameStatic(null, v);
        for (s.statics[0..i]) |o| if (std.mem.eql(u8, v.name, o.name)) return c.fail(v.at, "there's already a static named {s}", .{v.name});
        for (s.functions) |f| if (std.mem.eql(u8, v.name, f.name)) return c.fail(v.at, "there's already a function named {s}", .{v.name});
        if (c.topLevel(v.name)) return c.fail(v.at, "there's already something named {s}", .{v.name});
    }
}

/// Where a type is used decides what it can be.
const Use = enum {
    /// In memory, a field or an element.
    field,
    param,
    ret,
    pointee,
};

const Checker = struct {
    s: Schema,
    source: []const u8,
    diag: *Schema.Diagnostic,

    fn fail(c: Checker, at: usize, comptime fmt: []const u8, args: anytype) Error {
        return c.diag.fail(c.source, at, fmt, args);
    }

    const Named = struct {
        name: []const u8,
        at: Schema.Pos,
    };

    /// Types, traits and constants share one namespace.
    fn nameAt(c: Checker, i: usize) Named {
        const s = c.s;
        if (i < s.types.len) return .{ .name = s.types[i].name, .at = s.types[i].at };
        if (i < s.types.len + s.traits.len) {
            const t = s.traits[i - s.types.len];
            return .{ .name = t.name, .at = t.at };
        }
        const k = s.constants[i - s.types.len - s.traits.len];
        return .{ .name = k.name, .at = k.at };
    }

    fn names(c: Checker) Error!void {
        const count = c.s.types.len + c.s.traits.len + c.s.constants.len;
        for (0..count) |i| {
            const a = c.nameAt(i);
            for (0..i) |j| if (std.mem.eql(u8, c.nameAt(j).name, a.name)) return c.fail(a.at, "there's already something named {s}", .{a.name});
        }
    }

    fn topLevel(c: Checker, name: []const u8) bool {
        const count = c.s.types.len + c.s.traits.len + c.s.constants.len;
        for (0..count) |i| if (std.mem.eql(u8, c.nameAt(i).name, name)) return true;
        return false;
    }

    /// Existing code's, which has to say where it is.
    fn gameMethod(c: Checker, owner: ?*const Schema.Type, m: *const Schema.Method) Error!void {
        const prefix = if (owner) |o| o.name else "";
        const dot = if (owner != null) "." else "";
        if (m.virtual == null and m.annotations.len == 0)
            return c.fail(m.at, "{s}{s}{s} needs to say where it is, like [Virtual(n)] or a tool's [Sig(\"..\")]", .{ prefix, dot, m.name });
        try c.signature(m.signature, m.at);
    }

    fn gameStatic(c: Checker, owner: ?*const Schema.Type, v: *const Schema.Static) Error!void {
        const prefix = if (owner) |o| o.name else "";
        const dot = if (owner != null) "." else "";
        if (v.annotations.len == 0) return c.fail(v.at, "{s}{s}{s} needs to say where it is, like a tool's [Sig(\"..\")]", .{ prefix, dot, v.name });
        try c.ref(v.type, .field, v.at);
    }

    fn ref(c: Checker, r: Ref, use: Use, at: usize) Error!void {
        switch (r) {
            .prim => |p| if (p == .void and use != .ret and use != .pointee)
                return c.fail(at, "void is only for returns and pointers, like void*", .{}),
            .named => |n| {
                if (c.s.findType(n)) |t| {
                    if (t.kind == .@"error") return c.fail(at, "{s} is an error set, so it goes after a '!', like 'T!{s}'", .{ n, n });
                    if (t.kind == .@"opaque" and use != .pointee) return c.fail(at, "{s} is opaque, so it only goes behind a pointer, like {s}*", .{ n, n });
                } else if (c.s.findTrait(n) == null) {
                    return c.fail(at, "there's no type or trait named {s}", .{n});
                }
            },
            .pointer => |child| try c.ref(child.*, .pointee, at),
            .array => |a| {
                if (a.count) |n| return c.fail(at, "an array as long as {s} only goes on a struct's field, next to {s}", .{ n, n });
                if (a.len == 0) return c.fail(at, "an array needs at least one item", .{});
                if (use == .param or use == .ret) return c.fail(at, "C can't pass an array by value. Put it in a struct, or pass a pointer", .{});
                try c.ref(a.child.*, .field, at);
            },
            .slice => |child| try c.ref(child.*, .field, at),
            .optional => |child| {
                switch (child.*) {
                    .optional => return c.fail(at, "?? doesn't mean anything more than ?", .{}),
                    .prim => |p| if (p == .cstring) return c.fail(at, "a cstring can already be null", .{}),
                    .result => return c.fail(at, "an optional result is written '?T!E'", .{}),
                    else => {},
                }
                if (use == .field or use == .pointee) {
                    const nullable = child.* == .pointer or c.s.isObject(child.*);
                    if (!nullable) return c.fail(at, "in memory, ? only goes on pointers, traits and fn types. Use a bool next to it", .{});
                }
                try c.ref(child.*, if (use == .ret) .param else use, at);
            },
            .result => |res| {
                if (use != .ret) return c.fail(at, "a result like 'T!E' is only for returns", .{});
                const t = c.s.findType(res.err);
                if (t == null or t.?.kind != .@"error") return c.fail(at, "{s} isn't an error set", .{res.err});
                try c.ref(res.ok.*, .ret, at);
            },
            .func => |sig| try c.signature(sig.*, at),
        }
    }

    fn signature(c: Checker, sig: Schema.Signature, at: usize) Error!void {
        for (sig.params, 0..) |p, i| {
            const pat = if (p.at != 0) p.at else at;
            for (sig.params[0..i]) |q| if (std.mem.eql(u8, p.name, q.name)) return c.fail(pat, "there's already a parameter named {s}", .{p.name});
            try c.ref(p.type, .param, pat);
            if (p.keep and !c.s.holdsObject(p.type)) return c.fail(pat, "keep is for objects outliving the call, and {s} has none", .{p.name});
            if (p.inoutType()) |t| {
                if (p.keep) return c.fail(pat, "{s} can't be keep and inout", .{p.name});
                if (!c.plainValue(t)) return c.fail(pat, "inout is for numbers, enums, bitfields, structs, unions and arrays of them, not {f}", .{t});
            }
        }
        try c.ref(sig.ret, .ret, at);
    }

    /// Memory with nothing the callee could keep pointing at, so it's fine to write over.
    fn plainValue(c: Checker, r: Schema.Ref) bool {
        return switch (r) {
            .prim => |p| p != .string and p != .object and p != .blob and p != .void and p != .cstring,
            .named => |n| if (c.s.findType(n)) |t| switch (t.kind) {
                .@"struct", .@"union", .@"enum", .bitfield => !c.s.holdsObject(r),
                else => false,
            } else false,
            .array => |a| c.plainValue(a.child.*),
            else => false,
        };
    }

    fn typeDef(c: Checker, t: *const Schema.Type) Error!void {
        switch (t.kind) {
            .@"struct", .@"union" => |st| try c.structDef(t, st),
            .@"enum" => |e| {
                const bits: u16 = @intCast(e.backing.size(c.s.pointer_size) * 8);
                const min: i128 = if (e.backing.isSigned()) -(@as(i128, 1) << @intCast(bits - 1)) else 0;
                const max: i128 = if (e.backing.isSigned()) (@as(i128, 1) << @intCast(bits - 1)) - 1 else (@as(i128, 1) << @intCast(bits)) - 1;
                for (e.values, 0..) |v, i| {
                    if (v.value < min or v.value > max) return c.fail(v.at, "{s}.{s} = {d} doesn't fit in a {t}", .{ t.name, v.name, v.value, e.backing });
                    for (e.values[0..i]) |w| {
                        if (std.mem.eql(u8, v.name, w.name)) return c.fail(v.at, "{s} already has a {s}", .{ t.name, v.name });
                        if (v.value == w.value) return c.fail(v.at, "{s}.{s} and {s}.{s} are both {d}", .{ t.name, w.name, t.name, v.name, v.value });
                    }
                }
            },
            .bitfield => |b| {
                const width: usize = b.backing.size(c.s.pointer_size) * 8;
                for (b.members, 0..) |m, i| {
                    if (@as(usize, m.bit) + m.bits > width) return c.fail(m.at, "{s}.{s} goes past bit {d} of its {t}", .{ t.name, m.name, width, b.backing });
                    switch (m.type) {
                        .@"enum" => |n| {
                            const et = c.s.findType(n);
                            if (et == null or et.?.kind != .@"enum") return c.fail(m.at, "{s}.{s}: {s} isn't an enum", .{ t.name, m.name, n });
                            for (et.?.kind.@"enum".values) |v| if (v.value < 0 or v.value >= @as(i128, 1) << @intCast(m.bits))
                                return c.fail(m.at, "{s}.{s}: {s}.{s} = {d} doesn't fit in {d} bits", .{ t.name, m.name, n, v.name, v.value, m.bits });
                        },
                        else => {},
                    }
                    for (b.members[0..i]) |o| {
                        if (std.mem.eql(u8, m.name, o.name)) return c.fail(m.at, "{s} already has a {s}", .{ t.name, m.name });
                        if (m.bit < o.bit + o.bits and o.bit < m.bit + m.bits) return c.fail(m.at, "{s}.{s} overlaps {s}", .{ t.name, m.name, o.name });
                    }
                }
            },
            .@"opaque" => {},
            .func => |sig| try c.signature(sig, t.at),
            .@"error" => |e| for (e.errors, 0..) |x, i| {
                if (x.code == 0) return c.fail(x.at, "{s}.{s}: 0 means no error, so codes start at 1", .{ t.name, x.name });
                if (x.code >= Schema.cancelled_code) return c.fail(x.at, "{s}.{s}: the top three codes are Cancelled, Unsupported and Gone", .{ t.name, x.name });
                for (Schema.builtin_errors) |b| if (std.mem.eql(u8, x.name, b)) return c.fail(x.at, "{s}.{s}: every result can already fail with {s}", .{ t.name, x.name, b });
                for (e.errors[0..i]) |y| {
                    if (std.mem.eql(u8, x.name, y.name)) return c.fail(x.at, "{s} already has a {s}", .{ t.name, x.name });
                    if (x.code == y.code) return c.fail(x.at, "{s}.{s} and {s}.{s} are both {d}", .{ t.name, y.name, t.name, x.name, x.code });
                }
            },
        }
    }

    fn structDef(c: Checker, t: *const Schema.Type, st: Schema.Struct) Error!void {
        const base_size: usize = if (c.s.baseOf(t)) |b| b.size else 0;
        for (st.fields, 0..) |f, i| {
            if (f.type == .array and f.type.array.count != null) try c.counted(t, f) else try c.ref(f.type, .field, f.at);
            const size = (c.s.memory(f.type) orelse unreachable).size;
            for (st.fields[0..i]) |o| if (std.mem.eql(u8, f.name, o.name)) return c.fail(f.at, "{s} already has a {s}", .{ t.name, f.name });
            if (c.s.baseOf(t)) |b| if (c.s.findField(b, f.name) != null) return c.fail(f.at, "{s}.{s} is already in its base {s}", .{ t.name, f.name, b.name });
            if (t.kind == .@"union") continue;
            if (f.offset < base_size) return c.fail(f.at, "{s}.{s} at 0x{x} is inside its base, which is 0x{x} bytes", .{ t.name, f.name, f.offset, base_size });
            if (f.offset + size > t.size) return c.fail(f.at, "{s}.{s} goes past the end of {s}", .{ t.name, f.name, t.name });
            for (st.fields[0..i]) |o| {
                const osize = (c.s.memory(o.type) orelse unreachable).size;
                if (f.offset < o.offset + osize and o.offset < f.offset + size)
                    return c.fail(f.at, "{s}.{s} at 0x{x} overlaps {s} at 0x{x}", .{ t.name, f.name, f.offset, o.name, o.offset });
            }
        }
        for (st.methods, 0..) |*m, i| {
            try c.gameMethod(t, m);
            if (c.s.findField(t, m.name) != null) return c.fail(m.at, "{s} already has a field {s}", .{ t.name, m.name });
            for (st.methods[0..i]) |o| if (std.mem.eql(u8, m.name, o.name)) return c.fail(m.at, "{s} already has a {s}", .{ t.name, m.name });
        }
        for (st.statics, 0..) |*v, i| {
            try c.gameStatic(t, v);
            if (c.s.findField(t, v.name) != null) return c.fail(v.at, "{s} already has a field {s}", .{ t.name, v.name });
            for (st.methods) |m| if (std.mem.eql(u8, v.name, m.name)) return c.fail(v.at, "{s} already has a {s}", .{ t.name, v.name });
            for (st.statics[0..i]) |o| if (std.mem.eql(u8, v.name, o.name)) return c.fail(v.at, "{s} already has a {s}", .{ t.name, v.name });
        }
    }

    /// `T[count] items;`, where `count` is a whole number in the same struct or its bases.
    fn counted(c: Checker, t: *const Schema.Type, f: Schema.Field) Error!void {
        const a = f.type.array;
        const n = a.count.?;
        const count = c.s.findField(t, n) orelse return c.fail(f.at, "{s} has no field {s} for {s}'s length", .{ t.name, n, f.name });
        const whole = count.type == .prim and count.type.prim.isInt();
        if (!whole) return c.fail(f.at, "{s}.{s} has the length of {s}, so it has to be a whole number", .{ t.name, n, f.name });
        if (std.mem.eql(u8, n, f.name)) return c.fail(f.at, "{s} can't be its own length", .{f.name});
        if (a.child.* == .array and a.child.array.count != null) return c.fail(f.at, "only the outside of {s} can take its length from a field", .{f.name});
        try c.ref(a.child.*, .field, f.at);
    }

    fn trait(c: Checker, t: *const Schema.Trait) Error!void {
        for (t.bases, 0..) |b, i| {
            const base = c.s.findTrait(b) orelse return c.fail(t.at, "{s}'s base {s} isn't a trait", .{ t.name, b });
            for (t.bases[0..i]) |o| if (std.mem.eql(u8, b, o)) return c.fail(t.at, "{s} lists {s} twice", .{ t.name, b });
            if (c.s.extends(base, t)) return c.fail(t.at, "{s}'s bases go in a circle", .{t.name});
        }
        for (t.methods, 0..) |m, i| {
            for (reserved_methods) |r| if (std.mem.eql(u8, m.name, r) or std.mem.startsWith(u8, m.name, "salamander"))
                return c.fail(m.at, "{s}.{s}: objects and tables use that name, so pick another", .{ t.name, m.name });
            for (t.methods[0..i]) |o| if (std.mem.eql(u8, m.name, o.name)) return c.fail(m.at, "{s} already has a {s}", .{ t.name, m.name });
            try c.signature(m.signature, m.at);
        }
        // Each name means one method, wherever it's from
        for (c.s.traits) |*other| {
            if (!c.s.extends(t, other)) continue;
            for (other.methods) |*m| {
                const found = c.s.findMethod(t, m.name).?;
                if (found.method != m) return c.fail(if (found.trait == t) found.method.at else t.at, "{s}: {s}.{s} and {s}.{s} have the same name", .{ t.name, found.trait.name, m.name, other.name, m.name });
            }
        }
    }

    fn impl(c: Checker, im: *const Schema.Impl, index: usize) Error!void {
        const t = c.s.findTrait(im.trait) orelse return c.fail(im.at, "there's no trait named {s}", .{im.trait});
        const ty = c.s.findType(im.@"for") orelse return c.fail(im.at, "there's no type named {s}", .{im.@"for"});
        if (ty.kind != .@"struct" and ty.kind != .@"union") return c.fail(im.at, "{s} isn't a struct, so it can't have an impl", .{ty.name});
        for (c.s.impls[0..index]) |o| if (std.mem.eql(u8, o.trait, im.trait) and std.mem.eql(u8, o.@"for", im.@"for"))
            return c.fail(im.at, "there's already an impl {s} for {s}", .{ im.trait, im.@"for" });

        for (im.items, 0..) |it, i| {
            const found = c.s.findMethod(t, it.method) orelse return c.fail(it.at, "{s} has no method {s}", .{ t.name, it.method });
            const m = found.method;
            for (im.items[0..i]) |o| if (std.mem.eql(u8, it.method, o.method)) return c.fail(it.at, "{s} is already in this impl", .{it.method});
            switch (it.source) {
                .virtual => if (m.static) return c.fail(it.at, "{s} is static, so it has no vtable slot", .{it.method}),
                .external => {},
                .field => |path| {
                    if (m.static or m.async) return c.fail(it.at, "{s} is {s}, so it can't be a field", .{ it.method, if (m.static) "static" else "async" });
                    const f = c.s.fieldPath(ty, path) orelse return c.fail(it.at, "{s} has no field {s}", .{ ty.name, path });
                    const sig = m.signature;
                    const getter = sig.params.len == 0 and sig.ret.eql(f.type);
                    const setter = sig.params.len == 1 and sig.params[0].type.eql(f.type) and sig.ret.eql(.{ .prim = .void });
                    if (!getter and !setter) return c.fail(it.at, "{s} isn't a getter or setter of {s}, a {f}", .{ it.method, path, f.type });
                },
                .alias => |target| {
                    if (std.mem.eql(u8, target, it.method)) return c.fail(it.at, "{s} can't be itself", .{it.method});
                    const other = c.s.findMethod(t, target) orelse return c.fail(it.at, "{s} has no method {s}", .{ t.name, target });
                    if (other.method.static != m.static or !other.method.signature.eql(m.signature))
                        return c.fail(it.at, "{s} and {s} have different signatures", .{ it.method, target });
                    const target_item = for (im.items) |o| {
                        if (std.mem.eql(u8, o.method, target)) break o;
                    } else return c.fail(it.at, "{s} isn't in this impl", .{target});
                    if (target_item.source == .alias) return c.fail(it.at, "{s} is itself '= fn', so point at {s}", .{ target, target_item.source.alias });
                },
            }
        }
    }

    fn constant(c: Checker, k: *const Schema.Constant) Error!void {
        const prim = switch (k.type) {
            .prim => |p| p,
            else => return c.fail(k.at, "{s}: a constant is a number, a bool or a string", .{k.name}),
        };
        const ok = switch (k.value) {
            .int => |n| blk: {
                if (prim.isFloat()) break :blk true;
                if (!prim.isInt()) break :blk false;
                const bits: u16 = @intCast(prim.size(c.s.pointer_size) * 8);
                const min: i128 = if (prim.isSigned()) -(@as(i128, 1) << @intCast(bits - 1)) else 0;
                const max: i128 = if (prim.isSigned()) (@as(i128, 1) << @intCast(bits - 1)) - 1 else (@as(i128, 1) << @intCast(bits)) - 1;
                if (n < min or n > max) return c.fail(k.at, "{s} = {d} doesn't fit in a {t}", .{ k.name, n, prim });
                break :blk true;
            },
            .float => prim.isFloat(),
            .bool => prim == .bool,
            .string => prim == .string,
        };
        if (!ok) return c.fail(k.at, "{s} is a {t}, so it can't be {t}", .{ k.name, prim, k.value });
    }
};
