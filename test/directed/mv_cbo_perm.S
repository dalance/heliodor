// cbo.clean through Sv39 may access any page a load or a store may: it needs
// neither D (with or without menvcfg.ADUE) nor W, and under MXR an
// execute-only page is readable. Each sub-case runs the cbo.clean in S or U
// on VM_BASE + 0x1000 and then an ecall; a missing ecall cause (the cbo
// trapped) sets bit s-1 of the mask; tohost is 1 when the mask is 0, else
// (mask << 8) | 0x42.
//   1 S, RW A, ADUE 1      2 S, RW A, ADUE 0      3 U, RW A, ADUE 1
//   4 U, RW A, ADUE 0      5 U, RWX A, ADUE 1     6 U, X only with MXR
//   7 S, X only with MXR
#include "common/probe.h"
#define MENVCFG_ADUE (1 << 61)
#define ENVCFG_CBCFE (1 << 6)
#define MSTATUS_MXR  (1 << 19)

.macro CASE sub, flags, user, adue
    li      t0, MENVCFG_ADUE
    csrc    menvcfg, t0
    li      t0, \adue
    csrs    menvcfg, t0
    li      t0, PT_L0 + 8
    li      t1, PTE(VM_BASE + 0x1000, \flags)
    sd      t1, 0(t0)
    sfence.vma
    la      t6, trap_rec
    sd      zero, 0(t6)
    SET_RESUME 1f
.if \user
    ENTER_U 2f
.else
    ENTER_S 2f
.endif
2:  li      a0, VM_BASE + 0x1000
    .insn   i 0x0f, 2, x0, a0, 1    // cbo.clean (a0)
    ecall
1:  la      t6, trap_rec
    ld      t1, 0(t6)
    li      t0, 9 - \user
    beq     t1, t0, 3f
    li      t0, 1 << (\sub - 1)
    or      s3, s3, t0
    PRINT   'c', t1
3:
.endm

    .section .text
main:
    li      s3, 0
    jal     ra, vm_init
    li      t0, ENVCFG_CBCFE
    csrs    menvcfg, t0
    csrs    senvcfg, t0
    CASE 1, (PTE_V|PTE_R|PTE_W|PTE_A), 0, MENVCFG_ADUE
    CASE 2, (PTE_V|PTE_R|PTE_W|PTE_A), 0, 0
    // U: the 2 MiB code leaf becomes a user page
    li      t0, PT_L1
    li      t1, PTE(0x80000000, PTE_LEAF | PTE_U)
    sd      t1, 0(t0)
    CASE 3, (PTE_V|PTE_R|PTE_W|PTE_A|PTE_U), 1, MENVCFG_ADUE
    CASE 4, (PTE_V|PTE_R|PTE_W|PTE_A|PTE_U), 1, 0
    CASE 5, (PTE_V|PTE_R|PTE_W|PTE_X|PTE_A|PTE_U), 1, MENVCFG_ADUE
    // An execute-only page is readable under MXR, so a cbo may access it.
    li      t0, MSTATUS_MXR
    csrs    mstatus, t0
    CASE 6, (PTE_V|PTE_X|PTE_A|PTE_D|PTE_U), 1, 0
    li      t0, PT_L1
    li      t1, PTE(0x80000000, PTE_LEAF)
    sd      t1, 0(t0)
    CASE 7, (PTE_V|PTE_X|PTE_A|PTE_D), 0, 0
    beqz    s3, 9f
    slli    s3, s3, 8
    ori     s3, s3, 0x42
    REPORT_REG s3
9:  REPORT  1
