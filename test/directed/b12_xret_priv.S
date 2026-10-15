// B12: MRET in S/U and SRET in U must be illegal.
//
// Sub-case 1: U-mode mret; 2: S-mode mret; 3: U-mode sret. Spec: cause 2
// each. 0xB00C with a sub-case mask: the xRET executed (a re-executed mret lands on its own
// lower-mode entry again, which the s7 counter turns into an ecall).
#include "common/probe.h"

.macro CASE enter, op, sub
    la      t6, trap_rec
    sd      zero, 0(t6)
    li      s7, 0
    SET_RESUME 1f
    la      t0, 3f
    csrw    sepc, t0
    \enter  2f
2:  addi    s7, s7, 1
    li      t0, 1
    bgtu    s7, t0, 3f
    \op
3:  ecall
1:  la      t6, trap_rec
    ld      t1, 0(t6)
    li      t0, 2
    beq     t1, t0, 4f
    PRINT   'c', t1
    ori     s10, s10, 1 << (\sub - 1)
4:
.endm

    .section .text
main:
    li      s10, 0
    CASE    ENTER_U, mret, 1
    CASE    ENTER_S, mret, 2
    CASE    ENTER_U, sret, 3
    beqz    s10, 9f
    slli    s10, s10, 16
    li      t0, CODE_BUG(12)
    or      s10, s10, t0
    REPORT_REG s10
9:  REPORT  1
