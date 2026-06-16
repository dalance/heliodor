# Phase 11-H5.2b: a bare-metal guest for hypervisor infrastructure validation.
# Runs in VS-mode at GVA 0x80200000 (its load address; vsatp=Bare, so GVA==GPA,
# mapped by the hypervisor's G-stage to host 0x80600000). It prints "GUEST OK"
# via SBI DBCN console_write_byte, then requests SBI shutdown. Entered by the
# hypervisor with a0=hartid, a1=dtb.

    .section .text.init, "ax"
    .globl _start
_start:
    la   a3, msg
1:  lbu  a0, 0(a3)
    beqz a0, 2f
    li   a6, 2                   # DBCN FID 2 = console_write_byte
    li   a7, 0x4442434E
    ecall
    addi a3, a3, 1
    j    1b
2:
    li   a0, 0                   # SRST reset_type = shutdown
    li   a1, 0
    li   a6, 0
    li   a7, 0x53525354
    ecall
3:  j    3b

msg: .asciz "GUEST OK\n"
