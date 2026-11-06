// MI: Ssdbltrp. medeleg (and for VS hedeleg) delegates the illegal
// instruction; the S and VS handler records sstatus and counts the trap,
// then returns past the instruction with SRET. Each sub-case s that
// misbehaves stops with tohost (s << 8) | 0x42; tohost is 1 when all pass.
//   1 menvcfg.DTE = 0: mstatus.SDT and henvcfg.DTE read zero after a write
//     of 1
//   2 DTE = 1: a write that sets SDT and SIE leaves SIE clear
//   3 a trap into S sets SDT, the SRET of its handler clears it
//   4 an illegal instruction in S with SDT set is a double trap: M gets
//     cause 16, mtval the encoding, mepc the instruction, mtval2 2, and
//     scause, the S handler and SDT are untouched
//   5 MRET to S keeps SDT, MRET to U clears it
//   6 henvcfg.DTE = 1: a trap into VS sets vsstatus.SDT and the VS SRET
//     clears it, leaving mstatus.SDT alone
//   7 an illegal instruction in VS with vsstatus.SDT set is a double trap
//     into M (cause 16, mtval2 2, vscause untouched)
//   8 henvcfg.DTE = 0: vsstatus.SDT reads zero and two VS traps in a row are
//     both taken by the VS handler
#include "common/probe.h"

#define SDT     (1 << 24)
#define DTE     (1 << 59)
#define MPV     (1 << 39)
#define SIE     (1 << 1)
#define UNIMP   0xc0001073
#define MCAUSE_DBL 16

.macro FAIL sub
    li      t0, (\sub << 8) | 0x42
    REPORT_REG t0
.endm

// Enter VS at label: MPP = S, MPV = 1.
.macro ENTER_VS label
    li      t0, MPV
    csrs    mstatus, t0
    ENTER_S \label
.endm

    .section .text
main:
    la      t0, s_handler
    csrw    stvec, t0
    csrw    vstvec, t0
    li      t0, 1 << 2
    csrw    medeleg, t0
    csrw    hedeleg, t0

    // 1
    li      t0, SDT
    csrs    mstatus, t0
    csrr    t1, mstatus
    and     t1, t1, t0
    bnez    t1, 1f
    li      t0, DTE
    csrs    henvcfg, t0
    csrr    t1, henvcfg
    and     t1, t1, t0
    beqz    t1, 2f
1:  FAIL    1

    // 2
2:  li      t0, DTE
    csrs    menvcfg, t0
    li      t0, SDT | SIE
    csrs    mstatus, t0
    csrr    t1, mstatus
    and     t1, t1, t0
    li      t2, SDT
    bne     t1, t2, 1f
    li      t0, SDT
    csrc    mstatus, t0
    li      t0, SIE
    csrs    mstatus, t0
    csrr    t1, mstatus
    and     t1, t1, t0
    beqz    t1, 1f
    csrc    mstatus, t0
    j       2f
1:  FAIL    2

    // 3
2:  SET_RESUME 1f
    ENTER_S c3_s
c3_s:
    .word   UNIMP
    csrr    s4, sstatus
    ecall
1:  ld      t1, s_sts
    li      t0, SDT
    and     t1, t1, t0
    beqz    t1, 1f
    and     t1, s4, t0
    bnez    t1, 1f
    ld      t1, trap_cause
    li      t2, 9
    bne     t1, t2, 1f
    j       2f
1:  FAIL    3

    // 4
2:  li      t0, 0x77
    csrw    scause, t0
    ld      s6, s_cnt
    SET_RESUME 1f
    ENTER_S c4_s
c4_s:
    li      t0, SDT
    csrs    sstatus, t0
c4_ill:
    .word   UNIMP
    ecall
1:  ld      t1, trap_cause
    li      t2, MCAUSE_DBL
    bne     t1, t2, 1f
    ld      t1, trap_tval
    li      t2, UNIMP
    bne     t1, t2, 1f
    ld      t1, trap_epc
    la      t2, c4_ill
    bne     t1, t2, 1f
    csrr    t1, mtval2
    li      t2, 2
    bne     t1, t2, 1f
    csrr    t1, scause
    li      t2, 0x77
    bne     t1, t2, 1f
    ld      t1, s_cnt
    bne     t1, s6, 1f
    csrr    t1, mstatus
    li      t0, SDT
    and     t1, t1, t0
    beqz    t1, 1f
    j       2f
1:  FAIL    4

    // 5
2:  SET_RESUME 1f
    ENTER_S c5_s
c5_s:
    ecall
1:  csrr    t1, mstatus
    li      t0, SDT
    and     t1, t1, t0
    beqz    t1, 3f
    SET_RESUME 1f
    ENTER_U c5_u
c5_u:
    ecall
1:  csrr    t1, mstatus
    li      t0, SDT
    and     t1, t1, t0
    beqz    t1, 2f
3:  FAIL    5

    // 6
2:  li      t0, DTE
    csrs    henvcfg, t0
    csrr    t1, henvcfg
    and     t1, t1, t0
    beqz    t1, 1f
    csrw    vsstatus, zero
    SET_RESUME 3f
    ENTER_VS c6_vs
c6_vs:
    .word   UNIMP
    csrr    s4, sstatus
    ecall
3:  ld      t1, s_sts
    li      t0, SDT
    and     t1, t1, t0
    beqz    t1, 1f
    and     t1, s4, t0
    bnez    t1, 1f
    ld      t1, trap_cause
    li      t2, 10
    bne     t1, t2, 1f
    csrr    t1, mstatus
    and     t1, t1, t0
    bnez    t1, 1f
    j       2f
1:  FAIL    6

    // 7
2:  li      t0, 0x77
    csrw    vscause, t0
    ld      s6, s_cnt
    SET_RESUME 1f
    ENTER_VS c7_vs
c7_vs:
    li      t0, SDT
    csrs    sstatus, t0
    .word   UNIMP
    ecall
1:  ld      t1, trap_cause
    li      t2, MCAUSE_DBL
    bne     t1, t2, 1f
    csrr    t1, mtval2
    li      t2, 2
    bne     t1, t2, 1f
    csrr    t1, vscause
    li      t2, 0x77
    bne     t1, t2, 1f
    ld      t1, s_cnt
    bne     t1, s6, 1f
    csrr    t1, vsstatus
    li      t0, SDT
    and     t1, t1, t0
    beqz    t1, 1f
    j       2f
1:  FAIL    7

    // 8
2:  li      t0, DTE
    csrc    henvcfg, t0
    csrr    t1, vsstatus
    li      t0, SDT
    and     t1, t1, t0
    bnez    t1, 1f
    ld      s6, s_cnt
    SET_RESUME 3f
    ENTER_VS c8_vs
c8_vs:
    .word   UNIMP
    .word   UNIMP
    ecall
3:  ld      t1, trap_cause
    li      t2, 10
    bne     t1, t2, 1f
    ld      t1, s_cnt
    addi    t1, t1, -2
    bne     t1, s6, 1f
    REPORT  1
1:  FAIL    8

// S and VS handler: record sstatus, count, return past the instruction.
    .align 2
s_handler:
    la      t6, s_sts
    csrr    t5, sstatus
    sd      t5, 0(t6)
    ld      t5, 8(t6)
    addi    t5, t5, 1
    sd      t5, 8(t6)
    csrr    t5, sepc
    addi    t5, t5, 4
    csrw    sepc, t5
    sret

    .section .data
    .align 3
s_sts:  .dword 0
s_cnt:  .dword 0
