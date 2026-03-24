/* S-mode page fault handler test for heliodor.
 *
 * Tests Linux-style demand paging:
 *   1. M-mode: set up page tables with one page INVALID (V=0)
 *   2. S-mode: access the invalid page → store page fault
 *   3. S-mode trap handler: fix the PTE (set V=1 + permissions), sfence.vma
 *   4. Return via SRET, retry the access → succeeds
 *   5. Verify stored data can be loaded back
 *
 * Memory layout:
 *   0x0000-0x0FFF : M-mode code
 *   0x1000-0x1FFF : L2 page table
 *   0x2000-0x2FFF : L1 page table
 *   0x3000-0x3FFF : L0 page table
 *   0x4000-0x4FFF : Data page (initially UNMAPPED → demand-paged)
 *   0x5000-0x5FFF : S-mode code (mapped at VA 0x10000)
 *   0x7000-0x7FFF : Stack
 */

    .section .text.start, "ax"
    .global _start

_start:
    lui sp, 0x8

    /* Zero page tables */
    li t0, 0x1000
    li t1, 0x4000
1:  sd zero, 0(t0)
    addi t0, t0, 8
    blt t0, t1, 1b

    /* Copy S-mode code to PA 0x5000 */
    la t0, s_code
    li t1, 0x5000
    li t2, 512
2:  lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    addi t2, t2, -4
    bgtz t2, 2b

    /* Page tables */
    /* L2[0] → L1 */
    li t0, 0x1000
    li t1, ((2 << 10) | 0x01)
    sd t1, 0(t0)

    /* L1[0] → L0 */
    li t0, 0x2000
    li t1, ((3 << 10) | 0x01)
    sd t1, 0(t0)

    /* L0 entries */
    li t2, 0x3000
    /* Entry 0: VA 0x0000 → PA 0x0000 (code, RX) */
    li t1, ((0 << 10) | 0xCB)
    sd t1, 0(t2)
    /* Entry 3: VA 0x3000 → PA 0x3000 (L0 table itself, RW for handler) */
    li t1, ((3 << 10) | 0xCF)
    sd t1, 24(t2)
    /* Entry 4: VA 0x4000 → INTENTIONALLY UNMAPPED (V=0) */
    /* (PTE = 0, already zeroed) */
    /* Entry 5: VA 0x5000 → PA 0x5000 (code PA, RWX) */
    li t1, ((5 << 10) | 0xCF)
    sd t1, 40(t2)
    /* Entry 7: VA 0x7000 → PA 0x7000 (stack, RW) */
    li t1, ((7 << 10) | 0xCF)
    sd t1, 56(t2)
    /* Entry 0x10: VA 0x10000 → PA 0x5000 (S-mode code, RX) */
    li t1, ((5 << 10) | 0xCB)
    sd t1, 128(t2)

    /* M-mode trap handler for debugging */
    la t0, m_trap_debug
    csrw mtvec, t0

    /* Delegate page faults to S-mode: bits 12,13,15 */
    li t0, (1 << 12) | (1 << 13) | (1 << 15)
    csrw medeleg, t0
    li t0, 0x222
    csrw mideleg, t0

    /* Enable Sv39 */
    li t0, 1
    li t1, 8
    slli t1, t1, 60
    or t0, t0, t1
    csrw satp, t0
    sfence.vma zero, zero

    /* MRET to S-mode at VA 0x10000 */
    li t0, (1 << 11) | (1 << 7)
    csrw mstatus, t0
    li t0, 0x10000
    csrw mepc, t0
    mret

    li x3, 0xFF
3:  j 3b

    .balign 4
m_trap_debug:
    csrr x11, mcause
    csrr x12, mtval
    li x3, 0xBB               /* M-mode trap (should not happen) */
    j .

/* ============================================================
 * S-mode code (at VA 0x10000 = PA 0x5000)
 * ============================================================ */
    .balign 4
s_code:
    /* Set up S-mode trap handler.
     * la uses auipc+addi (PC-relative), so at runtime VA 0x10000+offset
     * it automatically produces the correct VA of the handler. */
    la t0, s_trap_handler
    csrw stvec, t0
    mv x10, t0               /* debug: save stvec in a0 */

    /* Set up stack */
    lui sp, 0x8

    li x1, 1                  /* S-mode running */

    /* Access unmapped page VA 0x4000: this should page fault */
    li t0, 0x4000
    li t1, 12345
    sd t1, 0(t0)              /* STORE PAGE FAULT expected here */

    /* If handler fixed the PTE and we got here via SRET,
     * the store succeeded. Now load it back. */
    ld t2, 0(t0)
    bne t1, t2, s_pgfault_fail

    li x3, 0xAA               /* success */
4:  nop
    j 4b

/* S-mode page fault handler
 * Must save/restore t0-t4 since the faulting code uses them.
 * Uses stack at sp (VA 0x7000 page, mapped). */
    .balign 4
s_trap_handler:
    /* Save registers to stack */
    addi sp, sp, -48
    sd t0, 0(sp)
    sd t1, 8(sp)
    sd t2, 16(sp)
    sd t3, 24(sp)
    sd t4, 32(sp)

    csrr t0, scause
    csrr t1, stval             /* faulting address */

    /* Check: store page fault (cause 15) */
    li t2, 15
    bne t0, t2, s_trap_check_load

    /* Fix PTE for VA 0x4000:
     * L0 entry 4 at VA 0x3000 + 4*8 = 0x3020
     * PTE = (4 << 10) | 0xCF  (PPN=4, V=1,R=1,W=1,X=1,A=1,D=1) */
    li t3, 0x3020              /* VA of L0[4] (L0 table is identity-mapped) */
    li t4, ((4 << 10) | 0xCF)
    sd t4, 0(t3)

    /* Flush TLB for the faulting VA */
    sfence.vma t1, zero

    li x9, 15                 /* handler reached (cause 15) */

    /* Restore registers from stack */
    ld t0, 0(sp)
    ld t1, 8(sp)
    ld t2, 16(sp)
    ld t3, 24(sp)
    ld t4, 32(sp)
    addi sp, sp, 48
    sret

s_trap_check_load:
    /* Check: load page fault (cause 13) */
    li t2, 13
    bne t0, t2, s_trap_other

    /* Same fix */
    li t3, 0x3020
    li t4, ((4 << 10) | 0xCF)
    sd t4, 0(t3)
    sfence.vma t1, zero
    li x9, 13

    /* Restore registers from stack */
    ld t0, 0(sp)
    ld t1, 8(sp)
    ld t2, 16(sp)
    ld t3, 24(sp)
    ld t4, 32(sp)
    addi sp, sp, 48
    sret

s_trap_other:
    li x3, 0xCC
5:  j 5b

s_pgfault_fail:
    li x3, 0xDD
6:  j 6b

    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
s_code_end:
