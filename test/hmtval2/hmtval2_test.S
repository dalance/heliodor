# Phase 11-H B: M-mode guest-page-fault -> mtval2 + mstatus.GVA.
#
# Like test/hgpf, but the guest-page-faults are NOT delegated (medeleg[21/23]=0),
# so they are taken in M-mode. M-mode records the faulting guest physical address
# in mtval2 (= GPA >> 2) and sets mstatus.GVA (bit 38) because mtval holds a guest
# virtual address. A V=1 guest (vsatp=Bare, hgatp=Sv39x4 with [0x40000000,
# 0x80000000) unmapped) loads then stores GVA 0x40000000:
#   load  -> cause 21 -> M : check mcause/mtval2/mstatus.GVA, skip the load, resume
#   store -> cause 23 -> M : check again -> PASS
# tohost @ 0x80001000: 1 = PASS; 0x5xx = unexpected mcause; 0x4xx = wrong mtval2;
# 0x6xx = mstatus.GVA not set.
#
# vsatp = CSR 0x280, hgatp = CSR 0x680, mtval2 = CSR 0x34b.

    .section .text.init
    .globl _start
_start:
    la   t0, m_handler
    csrw mtvec, t0

    # ---- G-stage page table (Sv39x4), root @ 0x80016000 ----
    li   t0, 0x80016010          # G L2[2] -> 1GiB leaf, HPA 0x80000000, V|R|W|X|U|A|D
    li   t1, 0x200000DF
    sd   t1, 0(t0)               # GPA [0x80000000,0xC0000000) identity (guest code)
    # G L2[1] (GPA [0x40000000,0x80000000)) left 0 = invalid -> data target faults

    csrw 0x280, zero             # vsatp = Bare (VS-stage identity)
    li   t0, 0x8000000000080016  # hgatp = Sv39x4, PPN=0x80016
    csrw 0x680, t0
    sfence.vma zero, zero

    csrw medeleg, zero           # delegate nothing -> guest-page-faults trap to M

    # ---- MRET into VS-mode: MPP=S(01, bit11), MPV=1(bit39) ----
    li   t0, 0x8000000800
    csrs mstatus, t0
    la   t0, guest_entry
    csrw mepc, t0
    mret                         # -> VS-mode @ guest_entry (V=1)

guest_entry:                     # VS-mode (V=1)
    li   a0, 0x40000000          # GVA == GPA 0x40000000 (G-stage UNMAPPED)
    ld   t5, 0(a0)               # LOAD -> G-stage load fault (cause 21) -> M, returns here+4
    li   a2, 0xDEAD
    sd   a2, 0(a0)               # STORE -> G-stage store fault (cause 23) -> M (PASS)
    li   t0, 0x70                # reached = no store fault (bug)
    li   t1, 0x80001000
    sw   t0, 0(t1)
0:  j    0b

    .balign 4
m_handler:                       # M-mode handler. Dispatches on mcause.
    csrr t0, mcause
    li   t1, 21                  # load guest-page-fault
    beq  t0, t1, m_load
    li   t1, 23                  # store guest-page-fault
    beq  t0, t1, m_store
    ori  t0, t0, 0x500           # unexpected mcause
    li   t1, 0x80001000
    sw   t0, 0(t1)
5:  j    5b

m_load:                          # cause 21: check mtval2 + GVA, skip the load, resume
    csrr t0, 0x34b               # mtval2
    li   t1, 0x10000000          # 0x40000000 >> 2
    bne  t0, t1, fail_tval2
    csrr t0, mstatus
    srli t0, t0, 38              # mstatus.GVA = bit 38
    andi t0, t0, 1
    beqz t0, fail_gva
    csrr t0, mepc
    addi t0, t0, 4               # advance past the faulting load
    csrw mepc, t0
    mret                         # -> guest (V restored from mstatus.MPV=1)

m_store:                         # cause 23: check mtval2 + GVA -> PASS
    csrr t0, 0x34b               # mtval2
    li   t1, 0x10000000
    bne  t0, t1, fail_tval2
    csrr t0, mstatus
    srli t0, t0, 38
    andi t0, t0, 1
    beqz t0, fail_gva
    li   t0, 1                   # PASS
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

fail_tval2:
    ori  t0, t0, 0x400
    li   t1, 0x80001000
    sw   t0, 0(t1)
4:  j    4b
fail_gva:
    li   t0, 0x600
    li   t1, 0x80001000
    sw   t0, 0(t1)
6:  j    6b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
