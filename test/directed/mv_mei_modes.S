// The machine external interrupt taken from each mode, and the VS external
// interrupt delegated to VS taken from VU. The harness pulses PLIC sources
// 1-5 once, early (irq=0x3e); sub-case k enables source k alone in the M
// context, waits in its mode with mie.MEIE set, and the M handler records
// mcause and returns to the check, which claims and completes source k.
// Each sub-case s that sees the wrong cause or claim sets bit s-1 of the
// mask; tohost is 1 when the mask is 0, else (mask << 8) | 0x42.
//   1 M with mstatus.MIE   2 HS   3 U   4 VS   5 VU
//   6 VU, hideleg.VSEI and hvip.VSEIP: VS takes interrupt 9 and ecalls to M
#include "common/probe.h"

#define PLIC        0x0c000000
#define PLIC_EN0    (PLIC + 0x2000)
#define PLIC_CLAIM0 (PLIC + 0x200004)
#define MPV         (1 << 39)
#define MEI_CAUSE   ((1 << 63) | 11)
#define VSEI_VS     ((1 << 63) | 9)
#define VSEI_BIT    (1 << 10)

.macro FAIL sub
    li      t0, 1 << (\sub - 1)
    or      s3, s3, t0
.endm

// Wait in the mode MPP/MPV give until the interrupt arrives.
.macro DROP mpp, mpv
    la      t0, 8f
    csrw    mepc, t0
    li      t0, MSTATUS_MPP | MPV
    csrc    mstatus, t0
    li      t0, \mpp | (\mpv << 39)
    csrs    mstatus, t0
    mret
8:  j       8b
.endm

.macro CLAIM sub, src
    li      t0, PLIC_CLAIM0
    lw      t1, 0(t0)
    li      t2, \src
    beq     t1, t2, 1f
    FAIL    \sub
1:  sw      t1, 0(t0)
    li      t0, PLIC_EN0
    sw      zero, 0(t0)
    li      t0, MEI_CAUSE
    beq     s5, t0, 2f
    FAIL    \sub
2:
.endm

.macro ENABLE src
    la      s4, 7f
    li      s5, 0
    li      t0, PLIC_EN0
    li      t1, 1 << \src
    sw      t1, 0(t0)
    li      t0, 1 << 11
    csrs    mie, t0
.endm

    .section .text
main:
    li      s3, 0
    la      t0, mvec
    csrw    mtvec, t0
    csrw    hgatp, zero
    csrw    vsatp, zero
    li      t0, PLIC + 4
    li      t1, 1
.rept 5
    sw      t1, 0(t0)
    addi    t0, t0, 4
.endr

    ENABLE  1
    csrsi   mstatus, 8
8:  j       8b
7:  CLAIM   1, 1
    ENABLE  2
    DROP    MSTATUS_MPP_S, 0
7:  CLAIM   2, 2
    ENABLE  3
    DROP    0, 0
7:  CLAIM   3, 3
    ENABLE  4
    DROP    MSTATUS_MPP_S, 1
7:  CLAIM   4, 4
    ENABLE  5
    DROP    0, 1
7:  CLAIM   5, 5

    csrw    mie, zero
    la      t0, vsvec
    csrw    vstvec, t0
    li      t0, VSEI_BIT
    csrw    hideleg, t0
    csrw    hvip, t0
    csrs    hie, t0
    li      s7, 0
    la      s4, 7f
    li      s5, 0
    DROP    0, 1
7:  csrw    hvip, zero
    csrw    hie, zero
    csrw    hideleg, zero
    li      t0, 10
    beq     s5, t0, 1f
    FAIL    6
1:  li      t0, VSEI_VS
    beq     s7, t0, 1f
    FAIL    6
1:  beqz    s3, 9f
    slli    s3, s3, 8
    ori     s3, s3, 0x42
    REPORT_REG s3
9:  REPORT  1

    .align 2
mvec:
    csrr    s5, mcause
    csrw    mie, zero
    li      t6, 0x88
    csrc    mstatus, t6
    li      t6, MSTATUS_MPP
    csrs    mstatus, t6
    li      t6, MPV
    csrc    mstatus, t6
    csrw    mepc, s4
    mret

    .align 2
vsvec:
    csrr    s7, scause
    ecall
