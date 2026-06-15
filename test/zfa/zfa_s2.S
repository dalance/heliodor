# P10 Zfa Stage 2: fround / froundnx with STATIC rounding mode (funct3),
# mirroring how riscv-tests validate FP rounding. Avoids the dynamic-frm path.
# M-mode, tohost @ 0x80001000.  1 = PASS, 3 = FAIL.

    .section .text.init
    .globl _start
_start:
    li        t0, (1 << 13)
    csrs      mstatus, t0

    li        t0, 0x40200000
    fmv.w.x   f1, t0             # 2.5f
    li        t0, 0x40600000
    fmv.w.x   f2, t0             # 3.5f
    li        t0, 0xBE99999A
    fmv.w.x   f3, t0             # -0.3f
    li        t0, 0x3E99999A
    fmv.w.x   f4, t0             # 0.3f
    li        t0, 0xC0200000
    fmv.w.x   f5, t0             # -2.5f

    fround.s  f6, f1, rne        # 2.5 -> 2.0
    fmv.x.w   t1, f6
    li        t2, 0x40000000
    bne       t1, t2, fail

    fround.s  f6, f2, rne        # 3.5 -> 4.0
    fmv.x.w   t1, f6
    li        t2, 0x40800000
    bne       t1, t2, fail

    fround.s  f6, f1, rup        # 2.5 -> 3.0
    fmv.x.w   t1, f6
    li        t2, 0x40400000
    bne       t1, t2, fail

    fround.s  f6, f3, rdn        # -0.3 -> -1.0
    fmv.x.w   t1, f6
    li        t2, 0xFFFFFFFFBF800000
    bne       t1, t2, fail

    fround.s  f6, f4, rup        # 0.3 -> 1.0
    fmv.x.w   t1, f6
    li        t2, 0x3F800000
    bne       t1, t2, fail

    fround.s  f6, f5, rtz        # -2.5 -> -2.0
    fmv.x.w   t1, f6
    li        t2, 0xFFFFFFFFC0000000
    bne       t1, t2, fail

    fround.s  f6, f1, rmm        # 2.5 -> 3.0 (ties to max magnitude)
    fmv.x.w   t1, f6
    li        t2, 0x40400000
    bne       t1, t2, fail

    # froundnx sets inexact; fround does not
    csrw      fflags, x0
    froundnx.s f6, f1, rne
    csrr      t3, fflags
    li        t2, 0x01
    bne       t3, t2, fail

    csrw      fflags, x0
    fround.s  f6, f1, rne
    csrr      t3, fflags
    bnez      t3, fail

    li        t0, 0x40000000
    fmv.w.x   f7, t0             # 2.0 exact
    csrw      fflags, x0
    froundnx.s f6, f7, rne
    csrr      t3, fflags
    bnez      t3, fail           # exact -> no inexact

    # double
    li        t0, 0x4004000000000000
    fmv.d.x   f1, t0             # 2.5d
    fround.d  f6, f1, rne
    fmv.x.d   t1, f6
    li        t2, 0x4000000000000000
    bne       t1, t2, fail

    li        t0, 0xBFD3333333333333
    fmv.d.x   f3, t0             # -0.3d
    fround.d  f6, f3, rdn
    fmv.x.d   t1, f6
    li        t2, 0xBFF0000000000000
    bne       t1, t2, fail

    # dynamic rounding via frm (validates the csrw-frm implicit redirect):
    # round(2.5) under frm=RUP must give 3.0 immediately after csrw frm.
    li        t0, 0x40200000
    fmv.w.x   f1, t0             # 2.5
    li        t0, 3
    csrw      frm, t0            # RUP
    fround.s  f6, f1             # dynamic rm
    fmv.x.w   t1, f6
    li        t2, 0x40400000
    bne       t1, t2, fail

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
