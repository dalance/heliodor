// vsetvli x0, x0 keeps vl only when VLMAX does not change; otherwise the
// encoding is reserved and this configuration sets vill (vl = 0). A vill
// vtype has VLMAX 0, so x0, x0 from it sets vill again. Each sub-case s
// whose vtype or vl is wrong sets bit s-1 of the mask; tohost is 1 when the
// mask is 0, else (mask << 8) | 0x42.
//   1 e32,m1 vl 4 -> e32,m2: vill, vl 0
//   2 e32,m1 vl 4 -> e64,m2: vtype 0x19, vl 4
//   3 vill -> e32,m1: vill, vl 0
//   4 e8,mf8 vl 1 -> e64,m1 (VLMAX 2 both): vtype 0x18, vl 1
#include "common/probe.h"

.macro CHECK sub, vt, vl
    csrr    t1, vtype
    li      t2, \vt
    bne     t1, t2, 2f
    csrr    t1, vl
    li      t2, \vl
    beq     t1, t2, 1f
2:  li      t0, 1 << (\sub - 1)
    or      s3, s3, t0
    PRINT   'r', t1
1:
.endm

    .section .text
main:
    li      s3, 0
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    vsetivli zero, 4, e32, m1, tu, mu
    vsetvli zero, zero, e32, m2, tu, mu
    CHECK   1, 0x8000000000000000, 0
    vsetivli zero, 4, e32, m1, tu, mu
    vsetvli zero, zero, e64, m2, tu, mu
    CHECK   2, 0x19, 4
    li      t0, -1
    vsetvl  zero, t0, t0
    vsetvli zero, zero, e32, m1, tu, mu
    CHECK   3, 0x8000000000000000, 0
    vsetivli zero, 1, e8, mf8, tu, mu
    vsetvli zero, zero, e64, m1, tu, mu
    CHECK   4, 0x18, 1
    beqz    s3, 9f
    slli    s3, s3, 8
    ori     s3, s3, 0x42
    REPORT_REG s3
9:  REPORT  1
