# Phase 11-H3c: data-side guest-page-faults (load cause 21 + store cause 23) +
# htval + hstatus.GVA, plus an HS->guest resume across the fault.
#
# A real guest (V=1, entered via MRET with MPP=S / MPV=1) runs with vsatp=Bare
# (VS-stage identity, GVA == GPA) and hgatp=Sv39x4 whose G-stage root maps only
# guest-physical [0x80000000,0xC0000000) (a 1 GiB identity gigapage, covering the
# guest's own code) and leaves [0x40000000,0x80000000) UNMAPPED. The guest first
# LOADs from GVA 0x40000000 (G-unmapped): VS passes it through to GPA 0x40000000,
# the G stage finds an invalid root entry, and a load guest-page-fault (cause 21)
# is delivered to HS. The HS handler checks htval=GPA>>2 (0x10000000), advances
# sepc past the load, and SRETs back into the guest (V restored from hstatus.SPV).
# The guest then STOREs to the same GVA -> store guest-page-fault (cause 23); the
# HS handler checks scause/htval/stval/hstatus.GVA and reports PASS.
# tohost @ 0x80001000: 1 = PASS, else a debug code.
#
# Discriminating: a plain load/store page-fault is cause 13/15 (not 21/23) and
# leaves htval untouched; the cause-21/23 + htval=0x10000000 + GVA trio only holds
# for a true G-stage data fault.
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
    # G L2[1] (GPA [0x40000000,0x80000000)) left 0 = invalid -> data target faults

    csrw 0x280, zero             # vsatp = Bare (VS-stage identity)
    li   t0, 0x8000000000080016  # Sv39x4, PPN=0x80016
    csrw 0x680, t0               # hgatp
    sfence.vma zero, zero

    li   t0, (1 << 21) | (1 << 23)   # load + store guest-page-faults
    csrw medeleg, t0             # ... delegated past M -> HS (hedeleg[*]=0 keeps them at HS)

    # ---- MRET into VS-mode: MPP=S(01, bit11), MPV=1(bit39) ----
    li   t0, 0x8000000800
    csrs mstatus, t0
    la   t0, guest_entry
    csrw mepc, t0
    mret                         # -> VS-mode @ guest_entry (G-translated fetch)

guest_entry:                     # runs in VS-mode (V=1)
    li   a0, 0x40000000          # GVA == GPA 0x40000000 (G-stage UNMAPPED)
    ld   t5, 0(a0)               # LOAD -> G-stage load fault (cause 21) -> HS, returns here+4
    li   a2, 0xDEAD
    sd   a2, 0(a0)               # STORE -> G-stage store fault (cause 23) -> HS (PASS)
    li   t0, 40                  # reached here = NO store fault (debug 40)
    li   t1, 0x80001000
    sw   t0, 0(t1)
0:  j    0b

    .balign 4
hs_handler:                      # HS-mode handler (V=0, priv=S, satp=Bare)
    csrr t0, scause
    li   t1, 21                  # load guest-page-fault
    beq  t0, t1, hs_load
    li   t1, 23                  # store guest-page-fault
    beq  t0, t1, hs_store
    ori  t0, t0, 0x300           # unexpected cause
    li   t1, 0x80001000
    sw   t0, 0(t1)
2:  j    2b

hs_load:                         # cause 21: check htval, skip the load, resume guest
    csrr t0, 0x643               # htval
    li   t1, 0x10000000          # 0x40000000 >> 2
    bne  t0, t1, hfail2
    csrr t0, sepc
    addi t0, t0, 4               # advance past the (4-byte) faulting load
    csrw sepc, t0
    sret                         # -> guest (V restored from hstatus.SPV=1)

hs_store:                        # cause 23: check htval/stval/GVA -> PASS
    csrr t0, 0x643               # htval
    li   t1, 0x10000000
    bne  t0, t1, hfail2
    csrr t0, stval
    li   t1, 0x40000000          # the faulting guest VA
    bne  t0, t1, hfail3
    csrr t0, 0x600               # hstatus
    andi t0, t0, 0x40            # GVA = bit 6
    beqz t0, hfail4
    li   t0, 1                   # PASS
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

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
