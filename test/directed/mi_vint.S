// The integer vector instructions added in MI: vmv.s.x, vmv<nr>r.v, the
// multiply-adds, the widening multiply-adds, add/subtract with carry and
// vzext/vsext, with the reserved forms of their fields.
//
// Spec: RVV 1.0 sections 11.4, 11.13, 11.14, 16.1 and 16.6; a misaligned
// vmv<nr>r.v register, vadc with vd = v0, a source EEW below 8 and a 2*SEW
// of 128 are reserved (illegal on this core).
// tohost: 1, or the number of the failing check:
//   2  vmv.s.x: element 0 not the low SEW bits of x[rs1], or element 1 written
//   3  vmv.s.x with vl 0 wrote vd
//   4  vmv2r.v with vl 1: element 3 of the second register not copied
//   5-8  vmacc.vv, vnmsac.vx, vmadd.vv, vnmsub.vx: wrong element 3
//   9-11 vwmacc.vv, vwmaccsu.vv, vwmaccus.vx: wrong element 3 (SEW 64)
//   12 vadc.vvm: wrong elements 0 and 1
//   13 vmadc.vvm and vmadc.vv: wrong carry masks
//   14 vmsbc.vx and vmsbc.vxm: wrong borrow masks
//   15 vsbc.vvm: wrong element 2
//   16 vsext.vf2, vzext.vf4, vsext.vf8: wrong element
//   17 vsext.vf2 and vzext.vf4 at LMUL 2: wrong element in the second register
//   18-21 vzext.vf2 at SEW 8, vwmacc.vv at SEW 64, vmv2r.v v3, vadc.vvm
//      with vd = v0: no cause 2
#include "common/probe.h"

// Element \i of \vd (current SEW, sign-extended) reads \val; clobbers t0,
// t1, v30 and v31.
.macro ELEM code, vd, i, val
    li      a0, \code
    vslidedown.vi v30, \vd, \i
    vmv.x.s t0, v30
    li      t1, \val
    bne     t0, t1, fail
.endm

// The low 4 bits of mask register \vd read \val.
.macro MASK4 code, vd, val
    li      a0, \code
    vsetivli zero, 1, e8, m1, tu, mu
    vmv.x.s t0, \vd
    andi    t0, t0, 0xf
    li      t1, \val
    bne     t0, t1, fail
    vsetivli zero, 4, e32, m1, tu, mu
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
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0

    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.i v1, 9
    li      t2, 0x123456789
    vmv.s.x v1, t2
    ELEM    2, v1, 0, 0x23456789
    ELEM    2, v1, 1, 9
    vmv.v.i v1, 9
    vsetivli zero, 0, e32, m1, tu, mu
    vmv.s.x v1, t2
    vsetivli zero, 4, e32, m1, tu, mu
    ELEM    3, v1, 0, 9

    vmv.v.i v2, 5
    vmv.v.i v3, 6
    vmv.v.i v4, 0
    vmv.v.i v5, 0
    vsetivli zero, 1, e32, m1, tu, mu
    vmv2r.v v4, v2
    vsetivli zero, 4, e32, m1, tu, mu
    ELEM    4, v5, 3, 6

    vmv.v.i v1, 10
    vmv.v.i v2, 3
    vmv.v.i v3, 4
    li      a1, 2
    vmacc.vv v1, v2, v3
    ELEM    5, v1, 3, 22
    vnmsac.vx v1, a1, v2
    ELEM    6, v1, 3, 16
    vmadd.vv v1, v2, v3
    ELEM    7, v1, 3, 52
    vnmsub.vx v1, a1, v2
    ELEM    8, v1, 3, -101

    vsetivli zero, 4, e64, m2, tu, mu
    vmv.v.i v4, 0
    li      t0, 100
    vadd.vx v4, v4, t0
    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.i v3, -4
    vwmacc.vv v4, v2, v3
    vsetivli zero, 4, e64, m2, tu, mu
    ELEM    9, v4, 3, 88
    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.i v6, -1
    vmv.v.i v7, 2
    vwmaccsu.vv v4, v6, v7
    vsetivli zero, 4, e64, m2, tu, mu
    ELEM    10, v4, 3, 86
    vsetivli zero, 4, e32, m1, tu, mu
    li      a2, 0xffffffff
    vmv.v.i v7, -1
    vwmaccus.vx v4, a2, v7
    vsetivli zero, 4, e64, m2, tu, mu
    ELEM    11, v4, 3, 86 - 0xffffffff

    vsetivli zero, 4, e32, m1, tu, mu
    li      t0, 0x5
    vmv.s.x v0, t0
    vid.v   v2
    vrsub.vi v2, v2, -1
    vmv.v.i v3, 2
    vadc.vvm v1, v2, v3, v0
    ELEM    12, v1, 0, 2
    ELEM    12, v1, 1, 0
    vmadc.vvm v8, v2, v3, v0
    MASK4   13, v8, 0x7
    vmadc.vv v8, v2, v3
    MASK4   13, v8, 0x3
    li      a3, 0xfffffffe
    vmsbc.vx v8, v2, a3
    MASK4   14, v8, 0xc
    li      t0, 0x2
    vmv.s.x v0, t0
    vmsbc.vxm v8, v2, a3, v0
    MASK4   14, v8, 0xe
    li      t0, 0x4
    vmv.s.x v0, t0
    vsbc.vvm v1, v3, v2, v0
    ELEM    15, v1, 2, 4

    vsetivli zero, 4, e16, m1, tu, mu
    vmv.v.i v2, -2
    vsetivli zero, 4, e32, m1, tu, mu
    vsext.vf2 v8, v2
    ELEM    16, v8, 3, -2
    vsetivli zero, 4, e8, m1, tu, mu
    vmv.v.i v2, -2
    vsetivli zero, 4, e32, m1, tu, mu
    vzext.vf4 v8, v2
    ELEM    16, v8, 3, 0xfe
    vsetivli zero, 2, e8, m1, tu, mu
    li      t0, 0x80
    vmv.v.x v2, t0
    vsetivli zero, 2, e64, m1, tu, mu
    vsext.vf8 v8, v2
    ELEM    16, v8, 1, -128

    vsetivli zero, 8, e16, m1, tu, mu
    vid.v   v2
    vsetivli zero, 8, e32, m2, tu, mu
    vsext.vf2 v8, v2
    ELEM    17, v8, 5, 5
    vsetivli zero, 8, e8, m1, tu, mu
    vid.v   v2
    vsetivli zero, 8, e32, m2, tu, mu
    vzext.vf4 v8, v2
    ELEM    17, v8, 6, 6

    SET_RESUME 1f
    vsetivli zero, 4, e8, m1, tu, mu
    vzext.vf2 v8, v2
1:  ILL     18
    SET_RESUME 1f
    vsetivli zero, 1, e64, m1, tu, mu
    vwmacc.vv v4, v2, v3
1:  ILL     19
    SET_RESUME 1f
    vsetivli zero, 4, e32, m1, tu, mu
    vmv2r.v v3, v2
1:  ILL     20
    SET_RESUME 1f
    vadc.vvm v0, v2, v3, v0
1:  ILL     21
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
