# Phase 11-H HLV / HLVX / HSV: hypervisor virtual-memory accesses.
#
# HS-mode (V=0, entered via MRET MPP=S / MPV=0) reaches into a guest's two-stage
# address space using the hypervisor load/store-virtual instructions. The guest
# translation is set up in M-mode first:
#   vsatp = Sv39, root @ GPA 0x80020000, mapping GVA 0x2000 -> GPA 0x80030000 via
#           a full 3-level walk (L2[0] -> L1[0] -> L0[2]) to a supervisor (U=0)
#           R|W|X leaf.
#   hgatp = Sv39x4, root @ HPA 0x80016000, a 1 GiB gigapage mapping guest-physical
#           [0x80000000,0xC0000000) -> HPA identity (covers both the VS-stage page
#           tables, which live in guest PA, and the data page).
#   hstatus.SPVP (bit 8) = 1, so HLV/HSV run with VS-supervisor privilege.
#
# Each HLV/HSV therefore performs a nested VS-stage (Sv39) -> G-stage (Sv39x4)
# walk from HS-mode even though the core itself runs at V=0. The HS code:
#   1. HSV.D  : write a 64-bit pattern to GVA 0x2000.
#   2. cross-check by a PLAIN HS bare load of HPA 0x80030000 — proves the HSV
#      translated GVA 0x2000 all the way to HPA 0x80030000 through both stages.
#   3. HLV.D  : read GVA 0x2000 back (HLV two-stage from HS).
#   4. HLVX.WU: read the low word of GVA 0x2000 via an execute-permission read
#      (the leaf is R|W|X, so HLVX succeeds and returns the zero-extended word).
# tohost @ 0x80001000: 1 = PASS, else a debug code (0x1xx/0x2xx/0x3xx = data
# mismatch at step 1/3/4; 0x4xx/0x5xx = an unexpected M/HS trap).
#
# Discriminating: HLV/HSV are SYSTEM funct3=100 (funct7=0110xxx). Without the H
# decode they trap illegal; without per-op two-stage threading the address is the
# raw rs1 with the wrong (single-stage / HS) translation, so the HSV would not
# reach HPA 0x80030000 and the cross-check (step 2) would read 0.
#
# vsatp = CSR 0x280, hgatp = CSR 0x680, hstatus = CSR 0x600.

    .section .text.init
    .globl _start
_start:
    la   t0, m_handler
    csrw mtvec, t0
    la   t0, hs_handler
    csrw stvec, t0

    # ---- G-stage page table (Sv39x4), root @ 0x80016000 ----
    li   t0, 0x80016010          # G L2[2] -> 1GiB leaf, HPA 0x80000000, V|R|W|X|U|A|D
    li   t1, 0x200000DF
    sd   t1, 0(t0)               # GPA [0x80000000,0xC0000000) identity

    # ---- VS-stage page table (Sv39), root (L2) @ 0x80020000 ----
    li   t0, 0x80020000
    li   t1, 0x20008401          # L2[0] -> L1 @ 0x80021000 (non-leaf, PPN=0x80021)
    sd   t1, 0(t0)
    li   t0, 0x80021000
    li   t1, 0x20008801          # L1[0] -> L0 @ 0x80022000 (non-leaf, PPN=0x80022)
    sd   t1, 0(t0)
    li   t0, 0x80022000
    li   t1, 0x2000C0CF          # L0[2] -> leaf GPA 0x80030000, V|R|W|X|A|D (U=0)
    sd   t1, 16(t0)              # L0[2] is at byte offset 2*8 = 16

    # ---- program the guest translation CSRs ----
    li   t0, 0x8000000000080020  # vsatp = Sv39, PPN=0x80020
    csrw 0x280, t0
    li   t0, 0x8000000000080016  # hgatp = Sv39x4, PPN=0x80016
    csrw 0x680, t0
    li   t0, 0x100               # hstatus.SPVP (bit 8) = 1 : HLV/HSV as VS-supervisor
    csrs 0x600, t0
    sfence.vma zero, zero

    # ---- MRET into HS-mode: MPP=S(01, bit11), MPV=0 (V=0, HS) ----
    li   t0, 0x800               # mstatus.MPP = S (bit 11)
    csrs mstatus, t0
    la   t0, hs_entry
    csrw mepc, t0
    mret                         # -> HS-mode @ hs_entry (V=0, priv=S, satp=Bare)

hs_entry:                        # HS-mode (V=0, priv=S, satp=Bare)
    li   t2, 0x2000              # guest VA
    li   t3, 0xDEADBEEF4AFEBABE  # 64-bit test pattern (low word has bit31 clear)
    hsv.d t3, (t2)               # HSV.D : write pattern to GVA 0x2000 (two-stage)

    # cross-check: HPA 0x80030000 must now hold the pattern (proves both stages)
    li   t0, 0x80030000
    ld   t1, 0(t0)
    bne  t1, t3, fail1

    hlv.d t4, (t2)               # HLV.D : read GVA 0x2000 back (two-stage)
    bne  t4, t3, fail2

    hlvx.wu t5, (t2)             # HLVX.WU : low word via execute-permission read
    li   t1, 0x4AFEBABE
    bne  t5, t1, fail3

    li   t0, 1                   # PASS
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

fail1:                           # step-1 HSV/cross-check mismatch
    li   t0, 0x100
    li   t1, 0x80001000
    sw   t0, 0(t1)
2:  j    2b
fail2:                           # step-3 HLV.D mismatch
    li   t0, 0x200
    li   t1, 0x80001000
    sw   t0, 0(t1)
3:  j    3b
fail3:                           # step-4 HLVX.WU mismatch
    li   t0, 0x300
    li   t1, 0x80001000
    sw   t0, 0(t1)
4:  j    4b

    .balign 4
hs_handler:                      # unexpected HS-mode trap (no HLV/HSV should fault)
    csrr t0, scause
    ori  t0, t0, 0x500
    li   t1, 0x80001000
    sw   t0, 0(t1)
5:  j    5b

    .balign 4
m_handler:                       # unexpected M-mode trap
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
