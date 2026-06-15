# P10 Svpbmt: page-based memory types (PTE[62:61] = PBMT).
#
# The cache-bypass effect of NC/IO cannot be observed in software on heliodor's
# coherent core, so this test pins the *interpretation* of the PBMT field, which
# is what the change adds:
#   - menvcfg.PBMTE gates interpretation: with PBMTE=0 a PBMT=11 PTE is treated
#     as an ordinary (cacheable) leaf — no fault.
#   - With PBMTE=1, PBMT=11 is reserved and raises a page fault.
#   - With PBMTE=1, PBMT=01 (NC) is a valid leaf — no fault.
#
# M-mode throughout (MPRV=1/MPP=S translates loads). A phase register (s4)
# tells the trap handler whether a fault is expected. tohost @ 0x80001000.
# 1 = PASS, 10 = FAIL.
#
#   VA 0x40000000 (VPN0=0, L0[0]) -> PA 0x80020000, PBMT=01 (NC)
#   VA 0x40001000 (VPN0=1, L0[1]) -> PA 0x80021000, PBMT=11 (reserved)

    .section .text.init
    .globl _start
_start:
    la   t0, mtrap
    csrw mtvec, t0
    li   s4, 0                   # phase 0: a fault is unexpected

    # ---- data ----
    li   t0, 0x80020000
    li   t1, 0xACAC
    sd   t1, 0(t0)
    li   t0, 0x80021000
    li   t1, 0xB1B1
    sd   t1, 0(t0)

    # ---- page tables ----
    li   t0, 0x80010008          # L2[1] -> L1
    li   t1, 0x20004401
    sd   t1, 0(t0)
    li   t0, 0x80011000          # L1[0] -> L0
    li   t1, 0x20004801
    sd   t1, 0(t0)
    li   t0, 0x80012000          # L0[0] -> PA 0x80020000, PBMT=01 (NC)
    li   t1, 0x20000000200080C7
    sd   t1, 0(t0)
    li   t0, 0x80012008          # L0[1] -> PA 0x80021000, PBMT=11 (reserved)
    li   t1, 0x60000000200084C7
    sd   t1, 0(t0)

    # ---- enable Sv39 (PBMTE still 0) ----
    li   t0, 0x8000000000080010
    csrw satp, t0
    sfence.vma zero, zero

    # ---- MPRV=1, MPP=S ----
    li   t0, 0x20800
    csrs mstatus, t0

    # ---- gating: PBMTE=0 -> PBMT=11 ignored, normal cacheable load works ----
    li   a0, 0x40001000
    ld   a1, 0(a0)               # must NOT fault (phase 0)
    li   t1, 0xB1B1
    bne  a1, t1, fail            # cached path -> reads the value we wrote

    # ---- enable PBMTE ----
    li   t0, 1
    slli t0, t0, 62              # menvcfg.PBMTE (bit 62)
    csrs menvcfg, t0
    sfence.vma zero, zero        # flush TLB so PBMT is re-interpreted

    # ---- acceptance: PBMT=01 (NC) is a valid leaf -> no fault ----
    li   a0, 0x40000000
    ld   a1, 0(a0)               # must NOT fault (phase 0); value not checked
                                 # (uncached vs cached data is not comparable)

    # ---- reserved fault: PBMTE=1 + PBMT=11 -> page fault ----
    li   s4, 1                   # phase 1: a fault is now expected = PASS
    li   a0, 0x40001000
    ld   a1, 0(a0)               # must fault -> mtrap
    j    fail                    # no fault -> bug

mtrap:
    csrr t6, mcause
    li   t5, 13                  # load page fault
    bne  t6, t5, fail_trap
    bnez s4, trap_pass           # phase 1 + load page fault -> expected
    # (phase 0 + fault falls through to fail_trap = unexpected)
fail_trap:
    li   t0, 0x20000
    csrc mstatus, t0
    li   t0, 10
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b
trap_pass:
    li   t0, 0x20000
    csrc mstatus, t0
    li   t0, 1
    li   t1, 0x80001000
    sw   t0, 0(t1)
2:  j    2b

fail:
    li   t0, 0x20000
    csrc mstatus, t0
    li   t0, 10
    li   t1, 0x80001000
    sw   t0, 0(t1)
3:  j    3b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
