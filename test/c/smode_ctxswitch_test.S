/* Minimal context switch: single process yield + resume */

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

/* S-mode kernel */
    .balign 4
s_kernel:
    la t0, s_trap_handler
    csrw stvec, t0
    lui sp, 0x8
    li x1, 1

    /* SRET to U-mode at VA 0x4000 */
    li t0, (1 << 18) | (1 << 5)
    csrw sstatus, t0
    li t0, 0x4000
    csrw sepc, t0
    li a0, 0
    sret

/* S-mode handler: just advance sepc past ECALL and return */
    .balign 4
s_trap_handler:
    csrr t0, scause
    li t1, 8
    bne t0, t1, s_trap_other

    /* ECALL: if a7=1, success. Otherwise advance and return. */
    li t0, 1
    beq a7, t0, s_success

    csrr t0, sepc
    addi t0, t0, 4
    csrw sepc, t0
    sret

s_success:
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

/* U-mode: count to 3 with yields, then done */
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
