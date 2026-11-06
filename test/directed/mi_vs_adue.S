// MI: hardware A/D updates in the VS-stage (henvcfg.ADUE). M-mode with
// MPRV, MPP = S and MPV makes its data accesses guest accesses through
// vsatp (Sv39) and hgatp (Sv39x4). The VS-stage leaf of GVA 0x40000000 has
// A = D = 0, and the G-stage leaf of the page holding it (VS_L0) has W = 1
// and D = 0. Each sub-case s that misbehaves stops with tohost
// (s << 8) | 0x42; tohost is 1 when all pass.
//   1 menvcfg.ADUE = 0: henvcfg.ADUE reads zero after a write of 1
//   2 ADUE on, load: no trap, the VS leaf gets A (not D), and the G-stage
//     leaf of VS_L0 gets D (the A write is a store to that page)
//   3 ADUE on, store: no trap, the VS leaf gets D
//   4 henvcfg.ADUE = 0 (Svade), A clear: load page fault (13), mtval = GVA
//   5 ADUE on, the G-stage leaf of VS_L0 read-only: the A write is an
//     implicit store guest-page fault reported for the load (21), mtval2 =
//     the leaf's GPA >> 2, mtinst = 0x3020, and the VS leaf keeps A clear
#include "common/probe.h"

#define G_ROOT  0x80014000
#define G_L1    0x80018000
#define G_L0    0x80019000
#define VS_ROOT 0x8001a000
#define VS_L1   0x8001b000
#define VS_L0   0x8001c000
#define DATA    0x80020000
#define GVA     0x40000000
#define MPV     (1 << 39)
#define ADUE    (1 << 61)
#define VS_LEAF (VS_L0 + 0)
#define G_VSL0  (G_L0 + ((VS_L0 >> 12) & 0x1ff) * 8)
#define G_FLAGS (PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D)

.macro FAIL sub
    li      t0, (\sub << 8) | 0x42
    REPORT_REG t0
.endm

    .section .text
main:
    li      t0, G_ROOT
    li      t1, G_ROOT + 0x9000
1:  sd      zero, 0(t0)
    addi    t0, t0, 8
    bltu    t0, t1, 1b
    // G-stage: GPA 2 GiB -> G_L1 -> G_L0, identity 4 KiB leaves
    li      t0, G_ROOT
    li      t1, PTE(G_L1, PTE_V)
    sd      t1, 16(t0)
    li      t0, G_L1
    li      t1, PTE(G_L0, PTE_V)
    sd      t1, 0(t0)
    li      t0, G_L0 + ((VS_ROOT >> 12) & 0x1ff) * 8
    li      t1, PTE(VS_ROOT, G_FLAGS)
    sd      t1, 0(t0)
    li      t0, G_L0 + ((VS_L1 >> 12) & 0x1ff) * 8
    li      t1, PTE(VS_L1, G_FLAGS)
    sd      t1, 0(t0)
    li      t0, G_L0 + ((DATA >> 12) & 0x1ff) * 8
    li      t1, PTE(DATA, G_FLAGS)
    sd      t1, 0(t0)
    // VS-stage: GVA 1 GiB -> VS_L1 -> VS_L0 -> DATA
    li      t0, VS_ROOT + 8
    li      t1, PTE(VS_L1, PTE_V)
    sd      t1, 0(t0)
    li      t0, VS_L1
    li      t1, PTE(VS_L0, PTE_V)
    sd      t1, 0(t0)
    li      t0, (8 << 60) | (G_ROOT >> 12)
    csrw    hgatp, t0
    li      t0, (8 << 60) | (VS_ROOT >> 12)
    csrw    vsatp, t0
    li      s1, GVA
    li      s2, DATA
    li      t0, 0x5a
    sd      t0, 0(s2)

    // 1
    li      t0, ADUE
    csrc    menvcfg, t0
    csrs    henvcfg, t0
    csrr    t1, henvcfg
    and     t1, t1, t0
    beqz    t1, 1f
    FAIL    1
1:  li      t0, ADUE
    csrs    menvcfg, t0
    csrs    henvcfg, t0

    // 2
    li      a0, PTE_W
    jal     ra, reset_pt
    SET_RESUME 1f
    jal     ra, mprv_on
    ld      a1, 0(s1)
    jal     ra, mprv_off
    li      t0, 0x5a
    bne     a1, t0, 2f
    li      t0, VS_LEAF
    ld      t1, 0(t0)
    andi    t1, t1, PTE_A | PTE_D
    li      t2, PTE_A
    bne     t1, t2, 2f
    li      t0, G_VSL0
    ld      t1, 0(t0)
    andi    t1, t1, PTE_D
    beqz    t1, 2f
    j       3f
1:  jal     ra, mprv_off
2:  FAIL    2

    // 3
3:  SET_RESUME 1f
    jal     ra, mprv_on
    sd      s2, 8(s1)
    jal     ra, mprv_off
    li      t0, VS_LEAF
    ld      t1, 0(t0)
    andi    t1, t1, PTE_D
    beqz    t1, 2f
    j       3f
1:  jal     ra, mprv_off
2:  FAIL    3

    // 4
3:  li      t0, ADUE
    csrc    henvcfg, t0
    li      a0, PTE_W
    jal     ra, reset_pt
    SET_RESUME 1f
    jal     ra, mprv_on
    ld      a1, 0(s1)
    jal     ra, mprv_off
    j       2f
1:  jal     ra, mprv_off
    la      t6, trap_rec
    ld      t1, 0(t6)
    li      t2, 13
    bne     t1, t2, 2f
    ld      t1, 8(t6)
    bne     t1, s1, 2f
    j       3f
2:  FAIL    4

    // 5
3:  li      t0, ADUE
    csrs    henvcfg, t0
    li      a0, 0
    jal     ra, reset_pt
    SET_RESUME 1f
    jal     ra, mprv_on
    ld      a1, 0(s1)
    jal     ra, mprv_off
    j       2f
1:  jal     ra, mprv_off
    la      t6, trap_rec
    ld      t1, 0(t6)
    li      t2, 21
    bne     t1, t2, 2f
    csrr    t1, mtval2
    li      t2, VS_LEAF >> 2
    bne     t1, t2, 2f
    csrr    t1, mtinst
    li      t2, 0x3020
    bne     t1, t2, 2f
    li      t0, VS_LEAF
    ld      t1, 0(t0)
    andi    t1, t1, PTE_A
    bnez    t1, 2f
    REPORT  1
2:  FAIL    5

// The VS leaf with A = D = 0, and the G-stage leaf of VS_L0 with W = a0 and
// D = 0; then both TLBs are flushed.
reset_pt:
    li      t0, VS_LEAF
    li      t1, PTE(DATA, PTE_V | PTE_R | PTE_W)
    sd      t1, 0(t0)
    li      t0, G_VSL0
    li      t1, PTE(VS_L0, PTE_V | PTE_R | PTE_U | PTE_A)
    or      t1, t1, a0
    sd      t1, 0(t0)
    .word   0x22000073              // hfence.vvma zero, zero
    .word   0x62000073              // hfence.gvma zero, zero
    ret

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
