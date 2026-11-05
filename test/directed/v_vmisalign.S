// Vector element accesses not aligned to their EEW.
//
// Spec: the implementation either performs a misaligned element access or
// raises an address-misaligned exception for it (cause 4 load, 6 store,
// mtval the element address, vstart the element index); it may not
// access a truncated address. This core traps.
// tohost: 1, or the number of the failing check:
//   2  vle32.v at base + 2: no cause 4 with mtval = base + 2, vstart 0
//   3  vse32.v at base + 2: no cause 6, or memory changed
//   4  vlse32.v stride 6: element 1 (base + 6) is not reported with
//      cause 4, mtval base + 6 and vstart 1
//   5  the elements of 4 before the faulting one were not loaded
//   6  vluxei64.v index 3 for element 0: no cause 4 with mtval base + 3
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

    .section .text
main:
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    li      s1, SCRATCH
    li      t0, 0x0000000400000003
    sd      t0, 0(s1)
    li      t0, 0x0000000600000005
    sd      t0, 8(s1)
    sd      zero, 16(s1)
    vsetivli zero, 2, e32, m1, tu, mu
    vmv.v.i v1, 9
    vmv.v.i v2, 7

    SET_RESUME 1f
    addi    t1, s1, 2
    vle32.v v1, (t1)
1:  FAULT   2, 4, SCRATCH + 2, 0

    SET_RESUME 1f
    addi    t1, s1, 2
    vse32.v v2, (t1)
1:  FAULT   3, 6, SCRATCH + 2, 0
    ld      t0, 0(s1)
    li      t1, 0x0000000400000003
    bne     t0, t1, fail

    SET_RESUME 1f
    li      t2, 6
    vlse32.v v1, (s1), t2
1:  FAULT   4, 4, SCRATCH + 6, 1
    li      a0, 5
    vmv.x.s t0, v1
    li      t1, 3
    bne     t0, t1, fail

    vsetivli zero, 1, e64, m1, tu, mu
    li      t0, 3
    vmv.v.x v4, t0
    SET_RESUME 1f
    vluxei64.v v1, (s1), v4
1:  FAULT   6, 4, SCRATCH + 3, 0
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
