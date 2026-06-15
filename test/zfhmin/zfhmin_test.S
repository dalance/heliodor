# P10 Zfhmin: minimal half-precision (binary16) floating-point.
#
# Zfhmin = {flh, fsh, fmv.x.h, fmv.h.x, fcvt.s.h, fcvt.h.s, fcvt.d.h, fcvt.h.d}
# (no half arithmetic/compare). This directed test exercises every instruction
# and the rounding / overflow / NaN-box / fflags corner cases.
#
# Bare M-mode. tohost @ 0x80001000: 1 = PASS, else = failing check id.
# Scratch DRAM at 0x80002000.
#
# binary16:  1.0=0x3C00  2.0=0x4000  -1.0=0xBC00  max=0x7BFF  inf=0x7C00
# binary32:  1.0=0x3F800000  2.0=0x40000000  65504=0x477FE000  65536=0x47800000
# binary64:  1.0=0x3FF0000000000000

    .section .text.init
    .globl _start
_start:

    # ---- 11: fmv.h.x + fcvt.s.h : half 1.0 -> single 1.0 ----
    li      a0, 0x3C00
    fmv.h.x fa0, a0              # fa0 = NaN-boxed half 1.0
    fcvt.s.h fa1, fa0
    fmv.x.w a1, fa1
    li      t0, 0x3F800000
    li      t6, 11
    bne     a1, t0, fail

    # ---- 12: fcvt.h.s : single 1.0 -> half 1.0 ----
    fcvt.h.s fa2, fa1
    fmv.x.h a2, fa2
    li      t0, 0x3C00
    li      t6, 12
    bne     a2, t0, fail

    # ---- 13: fcvt.d.h : half 1.0 -> double 1.0 ----
    fcvt.d.h fa3, fa0
    fmv.x.d a3, fa3
    li      t0, 0x3FF0000000000000
    li      t6, 13
    bne     a3, t0, fail

    # ---- 14: fcvt.h.d : double 1.0 -> half 1.0 ----
    fcvt.h.d fa4, fa3
    fmv.x.h a4, fa4
    li      t0, 0x3C00
    li      t6, 14
    bne     a4, t0, fail

    # ---- 15: fsh / flh round-trip (half 2.0) ----
    li      a0, 0x4000
    fmv.h.x fa0, a0
    li      t1, 0x80002000
    fsh     fa0, 0(t1)
    flh     fa5, 0(t1)
    fmv.x.h a5, fa5
    li      t0, 0x4000
    li      t6, 15
    bne     a5, t0, fail

    # ---- 16: flh NaN-boxes (convert reloaded half to single 2.0) ----
    fcvt.s.h fa6, fa5
    fmv.x.w a6, fa6
    li      t0, 0x40000000
    li      t6, 16
    bne     a6, t0, fail

    # ---- 17: fmv.x.h sign-extends (half -1.0 = 0xBC00) ----
    li      a0, 0xBC00
    fmv.h.x fa0, a0
    fmv.x.h a7, fa0
    li      t0, 0xFFFFFFFFFFFFBC00
    li      t6, 17
    bne     a7, t0, fail

    # ---- 18: narrowing RNE rounds down (single 1.0+2^-11 -> half 1.0) ----
    li      a0, 0x3F801000
    fmv.w.x fa0, a0
    fcvt.h.s fa1, fa0
    fmv.x.h a1, fa1
    li      t0, 0x3C00
    li      t6, 18
    bne     a1, t0, fail

    # ---- 19: narrowing RNE rounds up (single 1.0+2^-11+eps -> half 0x3C01) ----
    li      a0, 0x3F801001
    fmv.w.x fa0, a0
    fcvt.h.s fa1, fa0
    fmv.x.h a1, fa1
    li      t0, 0x3C01
    li      t6, 19
    bne     a1, t0, fail

    # ---- 20: overflow -> inf (single 65536 -> half inf, RNE) ----
    li      a0, 0x47800000
    fmv.w.x fa0, a0
    fcvt.h.s fa1, fa0
    fmv.x.h a1, fa1
    li      t0, 0x7C00
    li      t6, 20
    bne     a1, t0, fail

    # ---- 21: max finite (single 65504 -> half 0x7BFF) ----
    li      a0, 0x477FE000
    fmv.w.x fa0, a0
    fcvt.h.s fa1, fa0
    fmv.x.h a1, fa1
    li      t0, 0x7BFF
    li      t6, 21
    bne     a1, t0, fail

    # ---- 22: NX flag set on an inexact narrowing ----
    csrw    fflags, x0
    li      a0, 0x3F801000
    fmv.w.x fa0, a0
    fcvt.h.s fa1, fa0
    csrr    a1, fflags
    andi    a1, a1, 1
    li      t6, 22
    beqz    a1, fail

    # ---- 23: RTZ overflow -> max normal (single 65536 rtz -> 0x7BFF) ----
    li      a0, 0x47800000
    fmv.w.x fa0, a0
    fcvt.h.s fa1, fa0, rtz
    fmv.x.h a1, fa1
    li      t0, 0x7BFF
    li      t6, 23
    bne     a1, t0, fail

    # ---- 24: subnormal half -> single (smallest subnormal 0x0001 = 2^-24) ----
    li      a0, 0x0001
    fmv.h.x fa0, a0
    fcvt.s.h fa1, fa0
    fmv.x.w a1, fa1
    li      t0, 0x33800000          # single 2^-24
    li      t6, 24
    bne     a1, t0, fail

    # ---- all checks passed ----
    li      t0, 1
    li      t1, 0x80001000
    sw      t0, 0(t1)
1:  j       1b

fail:
    li      t1, 0x80001000
    sw      t6, 0(t1)
2:  j       2b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
