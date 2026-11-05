// vtype values that vsetvl must reject, and the ops that then must trap.
//
// Spec: vsetvl sets vill (vtype bit 63, the rest 0) and vl = 0 for a
// reserved vtype: a reserved bit (vtype[62:8]) set, vsew >= 4, vlmul = 4,
// or a fractional LMUL with SEW > LMUL * ELEN (ELEN 64). With vill set a
// vector instruction that depends on vtype raises an illegal-instruction
// exception.
// tohost: 1, or the number of the failing check:
//   2-7   the vtype was not rejected (2 bit 8 set, 3 e64 mf2, 4 e32 mf4,
//         5 e128 m1, 6 vlmul 4, 7 bit 62 set)
//   8-10  a legal vtype was rejected (8 e32 mf2, 9 e8 mf8, 10 e64 m8)
//   11    vadd.vv with vill set did not trap with cause 2
//   12    vle32.v with vill set did not trap with cause 2
#include "common/probe.h"

#define VILL (1 << 63)

// vsetvl with AVL 4 and vtype t1; fail with code unless vill is as expected.
.macro BAD code, vtype
    li      a0, \code
    li      t1, \vtype
    li      t0, 4
    vsetvl  t2, t0, t1
    bnez    t2, fail
    csrr    t3, vl
    bnez    t3, fail
    csrr    t3, vtype
    li      t4, VILL
    bne     t3, t4, fail
.endm

.macro GOOD code, vtype
    li      a0, \code
    li      t1, \vtype
    li      t0, 1
    vsetvl  t2, t0, t1
    beqz    t2, fail
    csrr    t3, vtype
    bne     t3, t1, fail
.endm

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
    li      s1, SCRATCH

    BAD     2, 0x110                // e32 m1, bit 8
    BAD     3, 0x1f                 // e64 mf2
    BAD     4, 0x16                 // e32 mf4
    BAD     5, 0x20                 // e128 m1
    BAD     6, 0x04                 // vlmul 4
    li      a0, 7
    li      t1, (1 << 62) | 0x10
    li      t0, 4
    vsetvl  t2, t0, t1
    bnez    t2, fail
    csrr    t3, vtype
    li      t4, VILL
    bne     t3, t4, fail

    GOOD    8, 0x17                 // e32 mf2
    GOOD    9, 0x05                 // e8 mf8
    GOOD    10, 0x1b                // e64 m8

    BAD     2, 0x110
    SET_RESUME 1f
    vadd.vv v1, v2, v3
1:  TRAPS   11
    SET_RESUME 1f
    vle32.v v1, (s1)
1:  TRAPS   12
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
