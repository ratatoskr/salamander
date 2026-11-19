//! How a schema method's arguments cross the C ABI, worked out at runtime, for traits only known from a parsed
//! schema. Memory is laid out like `rt.Abi`, and this says how it travels, in registers, by reference or over stack words.
//!
//! Windows x64 passes 1, 2, 4 and 8 byte aggregates in a register, others by reference, and returns bigger
//! ones through a hidden pointer. SysV x64 splits ones up to 16 bytes into eightbytes, int or float by what's
//! in them, and passes bigger ones or ones that don't fit on the stack. It returns them the same way or through
//! a hidden pointer. x86 passes them on the stack. Windows returns 1, 2, 4 and 8 byte ones in EAX:EDX, Linux
//! returns all of them through a hidden pointer. aarch64 passes up to four floats of one type in float registers,
//! others up to 16 bytes in int registers and bigger ones by reference. It returns them the same way or through X8.

const std = @import("std");
const builtin = @import("builtin");
const salamander_schema = @import("salamander_schema");
const dyn = @import("salamander_dyn");

const Schema = salamander_schema.Schema;
const Ref = Schema.Ref;

const x86 = builtin.cpu.arch == .x86;
const Rules = enum { win64, sysv64, x86_win, x86_linux, aapcs64 };
const rules: Rules = switch (dyn.abi) {
    .win64 => .win64,
    .sysv64 => .sysv64,
    .x86 => if (builtin.os.tag == .windows) .x86_win else .x86_linux,
    .aapcs64, .apple64 => .aapcs64,
};

pub const max_args = 16;
pub const max_params = dyn.max_params;

/// How something sits in memory as it crosses.
pub const Shape = struct {
    size: usize,
    alignment: usize,
};

/// A parameter or result's memory, the same as Zig's `rt.Abi` of its type.
pub fn shapeOf(s: Schema, r: Ref) Shape {
    const ps = s.pointer_size;
    const word: Shape = .{ .size = ps, .alignment = ps };
    const fat: Shape = .{ .size = 2 * @as(usize, ps), .alignment = ps };
    return switch (r) {
        .prim => |p| if (p == .void) .{ .size = 0, .alignment = 1 } else .{ .size = p.size(ps), .alignment = p.alignment(ps) },
        .named => |n| if (s.findType(n)) |t| switch (t.kind) {
            .func => fat,
            .@"error", .@"opaque" => unreachable,
            else => .{ .size = t.size, .alignment = t.alignment },
        } else fat,
        .pointer => word,
        .slice, .func => fat,
        .optional => |c| if (c.* == .pointer) word else if (s.isObject(c.*)) fat else blk: {
            // `{value, some}`, like `rt.Opt`
            const inner = shapeOf(s, c.*);
            break :blk .{ .size = std.mem.alignForward(usize, inner.size + 1, inner.alignment), .alignment = inner.alignment };
        },
        .array, .result => unreachable,
    };
}

/// Ints, floats and pointers go as themselves. Everything else is an aggregate.
pub const Class = union(enum) {
    int: u8,
    float: u8,
    aggregate: Shape,
};

/// Signed ints narrower than a register get sign-extended into it, which clang's callees count on.
fn isSigned(s: Schema, r: Ref) bool {
    const p: Schema.Prim = switch (r) {
        .prim => |p| p,
        .named => |n| if (s.findType(n)) |t| switch (t.kind) {
            .@"enum" => |e| e.backing,
            else => return false,
        } else return false,
        else => return false,
    };
    return p.isSigned();
}

pub fn classOf(s: Schema, r: Ref) Class {
    return switch (r) {
        .prim => |p| switch (p) {
            .f32 => .{ .float = 4 },
            .f64 => .{ .float = 8 },
            .string, .object, .blob, .void => .{ .aggregate = shapeOf(s, r) },
            else => .{ .int = @intCast(p.size(s.pointer_size)) },
        },
        .pointer => .{ .int = s.pointer_size },
        .optional => |c| if (c.* == .pointer) .{ .int = s.pointer_size } else .{ .aggregate = shapeOf(s, r) },
        .named => |n| if (s.findType(n)) |t| switch (t.kind) {
            .@"enum" => |e| .{ .int = @intCast(e.backing.size(s.pointer_size)) },
            .bitfield => |b| .{ .int = @intCast(b.backing.size(s.pointer_size)) },
            else => .{ .aggregate = shapeOf(s, r) },
        } else .{ .aggregate = shapeOf(s, r) },
        else => .{ .aggregate = shapeOf(s, r) },
    };
}

fn intType(size: usize) ?dyn.Type {
    return switch (size) {
        1 => .i8,
        2 => .i16,
        4 => .i32,
        8 => .i64,
        else => null,
    };
}

/// How one argument travels.
pub const Pass = union(enum) {
    /// In one parameter, as its bits. A small aggregate's bytes are an int.
    direct: Direct,
    /// A pointer to a copy of it. x64's way for big aggregates.
    by_ref: u8,
    /// Its bytes split over parameters, `size` each: stack words on x86 and for what didn't fit in
    /// registers, SysV x64's eightbytes, or aarch64's floats one per register.
    words: Words,

    pub const Direct = struct {
        index: u8,
        size: u8,
        signed: bool = false,
    };

    pub const Words = struct {
        index: u8,
        count: u8,
        size: u8,
    };
};

pub const Return = union(enum) {
    none,
    /// In RAX, EAX:EDX or a float register, this many bytes of it.
    direct: u8,
    /// Through a hidden pointer, the parameter at this index, which is returned too.
    hidden: u8,
    /// Its bytes over the result registers, `size` each, like SysV x64's two eightbytes.
    parts: Parts,

    pub const Parts = struct {
        count: u8,
        size: u8,
    };
};

pub const Error = error{Unsupported};

/// A method's C ABI, worked out from its schema signature.
pub const Lowered = struct {
    params: [max_params]dyn.Type = undefined,
    len: u8 = 0,
    conv: dyn.Conv = .cdecl,
    ret_type: dyn.Type = .void,
    ret_more: [dyn.max_results - 1]dyn.Type = undefined,
    ret_more_len: u8 = 0,
    /// The parameter `this` is in, and where an entry finds it before knowing anything else.
    this: ?u8 = null,
    this_place: dyn.Place = .reg0,
    args: [max_args]Pass = undefined,
    shapes: [max_args]Shape = undefined,
    arg_count: u8 = 0,
    /// The value's memory. The return, the hidden pointer's target, or a result's out param's.
    value: Shape = .{ .size = 0, .alignment = 1 },
    ret: Return = .none,
    /// `T!E`: returns a code, with the value through the last parameter when it has one.
    result: bool = false,
    out: ?u8 = null,

    pub fn signature(self: *const Lowered) dyn.Signature {
        return .{ .params = self.params[0..self.len], .ret = self.ret_type, .ret_more = self.ret_more[0..self.ret_more_len], .conv = self.conv };
    }

    fn add(self: *Lowered, t: dyn.Type) Error!u8 {
        if (self.len == max_params) return error.Unsupported;
        self.params[self.len] = t;
        self.len += 1;
        return self.len - 1;
    }

    /// `size` bytes over `t`s of `each` bytes.
    fn words(self: *Lowered, t: dyn.Type, size: usize, each: u8) Error!Pass {
        const n = (size + each - 1) / each;
        if (self.len + n > max_params) return error.Unsupported;
        const count: u8 = @intCast(n);
        const first = self.len;
        for (0..count) |_| _ = try self.add(t);
        return .{ .words = .{ .index = first, .count = count, .size = each } };
    }

    fn parts(self: *Lowered, split: Split) Error!Pass {
        const first = self.len;
        for (split.types[0..split.count]) |t| _ = try self.add(t);
        return .{ .words = .{ .index = first, .count = split.count, .size = split.size } };
    }
};

fn dynConv(c: Schema.Conv) dyn.Conv {
    return switch (c) {
        .c, .cdecl => .cdecl,
        .stdcall, .winapi => .stdcall,
        .thiscall => .thiscall,
        .fastcall => .fastcall,
    };
}

/// What an `async` method returns, a `core.Promise`, two words.
const promise_ref: Ref = .{ .prim = .object };

/// A scalar inside an aggregate, at its offset.
const Leaf = struct {
    offset: usize,
    size: usize,
    float: bool,
};

const max_leaves = 32;

const Leaves = struct {
    list: [max_leaves]Leaf = undefined,
    len: usize = 0,
    /// Too many to say, so it's neither in registers nor a float group.
    full: bool = false,

    fn add(self: *Leaves, leaf: Leaf) void {
        if (self.len == max_leaves) {
            self.full = true;
            return;
        }
        self.list[self.len] = leaf;
        self.len += 1;
    }

    fn all(self: *const Leaves) []const Leaf {
        return self.list[0..self.len];
    }
};

/// Every scalar in `r`'s memory, laid out like `shapeOf`.
fn leavesOf(s: Schema, r: Ref, base: usize, out: *Leaves, depth: usize) void {
    if (depth > 16) {
        out.full = true;
        return;
    }
    const ps: usize = s.pointer_size;
    switch (r) {
        .prim => |p| switch (p) {
            .void => {},
            .f32, .f64 => out.add(.{ .offset = base, .size = p.size(s.pointer_size), .float = true }),
            .string, .object, .blob => {
                out.add(.{ .offset = base, .size = ps, .float = false });
                out.add(.{ .offset = base + ps, .size = ps, .float = false });
            },
            else => out.add(.{ .offset = base, .size = p.size(s.pointer_size), .float = false }),
        },
        .pointer => out.add(.{ .offset = base, .size = ps, .float = false }),
        .slice, .func => {
            out.add(.{ .offset = base, .size = ps, .float = false });
            out.add(.{ .offset = base + ps, .size = ps, .float = false });
        },
        .optional => |c| if (c.* == .pointer) {
            out.add(.{ .offset = base, .size = ps, .float = false });
        } else if (s.isObject(c.*)) {
            leavesOf(s, .{ .prim = .object }, base, out, depth + 1);
        } else {
            leavesOf(s, c.*, base, out, depth + 1);
            out.add(.{ .offset = base + shapeOf(s, c.*).size, .size = 1, .float = false });
        },
        .array => |a| {
            const each = shapeOf(s, a.child.*).size;
            for (0..a.len) |k| {
                if (out.full) return;
                leavesOf(s, a.child.*, base + k * each, out, depth + 1);
            }
        },
        .named => |n| {
            const t = s.findType(n) orelse return leavesOf(s, .{ .prim = .object }, base, out, depth + 1);
            switch (t.kind) {
                .@"struct", .@"union" => {
                    var at: ?*const Schema.Type = t;
                    while (at) |cur| : (at = s.baseOf(cur)) {
                        const st = switch (cur.kind) {
                            .@"struct", .@"union" => |st| st,
                            else => break,
                        };
                        for (st.fields) |f| leavesOf(s, f.type, base + f.offset, out, depth + 1);
                        if (cur.kind != .@"struct") break;
                    }
                },
                .@"enum" => |e| out.add(.{ .offset = base, .size = e.backing.size(s.pointer_size), .float = false }),
                .bitfield => |b| out.add(.{ .offset = base, .size = b.backing.size(s.pointer_size), .float = false }),
                .func => leavesOf(s, .{ .prim = .object }, base, out, depth + 1),
                .@"error", .@"opaque" => out.full = true,
            }
        },
        .result => out.full = true,
    }
}

/// How an aggregate goes in registers, each part's type, `size` bytes each. Null if it doesn't,
/// like one bigger than 16 bytes on SysV x64.
const Split = struct {
    types: [4]dyn.Type = undefined,
    count: u8 = 0,
    size: u8 = 8,
    /// aarch64's float group, which takes float registers one member each.
    floats: bool = false,

    fn ints(self: Split) usize {
        var n: usize = 0;
        for (self.types[0..self.count]) |t| n += @intFromBool(!t.isFloat());
        return n;
    }

    fn floatCount(self: Split) usize {
        return self.count - self.ints();
    }
};

fn splitOf(s: Schema, r: Ref, shape: Shape) ?Split {
    var leaves: Leaves = .{};
    leavesOf(s, r, 0, &leaves, 0);
    if (leaves.full or shape.size == 0) return null;
    switch (rules) {
        .sysv64 => {
            if (shape.size > 16) return null;
            var out: Split = .{ .count = @intCast((shape.size + 7) / 8) };
            for (0..out.count) |k| {
                // An eightbyte is a float one only if everything in it is a float
                var float = true;
                for (leaves.all()) |l| {
                    if (l.offset < (k + 1) * 8 and l.offset + l.size > k * 8 and !l.float) float = false;
                    if (l.offset % @max(l.size, 1) != 0) return null;
                }
                out.types[k] = if (float) .f64 else .i64;
            }
            return out;
        },
        .aapcs64 => {
            // Up to four floats of one size, back to back, are a float group
            const all = leaves.all();
            if (all.len >= 1 and all.len <= 4) group: {
                const size = all[0].size;
                for (all, 0..) |l, k| if (!l.float or l.size != size or l.offset != k * size) break :group;
                if (shape.size != all.len * size) break :group;
                var out: Split = .{ .count = @intCast(all.len), .size = @intCast(size), .floats = true };
                for (0..all.len) |k| out.types[k] = if (size == 4) .f32 else .f64;
                return out;
            }
            if (shape.size > 16) return null;
            var out: Split = .{ .count = @intCast((shape.size + 7) / 8) };
            for (0..out.count) |k| out.types[k] = .i64;
            return out;
        },
        else => return null,
    }
}

/// Registers given out so far, to tell whether an aggregate still fits, the way `dyn` will place it.
const Used = struct {
    ints: usize = 0,
    floats: usize = 0,

    const int_regs: usize = switch (rules) {
        .sysv64 => 6,
        .aapcs64 => 8,
        else => 0,
    };
    const float_regs: usize = 8;

    fn take(self: *Used, t: dyn.Type) void {
        if (t == .sret and rules == .aapcs64) return;
        if (t.isInt()) self.ints += 1;
        if (t.isFloat()) self.floats += 1;
    }

    fn fits(self: Used, split: Split) bool {
        return self.ints + split.ints() <= int_regs and self.floats + split.floatCount() <= float_regs;
    }
};

pub fn lower(s: Schema, sig: Schema.Signature, static: bool, is_async: bool) Error!Lowered {
    var l: Lowered = .{ .conv = if (x86) dynConv(sig.conv) else .cdecl };
    if (sig.params.len > max_args) return error.Unsupported;
    // Microsoft's x64 ABI, which these rules don't do
    if (rules == .sysv64 and sig.conv == .winapi) return error.Unsupported;

    // What comes back, and whether it needs a hidden pointer
    var hidden = false;
    if (is_async) {
        l.value = shapeOf(s, promise_ref);
    } else switch (sig.ret) {
        .result => |res| {
            l.result = true;
            l.ret_type = .i32;
            l.ret = .{ .direct = 4 };
            if (!(res.ok.* == .prim and res.ok.prim == .void)) l.value = shapeOf(s, res.ok.*);
        },
        .prim => |p| if (p != .void) {
            l.value = shapeOf(s, sig.ret);
        },
        else => l.value = shapeOf(s, sig.ret),
    }
    if (!l.result and l.value.size > 0) {
        const class = if (is_async) Class{ .aggregate = l.value } else classOf(s, sig.ret);
        switch (class) {
            .int => |n| {
                l.ret_type = intType(n).?;
                l.ret = .{ .direct = n };
            },
            .float => |n| {
                l.ret_type = if (n == 4) .f32 else .f64;
                l.ret = .{ .direct = n };
            },
            .aggregate => |a| switch (rules) {
                .win64, .x86_win => if (intType(a.size)) |t| {
                    l.ret_type = t;
                    l.ret = .{ .direct = @intCast(a.size) };
                } else {
                    hidden = true;
                },
                .x86_linux => hidden = true,
                .sysv64, .aapcs64 => if (splitOf(s, if (is_async) promise_ref else sig.ret, a)) |split| {
                    l.ret_type = split.types[0];
                    for (split.types[1..split.count], 0..) |t, k| l.ret_more[k] = t;
                    l.ret_more_len = split.count - 1;
                    l.ret = .{ .parts = .{ .count = split.count, .size = split.size } };
                } else {
                    hidden = true;
                },
            },
        }
    }

    var used: Used = .{};
    // The hidden pointer always goes first, as LLVM and clang do for plain functions. So on x86 it takes ECX
    // from a thiscall's `this`, unlike C++ member functions under MSVC. On aarch64 it's in X8 instead.
    if (hidden) {
        l.ret = .{ .hidden = try l.add(.sret) };
        l.ret_type = dyn.Type.ptr;
        used.take(.sret);
    }
    if (!static) {
        l.this = try l.add(dyn.Type.ptr);
        used.take(dyn.Type.ptr);
    }
    if (l.this) |i| l.this_place = if (!x86)
        (if (i == 0 or rules == .aapcs64) .reg0 else .reg1)
    else switch (l.conv) {
        // Unless the hidden pointer takes ECX, `this` does
        .thiscall => if (i == 0 or !dyn.sretInRegister(l.conv)) .reg0 else .stack0,
        .fastcall => .reg0,
        .cdecl, .stdcall => if (i == 0) .stack0 else .stack1,
    };

    for (sig.params, 0..) |p, i| {
        const shape = shapeOf(s, p.type);
        l.shapes[i] = shape;
        l.args[i] = switch (classOf(s, p.type)) {
            .int => |n| blk: {
                used.take(.i64);
                break :blk .{ .direct = .{ .index = try l.add(intType(n).?), .size = n, .signed = isSigned(s, p.type) } };
            },
            .float => |n| blk: {
                used.take(.f64);
                break :blk .{ .direct = .{ .index = try l.add(if (n == 4) .f32 else .f64), .size = n } };
            },
            .aggregate => |a| switch (rules) {
                .x86_win, .x86_linux => try l.words(.word, a.size, 4),
                .win64 => if (intType(a.size)) |t|
                    .{ .direct = .{ .index = try l.add(t), .size = @intCast(a.size) } }
                else
                    .{ .by_ref = try l.add(dyn.Type.ptr) },
                .sysv64 => if (splitOf(s, p.type, a)) |split| blk: {
                    // All of it in registers or all of it on the stack
                    if (!used.fits(split)) break :blk try l.words(.word, a.size, 8);
                    for (split.types[0..split.count]) |t| used.take(t);
                    break :blk try l.parts(split);
                } else try l.words(.word, a.size, 8),
                .aapcs64 => if (splitOf(s, p.type, a)) |split| blk: {
                    if (used.fits(split)) {
                        for (split.types[0..split.count]) |t| used.take(t);
                        break :blk try l.parts(split);
                    }
                    // What doesn't fit closes its kind of register, for `dyn` too
                    if (split.floats) {
                        used.floats = Used.float_regs;
                        break :blk try l.words(.float_word, a.size, 8);
                    }
                    used.ints = Used.int_regs;
                    break :blk try l.words(.word, a.size, 8);
                } else blk: {
                    used.take(dyn.Type.ptr);
                    break :blk .{ .by_ref = try l.add(dyn.Type.ptr) };
                },
            },
        };
    }
    l.arg_count = @intCast(sig.params.len);
    if (l.result and l.value.size > 0) l.out = try l.add(dyn.Type.ptr);
    dyn.check(l.signature()) catch return error.Unsupported;
    return l;
}
