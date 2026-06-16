# Phase 11-H integration: a minimal hypervisor running a guest through full
# two-stage translation, servicing hypercalls via HLV/HSV.
#
# This ties the whole H stack together end-to-end (the per-feature tests each
# exercise one mechanism). HS sets up:
#   vsatp = Sv39, a 2 MiB identity megapage mapping GVA [0x80000000,0x80200000)
#           -> GPA identity with a supervisor (U=0) R|W|X leaf, via a real
#           2-level walk (L2[2] -> L1[0]=megapage).
#   hgatp = Sv39x4, a 1 GiB identity gigapage mapping GPA [0x80000000,0xC0000000)
#           -> HPA identity.
# So the guest runs at GVA == HPA but EVERY fetch and data access takes a full
# nested VS-stage -> G-stage walk (V=1 has no TLB), heavily exercising the
# two-stage MMU on the instruction-fetch path (the gpf tests only fetched through
# the G-stage gigapage; here fetch also descends the VS-stage Sv39 table).
# hstatus.SPVP=1 runs HLV/HSV as VS-supervisor; ECALL-from-VS (cause 10) is
# delegated to HS via medeleg[10].
#
# Flow:
#   guest: write arg 0x1234 to data page GVA 0x80003000; ECALL a7=1 ("double").
#   HS:    HLV.D the arg from the guest, double it, HSV.D it back, sepc+=4, SRET
#          (hstatus.SPV=1 -> resume the guest in VS-mode).
#   guest: load GVA 0x80003000, confirm 0x2468 (= 2*0x1234); ECALL a7=2 ("done").
#   HS:    bare-load HPA 0x80003000, confirm 0x2468 (the HSV reached the right
#          HPA through both stages), write tohost=1.
# The guest re-loads every register it needs after each ECALL (HS shares the hart
# GPRs and clobbers t0..t4, as a real hypervisor would before saving context).
# tohost @ 0x80001000: 1 = PASS, else a debug code (0x5xx unexpected scause,
# 0x6xx wrong HLV arg, 0x7xx wrong HSV result; M handler 0x2xx).
#
# CSR numbers: vsatp 0x280, hgatp 0x680, hstatus 0x600.

    .section .text.init
    .globl _start
_start:
    la   t0, m_handler
    csrw mtvec, t0
    la   t0, hs_handler
    csrw stvec, t0

    # ---- G-stage page table (Sv39x4), root @ 0x80016000 ----
    li   t0, 0x80016010          # G L2[2] -> 1GiB leaf HPA 0x80000000, V|R|W|X|U|A|D
    li   t1, 0x200000DF
    sd   t1, 0(t0)

    # ---- VS-stage page table (Sv39), root (L2) @ 0x80010000 ----
    li   t0, 0x80010010          # L2[2] -> L1 @ 0x80011000 (non-leaf, PPN=0x80011)
    li   t1, 0x20004401
    sd   t1, 0(t0)
    li   t0, 0x80011000          # L1[0] -> 2MiB megapage GVA[0x80000000,..)->GPA ident
    li   t1, 0x200000CF          # V|R|W|X|A|D (U=0 supervisor)
    sd   t1, 0(t0)

    # ---- program the guest translation CSRs ----
    li   t0, 0x8000000000080010  # vsatp = Sv39, PPN=0x80010
    csrw 0x280, t0
    li   t0, 0x8000000000080016  # hgatp = Sv39x4, PPN=0x80016
    csrw 0x680, t0
    li   t0, 0x100               # hstatus.SPVP = 1 (HLV/HSV as VS-supervisor)
    csrs 0x600, t0
    li   t0, (1 << 10)           # ECALL-from-VS (cause 10)
    csrw medeleg, t0             # ... delegated to HS
    sfence.vma zero, zero

    # ---- MRET into VS-mode: MPP=S(01, bit11), MPV=1(bit39) ----
    li   t0, 0x8000000800
    csrs mstatus, t0
    la   t0, guest_entry
    csrw mepc, t0
    mret                         # -> VS-mode @ guest_entry (full two-stage fetch)

guest_entry:                     # V=1, VS-supervisor, every access two-stage
    li   t1, 0x80003000          # guest data page (GVA)
    li   t2, 0x1234
    sd   t2, 0(t1)               # write arg (two-stage store)
    li   a7, 1                   # hypercall #1: double the argument
    ecall                        # -> cause 10 -> HS (medeleg[10])
    # --- resumed here by HS (registers assumed clobbered; re-load) ---
    li   t1, 0x80003000
    ld   t3, 0(t1)               # read the doubled result (two-stage load)
    li   t4, 0x2468              # expect 2 * 0x1234
    bne  t3, t4, g_fail
    li   a7, 2                   # hypercall #2: done
    ecall                        # -> HS writes tohost=1
g_spin:
    j    g_spin
g_fail:
    li   a7, 15                  # signal guest-side mismatch to HS
    ecall

    .balign 4
hs_handler:                      # HS-mode (V=0, satp=Bare) — services ECALL-from-VS
    csrr t0, scause
    li   t1, 10
    bne  t0, t1, hs_unexpected
    li   t1, 1
    beq  a7, t1, hc_double       # a7 is the guest's live hypercall number
    li   t1, 2
    beq  a7, t1, hc_done
    j    hs_unexpected           # unknown hypercall (incl. a7=15 guest fail)

hc_double:
    li   t2, 0x80003000          # guest data GVA
    hlv.d t3, (t2)               # read the guest's argument (VS-supervisor)
    li   t4, 0x1234
    bne  t3, t4, hs_badarg       # HLV must observe the guest's store
    slli t3, t3, 1               # double
    hsv.d t3, (t2)               # write the result back into guest memory
    csrr t0, sepc                # advance past the guest's ecall and resume
    addi t0, t0, 4
    csrw sepc, t0
    sret                         # hstatus.SPV=1 -> resume guest in VS-mode

hc_done:
    li   t0, 0x80003000          # cross-check via a bare HS load of the HPA
    ld   t1, 0(t0)               # (the HSV must have reached HPA 0x80003000)
    li   t2, 0x2468
    bne  t1, t2, hs_badresult
    li   t0, 1                   # PASS
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

hs_unexpected:
    li   t0, 0x500
    j    hs_report
hs_badarg:
    li   t0, 0x600
    j    hs_report
hs_badresult:
    li   t0, 0x700
    j    hs_report
hs_report:
    csrr t1, scause
    or   t0, t0, t1
    li   t1, 0x80001000
    sw   t0, 0(t1)
3:  j    3b

    .balign 4
m_handler:                       # unexpected M-mode trap
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
