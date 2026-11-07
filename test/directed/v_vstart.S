// vstart after vector instructions that complete.
//
// Spec: every vector instruction, vset{i}vl{i} included, resets vstart to
// 0 when it completes without a trap. Each check sets vstart to 1 first
// (and runs only with vstart below vl, so the op has elements to do). The
// arithmetic ops trap at vstart 1 on this core (mi_vstart).
// tohost: 1, or the number of the failing check:
//   3 vle32.v, 4 vse32.v, 5 vsetvli left vstart nonzero
#include "common/probe.h"

.macro VSTART_1
    li      t0, 1
    csrw    vstart, t0
.endm

.macro ZERO code
    li      a0, \code
    csrr    t0, vstart
    bnez    t0, fail
.endm

    .section .text
main:
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    vsetivli zero, 4, e32, m1, ta, ma
    li      s1, SCRATCH
    vmv.v.i v2, 1

    VSTART_1
    vle32.v v1, (s1)
    ZERO    3
    VSTART_1
    vse32.v v2, (s1)
    ZERO    4
    VSTART_1
    vsetivli zero, 4, e32, m1, ta, ma
    ZERO    5
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
