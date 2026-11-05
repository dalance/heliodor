// Masked-off and tail elements of vector loads under tu, mu.
//
// Spec: with vta = vma = 0 a load leaves the elements it does not access
// (mask bit 0, or index >= vl) undisturbed. Memory holds 1, 2, 3, 4 (e32),
// the destination starts as 0xaaaaaaaa in all four elements, v0 = 0b0101
// and vl = 3, so a masked load gives {1, old, 3, old}.
// tohost: 1, or the number of the failing check:
//   2 masked vle32.v, 3 unmasked vle32.v (vl 2, tail of two),
//   4 masked vlse32.v, 5 masked vluxei32.v, 6 masked vlseg2e32.v (both
//   fields), 7 masked vle32ff.v
#include "common/probe.h"

#define OLD 0xaaaaaaaa

// Fail with code unless v8 holds e0..e3 (read back through a store).
.macro EXPECT code, e0, e1, e2, e3
    li      a0, \code
    vsetivli zero, 4, e32, m1, tu, mu
    vse32.v v8, (s2)
    lwu     t0, 0(s2)
    li      t1, \e0
    bne     t0, t1, fail
    lwu     t0, 4(s2)
    li      t1, \e1
    bne     t0, t1, fail
    lwu     t0, 8(s2)
    li      t1, \e2
    bne     t0, t1, fail
    lwu     t0, 12(s2)
    li      t1, \e3
    bne     t0, t1, fail
.endm

.macro FILL
    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.x v8, s3
    vmv.v.x v9, s3
.endm

    .section .text
main:
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    li      s1, SCRATCH
    addi    s2, s1, 0x100
    li      t0, 1
    sw      t0, 0(s1)
    li      t0, 2
    sw      t0, 4(s1)
    li      t0, 3
    sw      t0, 8(s1)
    li      t0, 4
    sw      t0, 12(s1)
    li      s3, OLD
    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.i v0, 5
    vid.v   v16
    vsll.vi v16, v16, 2             // byte offsets 0, 4, 8, 12

    FILL
    vsetivli zero, 3, e32, m1, tu, mu
    vle32.v v8, (s1), v0.t
    EXPECT  2, 1, OLD, 3, OLD

    FILL
    vsetivli zero, 2, e32, m1, tu, mu
    vle32.v v8, (s1)
    EXPECT  3, 1, 2, OLD, OLD

    FILL
    li      t2, 4
    vsetivli zero, 3, e32, m1, tu, mu
    vlse32.v v8, (s1), t2, v0.t
    EXPECT  4, 1, OLD, 3, OLD

    FILL
    vsetivli zero, 3, e32, m1, tu, mu
    vluxei32.v v8, (s1), v16, v0.t
    EXPECT  5, 1, OLD, 3, OLD

    // Segment fields: v8 gets elements 0, 2, ..., v9 elements 1, 3, ...
    FILL
    vsetivli zero, 2, e32, m1, tu, mu
    vmv.v.i v0, 1
    vlseg2e32.v v8, (s1), v0.t
    EXPECT  6, 1, OLD, OLD, OLD
    vmv.v.v v8, v9
    EXPECT  6, 2, OLD, OLD, OLD

    FILL
    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.i v0, 5
    vsetivli zero, 3, e32, m1, tu, mu
    vle32ff.v v8, (s1), v0.t
    EXPECT  7, 1, OLD, 3, OLD
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
