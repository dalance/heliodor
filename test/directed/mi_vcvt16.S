// Vector conversions between 16-bit integers and singles (base V at SEW 16)
// and the SEWs where vector FP is reserved.
//
// Spec: at SEW 16 without Zvfh, vfwcvt.f.x[u].v and vfncvt[.rtz].x[u].f.w
// are the only conversions of the base V, the narrowing ones saturate to 16
// bits with NV alone; a vector FP op whose 2*SEW side would be 128 bits, or
// a conversion that needs FP16 arithmetic, is illegal.
// tohost: 1, or the number of the failing check:
//   2  vfwcvt.f.x.v -5: not 0xc0a00000
//   3  vfwcvt.f.xu.v 0xfffb: not 0x477ffb00
//   4  vfncvt.x.f.w 40000.0: not 0x7fff with NV
//   5  vfncvt.xu.f.w 70000.0: not 0xffff with NV
//   6  vfncvt.rtz.x.f.w -3.7: not -3 with NX
//   7  vfncvt.x.f.w -40000.0: not 0x8000 with NV
//   8  vfwcvt.f.x.v, vl 8: element 5 (second dest register) not 5.0
//   9  vfncvt.x.f.w, vl 8: element 6 (second source register) not 6
//   10 vfwcvt.x.f.v at SEW 16 (needs Zvfh): no cause 2
//   11 vfwcvt.f.f.v at SEW 64: no cause 2
//   12 vfwadd.vv at SEW 64: no cause 2
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

// The instruction at the resume label trapped with cause 2.
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
    li      t0, -5
    vmv.v.x v2, t0
    vfwcvt.f.x.v v4, v2
    vsetivli zero, 1, e32, m1, tu, mu
    E0      2, v4, 0xffffffffc0a00000

    vsetivli zero, 1, e16, mf2, tu, mu
    li      t0, 0xfffb
    vmv.v.x v2, t0
    vfwcvt.f.xu.v v4, v2
    vsetivli zero, 1, e32, m1, tu, mu
    E0      3, v4, 0x477ffb00

    li      t0, 0x471c4000
    vmv.v.x v4, t0
    vsetivli zero, 1, e16, mf2, tu, mu
    vfncvt.x.f.w v2, v4
    E0      4, v2, 0x7fff
    FFL     4, 0x10

    vsetivli zero, 1, e32, m1, tu, mu
    li      t0, 0x4788b800
    vmv.v.x v4, t0
    vsetivli zero, 1, e16, mf2, tu, mu
    vfncvt.xu.f.w v2, v4
    E0      5, v2, -1
    FFL     5, 0x10

    vsetivli zero, 1, e32, m1, tu, mu
    li      t0, 0xc06ccccd
    vmv.v.x v4, t0
    vsetivli zero, 1, e16, mf2, tu, mu
    vfncvt.rtz.x.f.w v2, v4
    E0      6, v2, -3
    FFL     6, 0x01

    vsetivli zero, 1, e32, m1, tu, mu
    li      t0, 0xc71c4000
    vmv.v.x v4, t0
    vsetivli zero, 1, e16, mf2, tu, mu
    vfncvt.x.f.w v2, v4
    E0      7, v2, -32768
    FFL     7, 0x10

    vsetivli zero, 8, e16, m1, tu, mu
    vid.v   v2
    vfwcvt.f.x.v v4, v2
    vsetivli zero, 8, e32, m2, tu, mu
    vslidedown.vi v8, v4, 5
    E0      8, v8, 0x40a00000

    vsetivli zero, 8, e16, m1, tu, mu
    vmv.v.i v1, 0
    vfncvt.x.f.w v1, v4
    vslidedown.vi v8, v1, 6
    E0      9, v8, 6

    SET_RESUME 1f
    vsetivli zero, 1, e16, mf2, tu, mu
    vfwcvt.x.f.v v4, v2
1:  ILL     10

    SET_RESUME 1f
    vsetivli zero, 1, e64, m1, tu, mu
    vfwcvt.f.f.v v4, v2
1:  ILL     11

    SET_RESUME 1f
    vsetivli zero, 1, e64, m1, tu, mu
    vfwadd.vv v4, v2, v2
1:  ILL     12
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
