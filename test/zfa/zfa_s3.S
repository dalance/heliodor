# P10 Zfa Stage 3: fcvtmod.w.d — double → signed int32, round-toward-zero,
# reduced modulo 2^32, sign-extended. NaN/+-inf convert to 0. Out-of-range finite
# values keep their low 32 bits (no saturation). FP exception flags match
# fcvt.w.d for the same operand (NV on NaN/inf/out-of-range, NX on inexact).
# M-mode, tohost @ 0x80001000.  1 = PASS, 3 = FAIL.

    .section .text.init
    .globl _start
_start:
    li        t0, (1 << 13)
    csrs      mstatus, t0          # enable FS

    # ---- result-value checks ----
    # 3.5 -> 3
    li        t0, 0x400C000000000000
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    li        t2, 3
    bne       a0, t2, fail

    # -3.5 -> -3 (toward zero)
    li        t0, 0xC00C000000000000
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    li        t2, -3
    bne       a0, t2, fail

    # 2.0 -> 2
    li        t0, 0x4000000000000000
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    li        t2, 2
    bne       a0, t2, fail

    # 0.9 -> 0
    li        t0, 0x3FECCCCCCCCCCCCD
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    bnez      a0, fail

    # -0.9 -> 0 (toward zero)
    li        t0, 0xBFECCCCCCCCCCCCD
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    bnez      a0, fail

    # 2^31 -> 0x80000000 as int32 -> sign-extended 0xFFFFFFFF80000000
    li        t0, 0x41E0000000000000
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    li        t2, 0xFFFFFFFF80000000
    bne       a0, t2, fail

    # 2^32 -> modulo 0
    li        t0, 0x41F0000000000000
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    bnez      a0, fail

    # 2^32 + 7 -> 7
    li        t0, 0x41F0000000700000
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    li        t2, 7
    bne       a0, t2, fail

    # -(2^32 + 7) -> -7
    li        t0, 0xC1F0000000700000
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    li        t2, -7
    bne       a0, t2, fail

    # 2^33 -> modulo 0
    li        t0, 0x4200000000000000
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    bnez      a0, fail

    # 5e9 = 5000000000 -> 5e9 mod 2^32 = 0x2A05F200
    li        t0, 0x41F2A05F20000000
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    li        t2, 0x2A05F200
    bne       a0, t2, fail

    # -5e9 -> -(0x2A05F200) mod 2^32 = 0xD5FA0E00, sign-ext 0xFFFFFFFFD5FA0E00
    li        t0, 0xC1F2A05F20000000
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    li        t2, 0xFFFFFFFFD5FA0E00
    bne       a0, t2, fail

    # 2^53 + 6 -> 6 (left-shift path, e=53)
    li        t0, 0x4340000000000003
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    li        t2, 6
    bne       a0, t2, fail

    # 2^84 -> 0 (e>=84: whole value is a multiple of 2^32)
    li        t0, 0x4530000000000000
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    bnez      a0, fail

    # 2^60 + 12345*2^8 -> 0x303900 (left-shift path, e=60)
    li        t0, 0x43B0000000003039
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    li        t2, 0x303900
    bne       a0, t2, fail

    # NaN -> 0
    li        t0, 0x7FF8000000000000
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    bnez      a0, fail

    # +inf -> 0
    li        t0, 0x7FF0000000000000
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    bnez      a0, fail

    # -inf -> 0
    li        t0, 0xFFF0000000000000
    fmv.d.x   f1, t0
    fcvtmod.w.d a0, f1, rtz
    bnez      a0, fail

    # ---- flag checks (same flags as fcvt.w.d) ----
    # 3.5: in-range inexact -> NX
    li        t0, 0x400C000000000000
    fmv.d.x   f1, t0
    csrw      fflags, x0
    fcvtmod.w.d a0, f1, rtz
    csrr      t3, fflags
    li        t2, 0x01
    bne       t3, t2, fail

    # 2.0: exact -> no flags
    li        t0, 0x4000000000000000
    fmv.d.x   f1, t0
    csrw      fflags, x0
    fcvtmod.w.d a0, f1, rtz
    csrr      t3, fflags
    bnez      t3, fail

    # 2^32: out-of-range -> NV (even though result is 0)
    li        t0, 0x41F0000000000000
    fmv.d.x   f1, t0
    csrw      fflags, x0
    fcvtmod.w.d a0, f1, rtz
    csrr      t3, fflags
    li        t2, 0x10
    bne       t3, t2, fail

    # NaN -> NV
    li        t0, 0x7FF8000000000000
    fmv.d.x   f1, t0
    csrw      fflags, x0
    fcvtmod.w.d a0, f1, rtz
    csrr      t3, fflags
    li        t2, 0x10
    bne       t3, t2, fail

    # pass
    li        t0, 1
    li        t1, 0x80001000
    sw        t0, 0(t1)
done:
    j         done
fail:
    li        t0, 3
    li        t1, 0x80001000
    sw        t0, 0(t1)
fail_done:
    j         fail_done

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
