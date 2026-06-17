# Phase 11-H B: H-extension CSR conformance read-back checks (M-mode).
#
#   1. misa.H (bit 7) is advertised.
#   2. mideleg bits 2/6/10 (VSSIP/VSTIP/VSEIP) are read-only ONE — write all-zero,
#      they must still read 1 (VS interrupts are always delegated to HS).
#   3. hedeleg bits 10/20/21/22/23 (ecall-from-VS, the guest-page-fault trio, and
#      virtual-instruction) are read-only ZERO — write all-one, they must read 0.
# tohost @ 0x80001000: 1 = PASS; 0x1x = misa.H, 0x2x = mideleg, 0x3x = hedeleg.

    .section .text.init
    .globl _start
_start:
    # ---- 1. misa.H ----
    csrr t0, misa
    srli t0, t0, 7               # bit 7 = H
    andi t0, t0, 1
    beqz t0, fail_misa

    # ---- 2. mideleg[2/6/10] read-only one ----
    csrw mideleg, zero           # try to clear all delegation
    csrr t0, mideleg
    li   t1, (1 << 2) | (1 << 6) | (1 << 10)
    and  t0, t0, t1
    bne  t0, t1, fail_mideleg     # bits 2/6/10 must still be 1

    # ---- 3. hedeleg[10/20/21/22/23] read-only zero ----
    li   t0, -1                  # all ones
    csrw 0x602, t0               # hedeleg
    csrr t0, 0x602
    li   t1, (1 << 10) | (1 << 20) | (1 << 21) | (1 << 22) | (1 << 23)
    and  t0, t0, t1
    bnez t0, fail_hedeleg         # those bits must be 0

    li   t0, 1                   # PASS
    li   t1, 0x80001000
    sw   t0, 0(t1)
0:  j    0b

fail_misa:
    li   t0, 0x10
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b
fail_mideleg:
    li   t0, 0x20
    li   t1, 0x80001000
    sw   t0, 0(t1)
2:  j    2b
fail_hedeleg:
    li   t0, 0x30
    li   t1, 0x80001000
    sw   t0, 0(t1)
3:  j    3b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
