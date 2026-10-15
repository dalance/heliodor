// B21: a pmpcfg write must order the younger loads behind it.
//
// M-mode with MPRV=1/MPP=S (satp Bare): entry 0 is a NAPOT 4 KiB region
// over PG, entry 1 the whole space RWX. A warm load from PG succeeds,
// then "csrw pmpcfg0" removes R from entry 0 and the very next load from
// PG must take a load access fault (cause 5). 0xB015: the load
// completed with the old permission.
#include "common/probe.h"

#define PG      (SCRATCH + 0x4000)
#define CFG_RW  ((0x1f << 8) | 0x1b)
#define CFG_NO  ((0x1f << 8) | 0x18)

    .section .text
main:
    li      t0, (PG >> 2) | 0x1ff
    csrw    pmpaddr0, t0
    li      t0, -1
    csrw    pmpaddr1, t0
    li      t0, CFG_RW
    csrw    pmpcfg0, t0
    li      s0, PG
    li      t0, 0x55
    sd      t0, 0(s0)
    li      s2, 0
    li      s3, 0
    li      s4, CFG_NO
    li      s5, CFG_RW
    .rept 4
    la      t6, trap_rec
    sd      zero, 0(t6)
    SET_RESUME 1f
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPRV | MSTATUS_MPP_S
    csrs    mstatus, t0
    ld      t1, 0(s0)
    csrw    pmpcfg0, s4
    ld      s1, 0(s0)
    addi    s2, s2, 1
1:  li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    csrw    pmpcfg0, s5
    la      t6, trap_rec
    ld      t0, 0(t6)
    li      t1, 5
    bne     t0, t1, 2f
    addi    s3, s3, 1
2:
    .endr
    PRINT   'n', s2
    PRINT   'f', s3
    bnez    s2, bug
    li      t0, 4
    bne     s3, t0, odd
    REPORT  1
bug:
    REPORT  CODE_BUG(21)
odd:
    REPORT  CODE_ODD(0x21)
