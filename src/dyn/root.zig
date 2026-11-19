//! Calls and detours for signatures only known at runtime. Args are raw bits in a `u64`.
//! Windows x64 and x86, SysV x64 on Linux and macOS, x86 Linux, and aarch64 on Windows, Linux and macOS.

const std = @import("std");

const builtin = @import("builtin");

pub const Abi = enum {
    win64,
    sysv64,
    /// Windows' and Linux's are the same but for big results, see `bind`.
    x86,
    aapcs64,
    /// Apple's packs stack args to their own size.
    apple64,
};

pub const abi: Abi = switch (builtin.cpu.arch) {
    .x86_64 => if (builtin.os.tag == .windows) .win64 else .sysv64,
    .x86 => .x86,
    .aarch64 => if (builtin.os.tag.isDarwin()) .apple64 else .aapcs64,
    else => @compileError("salamander's dyn is x86, x64 and aarch64 only"),
};

const backend = switch (abi) {
    .win64 => @import("x64.zig"),
    .sysv64 => @import("sysv64.zig"),
    .x86 => @import("x86.zig"),
    .aapcs64, .apple64 => @import("aarch64.zig"),
};

/// What C symbols are called in assembly. Mach-O and Windows x86 put `_` in front.
pub const symbol_prefix = if (builtin.os.tag.isDarwin() or (builtin.cpu.arch == .x86 and builtin.os.tag == .windows)) "_" else "";

const word_bits = @bitSizeOf(usize);

pub const Type = enum {
    void,
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,
    /// A pointer-sized piece of something bigger that goes on the stack, like a struct passed by value
    /// on x86 or one that didn't fit in registers. Never goes in a register.
    word,
    /// Like `word`, for a float-only struct on aarch64 that didn't fit in float registers. Then no more
    /// float args go in registers either.
    float_word,
    /// The hidden pointer to where a big result goes. X8 on aarch64, else the next int register.
    sret,

    pub const ptr: Type = if (word_bits == 64) .i64 else .i32;

    pub fn size(self: Type) u8 {
        return switch (self) {
            .void => 0,
            .i8 => 1,
            .i16 => 2,
            .i32, .f32 => 4,
            .i64, .f64 => 8,
            .word, .float_word, .sret => word_bits / 8,
        };
    }

    pub fn isFloat(self: Type) bool {
        return self == .f32 or self == .f64;
    }

    /// Ints, pointers and `sret`, which go in int registers.
    pub fn isInt(self: Type) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .sret => true,
            else => false,
        };
    }
};

/// x86 only, the rest ignore it.
pub const Conv = enum {
    /// Caller pops. x86's default.
    cdecl,
    /// Callee pops. Most Win32 APIs.
    stdcall,
    /// `this` in ECX, callee pops.
    thiscall,
    /// First two small int args in ECX and EDX, callee pops.
    fastcall,
};

pub const Signature = struct {
    params: []const Type = &.{},
    ret: Type = .void,
    /// Results that come back in more than one register, after `ret`: RDX or XMM1 on SysV x64, and X1
    /// or V1 to V3 on aarch64. Each register takes the next of its kind.
    ret_more: []const Type = &.{},
    conv: Conv = .cdecl,

    /// `ret` then `ret_more`.
    pub fn results(self: Signature) usize {
        return if (self.ret == .void) 0 else 1 + self.ret_more.len;
    }
};

/// Big structs passed by value on the stack take a word each, like a CPU's registers on x86 or SysV x64.
pub const max_params = 128;
pub const max_results = 4;

pub const Error = error{
    TooManyParams,
    VoidParam,
    /// A thiscall without a register-sized `this`.
    NoThis,
    /// Something this ABI doesn't have, like more than one result register on Windows.
    Unsupported,
};

/// Whether `call` and `args` can do `sig`.
pub fn check(sig: Signature) Error!void {
    if (sig.params.len > max_params) return error.TooManyParams;
    for (sig.params) |p| if (p == .void) return error.VoidParam;
    if (word_bits == 32 and sig.conv == .thiscall and (sig.params.len == 0 or !sig.params[0].isInt() or sig.params[0].size() > 4))
        return error.NoThis;
    if (sig.ret_more.len > 0 and sig.ret == .void) return error.Unsupported;
    if (sig.ret_more.len + 1 > max_results) return error.Unsupported;
    for (sig.ret_more) |r| if (r == .void or !(r.isFloat() or r == .i64 or r == .i32)) return error.Unsupported;
    if (sig.ret == .word or sig.ret == .float_word or sig.ret == .sret) return error.Unsupported;
    try backend.check(sig);
}

/// Returns the first result's bits, 0 for `void`. `sig` must pass `check`.
pub fn call(target: usize, sig: Signature, values: []const u64) u64 {
    var out: [max_results]u64 = @splat(0);
    callAll(target, sig, values, &out);
    return out[0];
}

/// Each result register's bits, `ret` first, in `out`.
pub fn callAll(target: usize, sig: Signature, values: []const u64, out: *[max_results]u64) void {
    std.debug.assert(values.len == sig.params.len);
    backend.call(target, sig, values, out);
}

pub const Frame = backend.Frame;

/// Whether a hidden result pointer takes ECX from `this`, x86 only. See `x86.sretInRegister`.
pub fn sretInRegister(conv: Conv) bool {
    return abi == .x86 and backend.sretInRegister(conv);
}

/// `sig` must pass `check`.
pub fn args(frame: *const Frame, sig: Signature, out: []u64) void {
    std.debug.assert(out.len == sig.params.len);
    backend.args(frame, sig, out);
}

/// On x86 this also sets the pop size, so call it even for `void`.
pub fn setReturn(frame: *Frame, sig: Signature, bits: u64) void {
    var all: [max_results]u64 = @splat(0);
    all[0] = bits;
    setReturns(frame, sig, &all);
}

/// Each result register's bits, like `callAll` gives them.
pub fn setReturns(frame: *Frame, sig: Signature, bits: *const [max_results]u64) void {
    backend.setReturns(frame, sig, bits);
}

/// Where one argument is, before the whole signature's known.
pub const Place = enum {
    /// The first int register. RCX on Windows x64, RDI on SysV x64, ECX on x86, X0 on aarch64.
    reg0,
    /// The second: RDX, RSI, EDX or X1.
    reg1,
    /// The first stack slot past the return address. x86 only.
    stack0,
    stack1,
};

pub fn word(frame: *const Frame, place: Place) usize {
    return backend.word(frame, place);
}

/// Stand-in for any signature. `handler` must call `setReturn`.
/// Use `entry` as a native address, not a Zig call. It's `void` rather than `noreturn`, since it does return.
pub fn Detour(comptime handler: *const fn (frame: *Frame) callconv(.c) void) type {
    return backend.Detour(handler);
}

const tests = struct {
    const x86 = word_bits == 32;

    fn f32Bits(v: f32) u64 {
        return @as(u32, @bitCast(v));
    }

    fn f64Bits(v: f64) u64 {
        return @bitCast(v);
    }

    fn fromF32(bits: u64) f32 {
        return @bitCast(@as(u32, @truncate(bits)));
    }

    noinline fn mixed(a: i32, b: f64, c: i64, d: f32, e: u8, f: f64, g: i32, h: f32) callconv(.c) f64 {
        return @as(f64, @floatFromInt(a)) + b + @as(f64, @floatFromInt(c)) + d + @as(f64, @floatFromInt(e)) + f + @as(f64, @floatFromInt(g)) + h;
    }

    const mixed_sig: Signature = .{ .params = &.{ .i32, .f64, .i64, .f32, .i8, .f64, .i32, .f32 }, .ret = .f64 };

    noinline fn many(a: i32, b: f32, c: i64, d: f64, e: i32, f: f32, g: i32, h: f64, i: i32, j: f32, k: i32, l: f64, m: i32, n: f32, o: i32, p: f64, q: i32, r: f32, s: i32, t: f64) callconv(.c) f64 {
        const ints = @as(f64, @floatFromInt(a + e + g + i + k + m + o + q + s)) + @as(f64, @floatFromInt(c));
        return ints * 1000 + b + d + f + h + j + l + n + p + r + t;
    }

    const many_sig: Signature = .{ .params = &.{ .i32, .f32, .i64, .f64, .i32, .f32, .i32, .f64, .i32, .f32, .i32, .f64, .i32, .f32, .i32, .f64, .i32, .f32, .i32, .f64 }, .ret = .f64 };
    const many_args = [_]u64{ 1, f32Bits(0.5), 2, f64Bits(0.25), 3, f32Bits(1), 4, f64Bits(2), 5, f32Bits(4), 6, f64Bits(8), 7, f32Bits(16), 8, f64Bits(32), 9, f32Bits(64), 10, f64Bits(128) };
    const many_result: f64 = 55 * 1000 + 0.5 + 0.25 + 1 + 2 + 4 + 8 + 16 + 32 + 64 + 128;

    noinline fn half(x: f32) callconv(.c) f32 {
        return x / 2;
    }

    noinline fn wide(a: i64, b: i64) callconv(.c) i64 {
        return a * b;
    }

    test "calls pass args and results" {
        try check(mixed_sig);
        const r = call(@intFromPtr(&mixed), mixed_sig, &.{ 1, f64Bits(2.5), 1 << 40, f32Bits(0.5), 7, f64Bits(-1), @as(u32, @bitCast(@as(i32, -3))), f32Bits(0.25) });
        try std.testing.expectEqual(@as(f64, 1 + 2.5 + (1 << 40) + 0.5 + 7 - 1 - 3 + 0.25), @as(f64, @bitCast(r)));
        try std.testing.expectEqual(@as(f32, 1.5), fromF32(call(@intFromPtr(&half), .{ .params = &.{.f32}, .ret = .f32 }, &.{f32Bits(3)})));
        try std.testing.expectEqual(@as(i64, -6 << 40), @as(i64, @bitCast(call(@intFromPtr(&wide), .{ .params = &.{ .i64, .i64 }, .ret = .i64 }, &.{ @bitCast(@as(i64, -3)), 2 << 40 }))));
    }

    noinline fn stdcallSub(a: i32, b: i64, c: i32) callconv(if (x86) .{ .x86_stdcall = .{} } else .c) i64 {
        return a - b - c;
    }

    noinline fn thiscallGet(self: *const [2]i32, i: u32, d: f64) callconv(if (x86) .{ .x86_thiscall = .{} } else .c) f64 {
        return @as(f64, @floatFromInt(self[i])) * d;
    }

    noinline fn fastcallMix(a: i64, b: i32, c: f32, d: i32, e: i32) callconv(if (x86) .{ .x86_fastcall = .{} } else .c) i32 {
        return @as(i32, @intCast(a)) * 1000 + b * 100 + @as(i32, @intFromFloat(c)) * 10 + d - e;
    }

    test "more args than registers, ints and floats mixed" {
        try std.testing.expectEqual(many_result, @as(f64, @bitCast(call(@intFromPtr(&many), many_sig, &many_args))));
    }

    test "x86 conventions" {
        try std.testing.expectEqual(@as(i64, 10 - 3 - 4), @as(i64, @bitCast(call(@intFromPtr(&stdcallSub), .{ .params = &.{ .i32, .i64, .i32 }, .ret = .i64, .conv = .stdcall }, &.{ 10, 3, 4 }))));
        const pair = [2]i32{ 5, 7 };
        const r = call(@intFromPtr(&thiscallGet), .{ .params = &.{ Type.ptr, .i32, .f64 }, .ret = .f64, .conv = .thiscall }, &.{ @intFromPtr(&pair), 1, f64Bits(1.5) });
        try std.testing.expectEqual(@as(f64, 10.5), @as(f64, @bitCast(r)));
        // a is 8 bytes, so b and d go in registers
        const sig: Signature = .{ .params = &.{ .i64, .i32, .f32, .i32, .i32 }, .ret = .i32, .conv = .fastcall };
        try std.testing.expectEqual(@as(u32, 1000 + 200 + 30 + 4 - 5), @as(u32, @truncate(call(@intFromPtr(&fastcallMix), sig, &.{ 1, 2, f32Bits(3), 4, 5 }))));
    }

    test "thiscall needs this" {
        if (!x86) return;
        try std.testing.expectError(error.NoThis, check(.{ .conv = .thiscall }));
        try std.testing.expectError(error.NoThis, check(.{ .params = &.{.f32}, .conv = .thiscall }));
        try std.testing.expectError(error.VoidParam, check(.{ .params = &.{.void} }));
    }

    var detour_sig: Signature = undefined;
    var seen: [max_params]u64 = undefined;
    var answer: u64 = 0;

    fn handler(frame: *Frame) callconv(.c) void {
        args(frame, detour_sig, seen[0..detour_sig.params.len]);
        setReturn(frame, detour_sig, answer);
    }

    const Entry = Detour(handler);

    test "detour reads args" {
        // Treat it as a native address, not a Zig call.
        var entry = @intFromPtr(&Entry.entry);
        std.mem.doNotOptimizeAway(&entry);
        detour_sig = mixed_sig;
        answer = f64Bits(42.5);
        const as_mixed: *const @TypeOf(mixed) = @ptrFromInt(entry);
        try std.testing.expectEqual(@as(f64, 42.5), as_mixed(1, 2.5, 1 << 40, 0.5, 7, -1, -3, 0.25));
        try std.testing.expectEqual(@as(u32, 1), @as(u32, @truncate(seen[0])));
        try std.testing.expectEqual(@as(f64, 2.5), @as(f64, @bitCast(seen[1])));
        try std.testing.expectEqual(@as(u64, 1 << 40), seen[2]);
        try std.testing.expectEqual(@as(f32, 0.5), fromF32(seen[3]));
        try std.testing.expectEqual(@as(u8, 7), @as(u8, @truncate(seen[4])));
        try std.testing.expectEqual(@as(f64, -1), @as(f64, @bitCast(seen[5])));
        try std.testing.expectEqual(@as(i32, -3), @as(i32, @bitCast(@as(u32, @truncate(seen[6])))));
        try std.testing.expectEqual(@as(f32, 0.25), fromF32(seen[7]));

        detour_sig = .{ .params = &.{.f32}, .ret = .f32 };
        answer = f32Bits(9.5);
        const as_half: *const @TypeOf(half) = @ptrFromInt(entry);
        try std.testing.expectEqual(@as(f32, 9.5), as_half(1));
    }

    test "detour reads args past the registers" {
        var entry = @intFromPtr(&Entry.entry);
        std.mem.doNotOptimizeAway(&entry);
        detour_sig = many_sig;
        answer = f64Bits(-7);
        const as_many: *const @TypeOf(many) = @ptrFromInt(entry);
        try std.testing.expectEqual(@as(f64, -7), as_many(1, 0.5, 2, 0.25, 3, 1, 4, 2, 5, 4, 6, 8, 7, 16, 8, 32, 9, 64, 10, 128));
        for (many_args, seen[0..many_args.len], many_sig.params) |want, got, p| {
            const mask: u64 = if (p.size() == 8) ~@as(u64, 0) else 0xFFFF_FFFF;
            try std.testing.expectEqual(want & mask, got & mask);
        }
    }

    test "detour pops like x86 callee" {
        var entry = @intFromPtr(&Entry.entry);
        std.mem.doNotOptimizeAway(&entry);
        detour_sig = .{ .params = &.{ .i64, .i32, .f32, .i32, .i32 }, .ret = .i32, .conv = .fastcall };
        answer = 77;
        const as_fast: *const @TypeOf(fastcallMix) = @ptrFromInt(entry);
        // A wrong pop would wreck the stack
        for (0..3) |_| try std.testing.expectEqual(@as(i32, 77), as_fast(1, 2, 3, 4, 5));
        try std.testing.expectEqual(@as(u64, 1), seen[0]);
        try std.testing.expectEqual(@as(u32, 2), @as(u32, @truncate(seen[1])));
        try std.testing.expectEqual(@as(f32, 3), fromF32(seen[2]));
        try std.testing.expectEqual(@as(u32, 5), @as(u32, @truncate(seen[4])));

        detour_sig = .{ .params = &.{ Type.ptr, .i32, .f64 }, .ret = .f64, .conv = .thiscall };
        answer = f64Bits(-2);
        const as_this: *const @TypeOf(thiscallGet) = @ptrFromInt(entry);
        const pair = [2]i32{ 0, 0 };
        for (0..3) |_| try std.testing.expectEqual(@as(f64, -2), as_this(&pair, 1, 0.5));
        try std.testing.expectEqual(@as(usize, @intFromPtr(&pair)), @as(usize, @truncate(seen[0])));
        try std.testing.expectEqual(@as(f64, 0.5), @as(f64, @bitCast(seen[2])));

        detour_sig = .{ .params = &.{ .i32, .i64, .i32 }, .ret = .i64, .conv = .stdcall };
        answer = @bitCast(@as(i64, -1 << 40));
        const as_std: *const @TypeOf(stdcallSub) = @ptrFromInt(entry);
        for (0..3) |_| try std.testing.expectEqual(@as(i64, -1 << 40), as_std(1, 2, 3));
    }
};

test {
    _ = tests;
}
