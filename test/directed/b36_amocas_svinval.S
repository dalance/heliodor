// B36: a faulting amocas.q must not write rd, and U-mode
// sfence.w.inval must be illegal.
//
// Sub-case 1: amocas.q a2, a4, (t0) to a PMA hole (access fault) with
// a2/a3 preset; spec leaves a2/a3 unchanged. Sub-case 2: U-mode
// "addi; sfence.w.inval"; spec raises illegal instruction (cause 2).
// 0xB024 with sub-case bit 0 / bit 1 set for each deviation observed.
#include "common/probe.h"

#define HOLE 0x40000000

    .section .text
main:
    li      a2, 0x1111
    li      a3, 0x2222
    li      a4, 0x3333
    li      a5, 0x4444
    la      t6, trap_rec
    sd      zero, 0(t6)
    SET_RESUME 1f
    li      t0, HOLE
    amocas.q a2, a4, (t0)
1:  mv      s3, a2
    mv      s4, a3
    la      t6, trap_rec
    ld      s1, 0(t6)
    PRINT   'c', s1
    PRINT   'x', s3
    PRINT   'y', s4
    li      s10, 0
    li      t0, 0x1111
    bne     s3, t0, 3f
    li      t0, 0x2222
    beq     s4, t0, 4f
3:  ori     s10, s10, 1
4:
    la      t6, trap_rec
    sd      zero, 0(t6)
    SET_RESUME 2f
    ENTER_U u_code
u_code:
    .option push
    .option norvc
    addi    a0, a0, 1
    sfence.w.inval
    ecall
    .option pop
2:  la      t6, trap_rec
    ld      s2, 0(t6)
    PRINT   'u', s2
    li      t0, 2
    beq     s2, t0, 5f
    ori     s10, s10, 2
5:  li      t0, 7
    bne     s1, t0, odd
    beqz    s10, 6f
    slli    s10, s10, 16
    li      t0, CODE_BUG(36)
    or      s10, s10, t0
    REPORT_REG s10
6:  REPORT  1
odd:
    REPORT  CODE_ODD(0x36)
