/* S-mode PLIC external-interrupt test for heliodor (P9.5).
 *
 * Exercises the full external-interrupt path the PLIC wiring adds:
 *   1. M-mode: set stvec, delegate the supervisor external interrupt
 *      (mideleg[9]), MRET into S-mode.
 *   2. S-mode: program the PLIC — prio[10]=1, enable source 10 for the
 *      hart's S-context (ctx = 2*0+1 = 1), threshold[ctx1]=0 — then enable
 *      sie.SEIE + sstatus.SIE and spin.
 *   3. The testbench pulses PLIC source 10 → o_irq_s[0] → SEIP → S-mode trap.
 *   4. S-mode handler: verify scause == supervisor-external (9), read the
 *      PLIC claim register (an MMIO load that must return 10), write it back
 *      to complete, and set x3 = 0xAA (pass).
 *
 * Register + MMIO only (no DRAM data, no stack), so it runs from ROM at PA 0.
 * NOP padding after control-affecting CSR writes mirrors the other smode_*
 * tests (belt-and-braces pipeline ordering).
 */
    .section .text.start, "ax"
    .global _start

_start:
    /* S-mode trap handler */
    la   t0, s_ext_handler
    csrw stvec, t0
    nop
    nop

    /* Delegate the supervisor external interrupt (cause 9) to S-mode */
    li   t0, (1 << 9)
    csrw mideleg, t0
    nop
    nop

    /* mstatus: MPP = S-mode (1<<11), MPIE = 1 (SIE active after MRET) */
    li   t0, (1 << 11) | (1 << 7)
    csrw mstatus, t0
    nop
    nop

    /* mepc = s_entry, drop to S-mode */
    la   t0, s_entry
    csrw mepc, t0
    nop
    nop
    mret

    li   x3, 0xFF              /* should never fall through MRET */
    j    .

    .balign 4
s_entry:
    /* PLIC prio[10] = 1   (0x0C000000 + 4*10 = 0x0C000028) */
    li   t0, 0x0C000028
    li   t1, 1
    sw   t1, 0(t0)
    nop
    nop

    /* PLIC enable source 10 for S-context 1  (0x0C002000 + 0x80*1 = 0x0C002080) */
    li   t0, 0x0C002080
    li   t1, (1 << 10)
    sw   t1, 0(t0)
    nop
    nop

    /* PLIC threshold[ctx1] = 0  (0x0C200000 + 0x1000*1 = 0x0C201000) */
    li   t0, 0x0C201000
    sw   zero, 0(t0)
    nop
    nop

    /* sie.SEIE (bit 9) */
    li   t0, (1 << 9)
    csrw sie, t0
    nop
    nop

    /* sstatus.SIE (bit 1) */
    csrsi sstatus, 2
    nop
    nop

    /* spin waiting for the external interrupt */
    li   x5, 0
    li   x6, 200000
s_spin:
    addi x5, x5, 1
    blt  x5, x6, s_spin

    li   x3, 0xDD             /* timeout: interrupt never arrived */
    j    .

    .balign 4
s_ext_handler:
    csrr x4, scause
    nop
    nop

    /* expect scause == (1<<63) | 9  (supervisor external interrupt) */
    li   t0, 9
    li   t1, 1
    slli t1, t1, 63
    or   t0, t0, t1
    bne  x4, t0, s_fail

    /* claim the interrupt: read the S-context claim register
     * (0x0C200000 + 0x1000*1 + 4).  This is an uncached MMIO load — it must do a
     * single exact-address bus read and return the highest-priority pending
     * source (10 = the UART).  Verify it BEFORE signalling success so x3==0xAA
     * means the whole delivery + claim path worked. */
    li   t0, 0x0C201004
    lw   t2, 0(t0)
    nop
    nop
    li   t1, 10
    bne  t2, t1, s_fail

    /* complete: write the claimed id back (clears the PLIC's in-service state) */
    sw   t2, 0(t0)
    nop
    nop

    li   x3, 0xAA           /* success: SEIP delivered, claim returned 10 */
    j    .

s_fail:
    li   x3, 0xEE
    j    .
