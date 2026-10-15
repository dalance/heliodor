// B04: a frm/fcsr CSR instruction and a simple op retired together.
//
// Each pair below is "<FP CSR op>; addi counter,counter,1", repeated with
// shifted alignment so the addi lands on either commit lane. Spec: every
// addi executes once. 0xB004: some addi executed twice (sub-case 1 for
// csrw frm, 2 for frrm, 3 for csrwi fcsr).
#include "common/probe.h"

#define NPAIR 16

    .section .text
main:
    li      t0, MSTATUS_FS_INIT
    csrs    mstatus, t0
    li      t0, 1
    li      s1, 0
    li      s2, 0
    li      s3, 0
    .option push
    .option norvc
    .rept NPAIR
    csrw    frm, t0
    addi    s1, s1, 1
    nop
    .endr
    .rept NPAIR
    frrm    t1
    addi    s2, s2, 1
    .endr
    .rept NPAIR
    csrwi   fcsr, 0
    addi    s3, s3, 1
    nop
    nop
    .endr
    .option pop
    PRINT   'w', s1
    PRINT   'r', s2
    PRINT   'f', s3
    li      t0, NPAIR
    bne     s1, t0, bug_w
    bne     s2, t0, bug_r
    bne     s3, t0, bug_f
    REPORT  1
bug_w:
    REPORT  CODE_BUG_SUB(4, 1)
bug_r:
    REPORT  CODE_BUG_SUB(4, 2)
bug_f:
    REPORT  CODE_BUG_SUB(4, 3)
