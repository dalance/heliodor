/* Sv39 MMU 4KB page test for heliodor — NOP-free version.
 * Same as sv39_4k_test.S but without NOP workarounds.
 */

   .section .text.start, "ax"
   .global _start

_start:
    /* Set up stack pointer (physical, M-mode) */
    lui sp, 0x8               /* sp = 0x8000 */

    /* Zero out page table area 0x1000-0x2FFF (2 pages) */
    li t0, 0x1000
    li t1, 0x3000
1:  sd zero, 0(t0)
    addi t0, t0, 8
    blt t0, t1, 1b

    /* --- Root page table (L2) at 0x1000 --- */
    li t0, 0x1000
    li t1, ((2 << 10) | 0x01)
    sd t1, 0(t0)

    /* --- L1 page table at 0x2000 --- */
    li t0, 0x2000
    li t1, ((3 << 10) | 0x01)
    sd t1, 0(t0)

    /* --- L0 page table at 0x3000 --- */
    li t2, 0x3000

    li t1, 0xCB
    sd t1, 0(t2)

    li t1, ((1 << 10) | 0xCF)
    sd t1, 8(t2)

    li t1, ((2 << 10) | 0xCF)
    sd t1, 16(t2)

    li t1, ((3 << 10) | 0xCF)
    sd t1, 24(t2)

    li t1, ((7 << 10) | 0xCF)
    sd t1, 56(t2)

    li t1, ((8 << 10) | 0xCF)
    sd t1, 64(t2)

    /* Configure trap delegation */
    li t0, 0xFFFF
    csrw medeleg, t0
    li t0, 0x222
    csrw mideleg, t0
    la t0, s_trap_handler
    csrw stvec, t0

    /* Enable Sv39 MMU */
    li t0, 1
    li t1, 8
    slli t1, t1, 60
    or t0, t0, t1
    csrw satp, t0
    sfence.vma zero, zero

    /* Switch to S-mode */
    li t0, (1 << 11)
    csrw mstatus, t0
    la t0, s_mode_entry
    csrw mepc, t0
    mret

s_mode_entry:
    li x3, 0xBB

    /* Test 1: Store/load doubleword to VA 0x3800 (no NOPs) */
    li t0, 0x3800
    li t1, 0x12345678
    sd t1, 0(t0)
    ld t2, 0(t0)
    bne t1, t2, fail

    /* Test 2: Store/load another value (no NOPs) */
    li t1, 0xABCD
    sd t1, 8(t0)
    ld t2, 8(t0)
    bne t1, t2, fail

    /* Test 3: Read code through MMU */
    li t0, 0
    ld a1, 0(t0)
    slli a2, a1, 32
    srli a2, a2, 32
    li t0, 0x8137
    bne a2, t0, fail

    /* All tests passed */
    li x3, 0xAA
fail:
    j fail

s_trap_handler:
    csrr x4, scause
    li x3, 0xBB
    j s_trap_handler
