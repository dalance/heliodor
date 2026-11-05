// Vector state with V = 1: mstatus.VS and vsstatus.VS both gate it.
//
// VS-mode (hgatp and vsatp Bare) runs vadd.vv, csrr vl and vsetvli, each
// ending in an ecall back to M.
//   2-4  vsstatus.VS = Off, mstatus.VS = Initial: each raises an
//        illegal-instruction exception (cause 2), not a virtual one
//   5    vsstatus.VS = Initial: vadd.vv runs (ecall, cause 10)
//   6    after it vsstatus.VS and mstatus.VS are both Dirty
//   7    mstatus.VS = Off, vsstatus.VS = Initial: vadd.vv raises cause 2
//   8    the trapped vadd.vv of 7 left v1 alone
// tohost: 1, or the number of the failing check.
#include "common/probe.h"

#define MPV       (1 << 39)
#define VS_DIRTY  0x0600

// Run label in VS-mode; the code ends with ecall (or traps).
.macro RUN_VS code, back
    la      t6, trap_rec
    sd      zero, 0(t6)
    SET_RESUME \back
    la      t0, \code
    csrw    mepc, t0
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S
    csrs    mstatus, t0
    li      t0, MPV
    csrs    mstatus, t0
    mret
.endm

.macro CAUSE code, cause
    la      t6, trap_rec
    li      a0, \code
    ld      t5, 0(t6)
    li      t4, \cause
    bne     t5, t4, fail
.endm

    .section .text
main:
    csrw    hgatp, zero
    csrw    vsatp, zero
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    vsetivli zero, 2, e32, m1, ta, ma
    vmv.v.i v1, 7
    vmv.v.i v2, 1
    vmv.v.i v3, 2
    li      t0, MSTATUS_VS
    csrc    vsstatus, t0

    RUN_VS  vs_vadd, c2
c2: CAUSE   2, 2
    RUN_VS  vs_csr, c3
c3: CAUSE   3, 2
    RUN_VS  vs_vset, c4
c4: CAUSE   4, 2

    li      t0, MSTATUS_VS_INIT
    csrs    vsstatus, t0
    RUN_VS  vs_vadd, c5
c5: CAUSE   5, 10
    li      a0, 6
    csrr    t0, vsstatus
    li      t1, MSTATUS_VS
    and     t0, t0, t1
    li      t2, VS_DIRTY
    bne     t0, t2, fail
    csrr    t0, mstatus
    and     t0, t0, t1
    bne     t0, t2, fail

    vmv.v.i v1, 7
    li      t0, MSTATUS_VS
    csrc    mstatus, t0
    RUN_VS  vs_vadd, c7
c7: CAUSE   7, 2
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    li      a0, 8
    vmv.x.s t0, v1
    li      t1, 7
    bne     t0, t1, fail
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0

vs_vadd:
    vadd.vv v1, v2, v3
    ecall
vs_csr:
    csrr    t0, vl
    ecall
vs_vset:
    vsetivli zero, 4, e64, m1, ta, ma
    ecall
