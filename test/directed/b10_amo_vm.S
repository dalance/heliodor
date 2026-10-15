// B10: an AMO under Sv39 must honour the page's W and D bits.
//
// S-mode stores and amoadd.d to a read-only page and to a W=1/D=0 page
// (menvcfg.ADUE=0). The plain stores are the control. Spec: all four
// raise a store page fault (cause 15) and memory is unchanged. 0xB00A:
// the amoadd completed without a fault (sub-case 1 read-only page,
// 2 D=0 page). Memory is printed after each case.
#include "common/probe.h"

#define PG_RO   (VM_BASE + 0x0000)
#define PG_ND   (VM_BASE + 0x1000)

.macro S_CASE op, addr, val, res, mem
    la      t6, trap_rec
    sd      zero, 0(t6)
    SET_RESUME 1f
    ENTER_S 2f
2:  li      t0, \addr
    li      t1, \val
    \op
    ecall
1:  la      t6, trap_rec
    ld      \res, 0(t6)
    li      t0, \addr
    ld      \mem, 0(t0)
.endm

    .section .text
main:
    jal     ra, vm_init
    li      t0, PT_L0
    li      t1, PTE(PG_RO, PTE_V | PTE_R | PTE_A | PTE_D)
    sd      t1, 0(t0)
    li      t1, PTE(PG_ND, PTE_V | PTE_R | PTE_W | PTE_A)
    sd      t1, 8(t0)
    sfence.vma
    li      t0, 1
    slli    t0, t0, 61
    csrc    menvcfg, t0
    li      t0, PG_RO
    li      t1, 100
    sd      t1, 0(t0)
    li      t0, PG_ND
    li      t1, 200
    sd      t1, 0(t0)
    fence
    S_CASE  "sd t1, 0(t0)", PG_RO, 0x10, s1, s7
    S_CASE  "amoadd.d zero, t1, (t0)", PG_RO, 1, s2, s5
    S_CASE  "sd t1, 0(t0)", PG_ND, 0x10, s3, s8
    S_CASE  "amoadd.d zero, t1, (t0)", PG_ND, 1, s4, s6
    PRINT   'a', s1
    PRINT   'w', s7
    PRINT   'b', s2
    PRINT   'r', s5
    PRINT   'c', s3
    PRINT   'x', s8
    PRINT   'd', s4
    PRINT   'n', s6
    li      t0, 15
    bne     s2, t0, bug_ro
    bne     s4, t0, bug_nd
    bne     s1, t0, odd
    bne     s3, t0, odd
    REPORT  1
bug_ro:
    REPORT  CODE_BUG_SUB(10, 1)
bug_nd:
    REPORT  CODE_BUG_SUB(10, 2)
odd:
    REPORT  CODE_ODD(0x10)
