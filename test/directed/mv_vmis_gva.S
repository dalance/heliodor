// A misaligned element of a vector access made in M-mode with MPRV and MPV
// set is a guest access: the trap into M sets mstatus.GVA (mtval holds a
// guest virtual address), as it does for a scalar access. vsatp and hgatp
// are Bare. Each sub-case s whose trap is wrong sets bit s-1 of the mask;
// tohost is 1 when the mask is 0, else (mask << 8) | 0x42.
//   1 vse32.v at a misaligned address: cause 6, GVA 1
//   2 vle32.v at a misaligned address: cause 4, GVA 1
//   3 amoadd.w at a misaligned address: cause 7, GVA 1
#include "common/probe.h"

#define MSTATUS_MPV  (1 << 39)
#define MSTATUS_GVA  (1 << 38)

.macro EXPECT_GVA sub, want, insn:vararg
    la      t0, trap_cause
    sd      zero, 0(t0)
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPRV | MSTATUS_MPV | MSTATUS_MPP_S
    csrs    mstatus, t0
    SET_RESUME 1f
    \insn
1:  li      t0, MSTATUS_MPRV | MSTATUS_MPV
    csrc    mstatus, t0
    csrr    t3, mstatus
    la      t0, trap_cause
    ld      t1, 0(t0)
    li      t2, \want
    bne     t1, t2, 2f
    li      t0, MSTATUS_GVA
    and     t3, t3, t0
    bnez    t3, 3f
2:  li      t0, 1 << (\sub - 1)
    or      s3, s3, t0
3:
.endm

    .section .text
main:
    li      s3, 0
    csrw    vsatp, zero
    csrw    hgatp, zero
    li      t0, MSTATUS_VS
    csrs    mstatus, t0
    vsetivli zero, 4, e32, m1, ta, ma
    li      s1, SCRATCH + 2
    EXPECT_GVA 1, 6, vse32.v v1, (s1)
    EXPECT_GVA 2, 4, vle32.v v1, (s1)
    EXPECT_GVA 3, 7, amoadd.w a0, a1, (s1)
    beqz    s3, 9f
    slli    s3, s3, 8
    ori     s3, s3, 0x42
    REPORT_REG s3
9:  REPORT  1
