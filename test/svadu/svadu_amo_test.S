# Svadu D-bit updates by atomics and by a store that is not the oldest op.
#
# M-mode with MPRV=1/MPP=S under Sv39 and menvcfg.ADUE=1. Every leaf below is
# V|R|W|A with D=0, so the first write to each page must set D in memory
# before it lands:
#   C  VA 0x40002000 -> PA 0x80022000: lr.d / sc.d (the SC must succeed)
#   D  VA 0x40003000 -> PA 0x80023000: amoadd.d
#   E  VA 0x40004000 -> PA 0x80024000: sd behind a divide chain, so it
#      reaches its page while older ops are still in flight
# The PTEs and the data are then read back with MPRV=0. Any trap fails.
# tohost @ 0x80001000: 1 = PASS, 10 = FAIL.

    .section .text.init
    .globl _start
_start:
    la   t0, fail
    csrw mtvec, t0

    li   t0, 0x80022000
    li   t1, 7
    sd   t1, 0(t0)
    li   t0, 0x80023000
    li   t1, 100
    sd   t1, 0(t0)
    li   t0, 0x80024000
    sd   zero, 0(t0)

    li   t0, 0x80010008          # L2[1] -> L1 @ 0x80011000
    li   t1, 0x20004401
    sd   t1, 0(t0)
    li   t0, 0x80011000          # L1[0] -> L0 @ 0x80012000
    li   t1, 0x20004801
    sd   t1, 0(t0)
    li   t0, 0x80012010          # L0[2] = C
    li   t1, 0x20008847
    sd   t1, 0(t0)
    li   t0, 0x80012018          # L0[3] = D
    li   t1, 0x20008c47
    sd   t1, 0(t0)
    li   t0, 0x80012020          # L0[4] = E
    li   t1, 0x20009047
    sd   t1, 0(t0)

    li   t0, 0x8000000000080010
    csrw satp, t0
    sfence.vma zero, zero
    li   t0, 1
    slli t0, t0, 61
    csrs menvcfg, t0
    li   t0, 0x20800
    csrs mstatus, t0             # MPRV=1, MPP=S

    li   a0, 0x40002000
    li   a2, 0x1234
1:  lr.d a1, (a0)
    sc.d a3, a2, (a0)
    bnez a3, 1b

    li   a0, 0x40003000
    li   a2, 5
    amoadd.d a1, a2, (a0)
    li   t1, 100
    bne  a1, t1, fail

    li   a0, 0x40004000
    li   t1, 1000000
    li   t2, 3
    div  t1, t1, t2
    div  t1, t1, t2
    div  t1, t1, t2
    sd   t1, 0(a0)
    li   a4, 0x40002000
    ld   a5, 0(a4)

    li   t0, 0x20000
    csrc mstatus, t0             # MPRV=0
    li   t2, 0x1234
    bne  a5, t2, fail
    li   t0, 0x80022000
    ld   t1, 0(t0)
    bne  t1, t2, fail
    li   t0, 0x80023000
    ld   t1, 0(t0)
    li   t2, 105
    bne  t1, t2, fail
    li   t0, 0x80024000
    ld   t1, 0(t0)
    li   t2, 37037
    bne  t1, t2, fail
    li   t0, 0x80012010
    li   t3, 3
2:  ld   t1, 0(t0)
    srli t1, t1, 7
    andi t1, t1, 1
    beqz t1, fail
    addi t0, t0, 8
    addi t3, t3, -1
    bnez t3, 2b

    li   t0, 1
    li   t1, 0x80001000
    sw   t0, 0(t1)
3:  j    3b

fail:
    li   t0, 0x20000
    csrc mstatus, t0
    li   t0, 10
    li   t1, 0x80001000
    sw   t0, 0(t1)
4:  j    4b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
