//! Windows x64 `dyn`. The first four args go in RCX, RDX, R8 and R9 or XMM0 to XMM3 by position, the
//! rest on the stack. Structs never go by value past a register, so there's no `word`.

const dyn = @import("root.zig");

pub fn check(sig: dyn.Signature) dyn.Error!void {
    if (sig.ret_more.len > 0) return error.Unsupported;
    for (sig.params) |p| if (p == .word or p == .float_word) return error.Unsupported;
}

/// Offsets are hard-coded in the call stub.
const CallFrame = extern struct {
    target: usize,
    regs: [4]u64,
    stack: [*]const u64,
    stack_len: usize,
    ret: u64 = 0,
    ret_float: u64 = 0,
};

pub fn call(target: usize, sig: dyn.Signature, values: []const u64, out: *[dyn.max_results]u64) void {
    var frame: CallFrame = .{ .target = target, .regs = @splat(0), .stack = values.ptr, .stack_len = 0 };
    for (values[0..@min(values.len, 4)], 0..) |v, i| frame.regs[i] = v;
    if (values.len > 4) {
        frame.stack = values[4..].ptr;
        frame.stack_len = values.len - 4;
    }
    salamander_x64_dyn_call(&frame);
    out[0] = if (sig.ret.isFloat()) frame.ret_float else frame.ret;
}

extern fn salamander_x64_dyn_call(frame: *CallFrame) callconv(.c) void;

// Returning assembly needs a returning declaration.
comptime {
    asm (
        \\.text
        \\.intel_syntax noprefix
        \\.p2align 4
        \\.global salamander_x64_dyn_call
        \\salamander_x64_dyn_call:
        \\push rbp
        \\mov rbp, rsp
        \\push rbx
        \\push rsi
        \\push rdi
        \\mov rbx, rcx
        \\mov rcx, [rbx + 48]
        \\lea rax, [rcx * 8 + 32]
        \\sub rsp, rax
        \\and rsp, -16
        \\lea rdi, [rsp + 32]
        \\mov rsi, [rbx + 40]
        \\cld
        \\rep movsq
        \\mov rcx, [rbx + 8]
        \\mov rdx, [rbx + 16]
        \\mov r8, [rbx + 24]
        \\mov r9, [rbx + 32]
        \\movq xmm0, rcx
        \\movq xmm1, rdx
        \\movq xmm2, r8
        \\movq xmm3, r9
        \\call qword ptr [rbx]
        \\mov [rbx + 56], rax
        \\movq [rbx + 64], xmm0
        \\lea rsp, [rbp - 24]
        \\pop rdi
        \\pop rsi
        \\pop rbx
        \\pop rbp
        \\ret
        \\.att_syntax prefix
    );
}

pub const Frame = extern struct {
    gpr: [4]u64,
    xmm: [4]u64,
    /// The caller's home space. Arg `i` past the fourth is `stack[i]`.
    stack: [*]const u64,
    ret: u64 = 0,
};

pub fn args(frame: *const Frame, sig: dyn.Signature, out: []u64) void {
    for (sig.params, out, 0..) |p, *o, i| {
        o.* = if (i >= 4) frame.stack[i] else if (p.isFloat()) frame.xmm[i] else frame.gpr[i];
    }
}

pub fn word(frame: *const Frame, place: dyn.Place) usize {
    return switch (place) {
        .reg0 => frame.gpr[0],
        .reg1 => frame.gpr[1],
        .stack0, .stack1 => unreachable,
    };
}

pub fn setReturns(frame: *Frame, _: dyn.Signature, bits: *const [dyn.max_results]u64) void {
    frame.ret = bits[0];
}

/// The result goes in both RAX and XMM0.
pub fn Detour(comptime handler: *const fn (frame: *Frame) callconv(.c) void) type {
    return struct {
        // Not `noreturn`: it returns, so code after a call to it mustn't be dropped
        pub fn entry() callconv(.naked) void {
            asm volatile (
                \\.intel_syntax noprefix
                \\push rbp
                \\mov rbp, rsp
                \\sub rsp, 112
                \\mov [rsp + 32], rcx
                \\mov [rsp + 40], rdx
                \\mov [rsp + 48], r8
                \\mov [rsp + 56], r9
                \\movq [rsp + 64], xmm0
                \\movq [rsp + 72], xmm1
                \\movq [rsp + 80], xmm2
                \\movq [rsp + 88], xmm3
                \\lea rax, [rbp + 16]
                \\mov [rsp + 96], rax
                \\mov qword ptr [rsp + 104], 0
                \\lea rcx, [rsp + 32]
                \\call %[handler:P]
                \\mov rax, [rsp + 104]
                \\movq xmm0, rax
                \\mov rsp, rbp
                \\pop rbp
                \\ret
                \\.att_syntax prefix
                :
                : [handler] "X" (handler),
            );
        }
    };
}
