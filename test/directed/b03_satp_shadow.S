// B03: after "csrw satp" without SFENCE.VMA, a fresh walk must use the
// new root.
//
// Root 1 (vm_init) leaves VA X unmapped; root 2 maps X to PA B. M-mode
// with MPRV=1/MPP=S switches satp to root 2 and loads X, which no TLB
// can hold. Spec: the load returns B's data. 0xB003: it faulted (cause
// 13, the walk used root 1) or returned other data (sub-case 2).
#include "common/probe.h"

#define ROOT2 0x80014000
#define L1B   0x80015000
#define L0B   0x80016000
#define VX    (VM_BASE + 0x10000)
#define PB    (VM_BASE + 0x30000)

    .section .text
main:
    jal     ra, vm_init
    li      t0, PT_L0
    sd      zero, 16 * 8(t0)
    sfence.vma
    li      t0, ROOT2
    li      t1, ROOT2 + 0x3000
1:  sd      zero, 0(t0)
    addi    t0, t0, 8
    bltu    t0, t1, 1b
    li      t0, ROOT2
    li      t1, PTE(L1B, PTE_V)
    sd      t1, 16(t0)
    li      t0, L1B
    li      t1, PTE(0x80000000, PTE_LEAF)
    sd      t1, 0(t0)
    li      t1, PTE(L0B, PTE_V)
    sd      t1, 8(t0)
    li      t0, L0B
    li      t1, PTE(PB, PTE_LEAF)
    sd      t1, 16 * 8(t0)
    li      t0, PB
    li      t1, 0xbbbb
    sd      t1, 0(t0)
    fence
    la      t6, trap_rec
    sd      zero, 0(t6)
    li      s1, 0
    SET_RESUME back
    li      s3, (8 << 60) | (ROOT2 >> 12)
    li      s4, VX
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPRV | MSTATUS_MPP_S
    csrs    mstatus, t0
    csrw    satp, s3
    ld      s1, 0(s4)
back:
    li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    la      t6, trap_rec
    ld      s2, 0(t6)
    PRINT   'c', s2
    PRINT   'd', s1
    bnez    s2, bug_fault
    li      t0, 0xbbbb
    bne     s1, t0, bug_data
    REPORT  1
bug_fault:
    li      t0, 13
    bne     s2, t0, odd
    REPORT  CODE_BUG_SUB(3, 1)
bug_data:
    REPORT  CODE_BUG_SUB(3, 2)
odd:
    REPORT  CODE_ODD(0x03)
