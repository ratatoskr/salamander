//! aarch64 `dyn`, Windows, Linux and macOS. Ints in X0-X7, floats in D0-D7, a big result's pointer in X8, the rest on the stack.
//! Apple packs stack args to their own size. A struct that didn't fit closes its kind's registers to later args.

const std = @import("std");
const dyn = @import("root.zig");

const regs = 8;
const apple = dyn.abi == .apple64;

pub fn check(sig: dyn.Signature) dyn.Error!void {
    if (sig.ret == .void) return;
    var ints: usize = @intFromBool(!sig.ret.isFloat());
    for (sig.ret_more) |t| ints += @intFromBool(!t.isFloat());
    if (ints > 2) return error.Unsupported;
}

/// Offsets are hard-coded in the call stub.
const CallFrame = extern struct {
    target: usize,
    x: [regs]u64,
    d: [regs]u64,
    stack: [*]const u8,
    /// In bytes, a multiple of 16.
    stack_len: usize,
    ret_x: [2]u64 = .{ 0, 0 },
    ret_d: [4]u64 = @splat(0),
    x8: u64 = 0,
};

pub const Frame = extern struct {
    x: [regs]u64,
    d: [regs]u64,
    /// The caller's stack args.
    stack: [*]const u8,
    x8: u64,
    ret_x: [2]u64 = .{ 0, 0 },
    ret_d: [4]u64 = @splat(0),
};

comptime {
    std.debug.assert(@offsetOf(CallFrame, "d") == 72 and @offsetOf(CallFrame, "stack") == 136 and @offsetOf(CallFrame, "ret_x") == 152 and @offsetOf(CallFrame, "ret_d") == 168 and @offsetOf(CallFrame, "x8") == 200);
    std.debug.assert(@offsetOf(Frame, "stack") == 128 and @offsetOf(Frame, "x8") == 136 and @offsetOf(Frame, "ret_x") == 144 and @offsetOf(Frame, "ret_d") == 160 and @sizeOf(Frame) == 192);
}

/// Where each param goes, the same for calls and detours.
const Slots = struct {
    ints: usize = 0,
    floats: usize = 0,
    /// Bytes into the stack args.
    offset: usize = 0,

    const Slot = union(enum) { x: usize, d: usize, x8, stack: struct { at: usize, size: usize } };

    fn next(self: *Slots, t: dyn.Type) Slot {
        switch (t) {
            .sret => return .x8,
            .word => self.ints = regs,
            .float_word => self.floats = regs,
            else => {},
        }
        if (t.isInt() and self.ints < regs) {
            self.ints += 1;
            return .{ .x = self.ints - 1 };
        }
        if (t.isFloat() and self.floats < regs) {
            self.floats += 1;
            return .{ .d = self.floats - 1 };
        }
        const size: usize = if (apple) t.size() else 8;
        self.offset = std.mem.alignForward(usize, self.offset, size);
        defer self.offset += size;
        return .{ .stack = .{ .at = self.offset, .size = size } };
    }
};

/// Which register result `k` is in. Ints take X0 then X1, floats D0 to D3.
fn resultSlot(sig: dyn.Signature, k: usize) struct { float: bool, i: usize } {
    var ints: usize = 0;
    var floats: usize = 0;
    for (0..k + 1) |j| {
        const t = if (j == 0) sig.ret else sig.ret_more[j - 1];
        if (j == k) return if (t.isFloat()) .{ .float = true, .i = floats } else .{ .float = false, .i = ints };
        if (t.isFloat()) floats += 1 else ints += 1;
    }
    unreachable;
}

pub fn call(target: usize, sig: dyn.Signature, values: []const u64, out: *[dyn.max_results]u64) void {
    var stack: [dyn.max_params * 8 + 16]u8 align(16) = undefined;
    var frame: CallFrame = .{ .target = target, .x = @splat(0), .d = @splat(0), .stack = &stack, .stack_len = 0 };
    var slots: Slots = .{};
    for (sig.params, values) |p, v| switch (slots.next(p)) {
        .x => |i| frame.x[i] = v,
        .d => |i| frame.d[i] = v,
        .x8 => frame.x8 = v,
        .stack => |s| @memcpy(stack[s.at..][0..s.size], std.mem.asBytes(&v)[0..s.size]),
    };
    frame.stack_len = std.mem.alignForward(usize, slots.offset, 16);
    salamander_a64_dyn_call(&frame);
    for (0..sig.results()) |k| {
        const r = resultSlot(sig, k);
        out[k] = if (r.float) frame.ret_d[r.i] else frame.ret_x[r.i];
    }
}

extern fn salamander_a64_dyn_call(frame: *CallFrame) callconv(.c) void;

// Returning assembly needs a returning declaration.
comptime {
    const name = dyn.symbol_prefix ++ "salamander_a64_dyn_call";
    asm (
        \\.text
        \\.p2align 2
        \\.global
    ++ " " ++ name ++ "\n" ++ name ++ ":\n" ++
        \\stp x29, x30, [sp, #-32]!
        \\mov x29, sp
        \\str x19, [sp, #16]
        \\mov x19, x0
        \\ldr x9, [x19, #144]
        \\sub sp, sp, x9
        \\ldr x11, [x19, #136]
        \\mov x12, sp
        \\cbz x9, 2f
        \\1:
        \\ldr x13, [x11], #8
        \\str x13, [x12], #8
        \\subs x9, x9, #8
        \\b.ne 1b
        \\2:
        \\ldp x0, x1, [x19, #8]
        \\ldp x2, x3, [x19, #24]
        \\ldp x4, x5, [x19, #40]
        \\ldp x6, x7, [x19, #56]
        \\ldp d0, d1, [x19, #72]
        \\ldp d2, d3, [x19, #88]
        \\ldp d4, d5, [x19, #104]
        \\ldp d6, d7, [x19, #120]
        \\ldr x8, [x19, #200]
        \\ldr x16, [x19]
        \\blr x16
        \\stp x0, x1, [x19, #152]
        \\stp d0, d1, [x19, #168]
        \\stp d2, d3, [x19, #184]
        \\mov sp, x29
        \\ldr x19, [sp, #16]
        \\ldp x29, x30, [sp], #32
        \\ret
        \\
    );
}

pub fn args(frame: *const Frame, sig: dyn.Signature, out: []u64) void {
    var slots: Slots = .{};
    for (sig.params, out) |p, *o| o.* = switch (slots.next(p)) {
        .x => |i| frame.x[i],
        .d => |i| frame.d[i],
        .x8 => frame.x8,
        .stack => |s| blk: {
            var v: u64 = 0;
            @memcpy(std.mem.asBytes(&v)[0..s.size], frame.stack[s.at..][0..s.size]);
            break :blk v;
        },
    };
}

pub fn word(frame: *const Frame, place: dyn.Place) usize {
    return switch (place) {
        .reg0 => frame.x[0],
        .reg1 => frame.x[1],
        .stack0, .stack1 => unreachable,
    };
}

pub fn setReturns(frame: *Frame, sig: dyn.Signature, bits: *const [dyn.max_results]u64) void {
    for (0..sig.results()) |k| {
        const r = resultSlot(sig, k);
        if (r.float) frame.ret_d[r.i] = bits[k] else frame.ret_x[r.i] = bits[k];
    }
}

pub fn Detour(comptime handler: *const fn (frame: *Frame) callconv(.c) void) type {
    return struct {
        // Not `noreturn`: it returns, so code after a call to it mustn't be dropped
        pub fn entry() callconv(.naked) void {
            asm volatile (
                \\stp x29, x30, [sp, #-208]!
                \\mov x29, sp
                \\stp x0, x1, [sp, #16]
                \\stp x2, x3, [sp, #32]
                \\stp x4, x5, [sp, #48]
                \\stp x6, x7, [sp, #64]
                \\stp d0, d1, [sp, #80]
                \\stp d2, d3, [sp, #96]
                \\stp d4, d5, [sp, #112]
                \\stp d6, d7, [sp, #128]
                \\add x9, sp, #208
                \\str x9, [sp, #144]
                \\str x8, [sp, #152]
                \\stp xzr, xzr, [sp, #160]
                \\stp xzr, xzr, [sp, #176]
                \\stp xzr, xzr, [sp, #192]
                \\add x0, sp, #16
                \\bl %[handler]
                \\ldp x0, x1, [sp, #160]
                \\ldp d0, d1, [sp, #176]
                \\ldp d2, d3, [sp, #192]
                \\ldp x29, x30, [sp], #208
                \\ret
                :
                : [handler] "X" (handler),
            );
        }
    };
}
