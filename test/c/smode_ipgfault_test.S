/* Instruction page fault test for heliodor.
 *
 * Tests demand paging for code: S-mode jumps to unmapped code page,
 * gets instruction page fault (cause 12), handler maps the page,
 * SRET retries the fetch.
 *
 * Memory layout (physical):
 *   0x0000-0x0FFF : M-mode code
 *   0x1000-0x1FFF : L2 page table
 *   0x2000-0x2FFF : L1 page table
 *   0x3000-0x3FFF : L0 page table
 *   0x4000-0x4FFF : Target code page (initially UNMAPPED)
 *   0x5000-0x5FFF : S-mode kernel (mapped at VA 0x10000)
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
    la t0, s_kernel
    li t1, 0x5000
    li t2, 512
2:  lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    addi t2, t2, -4
    bgtz t2, 2b

    /* Write target code at PA 0x4000:
     * li x9, 0xBB     (= li s1, 0xBB = addi x9, x0, 0xBB)
     * li x3, 0xAA     (= addi x3, x0, 0xAA)
     * j .              (= jal x0, 0)
     */
    li t0, 0x4000
    li t1, 0x0BB00493       /* addi x9, x0, 0xBB */
    sw t1, 0(t0)
    li t1, 0x0AA00193       /* addi x3, x0, 0xAA */
    sw t1, 4(t0)
    li t1, 0x0000006F       /* jal x0, 0 (j .) */
    sw t1, 8(t0)

    /* Page tables */
    li t0, 0x1000
    li t1, ((2 << 10) | 0x01)
    sd t1, 0(t0)

    li t0, 0x2000
    li t1, ((3 << 10) | 0x01)
    sd t1, 0(t0)

    li t2, 0x3000
    /* [0]: VA 0x0000 → PA 0x0000 (firmware, RX) */
    li t1, ((0 << 10) | 0xCB)
    sd t1, 0(t2)
    /* [3]: VA 0x3000 → PA 0x3000 (L0 table, RW for handler) */
    li t1, ((3 << 10) | 0xCF)
    sd t1, 24(t2)
    /* [4]: VA 0x4000 → INTENTIONALLY UNMAPPED (instruction page fault test) */
    /* [5]: VA 0x5000 → PA 0x5000 (S-mode code backing, RWX) */
    li t1, ((5 << 10) | 0xCF)
    sd t1, 40(t2)
    /* [7]: VA 0x7000 → PA 0x7000 (stack, RW) */
    li t1, ((7 << 10) | 0xCF)
    sd t1, 56(t2)
    /* [0x10]: VA 0x10000 → PA 0x5000 (S-mode kernel, RX) */
    li t1, ((5 << 10) | 0xCB)
    sd t1, 128(t2)

    /* M-mode trap handler */
    la t0, m_trap_debug
    csrw mtvec, t0

    /* Delegate page faults to S-mode */
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
    li x3, 0xEE
    j .

/* ============================================================
 * S-mode kernel (at VA 0x10000 = PA 0x5000)
 * ============================================================ */
    .balign 4
s_kernel:
    la t0, s_trap_handler
    csrw stvec, t0
    lui sp, 0x8
    li x1, 1               /* S-mode entered */

    /* Jump to unmapped code at VA 0x4000
     * This should cause an instruction page fault (cause 12) */
    li t0, 0x4000
    jalr zero, t0, 0       /* jump to VA 0x4000 */

    /* Should NOT reach here */
    li x3, 0xDD
4:  j 4b

/* S-mode trap handler: instruction page fault */
    .balign 4
s_trap_handler:
    addi sp, sp, -32
    sd t0, 0(sp)
    sd t1, 8(sp)
    sd t3, 16(sp)
    sd t4, 24(sp)

    csrr t0, scause

    /* Instruction page fault: cause 12 */
    li t1, 12
    bne t0, t1, s_trap_other

    /* Fix PTE: L0[4] at VA 0x3020 = PA 0x3020
     * PTE = (4 << 10) | 0xCB (PPN=4, V,R,X,A,D, no W) */
    li t3, 0x3020
    li t4, ((4 << 10) | 0xCB)
    sd t4, 0(t3)
    sfence.vma zero, zero

    li x9, 12              /* handler reached (cause 12) */

    ld t0, 0(sp)
    ld t1, 8(sp)
    ld t3, 16(sp)
    ld t4, 24(sp)
    addi sp, sp, 32
    sret                   /* retry instruction fetch at sepc=0x4000 */

s_trap_other:
    li x3, 0xCC
    j .

    nop
    nop
    nop
    nop
s_kernel_end:
