// H: VS external and VS timer interrupts injected through hvip and
// delegated by hideleg are taken in VS with the codes translated to 9 and 5.
//
// For each sub-case M sets one hvip bit, enters the guest (vsatp and hgatp
// Bare), and the guest enables that interrupt in sie and sstatus.SIE. The
// guest handler stores scause and leaves with ECALL; the guest loop gives up
// after a bounded spin and ECALLs without a store. Spec: scause is
// (1 << 63) | 9, then (1 << 63) | 5, and every exit to M is cause 10 (ECALL
// from VS). 0xE000 + bit s-1 for sub-case s (1 external, 2 timer) whose
// outcome differs.
#include "common/probe.h"

#define MPV       (1 << 39)
#define HVIP_VSTI (1 << 6)
#define HVIP_VSEI (1 << 10)
#define SIE_STIE  (1 << 5)
#define SIE_SEIE  (1 << 9)
#define SSTATUS_SIE (1 << 1)
#define IRQ       (1 << 63)

    .section .text
main:
    csrw    hgatp, zero
    csrw    vsatp, zero
    li      t0, HVIP_VSTI | HVIP_VSEI
    csrw    hideleg, t0
    la      t0, guest_trap
    csrw    vstvec, t0
    li      s3, 0
    li      a0, HVIP_VSEI
    li      a1, SIE_SEIE
    li      a2, IRQ | 9
    li      a3, 1
    jal     ra, run_case
    li      a0, HVIP_VSTI
    li      a1, SIE_STIE
    li      a2, IRQ | 5
    li      a3, 2
    jal     ra, run_case
    bnez    s3, odd
    REPORT  1
odd:
    li      t0, CODE_ODD(0)
    or      t0, t0, s3
    REPORT_REG t0

// a0 = hvip bit, a1 = sie bit, a2 = expected scause, a3 = sub-case bit.
run_case:
    la      t0, g_cause
    sd      zero, 0(t0)
    csrw    hvip, a0
    SET_RESUME 1f
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S
    csrs    mstatus, t0
    li      t0, MPV
    csrs    mstatus, t0
    la      t0, guest
    csrw    mepc, t0
    mret
1:  csrw    hvip, zero
    csrw    vsstatus, zero
    la      t0, trap_cause
    ld      t1, 0(t0)
    li      t2, 10
    bne     t1, t2, 2f
    la      t0, g_cause
    ld      t1, 0(t0)
    beq     t1, a2, 3f
2:  or      s3, s3, a3
3:  ret

guest:
    csrs    sie, a1
    li      t0, SSTATUS_SIE
    csrs    sstatus, t0
    li      t1, 1000
1:  addi    t1, t1, -1
    bnez    t1, 1b
    ecall

    .align 2
guest_trap:
    csrr    t0, scause
    la      t1, g_cause
    sd      t0, 0(t1)
    ecall

    .section .data
    .align 3
g_cause: .dword 0
