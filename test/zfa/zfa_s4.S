# P10 Zfa Stage 4: fli.s / fli.d — load an FP constant from the 32-entry table,
# selected by the rs1 *field* (an immediate index, not a register read).
# M-mode, tohost @ 0x80001000.  1 = PASS, 4 = FAIL.
#
# fmv.x.w sign-extends the single bits to 64; so the -1.0 expected value carries
# the upper-32 sign extension (see the Stage-2 fmv.x.w note).

    .section .text.init
    .globl _start
_start:
    li        t0, (1 << 13)
    csrs      mstatus, t0          # enable FS (mstatus.FS = Initial)

    # ---- fli.s (index in comment) ----
    fli.s     f1, -1.0             # 0
    fmv.x.w   t1, f1
    li        t2, 0xFFFFFFFFBF800000
    bne       t1, t2, fail

    fli.s     f1, min              # 1  (min positive normal, 2^-126)
    fmv.x.w   t1, f1
    li        t2, 0x00800000
    bne       t1, t2, fail

    fli.s     f1, 0.0625           # 6
    fmv.x.w   t1, f1
    li        t2, 0x3D800000
    bne       t1, t2, fail

    fli.s     f1, 0.3125           # 9
    fmv.x.w   t1, f1
    li        t2, 0x3EA00000
    bne       t1, t2, fail

    fli.s     f1, 0.5              # 12
    fmv.x.w   t1, f1
    li        t2, 0x3F000000
    bne       t1, t2, fail

    fli.s     f1, 1.0              # 16
    fmv.x.w   t1, f1
    li        t2, 0x3F800000
    bne       t1, t2, fail

    fli.s     f1, 2.5              # 21
    fmv.x.w   t1, f1
    li        t2, 0x40200000
    bne       t1, t2, fail

    fli.s     f1, inf              # 30
    fmv.x.w   t1, f1
    li        t2, 0x7F800000
    bne       t1, t2, fail

    fli.s     f1, nan              # 31  (canonical NaN)
    fmv.x.w   t1, f1
    li        t2, 0x7FC00000
    bne       t1, t2, fail

    # ---- fli.d ----
    fli.d     f2, -1.0             # 0
    fmv.x.d   t1, f2
    li        t2, 0xBFF0000000000000
    bne       t1, t2, fail

    fli.d     f2, min              # 1  (min positive normal, 2^-1022)
    fmv.x.d   t1, f2
    li        t2, 0x0010000000000000
    bne       t1, t2, fail

    fli.d     f2, 0.3125           # 9
    fmv.x.d   t1, f2
    li        t2, 0x3FD4000000000000
    bne       t1, t2, fail

    fli.d     f2, 1.0              # 16
    fmv.x.d   t1, f2
    li        t2, 0x3FF0000000000000
    bne       t1, t2, fail

    fli.d     f2, 2.5              # 21
    fmv.x.d   t1, f2
    li        t2, 0x4004000000000000
    bne       t1, t2, fail

    fli.d     f2, 128.0            # 26
    fmv.x.d   t1, f2
    li        t2, 0x4060000000000000
    bne       t1, t2, fail

    fli.d     f2, inf              # 30
    fmv.x.d   t1, f2
    li        t2, 0x7FF0000000000000
    bne       t1, t2, fail

    fli.d     f2, nan              # 31  (canonical NaN)
    fmv.x.d   t1, f2
    li        t2, 0x7FF8000000000000
    bne       t1, t2, fail

    # pass
    li        t0, 1
    li        t1, 0x80001000
    sw        t0, 0(t1)
done:
    j         done
fail:
    li        t0, 4
    li        t1, 0x80001000
    sw        t0, 0(t1)
fail_done:
    j         fail_done

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
