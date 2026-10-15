// B14: minstret must count retired instructions.
//
// Reads minstret and instret around 200 independent addi (pairs that can
// retire together). Spec: the delta is 201 (the addi plus the first
// read). 0xB00E: any other delta (sub-case 1 minstret, 2 instret).
#include "common/probe.h"

    .section .text
main:
    .option push
    .option norvc
    li      s1, 0
    li      s2, 0
    csrr    s3, minstret
    .rept 100
    addi    s1, s1, 1
    addi    s2, s2, 1
    .endr
    csrr    s4, minstret
    rdinstret s5
    .rept 100
    addi    s1, s1, 1
    addi    s2, s2, 1
    .endr
    rdinstret s6
    .option pop
    sub     s7, s4, s3
    sub     s8, s6, s5
    PRINT   'm', s7
    PRINT   'i', s8
    li      t0, 201
    bne     s7, t0, bug_m
    bne     s8, t0, bug_i
    REPORT  1
bug_m:
    REPORT  CODE_BUG_SUB(14, 1)
bug_i:
    REPORT  CODE_BUG_SUB(14, 2)
