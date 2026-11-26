//! Calling and implementing traits from a schema parsed at runtime, through memory laid out like `rt.Abi`.
//! Tables made here find the object's record through `this`, so static methods can't be implemented.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const rt = @import("salamander_runtime");
const dyn = @import("salamander_dyn");

pub const abi = @import("abi.zig");

const Schema = salamander_schema.Schema;
const plan = salamander_schema.plan;

/// Most methods a table made here can have. Calls aren't limited, but a script's impl misses methods past this.
pub const max_slots = 64;

/// A trait's methods, worked out from its schema. In the host's memory like everything tables point at.
pub const Trait = struct {
    info: *const rt.Info,
    /// In table order. Null for ones that can't cross, which are missing from tables made here.
    methods: []const ?abi.Lowered,
    /// Static ones can't be implemented here, since entries find their object through `this`.
    static: []const bool,

    pub const Error = error{ OutOfMemory, TooManyMethods };

    pub fn init(host: rt.Host, s: Schema, t: *const Schema.Trait) Error!*const Trait {
        var buf: [plan.max_methods]*const Schema.Method = undefined;
        const ms = plan.methods(s, t, &buf);
        if (ms.len == plan.max_methods) return error.TooManyMethods;
        const methods = try host.keep(?abi.Lowered, ms.len);
        const static = try host.keep(bool, ms.len);
        const infos = try host.keep(rt.MethodInfo, ms.len);
        for (ms, 0..) |m, i| {
            methods[i] = abi.lower(s, m.signature, m.static, m.async) catch null;
            static[i] = m.static;
            infos[i] = .{ .name = .init(try keepText(host, m.name)), .sig = Schema.methodHash(m) };
        }
        const info = &(try host.keep(rt.Info, 1))[0];
        info.* = .{ .hash = s.traitHash(t), .name = .init(try keepText(host, t.name)), .methods = .{ .ptr = infos.ptr, .len = ms.len } };
        const out = &(try host.keep(Trait, 1))[0];
        out.* = .{ .info = info, .methods = methods, .static = static };
        return out;
    }

    /// A method's slot, by name.
    pub fn find(self: *const Trait, name: []const u8) ?usize {
        for (self.info.methods.get(), 0..) |m, i| if (std.mem.eql(u8, m.name.get(), name)) return i;
        return null;
    }
};

fn keepText(host: rt.Host, text: []const u8) error{OutOfMemory}![]const u8 {
    const out = try host.keep(u8, text.len);
    @memcpy(out, text);
    return out;
}

/// Room for copies of arguments on the way in or out.
const Scratch = struct {
    buf: [4096]u8 align(16) = undefined,
    used: usize = 0,

    fn alloc(self: *Scratch, size: usize, alignment: usize) ?[*]u8 {
        const at = std.mem.alignForward(usize, self.used, @max(alignment, 8));
        if (at + size > self.buf.len) return null;
        self.used = at + @max(size, 8);
        @memset(self.buf[at .. at + @max(size, 8)], 0);
        return self.buf[at..].ptr;
    }
};

/// A plain function's lowered type, for calling or detouring it. Kept in the host's memory.
pub const Function = struct {
    lowered: abi.Lowered,
    /// The same as a `fn` value's with this signature, so one can be checked against it.
    hash: u64,

    pub const Error = error{ OutOfMemory, Unsupported };

    pub fn init(host: rt.Host, s: Schema, sig: Schema.Signature) Error!*const Function {
        const out = &(try host.keep(Function, 1))[0];
        out.* = .{
            .lowered = abi.lower(s, sig, true, false) catch return error.Unsupported,
            .hash = Schema.signatureHash(sig),
        };
        return out;
    }
};

/// Calls the native function at `address`, the way `call` calls a method.
pub fn callAt(f: *const Function, address: usize, args: []const [*]const u8, value: [*]u8) u32 {
    return invoke(&f.lowered, address, null, args, value);
}

/// What calls through a `Detour` go to.
pub const FnRecord = struct {
    function: *const Function,
    ctx: usize,
    /// Called with method 0.
    dispatch: Dispatch,
};

/// One entry for calls to functions of any type, each sent to whatever `find` gives, like a hook engine's current hook.
pub fn Detour(comptime find: fn () *const FnRecord) type {
    return struct {
        pub fn address() usize {
            return @intFromPtr(&Inner.entry);
        }

        const Inner = dyn.Detour(struct {
            fn handler(frame: *dyn.Frame) callconv(.c) void {
                const r = find();
                handle(frame, &r.function.lowered, r.ctx, r.dispatch, 0);
            }
        }.handler);
    };
}

/// Most native functions `function` makes, for the whole process.
pub const max_functions = 256;

var function_records: [max_functions]FnRecord = undefined;
var functions_made: std.atomic.Value(u32) = .init(0);

/// A native function of `f`'s type whose calls all go to `dispatch` as method 0. Never freed, so make one per function.
pub fn function(f: *const Function, ctx: usize, dispatch: Dispatch) error{TooManyFunctions}!usize {
    const n = functions_made.fetchAdd(1, .monotonic);
    if (n >= max_functions) return error.TooManyFunctions;
    function_records[n] = .{ .function = f, .ctx = ctx, .dispatch = dispatch };
    return functionAddress(n);
}

fn functionAddress(n: usize) usize {
    @setEvalBranchQuota(100_000);
    inline for (0..max_functions) |i| if (i == n) return @intFromPtr(&FunctionEntry(i).entry);
    unreachable;
}

fn FunctionEntry(comptime n: usize) type {
    @setEvalBranchQuota(10_000);
    return dyn.Detour(struct {
        fn handler(frame: *dyn.Frame) callconv(.c) void {
            const r = &function_records[n];
            handle(frame, &r.function.lowered, r.ctx, r.dispatch, 0);
        }
    }.handler);
}

/// Calls slot `i` of `obj`, a `t`, with `args[k]` pointing at argument k and the value written to `value`.
/// Gives a result's code, or 0. A missing method gives zero or `Unsupported`, a closed owner zero or `Gone`.
pub fn call(t: *const Trait, obj: rt.AnyObject, i: usize, args: []const [*]const u8, value: [*]u8) u32 {
    const l = &(t.methods[i] orelse return missing(null, rt.unsupported_code, value));
    const tab = obj.table orelse return missing(l, rt.gone_code, value);
    const entries: [*]const usize = @ptrCast(@alignCast(tab));
    const entry = entries[2 + i];
    if (entry == 0) return missing(l, rt.unsupported_code, value);
    const owner = rt.headerOf(tab).owner;
    if (owner) |o| if (!o.enter()) return missing(l, rt.gone_code, value);
    defer if (owner) |o| o.leave();
    return invoke(l, entry, obj.data, args, value);
}

fn invoke(l: *const abi.Lowered, entry: usize, this: ?usize, args: []const [*]const u8, value: [*]u8) u32 {
    var scratch: Scratch = .{};
    var raw: [abi.max_params]u64 = @splat(0);
    if (l.this) |at| raw[at] = this orelse 0;
    switch (l.ret) {
        .hidden => |at| raw[at] = @intFromPtr(value),
        else => {},
    }
    if (l.out) |at| raw[at] = @intFromPtr(value);
    for (l.args[0..l.arg_count], l.shapes[0..l.arg_count], args) |pass, shape, arg| switch (pass) {
        .direct => |d| {
            var bits: u64 = 0;
            @memcpy(std.mem.asBytes(&bits)[0..d.size], arg[0..d.size]);
            if (d.signed and d.size < 8) {
                const shift: u6 = @intCast(64 - @as(usize, d.size) * 8);
                bits = @bitCast(@as(i64, @bitCast(bits << shift)) >> shift);
            }
            raw[d.index] = bits;
        },
        // The callee can change its copy, so it gets one
        .by_ref => |at| {
            const copy = scratch.alloc(shape.size, shape.alignment) orelse return missing(l, rt.unsupported_code, value);
            @memcpy(copy[0..shape.size], arg[0..shape.size]);
            raw[at] = @intFromPtr(copy);
        },
        .words => |w| {
            var bytes: [abi.max_params * 8]u8 = @splat(0);
            @memcpy(bytes[0..shape.size], arg[0..shape.size]);
            for (0..w.count) |k| {
                var bits: u64 = 0;
                @memcpy(std.mem.asBytes(&bits)[0..w.size], bytes[k * w.size ..][0..w.size]);
                raw[w.index + k] = bits;
            }
        },
    };
    var results: [dyn.max_results]u64 = @splat(0);
    dyn.callAll(entry, l.signature(), raw[0..l.len], &results);
    if (l.result) return @truncate(results[0]);
    switch (l.ret) {
        .direct => |n| @memcpy(value[0..n], std.mem.asBytes(&results[0])[0..n]),
        .parts => |p| for (0..p.count) |k| {
            const at = k * p.size;
            const n = @min(p.size, l.value.size -| at);
            @memcpy(value[at..][0..n], std.mem.asBytes(&results[k])[0..n]);
        },
        else => {},
    }
    return 0;
}

fn missing(l: ?*const abi.Lowered, code: u32, value: [*]u8) u32 {
    const lowered = l orelse return code;
    @memset(value[0..lowered.value.size], 0);
    return if (lowered.result) code else 0;
}

/// Gets slot `method`'s arguments as pointers and writes the value to `value`. Returns a result's code.
pub const Dispatch = *const fn (ctx: usize, method: u32, args: []const [*]u8, value: [*]u8) u32;

/// What an object made here points at. Keep it till the table's owner is drained, since calls can come in till then.
pub const Record = struct {
    trait: *const Trait,
    ctx: usize,
    dispatch: Dispatch,
};

/// A table for `t` that dispatches through each object's record. One serves every `t` object `owner` guards.
pub fn table(host: rt.Host, t: *const Trait, owner: ?*rt.Owner) error{OutOfMemory}!*const anyopaque {
    const n = t.methods.len;
    const out = try host.keep(usize, n + 2);
    out[0] = @intFromPtr(t.info);
    out[1] = @intFromPtr(owner);
    for (t.methods, t.static, 0..) |m, static, i| {
        out[i + 2] = if (m == null or static or i >= max_slots) 0 else entryAddress(m.?.this_place, i);
    }
    return out.ptr;
}

/// An object of `t` whose methods all go to `dispatch` with `ctx`, guarded by `owner`. For many objects, share a `table`.
pub fn implement(host: rt.Host, t: *const Trait, ctx: usize, dispatch: Dispatch, owner: ?*rt.Owner) error{OutOfMemory}!rt.AnyObject {
    const record = &(try host.keep(Record, 1))[0];
    record.* = .{ .trait = t, .ctx = ctx, .dispatch = dispatch };
    return .{ .data = @intFromPtr(record), .table = try table(host, t, owner) };
}

const places: []const dyn.Place = if (@bitSizeOf(usize) == 32) &.{ .reg0, .stack0, .stack1 } else &.{ .reg0, .reg1 };

fn entryAddress(place: dyn.Place, slot: usize) usize {
    @setEvalBranchQuota(100_000);
    inline for (places) |p| if (p == place) {
        inline for (0..max_slots) |n| if (n == slot) return @intFromPtr(&Entry(p, n).entry);
    };
    unreachable;
}

fn Entry(comptime place: dyn.Place, comptime slot: usize) type {
    @setEvalBranchQuota(10_000);
    return dyn.Detour(struct {
        fn handler(frame: *dyn.Frame) callconv(.c) void {
            enter(frame, place, slot);
        }
    }.handler);
}

fn enter(frame: *dyn.Frame, place: dyn.Place, slot: usize) void {
    const record: *const Record = @ptrFromInt(dyn.word(frame, place));
    handle(frame, &record.trait.methods[slot].?, record.ctx, record.dispatch, slot);
}

fn handle(frame: *dyn.Frame, l: *const abi.Lowered, ctx: usize, dispatch: Dispatch, slot: usize) void {
    var raw: [abi.max_params]u64 = undefined;
    dyn.args(frame, l.signature(), raw[0..l.len]);

    var scratch: Scratch = .{};
    var ptrs: [abi.max_args][*]u8 = undefined;
    for (l.args[0..l.arg_count], l.shapes[0..l.arg_count], 0..) |pass, shape, k| ptrs[k] = switch (pass) {
        .direct => |d| blk: {
            const at = scratch.alloc(8, 8).?;
            @memcpy(at[0..d.size], std.mem.asBytes(&raw[d.index])[0..d.size]);
            break :blk at;
        },
        .by_ref => |at| @ptrFromInt(@as(usize, @truncate(raw[at]))),
        .words => |w| blk: {
            const at = scratch.alloc(@as(usize, w.count) * w.size, @max(shape.alignment, 8)).?;
            for (0..w.count) |j| @memcpy(at[j * w.size ..][0..w.size], std.mem.asBytes(&raw[w.index + j])[0..w.size]);
            break :blk at;
        },
    };
    const value: [*]u8 = switch (l.ret) {
        .hidden => |at| @ptrFromInt(@as(usize, @truncate(raw[at]))),
        else => if (l.out) |at| @ptrFromInt(@as(usize, @truncate(raw[at]))) else scratch.alloc(l.value.size, l.value.alignment).?,
    };
    @memset(value[0..l.value.size], 0);
    const code = dispatch(ctx, @intCast(slot), ptrs[0..l.arg_count], value);
    var bits: [dyn.max_results]u64 = @splat(0);
    if (l.result) bits[0] = code else switch (l.ret) {
        .none => {},
        .direct => |n| @memcpy(std.mem.asBytes(&bits[0])[0..n], value[0..n]),
        .hidden => |at| bits[0] = raw[at],
        .parts => |p| for (0..p.count) |k| {
            const at = k * p.size;
            const n = @min(p.size, l.value.size -| at);
            @memcpy(std.mem.asBytes(&bits[k])[0..n], value[at..][0..n]);
        },
    }
    dyn.setReturns(frame, l.signature(), &bits);
}

test {
    _ = @import("tests.zig");
}
