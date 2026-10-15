// B13: a read-only CSR instruction must not write the CSR back.
//
// Times a loop of 256 "csrr t1, mcycle" against the free-running time CSR
// (the harness ticks mtime every cycle), and the same loop with an addi
// in place of the csrr as the control. Spec: mcycle advances with time
// in both loops. 0xB00D with sub-case bit 0: the csrr loop loses at least
// one cycle per csrr (each read rewinds mcycle to the value it read).
// Sub-case bit 1: mstatus.SD stays set after FS goes from Dirty to Clean
// through a "csrr mstatus" in between.
#include "common/probe.h"

    .section .text
main:
    .option push
    .option norvc
    // control loop
    li      s0, 256
    rdtime  s1
    csrr    s2, mcycle
1:  addi    t1, t1, 0
    addi    s0, s0, -1
    bnez    s0, 1b
    rdtime  s3
    csrr    s4, mcycle
    // csrr loop
    li      s0, 256
    rdtime  s5
    csrr    s6, mcycle
1:  csrr    t1, mcycle
    addi    s0, s0, -1
    bnez    s0, 1b
    rdtime  s7
    csrr    s8, mcycle
    .option pop
    sub     s1, s3, s1          // control dt
    sub     s2, s4, s2          // control dm
    sub     s5, s7, s5          // csrr dt
    sub     s6, s8, s6          // csrr dm
    PRINT   'T', s1
    PRINT   'M', s2
    PRINT   't', s5
    PRINT   'm', s6
    // The control loop must lose almost nothing, else the method is unusable.
    li      s9, 0
    sub     t0, s1, s2
    li      t1, 32
    bge     t0, t1, odd
    // Bug: at least one cycle lost per csrr.
    sub     t0, s5, s6
    li      t1, 256
    blt     t0, t1, 1f
    ori     s9, s9, 1
1:
    // SD after Dirty -> read -> Clean
    li      t0, MSTATUS_FS
    csrs    mstatus, t0
    csrr    t1, mstatus
    li      t0, MSTATUS_FS_INIT
    csrc    mstatus, t0
    csrr    t1, mstatus
    PRINT   's', t1
    bgez    t1, 1f
    ori     s9, s9, 2
1:  beqz    s9, pass
    slli    s9, s9, 16
    li      t0, CODE_BUG(13)
    or      s9, s9, t0
    REPORT_REG s9
pass:
    REPORT  1
odd:
    REPORT  CODE_ODD(0x13)
