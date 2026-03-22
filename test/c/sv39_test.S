/* Sv39 MMU integration test for heliodor.
 *
 * Flow:
 *   1. M-mode: set up identity-mapped 1GB gigapage at PA 0x1000
 *   2. M-mode: configure trap delegation, stvec, satp
 *   3. M-mode: MRET → S-mode with Sv39 enabled
 *   4. S-mode: write "SV39 OK\n" via UART (through virtual addresses)
 *   5. S-mode: set x3 = 0xAA (success marker)
 *
 * Memory layout:
 *   0x0000-0x03FF  code (~256 instructions)
 *   0x1000-0x1FFF  Sv39 root page table (512 × 8B = 4KB)
 *   0x7C00-0x83FF  stack
 */

    .section .text.start, "ax"
    .global _start

_start:
    /* Set up stack pointer */
    lui sp, 0x8
    /* sp = 0x8000 */

    /* ============================================ */
    /* Set up Sv39 page table at PA 0x1000          */
    /* ============================================ */

    /* First, zero out the page table (512 entries × 8 bytes) */
    li t0, 0x1000           /* page table base */
    li t1, 0x2000           /* page table end */
1:  sd zero, 0(t0)
    addi t0, t0, 8
    blt t0, t1, 1b

    /* PT[0]: identity map VA [0, 1GB) → PA [0, 1GB) */
    /* PTE: PPN=0, D=1, A=1, G=1, U=0, X=1, W=1, R=1, V=1 = 0xEF */
    li t0, 0x1000
    li t1, 0xEF
    sd t1, 0(t0)

    /* ============================================ */
    /* Configure trap delegation                    */
    /* ============================================ */

    /* Delegate exceptions to S-mode */
    li t0, 0xFFFF
    csrw medeleg, t0

    /* Delegate S-mode interrupts */
    li t0, 0x222
    csrw mideleg, t0

    /* Set stvec to S-mode trap handler */
    la t0, s_trap_handler
    csrw stvec, t0

    /* ============================================ */
    /* Enable Sv39 MMU                              */
    /* ============================================ */

    /* satp = Sv39 mode (8) | ASID(0) | PPN(0x1000 >> 12 = 1) */
    li t0, 1
    li t1, 8
    slli t1, t1, 60
    or t0, t0, t1
    csrw satp, t0

    /* Flush TLB */
    sfence.vma zero, zero

    /* ============================================ */
    /* Switch to S-mode via MRET                    */
    /* ============================================ */

    /* Set mstatus.MPP = 01 (S-mode) */
    li t0, (1 << 11)
    csrw mstatus, t0

    /* Set mepc to S-mode entry point */
    la t0, s_mode_entry
    csrw mepc, t0

    /* MRET → enter S-mode with MMU enabled */
    mret

    /* ============================================ */
    /* S-mode code (runs with Sv39 virtual memory)  */
    /* ============================================ */
s_mode_entry:
    /* Simple store/load test through Sv39 virtual memory */
    li a0, 0x1800           /* address in data_mem region */
    li t0, 0xDEAD
    sd t0, 0(a0)            /* store through MMU */
    nop
    nop
    ld a1, 0(a0)            /* load back through MMU */

    /* Check result */
    li x3, 0xBB
    li t0, 0xDEAD
    bne a1, t0, 2f
    li x3, 0xAA             /* success */
2:  j 2b

    /* ============================================ */
    /* S-mode trap handler                          */
    /* ============================================ */
s_trap_handler:
    csrr x4, scause
    li x3, 0xBB             /* trap error marker */
3:  j 3b
