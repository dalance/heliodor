// Zvfhmin: the conversions between halves and singles at SEW 16.
//
// Spec: Zvfhmin adds vfwcvt.f.f.v and vfncvt.f.f.w at SEW 16 (rounding with
// frm, the flags of FCVT.S.H and FCVT.H.S); every other FP16 vector op
// needs Zvfh and is illegal.
// tohost: 1, or the number of the failing check:
//   2  vfwcvt.f.f.v 1.0h: not 0x3f800000
//   3  vfwcvt.f.f.v sNaN: not the canonical NaN with NV
//   4  vfncvt.f.f.w 1.0: not 0x3c00
//   5  vfncvt.f.f.w 65520.0 with frm RNE: not +inf with OF and NX
//   6  vfncvt.f.f.w 65520.0 with frm RTZ: not 0x7bff with NX alone
//   7  vfwcvt.f.f.v, vl 8: element 6 (second dest register) not 6.0
//   8  vfncvt.rod.f.f.w at SEW 16 (needs Zvfh): no cause 2
//   9  vfadd.vv at SEW 16 (needs Zvfh): no cause 2
#include "common/probe.h"

.macro E0 code, vd, val
    li      a0, \code
    vmv.x.s t0, \vd
    li      t1, \val
    bne     t0, t1, fail
.endm

.macro FFL code, val
    li      a0, \code
    csrr    t0, fflags
    li      t1, \val
    bne     t0, t1, fail
    csrw    fflags, zero
.endm

.macro ILL code
    li      a0, \code
    la      t6, trap_rec
    ld      t5, 24(t6)
    beqz    t5, fail
    sd      zero, 24(t6)
    ld      t5, 0(t6)
    li      t4, 2
    bne     t5, t4, fail
.endm

    .section .text
main:
    li      t0, MSTATUS_VS_INIT | MSTATUS_FS_INIT
    csrs    mstatus, t0
    csrw    frm, zero
    csrw    fflags, zero

    vsetivli zero, 1, e16, mf2, tu, mu
    li      t0, 0x3c00
    vmv.v.x v2, t0
    vfwcvt.f.f.v v4, v2
    vsetivli zero, 1, e32, m1, tu, mu
    E0      2, v4, 0x3f800000

    vsetivli zero, 1, e16, mf2, tu, mu
    li      t0, 0x7c01
    vmv.v.x v2, t0
    vfwcvt.f.f.v v4, v2
    vsetivli zero, 1, e32, m1, tu, mu
    E0      3, v4, 0x7fc00000
    FFL     3, 0x10

    li      t0, 0x3f800000
    vmv.v.x v4, t0
    vsetivli zero, 1, e16, mf2, tu, mu
    vfncvt.f.f.w v2, v4
    E0      4, v2, 0x3c00

    vsetivli zero, 1, e32, m1, tu, mu
    li      t0, 0x477ff000
    vmv.v.x v4, t0
    vsetivli zero, 1, e16, mf2, tu, mu
    vfncvt.f.f.w v2, v4
    E0      5, v2, 0x7c00
    FFL     5, 0x05
    li      t0, 1
    csrw    frm, t0
    vfncvt.f.f.w v2, v4
    E0      6, v2, 0x7bff
    FFL     6, 0x01
    csrw    frm, zero

    vsetivli zero, 8, e32, m2, tu, mu
    vmv.v.i v4, 0
    vsetivli zero, 8, e16, m1, tu, mu
    li      t0, 0x4600
    vmv.v.x v2, t0
    vfwcvt.f.f.v v4, v2
    vsetivli zero, 8, e32, m2, tu, mu
    vslidedown.vi v8, v4, 6
    E0      7, v8, 0x40c00000

    SET_RESUME 1f
    vsetivli zero, 1, e16, mf2, tu, mu
    vfncvt.rod.f.f.w v2, v4
1:  ILL     8

    SET_RESUME 1f
    vsetivli zero, 1, e16, mf2, tu, mu
    vfadd.vv v2, v2, v2
1:  ILL     9
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
