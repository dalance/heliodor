# Phase 11-H2: two-stage address translation (VS-stage Sv39 -> G-stage Sv39x4).
#
# Exercised from M-mode via MPRV=1 / MPP=S / MPV=1, so data accesses translate
# as if in VS-mode: a nested VS-stage walk (vsatp, Sv39) whose every PTE read is
# itself G-stage translated (hgatp, Sv39x4). The G-stage is a single 1 GiB
# gigapage mapping guest-physical [0x80000000,0xC0000000) identically to host-
# physical, so the VS page tables (placed in DRAM and treated as guest PAs)
# resolve to themselves and the final guest PA maps straight through.
#
#   GVA 0x40000000 --VS--> GPA 0x80020000 --G--> HPA 0x80020000  (value 0xAAAA)
#   GVA 0x40001000 --VS--> GPA 0x80021000 --G--> HPA 0x80021000  (value 0xBBBB)
#
# Instruction fetch is unaffected by MPRV, so the code runs bare in M-mode.
# Checks: both loads return the expected value; a store via a GVA lands at the
# right HPA (read back physically with MPRV off); and a corrupted VS leaf makes
# the GVA fault (load page fault). tohost @ 0x80001000: 1 = PASS, 10 = FAIL.
#
# vsatp = CSR 0x280, hgatp = CSR 0x680 (numeric, no -march=h dependency).

    .section .text.init
    .globl _start
_start:
    la   t0, mtrap
    csrw mtvec, t0
    li   s4, 0                   # phase 0: no fault expected

    # ---- data pages (host physical) ----
    li   t0, 0x80020000
    li   t1, 0xAAAA
    sd   t1, 0(t0)
    li   t0, 0x80021000
    li   t1, 0xBBBB
    sd   t1, 0(t0)

    # ---- VS-stage page table (Sv39), root @ 0x80013000 ----
    li   t0, 0x80013008          # VS L2[1] -> VS L1 @ 0x80014000 (non-leaf, V)
    li   t1, 0x20005001
    sd   t1, 0(t0)
    li   t0, 0x80014000          # VS L1[0] -> VS L0 @ 0x80015000 (non-leaf, V)
    li   t1, 0x20005401
    sd   t1, 0(t0)
    li   t0, 0x80015000          # VS L0[0] -> GPA 0x80020000, V|R|W|A|D
    li   t1, 0x200080C7
    sd   t1, 0(t0)
    li   t0, 0x80015008          # VS L0[1] -> GPA 0x80021000, V|R|W|A|D
    li   t1, 0x200084C7
    sd   t1, 0(t0)

    # ---- G-stage page table (Sv39x4), root @ 0x80016000 ----
    li   t0, 0x80016010          # G L2[2] -> 1GiB leaf, HPA 0x80000000, V|R|W|X|U|A|D
    li   t1, 0x200000DF
    sd   t1, 0(t0)

    # ---- program vsatp + hgatp ----
    li   t0, 0x8000000000080013  # Sv39, PPN=0x80013
    csrw 0x280, t0               # vsatp
    li   t0, 0x8000000000080016  # Sv39x4, PPN=0x80016
    csrw 0x680, t0               # hgatp
    sfence.vma zero, zero

    # ---- MPRV=1, MPP=S (01), MPV=1 (bit39): translate data as VS two-stage ----
    li   t0, 0x8000020800        # (1<<39)|(1<<17)|(1<<11)
    csrs mstatus, t0

    # ---- 1. load GVA 0x40000000 -> 0xAAAA ----
    li   s5, 2                   # fail code 2
    li   a0, 0x40000000
    ld   a1, 0(a0)
    li   t1, 0xAAAA
    bne  a1, t1, fail

    # ---- 2. load GVA 0x40001000 -> 0xBBBB (different VS VPN0) ----
    li   s5, 3                   # fail code 3
    li   a0, 0x40001000
    ld   a1, 0(a0)
    li   t1, 0xBBBB
    bne  a1, t1, fail

    # ---- 3. store 0x1234 via GVA 0x40001000 (two-stage store path) ----
    li   a0, 0x40001000
    li   a2, 0x1234
    sd   a2, 0(a0)

    # ---- verify the store landed at HPA 0x80021000 (MPRV off = bare) ----
    li   s5, 4                   # fail code 4
    li   t0, 0x20000
    csrc mstatus, t0             # MPRV=0
    li   t0, 0x80021000
    ld   t1, 0(t0)
    li   t2, 0x1234
    bne  t1, t2, fail

    # ---- 4. discriminating: invalidate VS L0[0] -> GVA 0x40000000 must fault ----
    li   t0, 0x80015000
    li   t1, 0                   # V=0 (invalid)
    sd   t1, 0(t0)
    sfence.vma zero, zero
    li   s4, 1                   # a fault is now expected = PASS
    li   t0, 0x20800             # MPRV=1, MPP=S (MPV bit39 still set)
    csrs mstatus, t0
    li   s5, 5                   # fail code 5 (no fault occurred)
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
    li   t1, 0x80001000
    sw   t6, 0(t1)               # write the actual mcause (debug) — non-1 = FAIL
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
    li   t1, 0x80001000
    sw   s5, 0(t1)
3:  j    3b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
