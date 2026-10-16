// Two memory pipes at once: pairs of independent loads and stores that issue,
// forward, scan and retire in the same cycle on a core with two pipes (and
// one after the other on a core with one). Each case runs several rounds with
// fresh values.
//
//   2  four stores to one line retire in pairs, then loads of each dword
//      forward from the store queue or the store buffer
//   3  two stores to one dword retire together: the younger one's bytes win
//      in the merged store-buffer entry
//   4  cbo.zero and a store to the same line retire together
//   5  two loads forward from two different stores in the same cycle
//   6  a store whose address waits on a divide, followed by two independent
//      loads, one of which overlaps it (order violation on either pipe)
//   7  a line-crossing store next to a plain store: three lines in a pair
//   8  a copy loop of two loads and two stores per iteration, checked
//      against the source afterwards
// tohost: 1 on success, else the number of the failing check.
#include "common/probe.h"

#define BUF    SCRATCH
#define SRC    (SCRATCH + 0x1000)
#define DST    (SCRATCH + 0x2000)
#define ROUNDS 4
#define WORDS  64

// t4 := 0 after a divide, so an address built from it is late.
.macro LATE_ZERO
    li      t2, 1000
    li      t3, 7
    div     t4, t2, t3
    addi    t4, t4, -142
.endm

.macro CHECK reg, exp, code
    li      a0, \code
    bne     \reg, \exp, fail
.endm

    .section .text
main:
    li      s0, BUF
    li      s1, ROUNDS
    li      s2, 0x0123456789abcdef
    li      s3, 0x1111111111111111
loop:
    add     s4, s2, s3
    add     s5, s4, s3
    add     s6, s5, s3

    // 2: four stores to one line, loads right behind and after a fence
    sd      s2, 0(s0)
    sd      s4, 8(s0)
    sd      s5, 16(s0)
    sd      s6, 24(s0)
    ld      a1, 0(s0)
    ld      a2, 8(s0)
    ld      a3, 16(s0)
    ld      a4, 24(s0)
    CHECK   a1, s2, 2
    CHECK   a2, s4, 2
    CHECK   a3, s5, 2
    CHECK   a4, s6, 2
    fence
    ld      a1, 0(s0)
    ld      a2, 8(s0)
    ld      a3, 16(s0)
    ld      a4, 24(s0)
    CHECK   a1, s2, 2
    CHECK   a2, s4, 2
    CHECK   a3, s5, 2
    CHECK   a4, s6, 2

    // 3: two stores to one dword in one pair, and two to one word
    sd      s2, 64(s0)
    sb      s3, 67(s0)
    sw      s4, 72(s0)
    sh      s5, 74(s0)
    fence
    ld      a1, 64(s0)
    lwu     a3, 72(s0)
    li      t0, 0xff << 24
    not     t1, t0
    and     t1, s2, t1
    andi    t2, s3, 0xff
    slli    t2, t2, 24
    or      t1, t1, t2
    CHECK   a1, t1, 3
    slli    t0, s5, 48
    srli    t0, t0, 32
    slli    t1, s4, 48
    srli    t1, t1, 48
    or      t0, t0, t1
    CHECK   a3, t0, 3

    // 4: cbo.zero and a store to its line retire together
    addi    t5, s0, 128
    sd      s2, 0(t5)
    sd      s2, 56(t5)
    fence
    .insn   i 0x0f, 2, x0, t5, 4
    sd      s3, 8(t5)
    fence
    ld      a1, 0(t5)
    ld      a2, 8(t5)
    ld      a3, 56(t5)
    CHECK   a1, zero, 4
    CHECK   a2, s3, 4
    CHECK   a3, zero, 4

    // 5: two loads forward from two stores in the same cycle
    sd      s4, 192(s0)
    sd      s5, 256(s0)
    ld      a1, 192(s0)
    ld      a2, 256(s0)
    lw      a3, 196(s0)
    lw      a4, 260(s0)
    CHECK   a1, s4, 5
    CHECK   a2, s5, 5
    srai    t0, s4, 32
    srai    t1, s5, 32
    CHECK   a3, t0, 5
    CHECK   a4, t1, 5

    // 6: late-address store, two younger loads (one overlaps)
    sd      zero, 320(s0)
    sd      s3, 328(s0)
    fence
    LATE_ZERO
    add     t5, s0, t4
    sd      s6, 320(t5)
    ld      a2, 328(s0)
    ld      a1, 320(s0)
    CHECK   a1, s6, 6
    CHECK   a2, s3, 6
    LATE_ZERO
    add     t5, s0, t4
    sd      s5, 328(t5)
    ld      a1, 320(s0)
    ld      a2, 328(s0)
    CHECK   a1, s6, 6
    CHECK   a2, s5, 6

    // 7: a line-crossing store next to a plain store
    sd      zero, 384(s0)
    sd      zero, 440(s0)
    sd      zero, 448(s0)
    fence
    sd      s2, 444(s0)
    sd      s3, 384(s0)
    ld      a1, 440(s0)
    ld      a2, 448(s0)
    fence
    ld      a3, 440(s0)
    ld      a4, 448(s0)
    ld      a5, 384(s0)
    slli    t0, s2, 32
    srli    t1, s2, 32
    CHECK   a1, t0, 7
    CHECK   a2, t1, 7
    CHECK   a3, t0, 7
    CHECK   a4, t1, 7
    CHECK   a5, s3, 7

    // 8: fill the source, copy two dwords per step, compare
    li      t0, SRC
    li      t1, WORDS
    mv      t2, s2
1:  sd      t2, 0(t0)
    add     t3, t2, s3
    sd      t3, 8(t0)
    add     t2, t3, s3
    addi    t0, t0, 16
    addi    t1, t1, -2
    bnez    t1, 1b
    li      t0, SRC
    li      t5, DST
    li      t1, WORDS
1:  ld      a1, 0(t0)
    ld      a2, 8(t0)
    sd      a1, 0(t5)
    sd      a2, 8(t5)
    addi    t0, t0, 16
    addi    t5, t5, 16
    addi    t1, t1, -2
    bnez    t1, 1b
    li      t0, SRC
    li      t5, DST
    li      t1, WORDS
1:  ld      a1, 0(t0)
    ld      a2, 0(t5)
    CHECK   a2, a1, 8
    addi    t0, t0, 8
    addi    t5, t5, 8
    addi    t1, t1, -1
    bnez    t1, 1b

    add     s2, s2, s3
    slli    t0, s3, 7
    srli    t1, s3, 57
    or      s3, t0, t1
    addi    s1, s1, -1
    bnez    s1, loop
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
