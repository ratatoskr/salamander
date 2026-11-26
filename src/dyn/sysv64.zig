//! SysV x64 `dyn`, Linux and macOS. Ints in RDI, RSI, RDX, RCX, R8, R9, floats in XMM0-XMM7, the rest on the stack.
//! Inline assembly is AT&T with every size spelled out, since Zig's own x64 backend takes that.

const dyn = @import("root.zig");

const gprs = 6;
const xmms = 8;

pub fn check(_: dyn.Signature) dyn.Error!void {}

/// Offsets are hard-coded in the call stub.
const CallFrame = extern struct {
    target: usize,
    gpr: [gprs]u64,
    xmm: [xmms]u64,
    stack: [*]const u64,
    stack_len: usize,
    rax: u64 = 0,
    rdx: u64 = 0,
    xmm0: u64 = 0,
    xmm1: u64 = 0,
};

comptime {
    const assert = @import("std").debug.assert;
    assert(@offsetOf(CallFrame, "xmm") == 56 and @offsetOf(CallFrame, "stack") == 120 and @offsetOf(CallFrame, "rax") == 136 and @offsetOf(CallFrame, "xmm1") == 160);
    assert(@offsetOf(Frame, "stack") == 112 and @offsetOf(Frame, "ret") == 120 and @offsetOf(Frame, "ret_xmm") == 136);
}

/// Where each param goes, the same for calls and detours.
const Slots = struct {
    gpr: usize = 0,
    xmm: usize = 0,
    stack: usize = 0,

    const Slot = union(enum) { gpr: usize, xmm: usize, stack: usize };

    fn next(self: *Slots, t: dyn.Type) Slot {
        if (t.isInt() and self.gpr < gprs) {
            self.gpr += 1;
            return .{ .gpr = self.gpr - 1 };
        }
        if (t.isFloat() and self.xmm < xmms) {
            self.xmm += 1;
            return .{ .xmm = self.xmm - 1 };
        }
        self.stack += 1;
        return .{ .stack = self.stack - 1 };
    }
};

/// Which register each result is in. Ints take RAX then RDX, floats XMM0 then XMM1.
const Results = struct {
    ints: usize = 0,
    floats: usize = 0,

    fn next(self: *Results, t: dyn.Type) struct { float: bool, i: usize } {
        if (t.isFloat()) {
            self.floats += 1;
            return .{ .float = true, .i = self.floats - 1 };
        }
        self.ints += 1;
        return .{ .float = false, .i = self.ints - 1 };
    }
};

fn resultTypes(sig: dyn.Signature, buf: *[dyn.max_results]dyn.Type) []const dyn.Type {
    if (sig.ret == .void) return buf[0..0];
    buf[0] = sig.ret;
    for (sig.ret_more, 1..) |t, i| buf[i] = t;
    return buf[0 .. 1 + sig.ret_more.len];
}

pub fn call(target: usize, sig: dyn.Signature, values: []const u64, out: *[dyn.max_results]u64) void {
    var stack: [dyn.max_params]u64 = undefined;
    var frame: CallFrame = .{ .target = target, .gpr = @splat(0), .xmm = @splat(0), .stack = &stack, .stack_len = 0 };
    var slots: Slots = .{};
    for (sig.params, values) |p, v| switch (slots.next(p)) {
        .gpr => |i| frame.gpr[i] = v,
        .xmm => |i| frame.xmm[i] = v,
        .stack => |i| stack[i] = v,
    };
    frame.stack_len = slots.stack;
    salamander_sysv64_dyn_call(&frame);
    var buf: [dyn.max_results]dyn.Type = undefined;
    var results: Results = .{};
    for (resultTypes(sig, &buf), 0..) |t, k| {
        const r = results.next(t);
        out[k] = if (r.float) (if (r.i == 0) frame.xmm0 else frame.xmm1) else (if (r.i == 0) frame.rax else frame.rdx);
    }
}

/// In sysv64.S.
extern fn salamander_sysv64_dyn_call(frame: *CallFrame) callconv(.c) void;

pub const Frame = extern struct {
    gpr: [gprs]u64,
    xmm: [xmms]u64,
    /// The caller's stack args, 8 bytes each.
    stack: [*]const u64,
    /// RAX and RDX.
    ret: [2]u64 = .{ 0, 0 },
    /// XMM0 and XMM1.
    ret_xmm: [2]u64 = .{ 0, 0 },
};

pub fn args(frame: *const Frame, sig: dyn.Signature, out: []u64) void {
    var slots: Slots = .{};
    for (sig.params, out) |p, *o| o.* = switch (slots.next(p)) {
        .gpr => |i| frame.gpr[i],
        .xmm => |i| frame.xmm[i],
        .stack => |i| frame.stack[i],
    };
}

pub fn word(frame: *const Frame, place: dyn.Place) usize {
    return switch (place) {
        .reg0 => frame.gpr[0],
        .reg1 => frame.gpr[1],
        .stack0, .stack1 => unreachable,
    };
}

pub fn setReturns(frame: *Frame, sig: dyn.Signature, bits: *const [dyn.max_results]u64) void {
    var buf: [dyn.max_results]dyn.Type = undefined;
    var results: Results = .{};
    for (resultTypes(sig, &buf), 0..) |t, k| {
        const r = results.next(t);
        if (r.float) frame.ret_xmm[r.i] = bits[k] else frame.ret[r.i] = bits[k];
    }
}

// XMM moves are in sysv64.S, since Zig's x64 backend can't do them inline and skips global assembly.
// The XMM helpers find the frame 8 bytes up, past their return address.
extern fn salamander_sysv64_save_xmm() callconv(.naked) void;
extern fn salamander_sysv64_load_xmm() callconv(.naked) void;

pub fn Detour(comptime handler: *const fn (frame: *Frame) callconv(.c) void) type {
    return struct {
        // Not `noreturn`: it returns, so code after a call to it mustn't be dropped
        pub fn entry() callconv(.naked) void {
            asm volatile (
                \\pushq %%rbp
                \\movq %%rsp, %%rbp
                \\subq $160, %%rsp
                \\movq %%rdi, 0(%%rsp)
                \\movq %%rsi, 8(%%rsp)
                \\movq %%rdx, 16(%%rsp)
                \\movq %%rcx, 24(%%rsp)
                \\movq %%r8, 32(%%rsp)
                \\movq %%r9, 40(%%rsp)
                \\callq %[save:P]
                \\leaq 16(%%rbp), %%rax
                \\movq %%rax, 112(%%rsp)
                \\movq $0, 120(%%rsp)
                \\movq $0, 128(%%rsp)
                \\movq $0, 136(%%rsp)
                \\movq $0, 144(%%rsp)
                \\movq %%rsp, %%rdi
                \\callq %[handler:P]
                // The calls can go through RAX, so XMM first
                \\callq %[load:P]
                \\movq 120(%%rsp), %%rax
                \\movq 128(%%rsp), %%rdx
                \\movq %%rbp, %%rsp
                \\popq %%rbp
                \\retq
                :
                : [handler] "X" (handler),
                  [save] "X" (&salamander_sysv64_save_xmm),
                  [load] "X" (&salamander_sysv64_load_xmm),
            );
        }
    };
}
