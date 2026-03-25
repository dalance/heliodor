/* S-mode → U-mode execution test for heliodor.
 *
 * Tests Linux-like user process execution:
 *   1. M-mode: set up page tables, delegate traps, jump to S-mode
 *   2. S-mode kernel: set up user page tables, jump to U-mode via SRET
 *   3. U-mode user program: ECALL (syscall) → S-mode handler
 *   4. S-mode handler: process syscall, SRET back to U-mode
 *   5. U-mode: verify syscall result, signal success
 *
 * Memory layout (physical):
 *   0x0000-0x0FFF : M-mode code
 *   0x1000-0x1FFF : L2 page table
 *   0x2000-0x2FFF : L1 page table
 *   0x3000-0x3FFF : L0 page table
 *   0x4000-0x4FFF : U-mode code (mapped at VA 0x80000 with U=1)
 *   0x5000-0x5FFF : S-mode kernel code (mapped at VA 0x10000)
 *   0x6000-0x6FFF : User data page (U=1, RW)
 *   0x7000-0x7FFF : Kernel/user stack
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

    /* Copy U-mode code to PA 0x4000 */
    la t0, u_program
    li t1, 0x4000
    li t2, 256
3:  lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    addi t2, t2, -4
    bgtz t2, 3b

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
    /* [0]: VA 0x0000 → PA 0x0000 (M-mode code, S-mode RX) */
    li t1, ((0 << 10) | 0xCB)
    sd t1, 0(t2)
    /* [4]: VA 0x4000 → PA 0x4000 (U-mode code, U=1 RX) */
    li t1, ((4 << 10) | 0xDB)     /* V,R,X,U,A,D = 0xDB */
    sd t1, 32(t2)
    /* [5]: VA 0x5000 → PA 0x5000 (S-mode code backing, S-mode RWX) */
    li t1, ((5 << 10) | 0xCF)
    sd t1, 40(t2)
    /* [6]: VA 0x6000 → PA 0x6000 (user data, U=1 RW) */
    li t1, ((6 << 10) | 0xDF)     /* V,R,W,U,A,D = 0xDF */
    sd t1, 48(t2)
    /* [7]: VA 0x7000 → PA 0x7000 (stack, S+U RW) */
    li t1, ((7 << 10) | 0xDF)     /* U=1 so both S(with SUM) and U can use */
    sd t1, 56(t2)
    /* [0x10]: VA 0x10000 → PA 0x5000 (S-mode kernel, S-mode RX) */
    li t1, ((5 << 10) | 0xCB)
    sd t1, 128(t2)
    /* L0[4] already maps VA 0x4000 → PA 0x4000 (U-mode code, U=1 RX) */

    /* M-mode trap handler */
    la t0, m_trap_handler
    csrw mtvec, t0

    /* Delegate exceptions to S-mode: ECALL_U(8), page faults(12,13,15) */
    li t0, (1 << 8) | (1 << 12) | (1 << 13) | (1 << 15)
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
    li t0, (1 << 11) | (1 << 7) | (1 << 18)  /* MPP=S, MPIE=1, SUM=1 */
    csrw mstatus, t0
    li t0, 0x10000
    csrw mepc, t0
    mret

    li x3, 0xFF
4:  j 4b

    .balign 4
m_trap_handler:
    csrr x11, mcause
    csrr x12, mtval
    li x3, 0xEE
    j .

/* ============================================================
 * S-mode kernel (at VA 0x10000 = PA 0x5000)
 * ============================================================ */
    .balign 4
s_kernel:
    /* Set up S-mode trap handler (for ECALL from U-mode) */
    la t0, s_trap_handler
    csrw stvec, t0

    /* Enable SUM so S-mode can access U=1 pages (for stack sharing) */
    li t0, (1 << 18)
    csrs sstatus, t0

    /* Set up stack */
    lui sp, 0x8
    li x1, 1               /* S-mode running */

    /* Prepare SRET to U-mode at VA 0x80000 */
    /* sstatus: SPP=0 (U-mode), SPIE=1 */
    li t0, (1 << 5)        /* SPIE=1 */
    csrw sstatus, t0
    /* Also re-enable SUM after sstatus write */
    li t0, (1 << 18)
    csrs sstatus, t0
    li t0, 0x4000
    csrw sepc, t0
    sret

    /* Should not reach here unless SRET returns */
5:  j 5b

/* S-mode trap handler for ECALL from U-mode */
    .balign 4
s_trap_handler:
    /* Save minimal context */
    addi sp, sp, -32
    sd t0, 0(sp)
    sd t1, 8(sp)
    sd ra, 16(sp)

    csrr t0, scause

    /* ECALL from U-mode: cause 8 */
    li t1, 8
    bne t0, t1, s_trap_other

    /* Simple syscall: a7=syscall number, a0=arg, return a0=result */
    /* Syscall 42: return a0 + 100 */
    li t0, 42
    bne a7, t0, s_syscall_unknown

    addi a0, a0, 100       /* result = arg + 100 */

    /* Advance sepc past ECALL */
    csrr t0, sepc
    addi t0, t0, 4
    csrw sepc, t0

    /* Restore and return to U-mode */
    ld t0, 0(sp)
    ld t1, 8(sp)
    ld ra, 16(sp)
    addi sp, sp, 32
    sret

s_syscall_unknown:
    li a0, -1
    csrr t0, sepc
    addi t0, t0, 4
    csrw sepc, t0
    ld t0, 0(sp)
    ld t1, 8(sp)
    ld ra, 16(sp)
    addi sp, sp, 32
    sret

s_trap_other:
    li x3, 0xCC
    j .

/* ============================================================
 * U-mode program (at VA 0x80000 = PA 0x4000)
 * ============================================================ */
    .balign 4
u_program:
    /* Test 1: ECALL syscall (42, arg=5) → expect return 105 */
    li a0, 5
    li a7, 42
    ecall

    /* Verify result */
    li t0, 105
    bne a0, t0, u_fail

    /* Test 2: Write to user data page (VA 0x6000) */
    li t0, 0x6000
    li t1, 0xBEEF
    sd t1, 0(t0)
    ld t2, 0(t0)
    bne t1, t2, u_fail

    /* All passed: signal via ECALL with special syscall */
    li x9, 0xAA
    li x3, 0xAA
6:  nop
    j 6b

u_fail:
    li x3, 0xDD
    j .

    nop
    nop
    nop
    nop
u_program_end:
