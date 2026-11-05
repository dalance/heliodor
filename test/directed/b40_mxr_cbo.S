// B40: vsstatus.MXR applies to the VS-stage only, and a CBO management op
// in a two-stage translation needs read or write permission in the G-stage
// (not write).
//
// M-mode with MPRV, MPP = S and MPV, vsatp Bare and an Sv39x4 G-stage: GPA
// 0x80200000 is execute-only, GPA 0x80201000 read-only (both U). With
// vsstatus.MXR a load of the execute-only page must still fault (cause 21);
// with mstatus.MXR it reads. cbo.clean of the read-only page must not
// fault. 0xB028 with bit 16 (vsstatus.MXR let the load through), bit 17
// (mstatus.MXR did not) and bit 18 (the CBO faulted).
#include "common/probe.h"

#define G_ROOT 0x80014000
#define G_L1   0x80018000
#define G_L0   0x80019000
#define MPV    (1 << 39)
#define MXR    (1 << 19)

    .section .text
main:
    li      t0, G_ROOT
    li      t1, PTE(G_L1, PTE_V)
    sd      t1, 16(t0)
    li      t0, G_L1
    li      t1, PTE(0x80000000, PTE_LEAF | PTE_U)
    sd      t1, 0(t0)
    li      t1, PTE(G_L0, PTE_V)
    sd      t1, 8(t0)
    li      t0, G_L0
    li      t1, PTE(0x80200000, PTE_V | PTE_X | PTE_U | PTE_A | PTE_D)
    sd      t1, 0(t0)
    li      t1, PTE(0x80201000, PTE_V | PTE_R | PTE_U | PTE_A | PTE_D)
    sd      t1, 8(t0)
    li      t0, (8 << 60) | (G_ROOT >> 12)
    csrw    hgatp, t0
    csrw    vsatp, zero
    .word   0x62000073              // hfence.gvma zero, zero
    li      t0, 0x40                // CBCFE
    csrs    menvcfg, t0
    csrs    henvcfg, t0
    li      s3, 0
    li      s4, 0x80200000
    // vsstatus.MXR: the G-stage still needs R
    li      t0, MXR
    csrs    vsstatus, t0
    SET_RESUME 1f
    la      t6, trap_rec
    sd      zero, 0(t6)
    jal     ra, mprv_on
    ld      a1, 0(s4)
1:  jal     ra, mprv_off
    la      t6, trap_rec
    ld      t1, 0(t6)
    li      t2, 21
    beq     t1, t2, 2f
    bnez    t1, odd
    li      t0, 0x10000
    or      s3, s3, t0
2:  li      t0, MXR
    csrc    vsstatus, t0
    // mstatus.MXR applies to both stages
    SET_RESUME 1f
    la      t6, trap_rec
    sd      zero, 0(t6)
    jal     ra, mprv_on
    li      t0, MXR
    csrs    mstatus, t0
    ld      a1, 0(s4)
1:  li      t0, MXR
    csrc    mstatus, t0
    jal     ra, mprv_off
    la      t6, trap_rec
    ld      t1, 0(t6)
    beqz    t1, 2f
    li      t2, 21
    bne     t1, t2, odd
    li      t0, 0x20000
    or      s3, s3, t0
2:  // cbo.clean of a read-only G-stage page
    li      s4, 0x80201000
    SET_RESUME 1f
    la      t6, trap_rec
    sd      zero, 0(t6)
    jal     ra, mprv_on
    .insn   i 0x0f, 2, x0, s4, 1    // cbo.clean (s4)
1:  jal     ra, mprv_off
    la      t6, trap_rec
    ld      t1, 0(t6)
    beqz    t1, 2f
    li      t2, 23
    bne     t1, t2, odd
    li      t0, 0x40000
    or      s3, s3, t0
2:  bnez    s3, bug
    REPORT  1
bug:
    li      t0, CODE_BUG(40)
    or      t0, t0, s3
    REPORT_REG t0
odd:
    PRINT   'c', t1
    REPORT  CODE_ODD(0x40)

mprv_on:
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPRV | MSTATUS_MPP_S
    csrs    mstatus, t0
    li      t0, MPV
    csrs    mstatus, t0
    ret

mprv_off:
    li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    ret
