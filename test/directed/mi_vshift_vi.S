// MI: the .vi shifts take imm5 as uimm5. At SEW 64 the shift amount has 6
// bits, so an imm5 with bit 4 set must shift by 16-31, not by that plus 32.
// tohost is 1, or 0x42 | (sub-case << 8) for the first wrong result:
//   1 vsll.vi 16   2 vsrl.vi 31   3 vsra.vi 17   4 vssrl.vi 20 (vxrm rdn)
#include "common/probe.h"

.macro VCHECK sub, want
    vmv.x.s t1, v2
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
    csrwi   vxrm, 2
    vsetivli zero, 2, e64, m1, ta, ma
    li      t0, 0x8123456789abcdef
    vmv.v.x v1, t0
    vsll.vi v2, v1, 16
    VCHECK  1, 0x456789abcdef0000
    vsrl.vi v2, v1, 31
    VCHECK  2, 0x102468acf
    vsra.vi v2, v1, 17
    VCHECK  3, 0xffffc091a2b3c4d5
    vssrl.vi v2, v1, 20
    VCHECK  4, 0x8123456789a
    REPORT  1
