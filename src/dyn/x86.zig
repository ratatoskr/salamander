//! x86 `dyn`, Windows and Linux. Stack args, plus ECX/EDX for thiscall and fastcall.

const builtin = @import("builtin");
const dyn = @import("root.zig");

pub fn check(sig: dyn.Signature) dyn.Error!void {
    if (sig.ret_more.len > 0) return error.Unsupported;
}

/// Whether a hidden result pointer takes ECX, which LLVM only does for thiscall on windows-gnu.
pub fn sretInRegister(conv: dyn.Conv) bool {
    return conv == .thiscall and builtin.os.tag == .windows and builtin.abi != .msvc;
}

const Place = union(enum) {
    ecx,
    edx,
    /// First 4-byte slot.
    stack: u16,
};

const Layout = struct {
    places: [dyn.max_params]Place = undefined,
    /// In 4-byte slots.
    stack_len: u16 = 0,

    fn of(sig: dyn.Signature) Layout {
        var out: Layout = .{};
        var regs: u2 = 0;
        const max_regs: u2 = switch (sig.conv) {
            .cdecl, .stdcall => 0,
            .thiscall => 1,
            .fastcall => 2,
        };
        for (sig.params, 0..) |p, i| {
            const fits = p.isInt() and p.size() <= 4 and (p != .sret or sretInRegister(sig.conv));
            // `check` makes sure a thiscall's `this` fits
            const first_reg_param = i == 0 or (i == 1 and sig.params[0] == .sret and !sretInRegister(sig.conv));
            const in_reg = regs < max_regs and fits and (sig.conv != .thiscall or first_reg_param);
            if (in_reg) {
                out.places[i] = if (regs == 0) .ecx else .edx;
                regs += 1;
            } else {
                out.places[i] = .{ .stack = out.stack_len };
                out.stack_len += if (p.size() == 8) 2 else 1;
            }
        }
        return out;
    }

    fn popBytes(self: Layout, sig: dyn.Signature) u32 {
        if (sig.conv != .cdecl) return @as(u32, self.stack_len) * 4;
        // On Linux even cdecl's callee pops the hidden result pointer
        const sret_on_stack = sig.params.len > 0 and sig.params[0] == .sret and self.places[0] == .stack;
        return if (builtin.os.tag != .windows and sret_on_stack) 4 else 0;
    }
};

/// Offsets are hard-coded in the call stub.
const CallFrame = extern struct {
    target: u32,
    ecx: u32 = 0,
    edx: u32 = 0,
    stack: [*]const u32,
    stack_len: u32,
    ret_lo: u32 = 0,
    ret_hi: u32 = 0,
    /// Nonzero if the result is on x87.
    float: u32 = 0,
    ret_float: [2]u32 = .{ 0, 0 },
};

pub fn call(target: usize, sig: dyn.Signature, values: []const u64, out: *[dyn.max_results]u64) void {
    const layout: Layout = .of(sig);
    var stack: [dyn.max_params * 2]u32 = undefined;
    var frame: CallFrame = .{ .target = target, .stack = &stack, .stack_len = layout.stack_len, .float = @intFromBool(sig.ret.isFloat()) };
    for (sig.params, values, 0..) |p, a, i| switch (layout.places[i]) {
        .ecx => frame.ecx = @truncate(a),
        .edx => frame.edx = @truncate(a),
        .stack => |at| {
            stack[at] = @truncate(a);
            if (p.size() == 8) stack[at + 1] = @truncate(a >> 32);
        },
    };
    salamander_x86_dyn_call(&frame);
    out[0] = switch (sig.ret) {
        // The stub stores x87's result as an f64
        .f32 => @as(u32, @bitCast(@as(f32, @floatCast(@as(f64, @bitCast(frame.ret_float)))))),
        .f64 => @bitCast(frame.ret_float),
        else => (@as(u64, frame.ret_hi) << 32) | frame.ret_lo,
    };
}

extern fn salamander_x86_dyn_call(frame: *CallFrame) callconv(.c) void;

// EBP restores ESP regardless of who pops.
comptime {
    const name = dyn.symbol_prefix ++ "salamander_x86_dyn_call";
    asm (
        \\.text
        \\.intel_syntax noprefix
        \\.p2align 4
        \\.global
    ++ " " ++ name ++ "\n" ++ name ++ ":\n" ++
        \\push ebp
        \\mov ebp, esp
        \\push ebx
        \\push esi
        \\push edi
        \\mov ebx, [ebp + 8]
        \\mov ecx, [ebx + 16]
        \\lea eax, [ecx * 4]
        \\sub esp, eax
        \\and esp, -16
        \\mov edi, esp
        \\mov esi, [ebx + 12]
        \\cld
        \\rep movsd
        \\mov ecx, [ebx + 4]
        \\mov edx, [ebx + 8]
        \\call dword ptr [ebx]
        \\mov [ebx + 20], eax
        \\mov [ebx + 24], edx
        \\cmp dword ptr [ebx + 28], 0
        \\je 1f
        \\fstp qword ptr [ebx + 32]
        \\1:
        \\lea esp, [ebp - 12]
        \\pop edi
        \\pop esi
        \\pop ebx
        \\pop ebp
        \\ret
        \\.att_syntax prefix
    );
}

pub const Frame = extern struct {
    ecx: u32,
    edx: u32,
    /// Just past the return address.
    stack: [*]const u32,
    ret_lo: u32 = 0,
    ret_hi: u32 = 0,
    pop: u32 = 0,
    /// 0 int, 1 f32 from `ret_lo`, 2 f64 from `ret_lo:ret_hi`.
    float: u32 = 0,
};

pub fn args(frame: *const Frame, sig: dyn.Signature, out: []u64) void {
    const layout: Layout = .of(sig);
    for (sig.params, out, 0..) |p, *o, i| o.* = switch (layout.places[i]) {
        .ecx => frame.ecx,
        .edx => frame.edx,
        .stack => |at| if (p.size() == 8) (@as(u64, frame.stack[at + 1]) << 32) | frame.stack[at] else frame.stack[at],
    };
}

pub fn word(frame: *const Frame, place: dyn.Place) usize {
    return switch (place) {
        .reg0 => frame.ecx,
        .reg1 => frame.edx,
        .stack0 => frame.stack[0],
        .stack1 => frame.stack[1],
    };
}

pub fn setReturns(frame: *Frame, sig: dyn.Signature, all: *const [dyn.max_results]u64) void {
    const bits = all[0];
    frame.ret_lo = @truncate(bits);
    frame.ret_hi = @truncate(bits >> 32);
    frame.pop = Layout.of(sig).popBytes(sig);
    frame.float = switch (sig.ret) {
        .f32 => 1,
        .f64 => 2,
        else => 0,
    };
}

/// Returns popping `pop` bytes. The handler gets the 16 byte aligned stack Linux needs.
pub fn Detour(comptime handler: *const fn (frame: *Frame) callconv(.c) void) type {
    return struct {
        // Not `noreturn`: it returns, so code after a call to it mustn't be dropped
        pub fn entry() callconv(.naked) void {
            asm volatile (
                \\.intel_syntax noprefix
                \\push ebp
                \\mov ebp, esp
                \\sub esp, 32
                \\and esp, -16
                \\mov [esp], ecx
                \\mov [esp + 4], edx
                \\lea eax, [ebp + 8]
                \\mov [esp + 8], eax
                \\mov dword ptr [esp + 12], 0
                \\mov dword ptr [esp + 16], 0
                \\mov dword ptr [esp + 20], 0
                \\mov dword ptr [esp + 24], 0
                \\mov eax, esp
                \\sub esp, 12
                \\push eax
                \\call %[handler:P]
                \\add esp, 16
                \\mov ecx, [esp + 24]
                \\cmp ecx, 1
                \\jne 1f
                \\fld dword ptr [esp + 12]
                \\jmp 2f
                \\1:
                \\cmp ecx, 2
                \\jne 2f
                \\fld qword ptr [esp + 12]
                \\2:
                \\mov eax, [esp + 12]
                \\mov edx, [esp + 16]
                \\mov ecx, [esp + 20]
                \\mov esp, ebp
                \\pop ebp
                \\push ebx
                \\mov ebx, [esp + 4]
                \\mov [esp + ecx + 4], ebx
                \\pop ebx
                \\add esp, ecx
                \\ret
                \\.att_syntax prefix
                :
                : [handler] "X" (handler),
            );
        }
    };
}
