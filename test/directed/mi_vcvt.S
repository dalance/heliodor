// Vector FP conversions on the scalar converter: rounding mode, round to
// odd, flags, and the reserved frm.
//
// Spec: vfcvt/vfwcvt/vfncvt round with frm (rtz forms toward zero, rod to
// odd) and raise the IEEE flags of the scalar FCVT; a vector FP
// instruction is illegal while frm holds a reserved value.
// tohost: 1, or the number of the failing check:
//   2  vfcvt.x.f.v 1.5 with frm RUP: not 2
//   3  vfcvt.x.f.v -1.5 with frm RDN: not -2
//   4  vfwcvt.x.f.v 1.5 with frm RUP: not 2
//   5  vfncvt.x.f.w 2.5 (double) with frm RUP: not 3
//   6  vfncvt.rod.f.f.w 1 + 2^-30: not 0x3f800001 with NX
//   7  vfncvt.f.f.w 1e300: not +inf with OF and NX
//   8  vfadd.vv with frm 5: no cause 2
#include "common/probe.h"

.macro FRM m
    li      t0, \m
    csrw    frm, t0
    csrw    fflags, zero
.endm

// Element 0 of \vd (scalar move at the current SEW) reads \val.
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
.endm

    .section .text
main:
    li      t0, MSTATUS_VS_INIT | MSTATUS_FS_INIT
    csrs    mstatus, t0

    vsetivli zero, 1, e32, m1, tu, mu
    li      t0, 0x3fc00000
    vmv.v.x v2, t0
    FRM     3
    vfcvt.x.f.v v1, v2
    E0      2, v1, 2
    li      t0, 0xbfc00000
    vmv.v.x v2, t0
    FRM     2
    vfcvt.x.f.v v1, v2
    E0      3, v1, -2

    li      t0, 0x3fc00000
    vmv.v.x v2, t0
    FRM     3
    vfwcvt.x.f.v v4, v2
    vsetivli zero, 1, e64, m1, tu, mu
    E0      4, v4, 2

    li      t0, 0x4004000000000000
    vmv.v.x v2, t0
    vsetivli zero, 1, e32, m1, tu, mu
    FRM     3
    vfncvt.x.f.w v1, v2
    E0      5, v1, 3

    vsetivli zero, 1, e64, m1, tu, mu
    li      t0, 0x3ff0000000400000
    vmv.v.x v2, t0
    vsetivli zero, 1, e32, m1, tu, mu
    FRM     0
    vfncvt.rod.f.f.w v1, v2
    E0      6, v1, 0x3f800001
    FFL     6, 0x01

    vsetivli zero, 1, e64, m1, tu, mu
    li      t0, 0x7e37e43c8800759c
    vmv.v.x v2, t0
    vsetivli zero, 1, e32, m1, tu, mu
    FRM     0
    vfncvt.f.f.w v1, v2
    E0      7, v1, 0x7f800000
    FFL     7, 0x05

    SET_RESUME 1f
    FRM     5
    vfadd.vv v1, v2, v2
1:  li      a0, 8
    la      t6, trap_rec
    ld      t5, 24(t6)
    beqz    t5, fail
    ld      t5, 0(t6)
    li      t4, 2
    bne     t5, t4, fail
    FRM     0
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
