// Strided and indexed accesses whose rs2 or vs2 field holds a value that
// names another unit-stride form (8 whole-register, 11 mask, 16
// fault-only-first).
//
// Spec: inst[24:20] is lumop/sumop only for mop 00. A strided or indexed
// op uses it as rs2 or vs2 and keeps its own element count, mask and fault
// rule.
// tohost: 1, or the number of the failing check:
//   2  vlse32.v rs2 = x8, all masked off: wrote vd
//   3  vlse32.v rs2 = x11, all masked off: wrote vd
//   4  vsse32.v rs2 = x8, all masked off: wrote memory
//   5  vlse32.v rs2 = x16, element 1 misaligned: no cause 4 with vstart 1
//      (a fault-only-first load would trim vl instead)
//   6  vl changed by the load of 5
//   7  vluxei32.v vs2 = v8, all masked off: wrote vd
#include "common/probe.h"

.macro FAULT code, cause, tval, vst
    la      t6, trap_rec
    li      a0, \code
    ld      t5, 24(t6)
    beqz    t5, fail
    sd      zero, 24(t6)
    ld      t5, 0(t6)
    li      t4, \cause
    bne     t5, t4, fail
    ld      t5, 8(t6)
    li      t4, \tval
    bne     t5, t4, fail
    csrr    t5, vstart
    li      t4, \vst
    bne     t5, t4, fail
    csrw    vstart, zero
.endm

// vd must still read 9 in every element.
.macro UNTOUCHED code, vd
    li      a0, \code
    vmsne.vi v30, \vd, 9
    vfirst.m t0, v30
    bgez    t0, fail
.endm

    .section .text
main:
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    li      s1, SCRATCH
    li      t0, 0x0000000400000003
    sd      t0, 0(s1)
    li      t0, 0x0000000600000005
    sd      t0, 8(s1)
    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.i v0, 0
    vmv.v.i v2, 7
    vmv.v.i v8, 0

    vmv.v.i v1, 9
    li      s0, 4
    vlse32.v v1, (s1), s0, v0.t
    UNTOUCHED 2, v1

    vmv.v.i v1, 9
    li      a1, 4
    vlse32.v v1, (s1), a1, v0.t
    UNTOUCHED 3, v1

    li      a0, 4
    li      s0, 4
    vsse32.v v2, (s1), s0, v0.t
    ld      t0, 0(s1)
    li      t1, 0x0000000400000003
    bne     t0, t1, fail
    ld      t0, 8(s1)
    li      t1, 0x0000000600000005
    bne     t0, t1, fail

    SET_RESUME 1f
    li      a6, 6
    vlse32.v v1, (s1), a6
1:  FAULT   5, 4, SCRATCH + 6, 1
    li      a0, 6
    csrr    t0, vl
    li      t1, 4
    bne     t0, t1, fail

    vmv.v.i v1, 9
    vluxei32.v v1, (s1), v8, v0.t
    UNTOUCHED 7, v1
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
