// Zvbb (with Zvkb): vandn, vrol, vror, the VXUNARY0 bit ops and vwsll,
// with the forms ACT4 does not exercise: masking, vror.vi with uimm bit 5,
// vwsll at LMUL 2 and its 2*SEW shift mask, and the reserved encodings.
//
// Spec: RISC-V vector crypto 1.0, Zvbb; vwsll at SEW 64 (EEW 128), the
// VXUNARY0 vs1 values 01011 and 01111, OPIVI funct6 000001 and arithmetic at
// vstart != 0 are illegal on this core.
// tohost: 1, or the number of the failing check:
//   2-3  vandn.vv (SEW 32), vandn.vx (SEW 8)
//   4    vrol.vv (SEW 16, the amount masked to 4 bits)
//   5-7  vror.vx (SEW 64), vror.vi with uimm 36 (SEW 64), vror.vi (SEW 8)
//   8-10 vbrev8 (SEW 32), vrev8 (SEW 64), vbrev (SEW 16)
//   11   vclz (SEW 32, and of 0)
//   12   vctz (SEW 64, of 0, and SEW 8)
//   13   vcpop.v (SEW 16)
//   14   vclz.v with vm = 0: inactive elements written
//   15   vwsll.vv (SEW 8, the amount masked to 4 bits)
//   16   vwsll.vx (SEW 32, the source zero-extended)
//   17   vwsll.vi at LMUL 2: wrong element in the fourth dest register
//   18-21 vwsll.vv at SEW 64, VXUNARY0 vs1 01011, OPIVI funct6 000001,
//      vclz.v at vstart 1: no cause 2
#include "common/probe.h"

    .option arch, +zvbb

// Element \i of \vd (current SEW, sign-extended) reads \val; clobbers t0,
// t1, v30 and v31.
.macro ELEM code, vd, i, val
    li      a0, \code
    vslidedown.vi v30, \vd, \i
    vmv.x.s t0, v30
    li      t1, \val
    bne     t0, t1, fail
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
    li      t0, 0x12345678
    vmv.v.x v2, t0
    li      t0, 0xffff
    vmv.v.x v3, t0
    vandn.vv v1, v2, v3
    ELEM    2, v1, 3, 0x12340000
    vsetivli zero, 16, e8, m1, tu, mu
    li      t0, 0x5a
    vmv.v.x v2, t0
    li      a1, 0x0f
    vandn.vx v1, v2, a1
    ELEM    3, v1, 15, 0x50

    vsetivli zero, 8, e16, m1, tu, mu
    li      t0, 0x8001
    vmv.v.x v2, t0
    vmv.v.i v3, 15
    vadd.vi v3, v3, 2
    vrol.vv v1, v2, v3
    ELEM    4, v1, 7, 0x0003

    vsetivli zero, 2, e64, m1, tu, mu
    vmv.v.i v2, 1
    li      a1, 1
    vror.vx v1, v2, a1
    ELEM    5, v1, 1, 0x8000000000000000
    vror.vi v1, v2, 36
    ELEM    6, v1, 1, 0x10000000
    vsetivli zero, 16, e8, m1, tu, mu
    vmv.v.i v2, 1
    vror.vi v1, v2, 3
    ELEM    7, v1, 9, 0x20

    vsetivli zero, 4, e32, m1, tu, mu
    li      t0, 0x01020380
    vmv.v.x v2, t0
    vbrev8.v v1, v2
    ELEM    8, v1, 2, 0xffffffff8040c001
    vsetivli zero, 2, e64, m1, tu, mu
    li      t0, 0x0102030405060708
    vmv.v.x v2, t0
    vrev8.v v1, v2
    ELEM    9, v1, 1, 0x0807060504030201
    vsetivli zero, 8, e16, m1, tu, mu
    vmv.v.i v2, 1
    vbrev.v v1, v2
    ELEM    10, v1, 5, -0x8000

    vsetivli zero, 4, e32, m1, tu, mu
    li      t0, 0x00010000
    vmv.v.x v2, t0
    vmv.s.x v2, zero
    vclz.v  v1, v2
    ELEM    11, v1, 3, 15
    ELEM    11, v1, 0, 32
    vsetivli zero, 2, e64, m1, tu, mu
    li      t0, 0x100
    vmv.v.x v2, t0
    vmv.s.x v2, zero
    vctz.v  v1, v2
    ELEM    12, v1, 1, 8
    ELEM    12, v1, 0, 64
    vsetivli zero, 16, e8, m1, tu, mu
    li      t0, 0x80
    vmv.v.x v2, t0
    vctz.v  v1, v2
    ELEM    12, v1, 11, 7
    vsetivli zero, 8, e16, m1, tu, mu
    li      t0, 0x1234
    vmv.v.x v2, t0
    li      t0, -1
    vmv.s.x v2, t0
    vcpop.v v1, v2
    ELEM    13, v1, 0, 16
    ELEM    13, v1, 6, 5

    vsetivli zero, 4, e32, m1, tu, mu
    li      t0, 0x5
    vmv.s.x v0, t0
    vmv.v.i v1, 9
    vmv.v.i v2, 0
    vclz.v  v1, v2, v0.t
    ELEM    14, v1, 2, 32
    ELEM    14, v1, 3, 9

    vsetivli zero, 8, e8, m1, tu, mu
    li      t0, 0xff
    vmv.v.x v2, t0
    vmv.v.i v3, 12
    vwsll.vv v4, v2, v3
    vsetivli zero, 8, e16, m1, tu, mu
    ELEM    15, v4, 7, -0x1000
    vsetivli zero, 2, e32, m1, tu, mu
    li      t0, 0x80000000
    vmv.v.x v2, t0
    li      a1, 31
    vwsll.vx v4, v2, a1
    vsetivli zero, 2, e64, m1, tu, mu
    ELEM    16, v4, 1, 0x4000000000000000
    vsetivli zero, 16, e16, m2, tu, mu
    vid.v   v2
    vwsll.vi v8, v2, 3
    vsetivli zero, 4, e32, m1, tu, mu
    ELEM    17, v11, 1, 104

    SET_RESUME 1f
    vsetivli zero, 1, e64, m1, tu, mu
    vwsll.vv v4, v2, v3
1:  ILL     18
    SET_RESUME 1f
    vsetivli zero, 4, e32, m1, tu, mu
    .word   (0x12 << 26) | (1 << 25) | (2 << 20) | (0x0b << 15) | (2 << 12) | (1 << 7) | 0x57
1:  ILL     19
    SET_RESUME 1f
    .word   (0x01 << 26) | (1 << 25) | (2 << 20) | (3 << 15) | (3 << 12) | (1 << 7) | 0x57
1:  ILL     20
    SET_RESUME 1f
    li      t0, 1
    csrw    vstart, t0
    vclz.v  v1, v2
1:  ILL     21
    csrw    vstart, zero
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
