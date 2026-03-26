/* Context switch test: two U-mode processes with cooperative scheduling.
 *
 * Process A and B share the same code (count + yield loop).
 * Each process counts to 3, yielding after each increment.
 * At 3, the process signals "done" via ECALL.
 * The kernel verifies both processes completed.
 *
 * Context save area at VA 0x6000:
 *   +0x000: Process A: sepc(8), a0(8), done(8)
 *   +0x080: Process B: sepc(8), a0(8), done(8)
 *   +0x200: current_proc (0=A, 1=B)
 */

    .section .text.start, "ax"
    .global _start

_start:
    lui sp, 0x8
    li t0, 0x1000
    li t1, 0x7000
1:  sd zero, 0(t0)
    addi t0, t0, 8
    blt t0, t1, 1b

    la t0, s_kernel
    li t1, 0x5000
    li t2, 512
2:  lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    addi t2, t2, -4
    bgtz t2, 2b

    la t0, u_code
    li t1, 0x4000
    li t2, 128
3:  lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    addi t2, t2, -4
    bgtz t2, 3b

    /* Page tables */
    li t0, 0x1000
    li t1, ((2 << 10) | 0x01)
    sd t1, 0(t0)
    li t0, 0x2000
    li t1, ((3 << 10) | 0x01)
    sd t1, 0(t0)
    li t2, 0x3000
    li t1, ((0 << 10) | 0xCB)
    sd t1, 0(t2)
    li t1, ((4 << 10) | 0xDB)
    sd t1, 32(t2)
    li t1, ((5 << 10) | 0xCF)
    sd t1, 40(t2)
    li t1, ((6 << 10) | 0xDF)
    sd t1, 48(t2)
    li t1, ((7 << 10) | 0xDF)
    sd t1, 56(t2)
    li t1, ((5 << 10) | 0xCB)
    sd t1, 128(t2)

    la t0, m_trap
    csrw mtvec, t0
    li t0, (1 << 8)
    csrw medeleg, t0

    li t0, 1
    li t1, 8
    slli t1, t1, 60
    or t0, t0, t1
    csrw satp, t0
    sfence.vma zero, zero

    li t0, (1 << 11) | (1 << 7) | (1 << 18)
    csrw mstatus, t0
    li t0, 0x10000
    csrw mepc, t0
    mret

    li x3, 0xFF
4:  j 4b

    .balign 4
m_trap:
    csrr x11, mcause
    li x3, 0xEE
    j .

/* ============================================================
 * S-mode kernel (VA 0x10000)
 * ============================================================ */
    .balign 4
s_kernel:
    la t0, s_trap_handler
    csrw stvec, t0
    lui sp, 0x8

    /* Init process A at ctx+0x000 */
    li t0, 0x6000
    li t1, 0x4000
    sd t1, 0(t0)          /* A.sepc */
    sd zero, 8(t0)        /* A.a0 */
    sd zero, 16(t0)       /* A.done */
    /* Init process B at ctx+0x080 */
    li t0, 0x6080
    sd t1, 0(t0)
    sd zero, 8(t0)
    sd zero, 16(t0)
    /* current_proc = 0 (A) */
    li t0, 0x6200
    sd zero, 0(t0)

    /* Launch process A */
    li t0, (1 << 18) | (1 << 5)
    csrw sstatus, t0
    li t0, 0x4000
    csrw sepc, t0
    li a0, 0
    li a7, 0
    sret

/* Trap handler: ECALL from U-mode.
 * a7=0: yield (save ctx, switch, restore, SRET)
 * a7=1: done  (mark done, check both, maybe switch) */
    .balign 4
s_trap_handler:
    /* Use sscratch to save sp, then use kernel stack */
    csrw sscratch, sp
    lui sp, 0x8

    /* Save caller-saved regs we use */
    addi sp, sp, -48
    sd t0, 0(sp)
    sd t1, 8(sp)
    sd t2, 16(sp)
    sd t3, 24(sp)
    sd ra, 32(sp)

    csrr t0, scause
    li t1, 8
    bne t0, t1, s_trap_other

    /* Get current process context base */
    li t3, 0x6200
    ld t0, 0(t3)           /* current_proc */
    slli t1, t0, 7
    li t2, 0x6000
    add t2, t2, t1         /* ctx base */

    /* Save: sepc+4, a0 */
    csrr t1, sepc
    addi t1, t1, 4
    sd t1, 0(t2)
    sd a0, 8(t2)

    /* Branch on syscall type */
    bnez a7, s_handle_done

    /* === YIELD === */
    /* Switch to other process */
    ld t0, 0(t3)           /* current_proc */
    xori t0, t0, 1
    sd t0, 0(t3)           /* current_proc = other */

    /* Restore other process */
    slli t1, t0, 7
    li t2, 0x6000
    add t2, t2, t1
    ld t1, 0(t2)           /* other.sepc */
    ld a0, 8(t2)           /* other.a0 */
    csrw sepc, t1
    li a7, 0               /* clear a7 for the resumed process */

    /* SRET to U-mode */
    li t0, (1 << 8)
    csrc sstatus, t0       /* SPP=0 */
    li t0, (1 << 5) | (1 << 18)
    csrs sstatus, t0       /* SPIE=1, SUM=1 */

    ld t0, 0(sp)
    ld t1, 8(sp)
    ld t2, 16(sp)
    ld t3, 24(sp)
    ld ra, 32(sp)
    addi sp, sp, 48
    csrr sp, sscratch      /* restore U-mode sp (not used but correct) */
    sret

s_handle_done:
    /* Mark current process as done */
    li t0, 1
    sd t0, 16(t2)          /* ctx.done = 1 */

    /* Check if both are done */
    li t0, 0x6000
    ld t0, 16(t0)          /* A.done */
    li t1, 0x6080
    ld t1, 16(t1)          /* B.done */
    and t0, t0, t1
    bnez t0, s_all_done

    /* Only one done: switch to the other */
    ld t0, 0(t3)           /* current_proc */
    xori t0, t0, 1
    sd t0, 0(t3)
    slli t1, t0, 7
    li t2, 0x6000
    add t2, t2, t1
    ld t1, 0(t2)
    ld a0, 8(t2)
    csrw sepc, t1
    li a7, 0

    li t0, (1 << 8)
    csrc sstatus, t0
    li t0, (1 << 5) | (1 << 18)
    csrs sstatus, t0

    ld t0, 0(sp)
    ld t1, 8(sp)
    ld t2, 16(sp)
    ld t3, 24(sp)
    ld ra, 32(sp)
    addi sp, sp, 48
    csrr sp, sscratch
    sret

s_all_done:
    li x9, 0xAA
    li x3, 0xAA
5:  nop
    j 5b

s_trap_other:
    csrr x11, scause
    li x3, 0xCC
    j .

    nop
    nop
    nop
    nop
s_kernel_end:

/* ============================================================
 * U-mode code (VA 0x4000)
 * a0 = counter, a7 = syscall (0=yield, 1=done)
 * ============================================================ */
    .balign 4
u_code:
    addi a0, a0, 1
    li t0, 3
    beq a0, t0, u_done
    li a7, 0
    ecall
    j u_code
u_done:
    li a7, 1
    ecall
    j u_code
    nop
    nop
u_code_end:
