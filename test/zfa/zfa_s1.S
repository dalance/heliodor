# P10 Zfa Stage 1 directed test: fminm/fmaxm (NaN -> canonical) + fleq/fltq (quiet).
# M-mode, riscv-tests tohost @ 0x80001000.  1 = PASS, 3 = FAIL.

    .section .text.init
    .globl _start
_start:
    li        t0, (1 << 13)        # mstatus.FS = Initial (enable FP)
    csrs      mstatus, t0

    # single-precision constants via fmv.w.x
    li        t0, 0x3f800000
    fmv.w.x   f1, t0               # 1.0f
    li        t0, 0x40000000
    fmv.w.x   f2, t0               # 2.0f
    li        t0, 0x7fc00000
    fmv.w.x   f3, t0               # qNaN

    fminm.s   f4, f1, f2           # min(1,2) = 1.0
    fmv.x.w   t1, f4
    li        t2, 0x3f800000
    bne       t1, t2, fail

    fmaxm.s   f4, f1, f2           # max(1,2) = 2.0
    fmv.x.w   t1, f4
    li        t2, 0x40000000
    bne       t1, t2, fail

    fminm.s   f4, f3, f2           # min(NaN,2) = canonical NaN (KEY vs fmin)
    fmv.x.w   t1, f4
    li        t2, 0x7fc00000
    bne       t1, t2, fail

    fmaxm.s   f4, f2, f3           # max(2,NaN) = canonical NaN
    fmv.x.w   t1, f4
    bne       t1, t2, fail

    fleq.s    t1, f2, f2           # 2 <= 2 -> 1
    li        t2, 1
    bne       t1, t2, fail
    fltq.s    t1, f1, f2           # 1 < 2 -> 1
    bne       t1, t2, fail

    csrw      fflags, x0           # quiet compare with qNaN: result 0, NO NV flag
    fltq.s    t1, f3, f2
    bnez      t1, fail
    csrr      t3, fflags
    bnez      t3, fail

    csrw      fflags, x0           # contrast: signaling flt with qNaN DOES set NV
    flt.s     t1, f3, f2
    csrr      t3, fflags
    li        t2, 0x10
    bne       t3, t2, fail

    # double-precision: fminm.d with NaN -> canonical, fleq.d sanity
    li        t0, 0x7ff8000000000000
    fmv.d.x   f3, t0               # qNaN (double)
    li        t4, 0x4000000000000000
    fmv.d.x   f2, t4               # 2.0d
    fminm.d   f4, f3, f2
    fmv.x.d   t1, f4
    bne       t1, t0, fail         # canonical NaN
    fleq.d    t1, f2, f2
    li        t2, 1
    bne       t1, t2, fail

    li        t0, 1                # PASS
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
