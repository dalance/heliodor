/* Instruction fetch MMU test for heliodor.
 *
 * Tests that S-mode code can execute from a non-identity-mapped virtual
 * address.  M-mode copies a small S-mode payload to physical page 0x5000,
 * then sets up page tables so VA 0x10000 maps to PA 0x5000.
 * After MRET to S-mode at VA 0x10000, the payload writes x3=0xAA.
 *
 * Memory layout:
 *   0x0000-0x0FFF : M-mode code (identity-mapped via level-0 PTE, VA=PA)
 *   0x1000-0x1FFF : L2 page table (root)
 *   0x2000-0x2FFF : L1 page table
 *   0x3000-0x3FFF : L0 page table
 *   0x4000-0x4FFF : Data page (RW, identity-mapped)
 *   0x5000-0x5FFF : S-mode code page (PA, mapped at VA 0x10000)
 *   0x7000-0x7FFF : Stack
 */

    .section .text.start, "ax"
    .global _start

_start:
    /* Set up stack pointer */
    lui sp, 0x8              /* sp = 0x8000 */

    /* Zero out page table area 0x1000-0x3FFF */
    li t0, 0x1000
    li t1, 0x4000
1:  sd zero, 0(t0)
    addi t0, t0, 8
    blt t0, t1, 1b

    /* Copy S-mode payload to physical page 0x5000 (64 bytes max) */
    la t0, s_payload         /* source (in M-mode code page) */
    li t1, 0x5000            /* destination */
    li t2, 64                /* payload size in bytes */
2:  lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    addi t2, t2, -4
    bgtz t2, 2b

    /* --- L2 root page table at 0x1000 --- */
    /* Entry 0: VPN[2]=0 → L1 at 0x2000 */
    li t0, 0x1000
    li t1, ((2 << 10) | 0x01)       /* PPN=2, V=1 (non-leaf) */
    sd t1, 0(t0)

    /* --- L1 page table at 0x2000 --- */
    /* Entry 0: VPN[1]=0 → L0 at 0x3000 */
    li t0, 0x2000
    li t1, ((3 << 10) | 0x01)       /* PPN=3, V=1 (non-leaf) */
    sd t1, 0(t0)

    /* --- L0 page table at 0x3000 --- */
    li t2, 0x3000

    /* Entry 0: VA 0x0000 → PA 0x0000 (code page, RXC) */
    li t1, ((0 << 10) | 0xCB)       /* PPN=0, V=1,R=1,X=1,A=1,D=1 */
    sd t1, 0(t2)

    /* Entry 4: VA 0x4000 → PA 0x4000 (data page, RWC) */
    li t1, ((4 << 10) | 0xCF)       /* PPN=4, V=1,R=1,W=1,X=1,A=1,D=1 */
    sd t1, 32(t2)

    /* Entry 5: VA 0x5000 → PA 0x5000 (identity, for page table access) */
    li t1, ((5 << 10) | 0xCF)
    sd t1, 40(t2)

    /* Entry 7: VA 0x7000 → PA 0x7000 (stack, RWC) */
    li t1, ((7 << 10) | 0xCF)
    sd t1, 56(t2)

    /* Entry 0x10: VA 0x10000 → PA 0x5000 (non-identity code mapping!) */
    /* VPN[0] = 0x10000 >> 12 = 0x10, L0 index = 0x10 */
    li t1, ((5 << 10) | 0xCB)       /* PPN=5, V=1,R=1,X=1,A=1,D=1 */
    sd t1, 128(t2)                   /* offset = 0x10 * 8 = 128 */

    /* Configure trap delegation and S-mode trap vector */
    li t0, 0xFFFF
    csrw medeleg, t0
    li t0, 0x222
    csrw mideleg, t0
    la t0, s_trap_handler
    csrw stvec, t0

    /* Enable Sv39: satp = (8 << 60) | 1 (ASID=0, PPN=1) */
    li t0, 1
    li t1, 8
    slli t1, t1, 60
    or t0, t0, t1
    csrw satp, t0
    sfence.vma zero, zero

    /* Switch to S-mode, jump to VA 0x10000 (mapped to PA 0x5000) */
    li t0, (1 << 11)         /* MPP = S-mode */
    csrw mstatus, t0
    li t0, 0x10000            /* mepc = VA 0x10000 */
    csrw mepc, t0
    mret

    /* Should not reach here */
    li x3, 0xBB
3:  j 3b

/* S-mode trap handler (identity-mapped VA) */
s_trap_handler:
    csrr x4, scause
    li x3, 0xBB               /* mark failure */
    j s_trap_handler

/* S-mode payload — will be copied to PA 0x5000, executed at VA 0x10000 */
    .balign 4
s_payload:
    li x3, 0xAA     /* addi x3, x0, 0xAA */
    j s_payload      /* spin (offset 0 = self-loop) */
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
s_payload_end:
