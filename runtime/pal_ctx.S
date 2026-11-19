/* pal_ctx.S — low-level callee-saved context switch for Wren fibers. */
#if defined(__APPLE__)
#define CSYM(name) _##name
#else
#define CSYM(name) name
#endif

#if defined(__aarch64__)
    .text
    .p2align 2
    .globl CSYM(pal_ctx_swap)
CSYM(pal_ctx_swap):
    /* x0 = PalContext *from, x1 = PalContext *to */
    stp x19, x20, [x0, #0]
    stp x21, x22, [x0, #16]
    stp x23, x24, [x0, #32]
    stp x25, x26, [x0, #48]
    stp x27, x28, [x0, #64]
    stp x29, x30, [x0, #80]
    mov x9, sp
    str x9, [x0, #96]
    stp d8,  d9,  [x0, #104]
    stp d10, d11, [x0, #120]
    stp d12, d13, [x0, #136]
    stp d14, d15, [x0, #152]

    ldp x19, x20, [x1, #0]
    ldp x21, x22, [x1, #16]
    ldp x23, x24, [x1, #32]
    ldp x25, x26, [x1, #48]
    ldp x27, x28, [x1, #64]
    ldp x29, x30, [x1, #80]
    ldr x9, [x1, #96]
    mov sp, x9
    ldp d8,  d9,  [x1, #104]
    ldp d10, d11, [x1, #120]
    ldp d12, d13, [x1, #136]
    ldp d14, d15, [x1, #152]
    ret

#elif defined(__x86_64__) && defined(_WIN32)
    .text
    .p2align 4
    .globl CSYM(pal_ctx_swap)
CSYM(pal_ctx_swap):
    /* %rcx = PalContext *from, %rdx = PalContext *to (Win64 ABI) */
    movq %rbx, 0(%rcx)
    movq %rbp, 8(%rcx)
    movq %rdi, 16(%rcx)
    movq %rsi, 24(%rcx)
    movq %r12, 32(%rcx)
    movq %r13, 40(%rcx)
    movq %r14, 48(%rcx)
    movq %r15, 56(%rcx)
    leaq 8(%rsp), %rax
    movq %rax, 64(%rcx)
    movq 0(%rsp), %rax
    movq %rax, 72(%rcx)

    movq 0(%rdx), %rbx
    movq 8(%rdx), %rbp
    movq 16(%rdx), %rdi
    movq 24(%rdx), %rsi
    movq 32(%rdx), %r12
    movq 40(%rdx), %r13
    movq 48(%rdx), %r14
    movq 56(%rdx), %r15
    movq 64(%rdx), %rsp
    movq 72(%rdx), %rax
    jmpq *%rax

#elif defined(__x86_64__)
    .text
    .p2align 4
    .globl CSYM(pal_ctx_swap)
CSYM(pal_ctx_swap):
    /* %rdi = PalContext *from, %rsi = PalContext *to */
    movq %rbx, 0(%rdi)
    movq %rbp, 8(%rdi)
    movq %r12, 16(%rdi)
    movq %r13, 24(%rdi)
    movq %r14, 32(%rdi)
    movq %r15, 40(%rdi)
    leaq 8(%rsp), %rcx
    movq %rcx, 48(%rdi)
    movq 0(%rsp), %rcx
    movq %rcx, 56(%rdi)

    movq 0(%rsi), %rbx
    movq 8(%rsi), %rbp
    movq 16(%rsi), %r12
    movq 24(%rsi), %r13
    movq 32(%rsi), %r14
    movq 40(%rsi), %r15
    movq 48(%rsi), %rsp
    movq 56(%rsi), %rcx
    jmpq *%rcx

#elif defined(__riscv) && (__riscv_xlen == 64)
    .text
    .p2align 2
    .globl CSYM(pal_ctx_swap)
CSYM(pal_ctx_swap):
    /* a0 = PalContext *from, a1 = PalContext *to */
    sd s0,   0(a0)
    sd s1,   8(a0)
    sd s2,  16(a0)
    sd s3,  24(a0)
    sd s4,  32(a0)
    sd s5,  40(a0)
    sd s6,  48(a0)
    sd s7,  56(a0)
    sd s8,  64(a0)
    sd s9,  72(a0)
    sd s10, 80(a0)
    sd s11, 88(a0)
    sd ra,  96(a0)
    sd sp, 104(a0)
    fsd fs0,  112(a0)
    fsd fs1,  120(a0)
    fsd fs2,  128(a0)
    fsd fs3,  136(a0)
    fsd fs4,  144(a0)
    fsd fs5,  152(a0)
    fsd fs6,  160(a0)
    fsd fs7,  168(a0)
    fsd fs8,  176(a0)
    fsd fs9,  184(a0)
    fsd fs10, 192(a0)
    fsd fs11, 200(a0)

    ld s0,   0(a1)
    ld s1,   8(a1)
    ld s2,  16(a1)
    ld s3,  24(a1)
    ld s4,  32(a1)
    ld s5,  40(a1)
    ld s6,  48(a1)
    ld s7,  56(a1)
    ld s8,  64(a1)
    ld s9,  72(a1)
    ld s10, 80(a1)
    ld s11, 88(a1)
    ld ra,  96(a1)
    ld sp, 104(a1)
    fld fs0,  112(a1)
    fld fs1,  120(a1)
    fld fs2,  128(a1)
    fld fs3,  136(a1)
    fld fs4,  144(a1)
    fld fs5,  152(a1)
    fld fs6,  160(a1)
    fld fs7,  168(a1)
    fld fs8,  176(a1)
    fld fs9,  184(a1)
    fld fs10, 192(a1)
    fld fs11, 200(a1)
    ret
#else
#error "pal_ctx_swap unsupported architecture"
#endif

#if defined(__linux__) && defined(__ELF__)
    .section .note.GNU-stack,"",@progbits
#endif
