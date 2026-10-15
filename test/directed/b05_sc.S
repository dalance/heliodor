// B05: a poisoned SC retires and is then replayed.
//
// "lr.d; sc.d a0, a1, (a0)" (rd == rs1) followed by younger loads that
// fill five lines of the reserved line's set, with their addresses
// delayed by a dependency chain of 0..23 adds so the eviction lands at
// varying distances from the SC's issue. Spec: each SC writes 0 or 1 to
// a0 once and never traps. 0xB005: the SC trapped (sub-case 1: a replay
// used the clobbered base) or a0 holds neither 0 nor 1 (sub-case 2).
// A second sweep evicts through older committed stores to the same set
// (their drain fills race the SC) instead of younger loads. The harness
// also prints the SC_REPLAY gtag count.
#include "common/probe.h"

#define SETSTRIDE 4096

.macro SC_TRY d
    sd      zero, 0(s0)
    ld      t0, 0(s0)
    mv      a0, s0
    li      a1, 5
    lr.d    t0, (a0)
    sc.d    a0, a1, (a0)
    li      t2, 0
    .rept \d
    addi    t2, t2, 0
    .endr
    add     t3, s1, t2
    ld      t4, 0(t3)
    add     t3, t3, s5
    ld      t4, 0(t3)
    add     t3, t3, s5
    ld      t4, 0(t3)
    add     t3, t3, s5
    ld      t4, 0(t3)
    add     t3, t3, s5
    ld      t4, 0(t3)
    li      t0, 1
    bgtu    a0, t0, bad_value
    add     s4, s4, a0
    li      t0, 5 * SETSTRIDE
    add     s1, s1, t0
.endm

.macro SC_DRAIN k, d
    sd      zero, 0(s0)
    ld      t0, 0(s0)
    mv      t3, s1
    .rept \k
    sd      t3, 0(t3)
    add     t3, t3, s5
    .endr
    li      t2, 0
    .rept \d
    addi    t2, t2, 0
    .endr
    add     a0, s0, t2
    li      a1, 5
    lr.d    t0, (a0)
    sc.d    a0, a1, (a0)
    li      t0, 1
    bgtu    a0, t0, bad_value
    add     s4, s4, a0
    li      t0, 6 * SETSTRIDE
    add     s1, s1, t0
.endm

    .section .text
main:
    li      s0, SCRATCH
    li      s1, SCRATCH + SETSTRIDE
    li      s4, 0
    li      s5, SETSTRIDE
    SET_RESUME sc_trap
    .irp d, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23
    SC_TRY  \d
    SC_TRY  \d
    li      s1, SCRATCH + SETSTRIDE
    .endr
    PRINT   'f', s4
    li      s4, 0
    .irp k, 4,5,6,8
    .irp d, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,18,20,22,24,28,32
    SC_DRAIN \k, \d
    li      s1, SCRATCH + SETSTRIDE
    .endr
    .endr
    PRINT   'g', s4
    REPORT  1
sc_trap:
    la      t6, trap_rec
    ld      a0, 0(t6)
    PRINT   'c', a0
    la      t6, trap_rec
    ld      a0, 8(t6)
    PRINT   'v', a0
    la      t6, trap_rec
    ld      a0, 16(t6)
    PRINT   'e', a0
    REPORT  CODE_BUG_SUB(5, 1)
bad_value:
    PRINT   'a', a0
    REPORT  CODE_BUG_SUB(5, 2)
