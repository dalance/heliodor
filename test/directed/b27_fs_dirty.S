// B27: FP state writes must set mstatus.FS to Dirty.
//
// From FS=Clean: fld (sub-case 1), csrw fflags (2), fmv.d.x (3), each
// followed by a read of mstatus.FS. Spec: FS = Dirty (3) each time.
// 0xB01B with a sub-case mask: FS stayed Clean.
#include "common/probe.h"

.macro CASE op, sub
    li      t0, MSTATUS_FS
    csrc    mstatus, t0
    li      t0, MSTATUS_FS_CLEAN
    csrs    mstatus, t0
    \op
    csrr    t1, mstatus
    srli    t1, t1, 13
    andi    t1, t1, 3
    li      t0, 3
    beq     t1, t0, 1f
    PRINT   'f', t1
    ori     s10, s10, 1 << (\sub - 1)
1:
.endm

    .section .text
main:
    li      s10, 0
    li      s0, SCRATCH
    sd      zero, 0(s0)
    CASE    "fld f1, 0(s0)", 1
    CASE    "csrwi fflags, 1", 2
    CASE    "fmv.d.x f2, zero", 3
    beqz    s10, 9f
    slli    s10, s10, 16
    li      t0, CODE_BUG(27)
    or      s10, s10, t0
    REPORT_REG s10
9:  REPORT  1
