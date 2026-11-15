// A vector op's FP scalar f[rs1] at SEW 32 must be NaN-boxed: a value whose
// upper 32 bits are not all ones reads as the canonical NaN (0x7fc00000).
// f1 holds 0x00000000_3f800000 (1.0f, not boxed), f2 the boxed 1.0f. Each
// sub-case s whose result is wrong sets bit s-1 of the mask; tohost is 1
// when the mask is 0, else (mask << 8) | 0x42.
//   1 vfmv.v.f              element 0 = 0x7fc00000
//   2 vfadd.vf (0 + f1)     element 0 = 0x7fc00000
//   3 vfmv.s.f              element 0 = 0x7fc00000
//   4 vfslide1down.vf       element 3 = 0x7fc00000
//   5 vfwadd.vf (0 + f1)    element 0 = 0x7ff8000000000000
//   6 vfmv.v.f with f2      element 0 = 0x3f800000
#include "common/probe.h"

.macro CHECK sub, want
    li      t2, \want
    beq     t1, t2, 1f
    li      t0, 1 << (\sub - 1)
    or      s3, s3, t0
    PRINT   'r', t1
1:
.endm

    .section .text
main:
    li      s3, 0
    li      t0, MSTATUS_VS_INIT | MSTATUS_FS_INIT
    csrs    mstatus, t0
    li      t0, 0x3f800000
    fmv.d.x f1, t0
    li      t0, 0xffffffff3f800000
    fmv.d.x f2, t0
    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.i v3, 0
    vfmv.v.f v1, f1
    vmv.x.s t1, v1
    CHECK   1, 0x7fc00000
    vfadd.vf v2, v3, f1
    vmv.x.s t1, v2
    CHECK   2, 0x7fc00000
    vmv.v.i v4, 0
    vfmv.s.f v4, f1
    vmv.x.s t1, v4
    CHECK   3, 0x7fc00000
    vfslide1down.vf v5, v3, f1
    vslidedown.vi v6, v5, 3
    vmv.x.s t1, v6
    CHECK   4, 0x7fc00000
    vfwadd.vf v8, v3, f1
    vsetivli zero, 2, e64, m1, tu, mu
    vmv.x.s t1, v8
    CHECK   5, 0x7ff8000000000000
    vsetivli zero, 4, e32, m1, tu, mu
    vfmv.v.f v1, f2
    vmv.x.s t1, v1
    CHECK   6, 0x3f800000
    beqz    s3, 9f
    slli    s3, s3, 8
    ori     s3, s3, 0x42
    REPORT_REG s3
9:  REPORT  1
