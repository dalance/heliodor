// B07: a misaligned access that crosses a page must translate both pages.
//
// S-mode, VA page 0x8020c000 -> PA 0x80210000 and VA page 0x8020d000 ->
// PA 0x80220000 (not adjacent). ld and sd at VA 0x8020cffc. Spec: the
// upper 4 bytes come from / go to PA 0x80220000. 0xB007: they come from
// / go to the PA right after the first page (0x80211000): sub-case 1
// for the load, 2 for the store. A misaligned trap is spec-legal and
// reported as inconclusive.
#include "common/probe.h"

#define VA0   (VM_BASE + 0xc000)
#define PA0   (VM_BASE + 0x10000)
#define PA1   (VM_BASE + 0x20000)
#define PAADJ (PA0 + 0x1000)

    .section .text
main:
    jal     ra, vm_init
    li      t0, PT_L0
    li      t1, PTE(PA0, PTE_LEAF)
    sd      t1, 12 * 8(t0)
    li      t1, PTE(PA1, PTE_LEAF)
    sd      t1, 13 * 8(t0)
    sfence.vma
    li      t0, PA0 + 0xff8
    li      t1, 0x1111111111111111
    sd      t1, 0(t0)
    li      t0, PA1
    li      t1, 0x2222222222222222
    sd      t1, 0(t0)
    li      t0, PAADJ
    li      t1, 0x3333333333333333
    sd      t1, 0(t0)
    fence
    la      t6, trap_rec
    sd      zero, 0(t6)
    SET_RESUME back
    ENTER_S s_code
s_code:
    li      t0, VA0 + 0xffc
    ld      s1, 0(t0)
    li      t1, 0x4444444444444444
    sd      t1, 0(t0)
    ecall
back:
    la      t6, trap_rec
    ld      s2, 0(t6)
    li      t0, PA1
    ld      s3, 0(t0)
    li      t0, PAADJ
    ld      s4, 0(t0)
    PRINT   'c', s2
    PRINT   'l', s1
    PRINT   'p', s3
    PRINT   'q', s4
    li      t0, 9
    bne     s2, t0, odd
    li      t0, 0x3333333311111111
    beq     s1, t0, bug_ld
    li      t0, 0x2222222211111111
    bne     s1, t0, odd
    li      t0, 0x3333333344444444
    beq     s4, t0, bug_st
    li      t0, 0x2222222244444444
    bne     s3, t0, odd
    REPORT  1
bug_ld:
    REPORT  CODE_BUG_SUB(7, 1)
bug_st:
    REPORT  CODE_BUG_SUB(7, 2)
odd:
    REPORT  CODE_ODD(0x07)
