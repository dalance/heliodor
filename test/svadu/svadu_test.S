# P10 Svadu: hardware update of the PTE A (accessed) / D (dirty) bits.
#
# With menvcfg.ADUE=0 (Svade) a leaf with A=0 (or, for a store, D=0) raises a
# page fault — software must set the bits and retry. With ADUE=1 (Svadu) the
# walk does NOT fault: hardware writes the updated PTE back to memory. This test
# exercises both, reading the PTE back PHYSICALLY (MPRV cleared) to prove the
# bits really landed in memory:
#
#   1. ADUE=1, load  VA 0x40000000 (leaf A: V|R, A=0) -> no fault, PTE A := 1
#   2. ADUE=1, store VA 0x40001000 (leaf B: V|R|W|A, D=0) -> no fault, PTE D := 1
#   3. discriminating: ADUE=0, reset leaf A to A=0, load it -> MUST page-fault
#
# M-mode throughout (MPRV=1/MPP=S translates the data accesses; MPRV cleared for
# the bare PTE read-backs). A phase register (s4) tells the trap handler whether
# a fault is expected. tohost @ 0x80001000: 1 = PASS, 10 = FAIL.
#
#   VA 0x40000000 (VPN0=0, L0[0]) -> PA 0x80020000  (read target)
#   VA 0x40001000 (VPN0=1, L0[1]) -> PA 0x80021000  (store target)

    .section .text.init
    .globl _start
_start:
    la   t0, mtrap
    csrw mtvec, t0
    li   s4, 0                   # phase 0: a fault is NOT expected

    # ---- data ----
    li   t0, 0x80020000
    li   t1, 0xAAAA
    sd   t1, 0(t0)               # leaf A target value
    li   t0, 0x80021000
    li   t1, 0
    sd   t1, 0(t0)               # leaf B target cleared

    # ---- page tables ----
    li   t0, 0x80010008          # L2[1] -> L1 @ 0x80011000
    li   t1, 0x20004401
    sd   t1, 0(t0)
    li   t0, 0x80011000          # L1[0] -> L0 @ 0x80012000
    li   t1, 0x20004801
    sd   t1, 0(t0)
    li   t0, 0x80012000          # L0[0] -> PA 0x80020000, V|R, A=0, D=0
    li   t1, 0x20008003
    sd   t1, 0(t0)
    li   t0, 0x80012008          # L0[1] -> PA 0x80021000, V|R|W|A, D=0
    li   t1, 0x20008447
    sd   t1, 0(t0)

    # ---- enable Sv39 ----
    li   t0, 0x8000000000080010
    csrw satp, t0
    sfence.vma zero, zero

    # ---- enable menvcfg.ADUE (bit 61) ----
    li   t0, 1
    slli t0, t0, 61
    csrs menvcfg, t0

    # ---- MPRV=1, MPP=S (translate data accesses) ----
    li   t0, 0x20800
    csrs mstatus, t0

    # ---- 1. LOAD: A=0 leaf, ADUE=1 -> no fault, value read, A written back ----
    li   a0, 0x40000000
    ld   a1, 0(a0)               # must NOT fault (phase 0)
    li   t1, 0xAAAA
    bne  a1, t1, fail

    # ---- 2. STORE: A=1/D=0 leaf, ADUE=1 -> no fault, D written back ----
    li   a0, 0x40001000
    li   a2, 0x5555
    sd   a2, 0(a0)               # must NOT fault

    # ---- verify the write-backs physically (MPRV=0 -> bare PTE reads) ----
    li   t0, 0x20000
    csrc mstatus, t0             # MPRV=0
    li   t0, 0x80012000          # leaf A PTE: A bit (6) must now be 1
    ld   t1, 0(t0)
    srli t2, t1, 6
    andi t2, t2, 1
    beqz t2, fail
    li   t0, 0x80012008          # leaf B PTE: D bit (7) must now be 1
    ld   t1, 0(t0)
    srli t2, t1, 7
    andi t2, t2, 1
    beqz t2, fail
    li   t0, 0x80021000          # the store itself must have landed
    ld   t1, 0(t0)
    li   t2, 0x5555
    bne  t1, t2, fail

    # ---- 3. discriminating: ADUE=0 -> A=0 leaf MUST fault ----
    li   t0, 0x80012000          # reset leaf A PTE back to A=0
    li   t1, 0x20008003
    sd   t1, 0(t0)
    li   t0, 1
    slli t0, t0, 61
    csrc menvcfg, t0             # clear ADUE
    sfence.vma zero, zero        # flush TLB so the leaf is re-walked
    li   s4, 1                   # phase 1: a fault is now expected = PASS
    li   t0, 0x20800
    csrs mstatus, t0             # MPRV=1, MPP=S again
    li   a0, 0x40000000
    ld   a1, 0(a0)               # must FAULT -> mtrap
    j    fail                    # no fault -> bug

mtrap:
    csrr t6, mcause
    li   t5, 13                  # load page fault
    bne  t6, t5, fail_trap
    bnez s4, trap_pass           # phase 1 + load page fault -> expected
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
