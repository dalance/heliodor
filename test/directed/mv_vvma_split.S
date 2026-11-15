// A guest translation is cached as the smaller of its two leaves, so a VS
// 2 MiB leaf over 4 KiB G-stage leaves leaves one TLB entry per 4 KiB page.
// SFENCE.VMA in VS with the VA of one of those pages orders the leaf PTE of
// that VA, which is the 2 MiB leaf, so it must remove the entries of the
// other pages too. VS loads two pages of the 2 MiB leaf, clears the leaf,
// fences with the VA of the first page and loads the second: that load must
// take a load page fault. tohost is 1 when it does, 0x142 when it does not,
// 0xE001 when the setup did not complete.
#include "common/probe.h"

#define G_ROOT  0x80014000
#define G_L1    0x80018000
#define G_L0    0x80019000
#define VS_ROOT 0x8001a000
#define VS_L1   0x8001b000
#define GVA     0x40000000

    .section .text
main:
    li      t0, G_ROOT
    li      t1, VS_L1 + 0x1000
1:  sd      zero, 0(t0)
    addi    t0, t0, 8
    bltu    t0, t1, 1b
    // G-stage: GPA 0x80000000 as a 2 MiB leaf, 0x80200000 as 4 KiB leaves.
    li      t0, G_ROOT
    li      t1, PTE(G_L1, PTE_V)
    sd      t1, 16(t0)
    li      t0, G_L1
    li      t1, PTE(0x80000000, PTE_LEAF | PTE_U)
    sd      t1, 0(t0)
    li      t1, PTE(G_L0, PTE_V)
    sd      t1, 8(t0)
    li      t0, G_L0
    li      t1, PTE(VM_BASE, PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D)
    sd      t1, 0(t0)
    li      t1, PTE(VM_BASE + 0x1000, PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D)
    sd      t1, 8(t0)
    // VS-stage: VA 0x80000000 identity as a 1 GiB leaf, GVA as a 2 MiB leaf
    // to GPA 0x80200000.
    li      t0, VS_ROOT
    li      t1, PTE(0x80000000, PTE_LEAF)
    sd      t1, 16(t0)
    li      t1, PTE(VS_L1, PTE_V)
    sd      t1, 8(t0)
    li      t0, VS_L1
    li      t1, PTE(VM_BASE, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)
    sd      t1, 0(t0)
    li      t0, (8 << 60) | (1 << 44) | (G_ROOT >> 12)
    csrw    hgatp, t0
    li      t0, (8 << 60) | (VS_ROOT >> 12)
    csrw    vsatp, t0
    hfence.gvma zero, zero
    hfence.vvma zero, zero
    li      s4, 0
    la      t0, trap_cnt
    sd      zero, 0(t0)
    SET_RESUME 3f
    la      t0, 2f
    csrw    mepc, t0
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S | (1 << 39)
    csrs    mstatus, t0
    mret
2:  li      t0, GVA
    ld      t1, 0(t0)
    li      t0, GVA + 0x1000
    ld      t1, 0(t0)
    li      t0, VS_L1
    sd      zero, 0(t0)
    li      t0, GVA
    sfence.vma t0, zero
    li      s4, 1
    li      t0, GVA + 0x1000
final_ld:
    ld      t1, 0(t0)
    ecall
3:  beqz    s4, 8f
    la      t0, trap_cnt
    ld      t1, 0(t0)
    li      t2, 1
    bne     t1, t2, 7f
    la      t0, trap_cause
    ld      t1, 0(t0)
    li      t2, 13
    bne     t1, t2, 7f
    la      t0, trap_epc
    ld      t1, 0(t0)
    la      t2, final_ld
    bne     t1, t2, 7f
    REPORT  1
7:  REPORT  0x142
8:  REPORT  CODE_ODD(1)
