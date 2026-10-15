// B46: count device-side UART THR writes per committed store.
//
// Commits NSTORE byte stores to the THR in three shapes (back-to-back,
// separated by a DRAM store, separated by a fence), then reads the
// harness counter at UART+0x100. Spec: exactly one device write per
// store. 0xB02E: the device saw more writes than stores were committed.
#include "common/probe.h"

#define NSTORE 12

    .section .text
main:
    li      s0, UART_THR
    li      s1, UART_WRCNT
    li      s2, SCRATCH
    fence
    ld      s3, 0(s1)
    li      t0, 'a'
    sb      t0, 0(s0)
    li      t0, 'b'
    sb      t0, 0(s0)
    li      t0, 'c'
    sb      t0, 0(s0)
    li      t0, 'd'
    sb      t0, 0(s0)
    li      t0, 'e'
    sb      t0, 0(s0)
    sd      t0, 0(s2)
    li      t0, 'f'
    sb      t0, 0(s0)
    sd      t0, 8(s2)
    li      t0, 'g'
    sb      t0, 0(s0)
    sd      t0, 16(s2)
    li      t0, 'h'
    sb      t0, 0(s0)
    fence
    li      t0, 'i'
    sb      t0, 0(s0)
    fence
    li      t0, 'j'
    sb      t0, 0(s0)
    fence
    li      t0, 'k'
    sb      t0, 0(s0)
    fence
    li      t0, '\n'
    sb      t0, 0(s0)
    fence
    ld      s4, 0(s1)
    sub     s5, s4, s3
    PRINT   'n', s5
    li      t0, NSTORE
    beq     s5, t0, pass
    bgtu    s5, t0, bug
    li      t0, 0xff
    and     s5, s5, t0
    li      t0, CODE_ODD(0)
    or      s5, s5, t0
    REPORT_REG s5
pass:
    REPORT  1
bug:
    REPORT  CODE_BUG(46)
