# Phase 11-H A2: nested-walk guest-page-fault htval. Companion to test/hgpf,
# which uses vsatp=Bare (no VS-stage walk). Here the VS-stage runs a REAL Sv39
# walk (L2 pointer -> L1 megapage) before the final guest-physical address hits
# an unmapped G-stage entry. This proves the MMU keeps g_in_gpa = the FINAL data
# GPA across the nested VS-stage walk, so htval (= GPA >> 2) is correct for a
# store guest-page-fault (cause 23) — and the load one (cause 21) — reached the
# hard way. hgpf only covers the GVA==GPA identity case.
#
# Layout (all set up from M-mode, Bare, before MRET):
#   G-stage (hgatp=Sv39x4, root @ 0x80016000):
#     G L2[2] = 1GiB leaf -> HPA 0x80000000 (guest code + page tables)
#     G L2[1] ([0x40000000,0x80000000)) left invalid -> the data access faults
#   VS-stage (vsatp=Sv39, root @ 0x80017000):
#     VS L2[2] = 1GiB leaf -> GPA 0x80000000 (identity: guest code + tables)
#     VS L2[1] -> VS L1 @ GPA 0x80018000 (a real pointer the walk must descend)
#     VS L1[0] = 2MiB leaf -> GPA 0x40000000 (the G-unmapped data target)
#
# The guest (V=1) LOADs from GVA 0x40000000: VS walks L2[1]->L1[0] -> GPA
# 0x40000000, the G stage finds an invalid L2[1] -> load guest-page-fault
# (cause 21), htval = 0x40000000 >> 2 = 0x10000000. HS checks it, skips the load,
# SRETs back. The guest then STOREs to the same GVA -> store guest-page-fault
# (cause 23); HS checks scause/htval/stval/hstatus.GVA and reports PASS.
# tohost @ 0x80001000: 1 = PASS, else a debug code.
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
    sd   t1, 0(t0)               # GPA [0x80000000,0xC0000000) identity (guest code/tables)
    # G L2[1] (GPA [0x40000000,0x80000000)) left 0 = invalid -> data target faults

    # ---- VS-stage page table (Sv39), root @ 0x80017000 ----
    # VS leaves are SUPERVISOR pages (U=0): the guest runs VS-supervisor (MPP=S),
    # which cannot fetch/access U=1 pages. (The G-stage leaves keep U=1 — the
    # G-stage treats every guest access as user.)
    li   t0, 0x80017010          # VS L2[2] -> 1GiB leaf, GPA 0x80000000 (identity)
    li   t1, 0x200000CF          # V|R|W|X|A|D (U=0)
    sd   t1, 0(t0)
    li   t0, 0x80017008          # VS L2[1] -> pointer to VS L1 @ GPA 0x80018000
    li   t1, 0x20006001          # PPN=0x80018, V only (non-leaf)
    sd   t1, 0(t0)
    li   t0, 0x80018000          # VS L1[0] -> 2MiB leaf, GPA 0x40000000, V|R|W|X|A|D (U=0)
    li   t1, 0x100000CF
    sd   t1, 0(t0)

    li   t0, 0x8000000000080017  # vsatp: Sv39, PPN=0x80017
    csrw 0x280, t0
    li   t0, 0x8000000000080016  # hgatp: Sv39x4, PPN=0x80016
    csrw 0x680, t0
    sfence.vma zero, zero

    li   t0, (1 << 21) | (1 << 23)   # load + store guest-page-faults
    csrw medeleg, t0             # ... delegated past M -> HS (hedeleg[*]=0 keeps them at HS)

    # ---- MRET into VS-mode: MPP=S(01, bit11), MPV=1(bit39) ----
    li   t0, 0x8000000800
    csrs mstatus, t0
    la   t0, guest_entry
    csrw mepc, t0
    mret                         # -> VS-mode @ guest_entry (VS+G translated fetch)

guest_entry:                     # runs in VS-mode (V=1), vsatp=Sv39 + hgatp=Sv39x4
    li   a0, 0x40000000          # GVA -> (VS walk) -> GPA 0x40000000 (G-UNMAPPED)
    ld   t5, 0(a0)               # LOAD -> nested G-stage load fault (cause 21), returns here+4
    li   a2, 0xDEAD
    sd   a2, 0(a0)               # STORE -> nested G-stage store fault (cause 23) -> HS (PASS)
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
