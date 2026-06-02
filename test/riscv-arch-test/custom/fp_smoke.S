# M6.B.2 FP smoke test — exercises the FPU compute datapath WITHOUT FP
# load/store (those are M6.B.3). Seeds FP regs via int→FP converts, does
# FP→FP arithmetic + FP→int converts/compares, and signals pass/fail via
# the riscv-tests tohost word at 0x80001000.
    .section .text.init
    .globl _start
_start:
    # Enable FP unit: mstatus.FS = Initial (bit 13).
    li   t0, 0x2000
    csrs mstatus, t0

    # f1 = 2.0, f2 = 3.0 (signed int64 → double)
    li      t0, 2
    fcvt.d.l f1, t0
    li      t0, 3
    fcvt.d.l f2, t0

    # FADD.D: f3 = 2.0 + 3.0 = 5.0 ; t1 = (long)f3 == 5
    fadd.d   f3, f1, f2
    fcvt.l.d t1, f3
    li       t2, 5
    bne      t1, t2, fail

    # FMUL.D: f4 = 2.0 * 3.0 = 6.0 ; t1 == 6
    fmul.d   f4, f1, f2
    fcvt.l.d t1, f4
    li       t2, 6
    bne      t1, t2, fail

    # FSUB.D: f5 = 3.0 - 2.0 = 1.0 ; t1 == 1
    fsub.d   f5, f2, f1
    fcvt.l.d t1, f5
    li       t2, 1
    bne      t1, t2, fail

    # Single precision: f6 = 2.0f, f7 = 3.0f (int32 → single), FADD.S = 5.0f
    li       t0, 2
    fcvt.s.w f6, t0
    li       t0, 3
    fcvt.s.w f7, t0
    fadd.s   f8, f6, f7
    fcvt.w.s t1, f8
    li       t2, 5
    bne      t1, t2, fail

    # FEQ.D: 2.0 == 2.0 → 1
    feq.d    t1, f1, f1
    li       t2, 1
    bne      t1, t2, fail

    # FLT.D: 2.0 < 3.0 → 1
    flt.d    t1, f1, f2
    li       t2, 1
    bne      t1, t2, fail

    # FMV.X.D round-trip: move f1 bits to integer, FMV.D.X back, FEQ
    fmv.x.d  t0, f1
    fmv.d.x  f9, t0
    feq.d    t1, f9, f1
    li       t2, 1
    bne      t1, t2, fail

    # All passed.
    li       t3, 1
    j        done
fail:
    li       t3, 3          # fail code (>1)
done:
    li       t4, 0x80001000
    sd       t3, 0(t4)
1:  j        1b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
