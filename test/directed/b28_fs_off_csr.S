// B28: FP CSR access with FS=Off must be illegal.
//
// M-mode "csrr t1, fflags" (sub-case 1) and "csrr t1, frm" (2) with
// mstatus.FS=0. Spec: illegal instruction (cause 2). 0xB01C with a sub-case mask: no trap.
#include "common/probe.h"

.macro CASE op, sub
    la      t6, trap_rec
    sd      zero, 0(t6)
    SET_RESUME 1f
    \op
1:  la      t6, trap_rec
    ld      t1, 0(t6)
    li      t0, 2
    beq     t1, t0, 2f
    PRINT   'c', t1
    ori     s10, s10, 1 << (\sub - 1)
2:
.endm

    .section .text
main:
    li      s10, 0
    li      t0, MSTATUS_FS
    csrc    mstatus, t0
    CASE    "csrr t1, fflags", 1
    CASE    "csrr t1, frm", 2
    beqz    s10, 9f
    slli    s10, s10, 16
    li      t0, CODE_BUG(28)
    or      s10, s10, t0
    REPORT_REG s10
9:  REPORT  1
