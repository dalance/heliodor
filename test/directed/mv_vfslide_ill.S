// vfslide1up.vf and vfslide1down.vf are vector FP instructions: illegal at
// SEW 8 and 16 (no Zvfh), with mstatus.FS or VS Off, and in VS with
// vsstatus.FS or VS Off. Each sub-case s that does not raise illegal
// instruction sets bit s-1 of the mask; tohost is 1 when the mask is 0,
// else (mask << 8) | 0x42.
//   1 M, SEW 16: vfslide1down.vf
//   2 M, SEW 8: vfslide1up.vf
//   3 M, SEW 32, mstatus.FS Off: vfslide1down.vf
//   4 VS, SEW 32, vsstatus.VS Off: vfslide1down.vf
//   5 VS, SEW 32, vsstatus.FS Off: vfslide1up.vf
#include "common/probe.h"

// Run insn at the current privilege; count it in s3 unless it trapped with
// cause 2.
.macro EXPECT_ILL sub, insn:vararg
    la      t0, trap_cnt
    sd      zero, 0(t0)
    SET_RESUME 1f
    \insn
1:  la      t0, trap_cnt
    ld      t1, 0(t0)
    la      t0, trap_cause
    ld      t2, 0(t0)
    li      t3, 1
    bne     t1, t3, 2f
    li      t3, 2
    beq     t2, t3, 3f
2:  li      t0, 1 << (\sub - 1)
    or      s3, s3, t0
3:
.endm

    .section .text
main:
    li      s3, 0
    li      t0, MSTATUS_FS | MSTATUS_VS
    csrs    mstatus, t0
    vsetivli zero, 4, e16, m1, ta, ma
    EXPECT_ILL 1, vfslide1down.vf v1, v2, f3
    vsetivli zero, 4, e8, m1, ta, ma
    EXPECT_ILL 2, vfslide1up.vf v1, v2, f3
    vsetivli zero, 4, e32, m1, ta, ma
    li      t0, MSTATUS_FS
    csrc    mstatus, t0
    EXPECT_ILL 3, vfslide1down.vf v1, v2, f3
    li      t0, MSTATUS_FS
    csrs    mstatus, t0
    // VS with vsstatus.FS on, VS off, then FS off, VS on.
    csrw    vsatp, zero
    csrw    hgatp, zero
    li      t0, MSTATUS_FS
    csrw    vsstatus, t0
    la      t0, 4f
    csrw    mepc, t0
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S | (1 << 39)
    csrs    mstatus, t0
    mret
4:  EXPECT_ILL 4, vfslide1down.vf v1, v2, f3
    SET_RESUME 6f
    ecall
6:  li      t0, MSTATUS_VS
    csrw    vsstatus, t0
    la      t0, 5f
    csrw    mepc, t0
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S | (1 << 39)
    csrs    mstatus, t0
    mret
5:  EXPECT_ILL 5, vfslide1up.vf v1, v2, f3
    SET_RESUME 7f
    ecall
7:  beqz    s3, 9f
    slli    s3, s3, 8
    ori     s3, s3, 0x42
    REPORT_REG s3
9:  REPORT  1
