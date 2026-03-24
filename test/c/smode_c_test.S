/* S-mode C program test for heliodor.
 *
 * M-mode firmware sets up environment, then runs a small C function
 * in S-mode that tests function calls, stack, pointers, and UART output.
 *
 * Memory layout:
 *   0x0000-0x0FFF : M-mode firmware (identity-mapped)
 *   0x1000-0x1FFF : L2 page table
 *   0x2000-0x2FFF : L1 page table
 *   0x3000-0x3FFF : L0 page table (low)
 *   0x4000-0x4FFF : L0 page table (UART region)
 *   0x5000-0x5FFF : S-mode code+data page
 *   0x6000-0x6FFF : S-mode data page 2
 *   0x7000-0x7FFF : Stack
 */

    .section .text.start, "ax"
    .global _start

_start:
    lui sp, 0x8

    /* Zero page tables */
    li t0, 0x1000
    li t1, 0x5000
1:  sd zero, 0(t0)
    addi t0, t0, 8
    blt t0, t1, 1b

    /* Copy S-mode code to PA 0x5000 */
    la t0, s_code_start
    li t1, 0x5000
    la t2, s_code_end
2:  lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    blt t0, t2, 2b

    /* Page table setup */
    /* L2[0] → L1 at 0x2000 */
    li t0, 0x1000
    li t1, ((2 << 10) | 0x01)
    sd t1, 0(t0)

    /* L1[0] → L0 at 0x3000 */
    li t0, 0x2000
    li t1, ((3 << 10) | 0x01)
    sd t1, 0(t0)
    /* L1[0x80] → L0 at 0x4000 (for UART 0x10000000) */
    li t1, ((4 << 10) | 0x01)
    sd t1, 1024(t0)

    /* L0 at 0x3000 */
    li t2, 0x3000
    li t1, ((0 << 10) | 0xCB)     /* VA 0x0000 → PA 0x0000 (RX) */
    sd t1, 0(t2)
    li t1, ((5 << 10) | 0xCF)     /* VA 0x5000 → PA 0x5000 (RWX) */
    sd t1, 40(t2)
    li t1, ((6 << 10) | 0xCF)     /* VA 0x6000 → PA 0x6000 (RW) */
    sd t1, 48(t2)
    li t1, ((7 << 10) | 0xCF)     /* VA 0x7000 → PA 0x7000 (stack) */
    sd t1, 56(t2)

    /* L0 at 0x4000: UART at 0x10000000 → PA 0x10000000 */
    li t2, 0x4000
    li t1, ((0x10000 << 10) | 0xCF)
    sd t1, 0(t2)

    /* Trap setup */
    li t0, 0xFFFF
    csrw medeleg, t0
    li t0, 0x222
    csrw mideleg, t0
    la t0, s_trap
    csrw stvec, t0
    li t0, 7
    csrw 0x306, t0             /* mcounteren: allow cycle/time/instret */

    /* Enable Sv39 */
    li t0, 1
    li t1, 8
    slli t1, t1, 60
    or t0, t0, t1
    csrw satp, t0
    sfence.vma zero, zero

    /* MRET to S-mode at VA 0x5000 */
    li t0, (1 << 11) | (1 << 7)
    csrw mstatus, t0
    li t0, 0x5000
    csrw mepc, t0
    /* a0 = hartid (0), a1 = dtb_addr (0, unused) — Linux convention */
    li a0, 0
    li a1, 0
    mret

    li x3, 0xFF
3:  j 3b

    .balign 4
s_trap:
    csrr x4, scause
    li x3, 0xCC
4:  j 4b

/* ============================================================
 * S-mode code (copied to PA 0x5000, executed at VA 0x5000)
 * Hand-written C-like code testing function calls and memory
 * ============================================================ */
    .balign 4
s_code_start:
    /* Entry: set up stack at 0x8000 (top of VA 0x7000 page) */
    lui sp, 0x8

    /* Call uart_putchar('O') */
    li a0, 0x4F                /* 'O' */
    jal ra, s_uart_putchar

    /* Call uart_putchar('K') */
    li a0, 0x4B                /* 'K' */
    jal ra, s_uart_putchar

    /* Call uart_putchar('\n') */
    li a0, 0x0A
    jal ra, s_uart_putchar

    /* Test memory: store and load through pointer */
    li t0, 0x6000              /* data page */
    li t1, 12345
    sd t1, 0(t0)
    ld t2, 0(t0)
    bne t1, t2, s_c_fail

    /* Test stack: push/pop */
    addi sp, sp, -16
    li t0, 42
    sd t0, 0(sp)
    li t1, 99
    sd t1, 8(sp)
    ld t2, 0(sp)
    ld t3, 8(sp)
    addi sp, sp, 16
    li t4, 42
    bne t2, t4, s_c_fail
    li t4, 99
    bne t3, t4, s_c_fail

    /* Success */
    li x3, 0xAA
5:  nop
    j 5b

/* uart_putchar(char c): write a0 to UART THR at 0x10000000 */
s_uart_putchar:
    li t0, 0x10000000
    sb a0, 0(t0)
    ret

s_c_fail:
    li x3, 0xDD
6:  j 6b

    /* Padding for copy */
    nop
    nop
    nop
    nop
s_code_end:
