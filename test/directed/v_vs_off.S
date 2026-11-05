// Vector instructions and vector CSR accesses with mstatus.VS = Off.
//
// Spec: each raises an illegal-instruction exception (mtval the
// instruction) and changes no state: the vector registers, vl, vtype and
// memory keep their values, and mstatus.VS stays Off.
// tohost: 1, or the number of the failing check:
//   2-12  the instruction did not trap with cause 2 (2 vadd.vv, 3 vle32.v,
//         4 vse32.v, 5 vsetvli, 6 vmv.x.s, 7 csrr vl, 8 csrr vtype, 9 csrr
//         vlenb, 10 csrw vstart, 11 csrw vxrm, 12 csrr vcsr)
//   13    mtval is not the vadd.vv instruction
//   14    the trapped ops changed a vector register, vl or vtype
//   15    the trapped vse32.v wrote memory
//   16    the trapped vmv.x.s or csrr wrote its rd
//   17    mstatus.VS is not Off after the traps
#include "common/probe.h"

#define VADD_V1 0x022180d7          // vadd.vv v1, v2, v3

.macro TRAPS code
    la      t6, trap_rec
    li      a0, \code
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
    vsetivli zero, 2, e32, m1, ta, ma
    vmv.v.i v1, 7
    vmv.v.i v2, 1
    vmv.v.i v3, 2
    li      s1, SCRATCH
    li      t0, 0x55
    sd      t0, 0(s1)
    li      t0, MSTATUS_VS
    csrc    mstatus, t0
    li      s5, 0x77                // rd of the trapped reads

    SET_RESUME 1f
    .word   VADD_V1
1:  TRAPS   2
    ld      t5, 8(t6)
    li      t4, VADD_V1
    li      a0, 13
    bne     t5, t4, fail
    SET_RESUME 1f
    vle32.v v1, (s1)
1:  TRAPS   3
    SET_RESUME 1f
    vse32.v v2, (s1)
1:  TRAPS   4
    SET_RESUME 1f
    vsetivli zero, 4, e64, m2, ta, ma
1:  TRAPS   5
    SET_RESUME 1f
    vmv.x.s s5, v1
1:  TRAPS   6
    SET_RESUME 1f
    csrr    s5, vl
1:  TRAPS   7
    SET_RESUME 1f
    csrr    s5, vtype
1:  TRAPS   8
    SET_RESUME 1f
    csrr    s5, vlenb
1:  TRAPS   9
    SET_RESUME 1f
    csrw    vstart, 1
1:  TRAPS   10
    SET_RESUME 1f
    csrwi   vxrm, 3
1:  TRAPS   11
    SET_RESUME 1f
    csrr    s5, vcsr
1:  TRAPS   12

    li      a0, 16
    li      t0, 0x77
    bne     s5, t0, fail
    li      a0, 17
    csrr    t0, mstatus
    li      t1, MSTATUS_VS
    and     t0, t0, t1
    bnez    t0, fail
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    li      a0, 14
    csrr    t0, vl
    li      t1, 2
    bne     t0, t1, fail
    csrr    t0, vtype
    li      t1, 0xd0                // e32, m1, ta, ma
    bne     t0, t1, fail
    csrr    t0, vstart
    bnez    t0, fail
    csrr    t0, vxrm
    bnez    t0, fail
    vmv.x.s t0, v1
    li      t1, 7
    bne     t0, t1, fail
    li      a0, 15
    ld      t0, 0(s1)
    li      t1, 0x55
    bne     t0, t1, fail
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
