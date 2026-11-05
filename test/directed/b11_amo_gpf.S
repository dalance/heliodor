// B11: a store or AMO guest-page fault must report cause 23.
//
// M-mode with MPRV, MPP = S and MPV translates data through the two stages
// (vsatp Bare, hgatp Sv39x4 mapping only GPA [2 GiB, 3 GiB)). An amoadd.d, a
// store and a load to GPA 1 GiB fault in the G-stage. Spec: causes 23, 23
// and 21, mtval2 = GPA >> 2 and mstatus.GVA. 0xB00B with bit 16 (AMO) and
// bit 17 (store) for a cause 15.
#include "common/probe.h"

#define G_ROOT 0x80014000
#define MPV    (1 << 39)
#define GVA    (1 << 38)

    .section .text
main:
    li      t0, G_ROOT
    li      t1, PTE(0x80000000, PTE_LEAF | PTE_U)
    sd      t1, 16(t0)
    li      t0, (8 << 60) | (G_ROOT >> 12)
    csrw    hgatp, t0
    csrw    vsatp, zero
    .word   0x62000073              // hfence.gvma zero, zero
    li      s3, 0                   // bug mask
    li      s4, 0x40000000
    // AMO
    SET_RESUME 1f
    jal     ra, mprv_on
    amoadd.d a0, a1, (s4)
1:  li      a0, 23
    li      a1, 0x10000
    jal     ra, check
    // store
    SET_RESUME 1f
    jal     ra, mprv_on
    sd      a1, 0(s4)
1:  li      a0, 23
    li      a1, 0x20000
    jal     ra, check
    // load
    SET_RESUME 1f
    jal     ra, mprv_on
    ld      a1, 0(s4)
1:  li      a0, 21
    li      a1, 0
    jal     ra, check
    bnez    s3, bug
    REPORT  1
bug:
    li      t0, CODE_BUG(11)
    or      t0, t0, s3
    REPORT_REG t0

mprv_on:
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPRV | MSTATUS_MPP_S
    csrs    mstatus, t0
    li      t0, MPV
    csrs    mstatus, t0
    ret

// a0 = the expected cause, a1 = the bug bit of a cause 15. Clears MPRV.
check:
    li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    la      t6, trap_rec
    ld      t1, 0(t6)
    beq     t1, a0, 1f
    li      t2, 15
    bne     t1, t2, odd
    beqz    a1, odd
    or      s3, s3, a1
    ret
1:  csrr    t1, mtval2
    li      t2, 0x10000000
    bne     t1, t2, odd
    csrr    t1, mstatus
    li      t2, GVA
    and     t1, t1, t2
    beqz    t1, odd
    ret
odd:
    PRINT   'c', t1
    REPORT  CODE_ODD(0x11)
