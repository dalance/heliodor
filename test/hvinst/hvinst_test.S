# Phase 11-H B: HLV/HLVX/HSV mode-trap conformance.
#
# HLV/HLVX/HSV are valid only in M, HS-S, or HS-U with hstatus.HU=1. This test
# checks the two illegal cases:
#   (1) executed in VS-mode (V=1)            -> VIRTUAL instruction (cause 22)
#   (2) executed in HS-U (V=0,U) with HU=0   -> ILLEGAL instruction (cause 2)
# Both are delegated to HS (medeleg[2]=medeleg[22]=1, hedeleg untouched so 22 is
# NOT delegated to VS — virtual-instruction is always taken in HS/M).
#
# The mode-trap takes priority over any access fault, so vsatp/hgatp can be Bare
# (the HLV's bare access result is irrelevant and is suppressed by the trap).
# tohost @ 0x80001000: 1 = PASS; 0x4xx = unexpected M trap; 0x5xx = unexpected
# scause; 0x6x = an HLV that did NOT trap (mode-trap missing).
#
# Discriminating: without the mode-trap an HLV in VS/VU or HS-U(HU=0) just runs
# (does a bare/two-stage access and writes rd), reaching the 0x6x "no-trap" sink.
#
# hstatus = CSR 0x600.

    .section .text.init
    .globl _start
_start:
    la   t0, m_handler
    csrw mtvec, t0
    la   t0, hs_handler
    csrw stvec, t0

    li   t0, (1 << 2) | (1 << 22) # delegate illegal(2) + virtual-instruction(22) to HS
    csrw medeleg, t0
    # hedeleg: try to delegate virtual-instruction (bit 22) to VS. It is read-only
    # zero (Phase 11-H B), so cause 22 must still trap to HS, not the guest's
    # vstvec (which is left 0 — a VS delivery would jump the guest to 0).
    li   t0, -1                  # all ones: exercise the hedeleg read-only-0 mask
    csrw 0x602, t0

    csrw 0x280, zero             # vsatp = Bare
    csrw 0x680, zero             # hgatp = Bare (mode-trap precedes any access fault)
    # hstatus.HU (bit 9) left 0 : HLV/HSV illegal in HS-U.

    # ---- MRET into VS-mode: MPP=S(01, bit11), MPV=1(bit39) ----
    li   t0, 0x8000000800
    csrs mstatus, t0
    la   t0, guest_entry
    csrw mepc, t0
    mret                         # -> VS-mode @ guest_entry (V=1)

guest_entry:                     # VS-mode (V=1): an HLV here is a virtual instruction
    li   t2, 0x2000
    hlv.d t4, (t2)               # -> cause 22 (virtual instruction) -> HS
    li   t0, 0x60                # reached = NO trap (bug)
    li   t1, 0x80001000
    sw   t0, 0(t1)
0:  j    0b

    .balign 4
hs_handler:                      # HS-mode handler (V=0). Dispatches on scause.
    csrr t0, scause
    li   t1, 22
    beq  t0, t1, got_vi          # (1) virtual instruction from VS-mode HLV
    li   t1, 2
    beq  t0, t1, got_illegal     # (2) illegal from HS-U HLV (HU=0)
    ori  t0, t0, 0x500           # unexpected scause
    li   t1, 0x80001000
    sw   t0, 0(t1)
5:  j    5b

got_vi:                          # cause 22 confirmed. Now drop to HS-U and HLV again.
    csrr t0, 0x600               # hstatus
    li   t1, ~0x280              # clear SPV (bit7) so SRET stays V=0, and HU (bit9)=0
    and  t0, t0, t1
    csrw 0x600, t0
    li   t1, 0x100               # sstatus.SPP (bit8) = 0 -> SRET returns to U-mode
    csrc sstatus, t1
    la   t0, u_entry
    csrw sepc, t0
    sret                         # -> HS-U (V=0, priv=U)

got_illegal:                     # cause 2 from HS-U HLV with HU=0 -> PASS
    li   t0, 1
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

    .balign 4
u_entry:                         # HS-U (V=0, priv=U): an HLV here is illegal (HU=0)
    li   t2, 0x2000
    hlv.d t4, (t2)               # -> cause 2 (illegal instruction) -> HS
    li   t0, 0x62                # reached = NO trap (bug)
    li   t1, 0x80001000
    sw   t0, 0(t1)
2:  j    2b

    .balign 4
m_handler:                       # unexpected M-mode trap (cause not delegated)
    csrr t6, mcause
    ori  t6, t6, 0x400
    li   t1, 0x80001000
    sw   t6, 0(t1)
6:  j    6b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
