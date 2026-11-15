// A PMP entry that matches some but not all bytes of an access makes it
// fail, whatever the privilege and the entry's permissions. Entry 0 is NA4
// on SCRATCH + 4 (no permission, unlocked), entry 1 a NAPOT over everything
// (RWX). Each M-mode access below covers SCRATCH .. SCRATCH + 7, so entry 0
// matches its upper half only: it must raise an access fault (cause 5 for a
// load, 7 for a store) with tval = SCRATCH. A missing or wrong trap sets bit
// s-1 of the mask; tohost is 1 when the mask is 0, else (mask << 8) | 0x42.
//   1 ld          2 sd          3 vle64.v (1 element)    4 vse64.v
//   5 vle32.v of 2 elements: element 1 (SCRATCH + 4) matches fully and is
//     allowed for M: no trap
//   6 amoadd.d    7 lr.d
//   8 cbo.zero    9 cbo.clean: the CMO spec checks the whole cache block
//     (spike checks only the byte at rs1 and does not trap)
#include "common/probe.h"

.macro CASE sub, cause
    la      t6, trap_rec
    sd      zero, 0(t6)
    sd      zero, 8(t6)
    SET_RESUME 1f
    li      a0, SCRATCH
.endm

.macro CHECK sub, cause
1:  la      t6, trap_rec
    ld      t1, 0(t6)
    li      t0, \cause
    bne     t1, t0, 2f
    beqz    t1, 3f
    ld      t1, 8(t6)
    li      t0, SCRATCH
    beq     t1, t0, 3f
2:  li      t0, 1 << (\sub - 1)
    or      s3, s3, t0
    PRINT   'c', t1
3:
.endm

    .section .text
main:
    li      s3, 0
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    li      t0, -1
    csrw    pmpaddr1, t0
    li      t0, (SCRATCH + 4) >> 2
    csrw    pmpaddr0, t0
    li      t0, (0x1f << 8) | 0x10
    csrw    pmpcfg0, t0
    vsetivli zero, 1, e64, m1, tu, mu
    CASE    1
    ld      t1, 0(a0)
    CHECK   1, 5
    CASE    2
    sd      zero, 0(a0)
    CHECK   2, 7
    CASE    3
    vle64.v v1, (a0)
    CHECK   3, 5
    CASE    4
    vse64.v v1, (a0)
    CHECK   4, 7
    vsetivli zero, 2, e32, m1, tu, mu
    CASE    5
    vle32.v v1, (a0)
    CHECK   5, 0
    CASE    6
    amoadd.d zero, zero, (a0)
    CHECK   6, 7
    CASE    7
    lr.d    t1, (a0)
    CHECK   7, 5
    CASE    8
    .insn   i 0x0f, 2, x0, a0, 4    // cbo.zero (a0)
    CHECK   8, 7
    CASE    9
    .insn   i 0x0f, 2, x0, a0, 1    // cbo.clean (a0)
    CHECK   9, 7
    li      t0, 0x1f
    csrw    pmpcfg0, t0
    beqz    s3, 9f
    slli    s3, s3, 8
    ori     s3, s3, 0x42
    REPORT_REG s3
9:  REPORT  1
