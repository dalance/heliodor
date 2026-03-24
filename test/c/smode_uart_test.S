/* S-mode UART output test for heliodor.
 *
 * Simulates Linux earlycon: S-mode code outputs characters via MMIO UART
 * through Sv39 page tables.
 *
 * Memory layout:
 *   0x0000-0x0FFF : M-mode code (identity-mapped)
 *   0x1000-0x1FFF : L2 page table (root)
 *   0x2000-0x2FFF : L1 page table
 *   0x3000-0x3FFF : L0 page table (for VA 0x0000-0x1FF000)
 *   0x4000-0x4FFF : L0 page table (for VA 0x10000000 UART region)
 *   0x5000-0x5FFF : S-mode code (mapped at VA 0x80200000)
 *   0x7000-0x7FFF : Stack
 *
 * Page table entries:
 *   VA 0x00000000 → PA 0x00000 (M-mode code, RX)
 *   VA 0x00004000 → PA 0x04000 (L0 for UART, non-leaf)
 *   VA 0x00007000 → PA 0x07000 (stack, RW)
 *   VA 0x10000000 → PA 0x10000000 (UART MMIO, RW, 1GB megapage)
 *   VA 0x00010000 → PA 0x05000 (S-mode code, RX)
 *
 * Result: x3 = 0xAA on success (after printing "Hi" to UART)
 */

    .section .text.start, "ax"
    .global _start

_start:
    lui sp, 0x8

    /* Zero page tables 0x1000-0x4FFF */
    li t0, 0x1000
    li t1, 0x5000
1:  sd zero, 0(t0)
    addi t0, t0, 8
    blt t0, t1, 1b

    /* Copy S-mode payload to PA 0x5000 */
    la t0, s_payload
    li t1, 0x5000
    li t2, 128
2:  lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    addi t2, t2, -4
    bgtz t2, 2b

    /* === Page table setup === */

    /* L2 root at 0x1000 */
    li t0, 0x1000
    /* Entry 0: VPN[2]=0 → L1 at 0x2000 */
    li t1, ((2 << 10) | 0x01)
    sd t1, 0(t0)
    /* Entry 4: VPN[2]=4 → UART megapage (1GB leaf)
     * VA 0x10000000 >> 30 = 0x0 (within VPN[2]=0 range actually)
     * 0x10000000 = 256MB, VPN[2] = 0x10000000 >> 30 = 0
     * So UART at 0x10000000 has VPN[2]=0, VPN[1]=0x80, VPN[0]=0
     * Need L1 entry for VPN[1]=0x80 */

    /* L1 at 0x2000 */
    li t0, 0x2000
    /* Entry 0: VPN[1]=0 → L0 at 0x3000 */
    li t1, ((3 << 10) | 0x01)
    sd t1, 0(t0)
    /* Entry 0x80: VPN[1]=0x80 (for VA 0x10000000) → L0 at 0x4000 */
    li t1, ((4 << 10) | 0x01)
    sd t1, 1024(t0)           /* offset = 0x80 * 8 = 1024 */

    /* L0 at 0x3000 (low addresses) */
    li t2, 0x3000
    /* Entry 0: VA 0x0000 → PA 0x0000 (code, RX, A=1,D=1) */
    li t1, ((0 << 10) | 0xCB)
    sd t1, 0(t2)
    /* Entry 5: VA 0x5000 → PA 0x5000 (identity) */
    li t1, ((5 << 10) | 0xCF)
    sd t1, 40(t2)
    /* Entry 7: VA 0x7000 → PA 0x7000 (stack, RW) */
    li t1, ((7 << 10) | 0xCF)
    sd t1, 56(t2)
    /* Entry 0x10: VA 0x10000 → PA 0x5000 (S-mode code, RX) */
    li t1, ((5 << 10) | 0xCB)
    sd t1, 128(t2)

    /* L0 at 0x4000 (UART region: VA 0x10000000 + VPN[0]*4096)
     * VA 0x10000000: VPN[0] = (0x10000000 >> 12) & 0x1FF = 0
     * PA 0x10000000: PPN = 0x10000000 >> 12 = 0x10000 */
    li t2, 0x4000
    /* Entry 0: VA 0x10000000 → PA 0x10000000 (UART, RW, A=1,D=1) */
    li t1, ((0x10000 << 10) | 0xCF)
    sd t1, 0(t2)

    /* Trap delegation + vectors */
    li t0, 0xFFFF
    csrw medeleg, t0
    li t0, 0x222
    csrw mideleg, t0
    la t0, s_trap_handler
    csrw stvec, t0

    /* mcounteren: allow S-mode to read cycle/time/instret */
    li t0, 7
    csrw 0x306, t0            /* mcounteren */

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
s_trap_handler:
    csrr x4, scause
    li x3, 0xCC
4:  j 4b

/* S-mode payload: print "Hi" to UART at VA 0x10000000, then set x3=0xAA */
    .balign 4
s_payload:
    /* UART THR at VA 0x10000000 (offset 0 from UART base) */
    li t0, 0x10000000

    /* Print 'H' */
    li t1, 0x48               /* 'H' */
    sb t1, 0(t0)

    /* Print 'i' */
    li t1, 0x69               /* 'i' */
    sb t1, 0(t0)

    /* Print newline */
    li t1, 0x0A               /* '\n' */
    sb t1, 0(t0)

    /* Read time CSR (tests mcounteren) */
    rdtime x2

    /* Success */
    li x3, 0xAA
5:  nop
    j 5b

    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
s_payload_end:
