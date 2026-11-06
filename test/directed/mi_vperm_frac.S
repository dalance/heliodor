// MI: vrgather and vslidedown bound their source index by VLMAX, which a
// fractional LMUL makes smaller than the elements of one register. At e16 mf2
// (VLMAX 4) the source elements 4-7 of v1 hold data but must read as 0.
// tohost is 1, or 0x42 | (sub-case << 8) for the first wrong result:
//   1 vrgather.vi v2, v1, 5      element 0 is 0
//   2 vslidedown.vi v2, v1, 2    element 2 is 0
//   3 vrgather.vx with index 3   element 0 is v1[3] (in range)
#include "common/probe.h"

.macro VCHECK sub, elem, want
    vslidedown.vi v3, v2, \elem
    vmv.x.s t1, v3
    li      t2, \want
    beq     t1, t2, 1f
    PRINT   'r', t1
    li      t0, (\sub << 8) | 0x42
    REPORT_REG t0
1:
.endm

    .section .text
main:
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    vsetivli zero, 8, e16, m1, ta, ma
    vid.v   v1
    vadd.vi v1, v1, 1               // v1 = 1..8
    vsetivli zero, 4, e16, mf2, ta, ma
    vrgather.vi v2, v1, 5
    VCHECK  1, 0, 0
    vslidedown.vi v2, v1, 2
    VCHECK  2, 2, 0
    li      t0, 3
    vrgather.vx v2, v1, t0
    VCHECK  3, 0, 4
    REPORT  1
