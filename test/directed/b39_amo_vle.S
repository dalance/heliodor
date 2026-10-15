// B39: amoadd x0 followed by a vle of the same line.
//
// Spec: the vector load observes the AMO's result. 0xB027: the vle read
// the value from before the AMO (sub-case 1 same dword, 2 other dword of
// the same line).
#include "common/probe.h"

.macro TRY off
    ld      t0, \off(s0)
    addi    t0, t0, 3
    amoadd.d zero, s1, (s0)
    vle64.v v1, (s2)
    vmv.x.s t2, v1
    ld      t3, \off(s0)
.endm

    .section .text
main:
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    vsetivli zero, 1, e64, m1, ta, ma
    li      s0, SCRATCH + 0x1000
    li      s1, 3
    sd      zero, 0(s0)
    sd      zero, 8(s0)
    .rept 8
    mv      s2, s0
    TRY     0
    bne     t2, t0, bug_same
    bne     t3, t0, odd
    .endr
    .rept 8
    addi    s2, s0, 8
    ld      t0, 8(s0)
    li      t1, 7
    add     t0, t0, t1
    amoadd.d zero, t1, (s2)
    amoadd.d zero, s1, (s0)
    vle64.v v1, (s2)
    vmv.x.s t2, v1
    bne     t2, t0, bug_other
    .endr
    REPORT  1
bug_same:
    PRINT   'g', t2
    REPORT  CODE_BUG_SUB(39, 1)
bug_other:
    PRINT   'g', t2
    REPORT  CODE_BUG_SUB(39, 2)
odd:
    REPORT  CODE_ODD(0x39)
