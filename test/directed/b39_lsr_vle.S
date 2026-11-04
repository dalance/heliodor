// B39: a vector load next to scalar loads still in flight.
//
// Spec: every load returns its own line's data. Each try runs a scalar
// load, a vle64 of another line and a younger scalar load of a third line,
// all three lines cold. 0xB027 + sub-case: 5 the older scalar load was
// wrong, 6 the vector element was wrong, 7 the younger scalar load was
// wrong.
#include "common/probe.h"

.macro TRY i, j, k
    ld      t0, (\i * 64)(s0)
    addi    s2, s0, \j * 64
    vle64.v v1, (s2)
    vmv.x.s t1, v1
    ld      t2, (\k * 64)(s0)
    li      t3, 0x1000 + \i
    bne     t0, t3, bad_old
    li      t3, 0x1000 + \j
    bne     t1, t3, bad_vec
    li      t3, 0x1000 + \k
    bne     t2, t3, bad_young
.endm

    .section .text
main:
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    vsetivli zero, 1, e64, m1, ta, ma
    la      s0, tbl
    TRY     0, 1, 2
    TRY     3, 4, 5
    TRY     6, 7, 6
    TRY     8, 8, 9
    TRY     10, 11, 11
    TRY     12, 13, 14
    REPORT  1
bad_old:
    PRINT   'o', t0
    REPORT  CODE_BUG_SUB(39, 5)
bad_vec:
    PRINT   'v', t1
    REPORT  CODE_BUG_SUB(39, 6)
bad_young:
    PRINT   'y', t2
    REPORT  CODE_BUG_SUB(39, 7)

    .section .data
    .align 6
tbl:
    .set n, 0
    .rept 16
    .dword 0x1000 + n
    .dword 0, 0, 0, 0, 0, 0, 0
    .set n, n + 1
    .endr
