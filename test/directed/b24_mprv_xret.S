// B24: an MRET to a mode below M must clear MPRV.
//
// M-mode sets MPRV=1/MPP=S and mrets to S, which ecalls back. Spec:
// mstatus.MPRV reads 0. 0xB018: MPRV is still 1.
#include "common/probe.h"

    .section .text
main:
    SET_RESUME back
    li      t0, MSTATUS_MPRV
    csrs    mstatus, t0
    ENTER_S s_code
s_code:
    ecall
back:
    csrr    s1, mstatus
    la      t6, trap_rec
    ld      s2, 0(t6)
    PRINT   'm', s1
    PRINT   'c', s2
    li      t0, 9
    bne     s2, t0, odd
    li      t0, MSTATUS_MPRV
    and     t0, s1, t0
    bnez    t0, bug
    REPORT  1
bug:
    li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    REPORT  CODE_BUG(24)
odd:
    REPORT  CODE_ODD(0x24)
