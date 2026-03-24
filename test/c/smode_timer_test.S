/* S-mode timer interrupt test for heliodor.
 *
 * Flow:
 *   1. M-mode: set mtimecmp=500, delegate STIP, enable MTIE, MRET to S
 *   2. Timer fires (MTIP) → M-mode handler
 *   3. M-mode handler: inject STIP, disable MTIP, MRET
 *   4. STIP → S-mode handler (delegated)
 *   5. S-mode handler: verify scause, set x3=0xAA
 *
 * Uses NOP padding between instructions for pipeline safety.
 */

    .section .text.start, "ax"
    .global _start

_start:
    /* M-mode trap handler */
    la t0, m_trap_handler
    csrw mtvec, t0
    nop
    nop

    /* S-mode trap handler */
    la t0, s_timer_handler
    csrw stvec, t0
    nop
    nop

    /* Delegate STIP to S-mode */
    li t0, 0x222
    csrw mideleg, t0
    nop
    nop

    /* Set mtimecmp = 500 (well after init completes) */
    lui t0, 0x02004           /* t0 = 0x02004000 */
    nop
    nop
    nop
    li t1, 500
    nop
    nop
    nop
    sd t1, 0(t0)
    nop
    nop
    nop

    /* Enable MTIE (bit 7) and STIE (bit 5) */
    li t0, 0xA0
    csrw mie, t0
    nop
    nop

    /* mstatus: MPP=S-mode, MPIE=1 (MIE=1 after MRET) */
    li t0, (1 << 11) | (1 << 7)
    csrw mstatus, t0
    nop
    nop

    /* mepc = s_entry */
    la t0, s_entry
    csrw mepc, t0
    nop
    nop

    mret

    li x3, 0xFF
    j .

/* S-mode entry */
    .balign 4
s_entry:
    li x1, 1                  /* S-mode running */
    nop
    nop

    /* Enable sstatus.SIE */
    csrsi sstatus, 2
    nop
    nop

    /* Spin: wait for interrupt */
    li x5, 0
    li x6, 100000
s_spin:
    addi x5, x5, 1
    blt x5, x6, s_spin

    li x3, 0xDD              /* timeout */
    j .

/* M-mode trap handler */
    .balign 4
m_trap_handler:
    csrr t0, mcause
    nop
    nop

    /* Check MTIP: cause = 0x8000000000000007 */
    li t1, 7
    li t2, 1
    slli t2, t2, 63
    or t1, t1, t2
    bne t0, t1, m_trap_other

    /* Inject STIP: set mip bit 5 */
    li t0, (1 << 5)
    csrs mip, t0
    nop
    nop

    /* Disable MTIP: set mtimecmp = MAX */
    lui t0, 0x02004
    li t1, -1
    sd t1, 0(t0)
    nop
    nop

    /* Disable MTIE */
    li t0, (1 << 7)
    csrc mie, t0
    nop
    nop

    mret

m_trap_other:
    csrr x2, mcause           /* debug: store mcause in x2 */
    csrr x10, mip             /* debug: store mip in x10 */
    csrr x11, mie             /* debug: store mie in x11 */
    csrr x12, mideleg         /* debug: store mideleg in x12 */
    li x3, 0xBB
    j .

/* S-mode timer handler */
    .balign 4
s_timer_handler:
    csrr x4, scause
    nop
    nop

    /* Verify interrupt + STIP */
    li t0, 5
    li t1, 1
    slli t1, t1, 63
    or t0, t0, t1
    bne x4, t0, s_timer_fail

    csrci sstatus, 2          /* disable SIE */
    li x3, 0xAA               /* success */
    csrr x2, sepc
    sret

s_timer_fail:
    li x3, 0xEE
    j .
