// SysV x64 `dyn`'s assembly, see sysv64.zig. Offsets match its `CallFrame` and `Frame`.

#ifdef __APPLE__
#define SYM(name) _##name
#else
#define SYM(name) name
#endif

    .text

// salamander_sysv64_dyn_call(CallFrame* frame) copies the stack args, loads the registers, calls and keeps the results.
    .p2align 4
    .globl SYM(salamander_sysv64_dyn_call)
SYM(salamander_sysv64_dyn_call):
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    movq %rdi, %rbx
    movq 128(%rbx), %rcx
    leaq 15(,%rcx,8), %rax
    andq $-16, %rax
    subq %rax, %rsp
    movq 120(%rbx), %rsi
    movq %rsp, %rdi
    cld
    rep movsq
    movq 8(%rbx), %rdi
    movq 16(%rbx), %rsi
    movq 24(%rbx), %rdx
    movq 32(%rbx), %rcx
    movq 40(%rbx), %r8
    movq 48(%rbx), %r9
    movq 56(%rbx), %xmm0
    movq 64(%rbx), %xmm1
    movq 72(%rbx), %xmm2
    movq 80(%rbx), %xmm3
    movq 88(%rbx), %xmm4
    movq 96(%rbx), %xmm5
    movq 104(%rbx), %xmm6
    movq 112(%rbx), %xmm7
    // An upper bound on vector registers, for variadic callees
    movl $8, %eax
    callq *(%rbx)
    movq %rax, 136(%rbx)
    movq %rdx, 144(%rbx)
    movq %xmm0, 152(%rbx)
    movq %xmm1, 160(%rbx)
    leaq -16(%rbp), %rsp
    popq %r12
    popq %rbx
    popq %rbp
    retq

// A detour's XMM0 to XMM7 into its `Frame.xmm`.
    .p2align 4
    .globl SYM(salamander_sysv64_save_xmm)
SYM(salamander_sysv64_save_xmm):
    movq %xmm0, 56(%rsp)
    movq %xmm1, 64(%rsp)
    movq %xmm2, 72(%rsp)
    movq %xmm3, 80(%rsp)
    movq %xmm4, 88(%rsp)
    movq %xmm5, 96(%rsp)
    movq %xmm6, 104(%rsp)
    movq %xmm7, 112(%rsp)
    retq

// A detour's `Frame.ret_xmm` into XMM0 and XMM1.
    .p2align 4
    .globl SYM(salamander_sysv64_load_xmm)
SYM(salamander_sysv64_load_xmm):
    movq 144(%rsp), %xmm0
    movq 152(%rsp), %xmm1
    retq

#ifdef __linux__
    .section .note.GNU-stack,"",@progbits
#endif
