# Phase 11-H3d: instruction guest-page-fault (cause 20) + htval + hstatus.GVA.
#
# A real guest (V=1, entered via MRET with MPP=S / MPV=1) runs with vsatp=Bare
# (VS-stage identity, GVA == GPA) and hgatp=Sv39x4 whose G-stage root maps only
# guest-physical [0x80000000,0xC0000000) (a 1 GiB identity gigapage, covering the
# guest's own code) and leaves [0x40000000,0x80000000) UNMAPPED. The guest jumps
# to GVA 0x40000000: the fetch's VS stage passes it through (Bare) to GPA
# 0x40000000, the G stage finds an invalid root entry, and the FETCH raises an
# instruction guest-page-fault (cause 20). With medeleg[20]=1 (and hedeleg[20]=0)
# it is delivered to HS-mode at stvec. The HS handler confirms scause=20,
# htval=GPA>>2 (0x10000000), stval=the faulting fetch VA (0x40000000), and
# hstatus.GVA=1.
# tohost @ 0x80001000: 1 = PASS, else a debug code.
#
# Discriminating: a plain instruction page-fault is cause 12 (not 20) and leaves
# htval untouched; the cause-20 + htval=0x10000000 + GVA trio only holds for a
# true G-stage fetch fault.
#
# vsatp = CSR 0x280, hgatp = CSR 0x680, htval = CSR 0x643, hstatus = CSR 0x600.

    .section .text.init
    .globl _start
_start:
    la   t0, m_handler
    csrw mtvec, t0
    la   t0, hs_handler
    csrw stvec, t0               # HS-mode trap vector (V=0 after a guest exit)

    # ---- G-stage page table (Sv39x4), root @ 0x80016000 ----
    li   t0, 0x80016010          # G L2[2] -> 1GiB leaf, HPA 0x80000000, V|R|W|X|U|A|D
    li   t1, 0x200000DF
    sd   t1, 0(t0)               # GPA [0x80000000,0xC0000000) identity (guest code)
    # G L2[1] (GPA [0x40000000,0x80000000)) left 0 = invalid -> fetch target faults

    csrw 0x280, zero             # vsatp = Bare (VS-stage identity)
    li   t0, 0x8000000000080016  # Sv39x4, PPN=0x80016
    csrw 0x680, t0               # hgatp
    sfence.vma zero, zero

    li   t0, (1 << 20)           # instruction guest-page-fault
    csrw medeleg, t0             # ... delegated past M -> HS (hedeleg[20]=0 keeps it at HS)

    # ---- MRET into VS-mode: MPP=S(01, bit11), MPV=1(bit39) ----
    li   t0, 0x8000000800
    csrs mstatus, t0
    la   t0, guest_entry
    csrw mepc, t0
    mret                         # -> VS-mode @ guest_entry (G-translated fetch)

guest_entry:                     # runs in VS-mode (V=1)
    li   t0, 0x40000000          # GVA == GPA 0x40000000 (G-stage UNMAPPED)
    jr   t0                      # fetch from there -> instruction guest-page-fault (20) -> HS

    .balign 4
hs_handler:                      # HS-mode handler (V=0, priv=S, satp=Bare)
    csrr t0, scause
    li   t1, 20                  # instruction guest-page-fault
    bne  t0, t1, hfail
    csrr t0, 0x643               # htval
    li   t1, 0x10000000          # 0x40000000 >> 2
    bne  t0, t1, hfail2
    csrr t0, stval
    li   t1, 0x40000000          # the faulting fetch (guest) VA
    bne  t0, t1, hfail3
    csrr t0, 0x600               # hstatus
    andi t0, t0, 0x40            # GVA = bit 6
    beqz t0, hfail4
    li   t0, 1                   # PASS
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

hfail:                           # wrong cause
    ori  t0, t0, 0x300
    li   t1, 0x80001000
    sw   t0, 0(t1)
2:  j    2b
hfail2:                          # wrong htval
    ori  t0, t0, 0x400
    li   t1, 0x80001000
    sw   t0, 0(t1)
3:  j    3b
hfail3:                          # wrong stval
    ori  t0, t0, 0x500
    li   t1, 0x80001000
    sw   t0, 0(t1)
4:  j    4b
hfail4:                          # GVA not set
    li   t0, 0x600
    li   t1, 0x80001000
    sw   t0, 0(t1)
5:  j    5b

    .balign 4
m_handler:                       # M-mode handler (unexpected — fault not delegated)
    csrr t6, mcause
    ori  t6, t6, 0x200
    li   t1, 0x80001000
    sw   t6, 0(t1)
6:  j    6b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
