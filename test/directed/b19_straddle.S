// B19: a 32-bit instruction whose upper half is on an unmapped page.
//
// S-mode jumps to VA 0x80204ffe, where "addi a0, a0, 0x123" straddles
// into VA page 0x80205000 (PTE invalid; the PA behind it holds the upper
// half and an ecall). Spec: instruction page fault, cause 12, mepc
// 0x80204ffe, mtval 0x80205000, a0 untouched. 0xB013: the addi executed
// from the physical page behind the unmapped one.
#include "common/probe.h"

#define STR_PC  0x80204ffe

    .section .text
main:
    jal     ra, vm_init
    li      t0, PT_L0
    sd      zero, 5 * 8(t0)
    li      t0, STR_PC
    li      t1, 0x0513
    sh      t1, 0(t0)
    li      t1, 0x1235
    sh      t1, 2(t0)
    li      t1, 0x0073
    sh      t1, 4(t0)
    sh      zero, 6(t0)
    fence
    fence.i
    sfence.vma
    li      a0, 0
    SET_RESUME back
    ENTER_S go
go: li      t0, STR_PC
    jr      t0
back:
    la      t6, trap_rec
    ld      s1, 0(t6)
    ld      s2, 8(t6)
    ld      s3, 16(t6)
    mv      s4, a0
    PRINT   'c', s1
    PRINT   'v', s2
    PRINT   'e', s3
    PRINT   'a', s4
    bnez    s4, bug
    li      t0, 12
    bne     s1, t0, odd
    li      t0, STR_PC
    bne     s3, t0, odd
    REPORT  1
bug:
    REPORT  CODE_BUG(19)
odd:
    REPORT  CODE_ODD(0x19)
