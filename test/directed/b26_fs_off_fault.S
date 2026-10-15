// B26: with FS=Off, an FP load to an unmapped page is illegal first.
//
// S-mode flw from an unmapped VA with mstatus.FS=0. Spec: illegal
// instruction (cause 2). 0xB01A: load page fault (cause 13) reported.
#include "common/probe.h"

#define UNMAPPED (VM_BASE + 0x2000)

    .section .text
main:
    jal     ra, vm_init
    li      t0, PT_L0
    sd      zero, 2 * 8(t0)
    sfence.vma
    li      t0, MSTATUS_FS
    csrc    mstatus, t0
    SET_RESUME back
    ENTER_S s_code
s_code:
    li      t0, UNMAPPED
    flw     f1, 0(t0)
    ecall
back:
    la      t6, trap_rec
    ld      s1, 0(t6)
    PRINT   'c', s1
    li      t0, 2
    beq     s1, t0, pass
    li      t0, 13
    beq     s1, t0, bug
    REPORT  CODE_ODD(0x26)
pass:
    REPORT  1
bug:
    REPORT  CODE_BUG(26)
