// B17: mtval of an EBREAK.
//
// Spec chosen for the new core: mtval = the EBREAK's pc (the platform
// description reports the VA). 0xB011: mtval is 0.
#include "common/probe.h"

    .section .text
main:
    SET_RESUME back
    .option push
    .option norvc
brk:
    ebreak
    .option pop
back:
    la      t6, trap_rec
    ld      s1, 0(t6)
    ld      s2, 8(t6)
    PRINT   'c', s1
    PRINT   'v', s2
    li      t0, 3
    bne     s1, t0, odd
    la      t0, brk
    beq     s2, t0, pass
    beqz    s2, bug
odd:
    REPORT  CODE_ODD(0x17)
pass:
    REPORT  1
bug:
    REPORT  CODE_BUG(17)
