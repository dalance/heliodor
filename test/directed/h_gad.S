// G-stage A/D updates (menvcfg.ADUE) and the htinst/mtinst pseudoinstruction
// of a guest-page fault on an implicit VS-stage PTE read.
//
// M-mode with MPRV, MPP = S and MPV. The G-stage maps GPA 0x80200000 through
// a 4 KiB leaf with A = D = 0. With ADUE a load sets A only, a store sets D;
// without ADUE a load of another such page faults (cause 21, mtval2 = GPA >>
// 2, mtinst 0). With vsatp Sv39 rooted at G-unmapped GPA 0x40000000 a load
// and a store fault on the root PTE read: causes 21 and 23, mtval2 0x10000000
// and mtinst 0x3000 (a 64-bit read for VS-stage translation). tohost 1 on
// success, 0xE0nn for the first unexpected value (nn = the step).
#include "common/probe.h"

#define G_ROOT 0x80014000
#define G_L1   0x80018000
#define G_L0   0x80019000
#define MPV    (1 << 39)
#define ADUE   (1 << 61)

.macro EXPECT reg, val, step
    li      t2, \val
    beq     \reg, t2, 98f
    PRINT   'v', \reg
    REPORT  CODE_ODD(\step)
98:
.endm

    .section .text
main:
    li      t0, G_ROOT
    li      t1, PTE(G_L1, PTE_V)
    sd      t1, 16(t0)
    li      t0, G_L1
    li      t1, PTE(0x80000000, PTE_LEAF | PTE_U)
    sd      t1, 0(t0)
    li      t1, PTE(G_L0, PTE_V)
    sd      t1, 8(t0)
    li      t0, G_L0
    li      t1, PTE(0x80200000, PTE_V | PTE_R | PTE_W | PTE_U)
    sd      t1, 0(t0)
    li      t1, PTE(0x80201000, PTE_V | PTE_R | PTE_W | PTE_U)
    sd      t1, 8(t0)
    li      t0, (8 << 60) | (G_ROOT >> 12)
    csrw    hgatp, t0
    csrw    vsatp, zero
    .word   0x62000073              // hfence.gvma zero, zero
    li      t0, ADUE
    csrs    menvcfg, t0
    li      s4, 0x80200000
    // a load sets A
    SET_RESUME 1f
    la      t6, trap_rec
    sd      zero, 0(t6)
    jal     ra, mprv_on
    ld      a1, 0(s4)
1:  jal     ra, mprv_off
    la      t6, trap_rec
    ld      t1, 0(t6)
    EXPECT  t1, 0, 0x01
    li      t0, G_L0
    ld      t1, 0(t0)
    andi    t1, t1, 0xc0
    EXPECT  t1, 0x40, 0x02
    // a store sets D
    SET_RESUME 1f
    jal     ra, mprv_on
    sd      a1, 8(s4)
1:  jal     ra, mprv_off
    la      t6, trap_rec
    ld      t1, 0(t6)
    EXPECT  t1, 0, 0x03
    li      t0, G_L0
    ld      t1, 0(t0)
    andi    t1, t1, 0xc0
    EXPECT  t1, 0xc0, 0x04
    // without ADUE, A = 0 is a guest-page fault. A younger path may have
    // set A speculatively while ADUE was on, so the leaf is written again.
    li      t0, ADUE
    csrc    menvcfg, t0
    li      t0, G_L0
    li      t1, PTE(0x80201000, PTE_V | PTE_R | PTE_W | PTE_U)
    sd      t1, 8(t0)
    .word   0x62000073              // hfence.gvma zero, zero
    li      s4, 0x80201000
    SET_RESUME 1f
    jal     ra, mprv_on
    ld      a1, 0(s4)
1:  jal     ra, mprv_off
    la      t6, trap_rec
    ld      t1, 0(t6)
    EXPECT  t1, 21, 0x05
    csrr    t1, mtval2
    EXPECT  t1, 0x80201000 >> 2, 0x06
    csrr    t1, mtinst
    EXPECT  t1, 0, 0x07
    // an implicit VS-stage PTE read faults in the G-stage
    li      t0, (8 << 60) | (0x40000000 >> 12)
    csrw    vsatp, t0
    .word   0x22000073              // hfence.vvma zero, zero
    li      s4, 0x1000
    SET_RESUME 1f
    jal     ra, mprv_on
    ld      a1, 0(s4)
1:  jal     ra, mprv_off
    la      t6, trap_rec
    ld      t1, 0(t6)
    EXPECT  t1, 21, 0x08
    csrr    t1, mtval2
    EXPECT  t1, 0x10000000, 0x09
    csrr    t1, mtinst
    EXPECT  t1, 0x3000, 0x0a
    la      t6, trap_rec
    ld      t1, 8(t6)
    EXPECT  t1, 0x1000, 0x0b
    SET_RESUME 1f
    jal     ra, mprv_on
    sd      a1, 0(s4)
1:  jal     ra, mprv_off
    la      t6, trap_rec
    ld      t1, 0(t6)
    EXPECT  t1, 23, 0x0c
    csrr    t1, mtinst
    EXPECT  t1, 0x3000, 0x0d
    REPORT  1

mprv_on:
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPRV | MSTATUS_MPP_S
    csrs    mstatus, t0
    li      t0, MPV
    csrs    mstatus, t0
    ret

mprv_off:
    li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    ret
