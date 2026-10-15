// Memory-order violations: a younger load whose address is known early runs
// ahead of an older store whose address waits on a divide. The load must
// end with the store's bytes (replayed at commit or ordered otherwise).
// Each case runs several rounds with fresh values.
//
//   2  sd then ld of the same dword
//   3  sw to the upper half then ld of the dword (partial overlap)
//   4  sb to byte 5 then lbu of that byte
//   5  sd then ld of the same dword, the load's own address also late but
//      shorter (both behind divides)
//   6  sd then an independent ld of the next dword is not disturbed
// tohost: 1 on success, else the number of the failing check.
#include "common/probe.h"

#define BUF   SCRATCH
#define ROUNDS 6

// t4 := 0 after a divide, so an address built from it is late.
.macro LATE_ZERO
    li      t2, 1000
    li      t3, 7
    div     t4, t2, t3
    addi    t4, t4, -142
.endm

    .section .text
main:
    li      s0, BUF
    li      s1, ROUNDS
    li      s2, 0x0101010101010101
    li      s3, 0x1111111111111111
loop:
    sd      zero, 0(s0)
    sd      s3, 8(s0)
    fence

    LATE_ZERO
    add     t5, s0, t4
    sd      s2, 0(t5)
    ld      a1, 0(s0)
    li      a0, 2
    bne     a1, s2, fail

    sd      zero, 0(s0)
    fence
    LATE_ZERO
    add     t5, s0, t4
    sw      s2, 4(t5)
    ld      a1, 0(s0)
    slli    t0, s2, 32
    li      a0, 3
    bne     a1, t0, fail

    sd      zero, 0(s0)
    fence
    LATE_ZERO
    add     t5, s0, t4
    sb      s2, 5(t5)
    lbu     a1, 5(s0)
    andi    t0, s2, 0xff
    li      a0, 4
    bne     a1, t0, fail

    sd      zero, 0(s0)
    fence
    li      t2, 1000
    li      t3, 7
    div     t4, t2, t3
    addi    t4, t4, -142
    li      t2, 99
    li      t3, 3
    div     t6, t2, t3
    addi    t6, t6, -33
    add     t5, s0, t4
    sd      s2, 0(t5)
    add     t6, s0, t6
    ld      a1, 0(t6)
    li      a0, 5
    bne     a1, s2, fail

    LATE_ZERO
    add     t5, s0, t4
    sd      s3, 0(t5)
    ld      a1, 8(s0)
    li      a0, 6
    bne     a1, s3, fail

    add     s2, s2, s3
    addi    s1, s1, -1
    bnez    s1, loop
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
