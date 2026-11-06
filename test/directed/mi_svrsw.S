// MI: Svrsw60t59b. PTE bits 60:59 are ignored at every level of the
// S-stage, the VS-stage and the G-stage; bit 58 stays reserved. M-mode
// with MPRV and MPP = S makes its data accesses S-mode accesses through
// satp, and with MPV also guest accesses through vsatp and hgatp. Each
// sub-case s that misbehaves stops with tohost (s << 8) | 0x42; tohost is
// 1 when all pass.
//   1 S-stage: the root entry and the leaf of VA carry bits 60:59, the load
//     succeeds
//   2 S-stage: the leaf carries bit 58, load page fault (13), mtval = VA
//   3 two-stage: every VS-stage and G-stage entry on the path carries bits
//     60:59, the load succeeds
//   4 two-stage: the G-stage leaf of the data page carries bit 58, load
//     guest-page fault (21), mtval2 = the data GPA >> 2
//   5 two-stage: the VS-stage leaf carries bit 58, load page fault (13)
#include "common/probe.h"

#define S_ROOT  0x80030000
#define S_L1    0x80031000
#define S_L0    0x80032000
#define G_ROOT  0x80014000
#define G_L1    0x80018000
#define G_L0    0x80019000
#define VS_ROOT 0x8001a000
#define VS_L1   0x8001b000
#define VS_L0   0x8001c000
#define DATA    0x80020000
#define VA      0x40000000
#define MPV     (1 << 39)
#define SW      (3 << 59)
#define B58     (1 << 58)
#define LEAF    (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
#define G_LEAF  (PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D)
#define G_DATA  (G_L0 + ((DATA >> 12) & 0x1ff) * 8)

.macro FAIL sub
    li      t0, (\sub << 8) | 0x42
    REPORT_REG t0
.endm

// Store PTE(pa, fl) | extra at addr.
.macro SETPTE addr, pa, fl, extra
    li      t0, \addr
    li      t1, PTE(\pa, \fl)
    li      t2, \extra
    or      t1, t1, t2
    sd      t1, 0(t0)
.endm

    .section .text
main:
    li      t0, G_ROOT
    li      t1, S_L0 + 0x1000
1:  sd      zero, 0(t0)
    addi    t0, t0, 8
    bltu    t0, t1, 1b
    li      s1, VA
    li      s2, DATA
    li      t0, 0x5a
    sd      t0, 0(s2)
    li      t0, (8 << 60) | (S_ROOT >> 12)
    csrw    satp, t0
    li      t0, (8 << 60) | (G_ROOT >> 12)
    csrw    hgatp, t0
    li      t0, (8 << 60) | (VS_ROOT >> 12)
    csrw    vsatp, t0

    // 1
    SETPTE  S_ROOT + 8, S_L1, PTE_V, SW
    SETPTE  S_L1, S_L0, PTE_V, 0
    SETPTE  S_L0, DATA, LEAF, SW
    sfence.vma
    li      s3, 0
    SET_RESUME 1f
    jal     ra, mprv_on
    ld      a1, 0(s1)
    jal     ra, mprv_off
    li      t0, 0x5a
    bne     a1, t0, 2f
    j       3f
1:  jal     ra, mprv_off
2:  FAIL    1

    // 2
3:  SETPTE  S_L0, DATA, LEAF, B58
    sfence.vma
    SET_RESUME 1f
    jal     ra, mprv_on
    ld      a1, 0(s1)
    jal     ra, mprv_off
    j       2f
1:  jal     ra, mprv_off
    li      a0, 13
    mv      a1, s1
    jal     ra, check_trap
    beqz    a0, 3f
2:  FAIL    2

    // 3
3:  SETPTE  G_ROOT + 16, G_L1, PTE_V, SW
    SETPTE  G_L1, G_L0, PTE_V, SW
    SETPTE  G_L0 + ((VS_ROOT >> 12) & 0x1ff) * 8, VS_ROOT, G_LEAF, SW
    SETPTE  G_L0 + ((VS_L1 >> 12) & 0x1ff) * 8, VS_L1, G_LEAF, SW
    SETPTE  G_L0 + ((VS_L0 >> 12) & 0x1ff) * 8, VS_L0, G_LEAF, SW
    SETPTE  G_DATA, DATA, G_LEAF, SW
    SETPTE  VS_ROOT + 8, VS_L1, PTE_V, SW
    SETPTE  VS_L1, VS_L0, PTE_V, SW
    SETPTE  VS_L0, DATA, LEAF, SW
    jal     ra, hfence
    li      s3, MPV
    SET_RESUME 1f
    jal     ra, mprv_on
    ld      a1, 0(s1)
    jal     ra, mprv_off
    li      t0, 0x5a
    bne     a1, t0, 2f
    j       3f
1:  jal     ra, mprv_off
2:  FAIL    3

    // 4
3:  SETPTE  G_DATA, DATA, G_LEAF, B58
    jal     ra, hfence
    SET_RESUME 1f
    jal     ra, mprv_on
    ld      a1, 0(s1)
    jal     ra, mprv_off
    j       2f
1:  jal     ra, mprv_off
    li      a0, 21
    mv      a1, s1
    jal     ra, check_trap
    bnez    a0, 2f
    csrr    t1, mtval2
    li      t2, DATA >> 2
    beq     t1, t2, 3f
2:  FAIL    4

    // 5
3:  SETPTE  G_DATA, DATA, G_LEAF, SW
    SETPTE  VS_L0, DATA, LEAF, B58
    jal     ra, hfence
    SET_RESUME 1f
    jal     ra, mprv_on
    ld      a1, 0(s1)
    jal     ra, mprv_off
    j       2f
1:  jal     ra, mprv_off
    li      a0, 13
    mv      a1, s1
    jal     ra, check_trap
    bnez    a0, 2f
    REPORT  1
2:  FAIL    5

// a0 = 0 if the last trap had cause a0 and mtval a1.
check_trap:
    la      t6, trap_rec
    ld      t1, 0(t6)
    bne     t1, a0, 1f
    ld      t1, 8(t6)
    bne     t1, a1, 1f
    li      a0, 0
    ret
1:  li      a0, 1
    ret

hfence:
    .word   0x22000073              // hfence.vvma zero, zero
    .word   0x62000073              // hfence.gvma zero, zero
    ret

// MPRV with MPP = S, and MPV = s3 (0 or MPV).
mprv_on:
    li      t0, MSTATUS_MPP | MPV
    csrc    mstatus, t0
    li      t0, MSTATUS_MPRV | MSTATUS_MPP_S
    or      t0, t0, s3
    csrs    mstatus, t0
    ret

mprv_off:
    li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    ret
