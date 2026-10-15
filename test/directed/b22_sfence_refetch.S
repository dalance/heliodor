// B22: SFENCE.VMA must make younger fetches use the new translation.
//
// S-mode runs VA page P (mapped to PA A, "li a0,1; ecall") once to warm
// the I-side, rewrites P's PTE to PA B ("li a0,2; ecall"), executes
// sfence.vma and jumps to P. Spec: a0 = 2. 0xB016: a0 = 1, the jump ran
// the stale mapping.
#include "common/probe.h"

#define VP      (VM_BASE + 0x8000)
#define PA_A    (VM_BASE + 0x9000)
#define PA_B    (VM_BASE + 0xa000)

    .section .text
main:
    jal     ra, vm_init
    // li a0, 1 / li a0, 2 ; ecall
    li      t0, PA_A
    li      t1, 0x00100513
    sw      t1, 0(t0)
    li      t1, 0x00000073
    sw      t1, 4(t0)
    li      t0, PA_B
    li      t1, 0x00200513
    sw      t1, 0(t0)
    li      t1, 0x00000073
    sw      t1, 4(t0)
    li      t0, PT_L0
    li      t1, PTE(PA_A, PTE_LEAF)
    sd      t1, 8 * 8(t0)
    fence
    fence.i
    sfence.vma
    li      s4, 0
    li      s5, 0
    .rept 4
    SET_RESUME 1f
    ENTER_S 2f
2:  li      t0, VP
    jr      t0
1:  mv      s1, a0
    SET_RESUME 1f
    ENTER_S 2f
2:  li      t0, PT_L0 + 8 * 8
    li      t1, PTE(PA_B, PTE_LEAF)
    sd      t1, 0(t0)
    sfence.vma
    li      t0, VP
    jr      t0
1:  mv      s2, a0
    li      t0, PT_L0 + 8 * 8
    li      t1, PTE(PA_A, PTE_LEAF)
    sd      t1, 0(t0)
    sfence.vma
    li      t0, 2
    bne     s2, t0, 3f
    addi    s4, s4, 1
    j       4f
3:  addi    s5, s5, 1
4:
    .endr
    PRINT   'w', s1
    PRINT   'g', s4
    PRINT   'b', s5
    bnez    s5, bug
    REPORT  1
bug:
    REPORT  CODE_BUG(22)
