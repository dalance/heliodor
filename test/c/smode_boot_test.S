/* S-mode boot test for heliodor.
 *
 * Simulates a minimal Linux-like boot flow:
 *   1. M-mode firmware: set up trap delegation, timer, page tables, Sv39
 *   2. MRET to S-mode at virtual address (non-identity mapped)
 *   3. S-mode: store/load through MMU, ECALL to M-mode (SBI call)
 *   4. M-mode SBI handler: advance sepc, SRET back to S-mode
 *   5. S-mode: verify ECALL return, set success marker
 *
 * Memory layout (physical):
 *   0x0000-0x0FFF : M-mode code + SBI handler (identity-mapped)
 *   0x1000-0x1FFF : L2 page table (root, satp.PPN=1)
 *   0x2000-0x2FFF : L1 page table
 *   0x3000-0x3FFF : L0 page table
 *   0x4000-0x4FFF : S-mode data page (mapped at VA 0x4000, identity)
 *   0x5000-0x5FFF : S-mode code page (PA, mapped at VA 0x80000000)
 *   0x7000-0x7FFF : Stack (mapped at VA 0x7000, identity)
 *
 * Virtual address mapping (Sv39):
 *   VA 0x0000_0000 → PA 0x0000 (M-mode code, RX, S-mode accessible)
 *   VA 0x0000_4000 → PA 0x4000 (data, RW)
 *   VA 0x0000_5000 → PA 0x5000 (code PA page, identity for PTW)
 *   VA 0x0000_7000 → PA 0x7000 (stack, RW)
 *   VA 0x8000_0000 → PA 0x5000 (S-mode code, RX, non-identity!)
 *
 * Result: x3 = 0xAA on success
 */

    .section .text.start, "ax"
    .global _start

_start:
    /* ============================================================
     * Phase 1: M-mode firmware setup
     * ============================================================ */

    /* Stack pointer */
    lui sp, 0x8              /* sp = 0x8000 */

    /* Zero out page table area 0x1000-0x3FFF */
    li t0, 0x1000
    li t1, 0x4000
1:  sd zero, 0(t0)
    addi t0, t0, 8
    blt t0, t1, 1b

    /* Copy S-mode payload to PA 0x5000 */
    la t0, s_payload
    li t1, 0x5000
    li t2, 128               /* copy 128 bytes */
2:  lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    addi t2, t2, -4
    bgtz t2, 2b

    /* --- Page table setup (Sv39, 3-level) --- */

    /* L2 root at 0x1000 */
    /* Entry 0: VPN[2]=0 → L1 at 0x2000 */
    li t0, 0x1000
    li t1, ((2 << 10) | 0x01)       /* PPN=2, V=1 (non-leaf) */
    sd t1, 0(t0)
    /* Entry 2: VPN[2]=2 (VA 0x8000_0000) → L1 at 0x2000 */
    /* VPN[2] for 0x80000000 = 0x80000000 >> 30 = 2 */
    sd t1, 16(t0)                    /* offset = 2 * 8 = 16 */

    /* L1 at 0x2000 */
    /* Entry 0: VPN[1]=0 → L0 at 0x3000 */
    li t0, 0x2000
    li t1, ((3 << 10) | 0x01)       /* PPN=3, V=1 (non-leaf) */
    sd t1, 0(t0)

    /* L0 at 0x3000 */
    li t2, 0x3000

    /* Entry 0: VA 0x0000 → PA 0x0000 (M-mode code, RX, A=1,D=1) */
    li t1, ((0 << 10) | 0xCB)       /* PPN=0, V R X A D */
    sd t1, 0(t2)

    /* Entry 4: VA 0x4000 → PA 0x4000 (data page, RW, A=1,D=1) */
    li t1, ((4 << 10) | 0xCF)       /* PPN=4, V R W X A D */
    sd t1, 32(t2)

    /* Entry 5: VA 0x5000 → PA 0x5000 (identity for PTW access) */
    li t1, ((5 << 10) | 0xCF)       /* PPN=5, V R W X A D */
    sd t1, 40(t2)

    /* Entry 7: VA 0x7000 → PA 0x7000 (stack, RW, A=1,D=1) */
    li t1, ((7 << 10) | 0xCF)       /* PPN=7, V R W X A D */
    sd t1, 56(t2)

    /* For VA 0x80000000: VPN[2]=2, VPN[1]=0, VPN[0]=0
     * L2[2] → L1 at 0x2000, L1[0] → L0 at 0x3000, L0[0] = M-mode code
     * But we want VA 0x80000000 to map to PA 0x5000 (S-mode code).
     * VPN[0] = (0x80000000 >> 12) & 0x1FF = 0
     * So we need a SEPARATE L1 for VPN[2]=2.
     * Reuse: L2[2] points to L1 at 0x2000, L1[0] points to L0 at 0x3000,
     * L0[0] is already the M-mode page. Conflict!
     * Solution: L2[2] → separate L1 page. But we're out of pages.
     * Simpler: use a 1GB megapage mapping.
     * L2[2] = leaf gigapage: PPN = 0x5000 >> 30 = 0, offset = VA[29:0]
     * But 0x5000 is at byte 0x5000, and a gigapage PPN must be aligned.
     * PA = PPN[43:18] || VA[29:0]. For PA 0x5000:
     *   PPN[43:18] = 0, VA[29:0] = 0x5000 → PA = 0x5000. Works!
     * But PPN[17:0] must be 0 for gigapage alignment → PPN = 0.
     * PTE = PPN=0, V=1, R=1, X=1, A=1, D=1 = 0xCB
     * VA 0x80000000 → PA = 0 || 0x80000000[29:0] = 0x00000000.
     * That maps to PA 0, not 0x5000. Wrong.
     *
     * Better approach: use a 2MB megapage at L1 level.
     * L2[2] → new L1 at... we need another page.
     * Actually, let's just NOT use 0x80000000. Use 0x10000 instead
     * (same as imem_mmu_test) for the non-identity mapping.
     */

    /* Entry 0x10: VA 0x10000 → PA 0x5000 (S-mode code, RX, A=1,D=1) */
    li t1, ((5 << 10) | 0xCB)       /* PPN=5, V R X A D */
    sd t1, 128(t2)                   /* offset = 0x10 * 8 = 128 */

    /* --- Trap delegation --- */
    /* Delegate ECALL-from-U to S-mode (bit 8) */
    li t0, (1 << 8)
    csrw medeleg, t0
    /* Delegate S-mode interrupts */
    li t0, 0x222                     /* SSIP + STIP + SEIP */
    csrw mideleg, t0

    /* --- Set up trap vectors --- */
    la t0, m_trap_handler
    csrw mtvec, t0
    la t0, s_trap_entry
    csrw stvec, t0

    /* --- Enable Sv39 --- */
    li t0, 1                         /* satp.PPN = 1 (root at 0x1000) */
    li t1, 8
    slli t1, t1, 60                  /* satp.MODE = 8 (Sv39) */
    or t0, t0, t1
    csrw satp, t0
    sfence.vma zero, zero

    /* --- Switch to S-mode at VA 0x10000 --- */
    li t0, (1 << 11)                 /* mstatus.MPP = S-mode (01) */
    csrw mstatus, t0
    li t0, 0x10000
    csrw mepc, t0
    mret

    /* Should not reach here */
    li x3, 0xFF
3:  j 3b

/* ============================================================
 * M-mode trap handler (mtvec)
 * Handles ECALL from S-mode as SBI call, then SRET back.
 * ============================================================ */
    .balign 4
m_trap_handler:
    csrr t0, mcause
    /* ECALL from S-mode: cause = 9 */
    li t1, 9
    bne t0, t1, m_trap_fail

    /* SBI handler: set x2 = 0xBB (SBI return marker) */
    li x2, 0xBB

    /* Advance sepc past ECALL (4 bytes) */
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0

    /* Return to S-mode via MRET (mstatus.MPP=S from trap entry) */
    mret

m_trap_fail:
    li x3, 0xEE
4:  j 4b

/* ============================================================
 * S-mode trap handler entry (stvec, identity-mapped VA)
 * ============================================================ */
    .balign 4
s_trap_entry:
    csrr x4, scause
    li x3, 0xCC                      /* mark S-mode trap taken */
5:  j 5b

/* ============================================================
 * S-mode payload (copied to PA 0x5000, executed at VA 0x10000)
 * ============================================================ */
    .balign 4
s_payload:
    /* Phase 2: Running in S-mode with Sv39 enabled */

    /* Store test value to data page (VA 0x4000) */
    li t0, 0x4000
    li t1, 0xDEAD
    sd t1, 0(t0)

    /* Load it back */
    ld t2, 0(t0)

    /* Verify: t2 should equal t1 */
    bne t1, t2, s_fail

    /* Set x1 = 1 (S-mode running marker) */
    li x1, 1

    /* ECALL to M-mode (SBI call) */
    ecall

    /* After ECALL: M-mode handler sets x2=0xBB and SRETs here */
    /* Verify x2 == 0xBB */
    li t0, 0xBB
    bne x2, t0, s_fail

    /* Success! */
    li x3, 0xAA
s_spin:
    nop
    j s_spin

s_fail:
    li x3, 0xDD
6:  j 6b

    /* Pad to ensure full copy */
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
s_payload_end:
