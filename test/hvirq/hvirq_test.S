# Phase 11-H3b: virtual (VS-level) interrupt delivery into VS-mode + VS-mode SRET.
#
# M-mode injects a VS software interrupt by setting hvip.VSSIP (bit 2), delegates
# it to VS with hideleg[2], then MRETs into VS-mode (MPP=S, MPV=1) with vsatp=
# hgatp=Bare so V=1 is plain identity addressing. The guest enables sie.SSIE and
# sstatus.SIE; the pending VSSIP is then delivered as a *supervisor software
# interrupt* (the VS code 2 is translated to the standard code 1) into VS-mode at
# vstvec, with V still 1. The guest handler confirms scause = (interrupt | 1),
# clears the interrupt by writing sip (which aliases hvip.VSSIP), marks a flag,
# and SRETs (a VS-mode SRET, which must restore from vsstatus and return to
# vsepc). Back in the guest, the cleared interrupt does not re-fire; the guest
# ECALLs (cause 10, ECALL-from-VS) so the M handler can confirm the whole chain.
# tohost @ 0x80001000: 1 = PASS, else a debug code.
#
# Discriminating: if VS-interrupt delivery were broken the guest would spin
# forever and tohost would stay 0 (distinct from any failure code). If the
# interrupt went to HS/M instead of VS, or the cause were not translated to 1,
# the guest handler's checks would fail (writes scause|0x300). If the VS-mode
# SRET mis-restored, the interrupt would re-fire or return to the wrong PC.
#
# CSR numbers: vstvec 0x205, hideleg 0x603, hvip 0x645, vsatp 0x280, hgatp 0x680.
# The VS interrupt handler keeps off t1/s3 (the guest's spin-loop registers).

    .section .text.init
    .globl _start
_start:
    la   t0, m_handler
    csrw mtvec, t0
    la   t0, guest_trap
    csrw 0x205, t0               # vstvec
    li   t0, (1 << 2)            # VSSIP position (VS-level software interrupt)
    csrw 0x603, t0               # hideleg: delegate VSSIP to VS-mode
    csrw 0x280, zero             # vsatp = Bare (V=1 identity)
    csrw 0x680, zero             # hgatp = Bare
    csrw 0x645, t0               # hvip:  inject VSSIP -> pending
    li   s3, 0                   # flag: guest interrupt handler not yet run

    # ---- MRET into VS-mode: MPP=S(01, bit11), MPV=1(bit39) ----
    li   t0, 0x8000000800        # (1<<39)|(1<<11)
    csrs mstatus, t0
    la   t0, guest_entry
    csrw mepc, t0
    mret                         # -> VS-mode @ guest_entry

guest_entry:                     # runs in VS-mode (V=1)
    li   t0, (1 << 1)            # SSIE
    csrs sie, t0                 # vsie.SSIE = 1 (guest enables sw interrupt)
    li   t1, 0xBEEF
    li   t0, (1 << 1)            # SIE
    csrs sstatus, t0             # vsstatus.SIE = 1 -> pending VSSIP deliverable
    # Spin until the VS interrupt handler runs. The interrupt is taken at an
    # instruction boundary somewhere in this loop; the handler sets s3 and SRETs
    # back to vsepc (here), after which the loop exits. (If delivery is broken the
    # guest spins forever and tohost stays 0 — distinct from any failure code.)
spin:
    bne  s3, t1, spin
    ecall                        # ECALL from VS -> cause 10 -> M handler

    .balign 4                    # tvec targets must be 4-byte aligned
guest_trap:                      # VS-mode interrupt handler (reached via vstvec)
    csrr t3, scause              # V=1: scause aliases vscause
    bgez t3, gt_fail             # MSB(63) set => interrupt; clear => unexpected sync trap
    andi t4, t3, 0xff            # low bits = cause number
    li   t5, 1                   # expect supervisor software interrupt (VSSIP->1)
    bne  t4, t5, gt_fail
    csrw sip, zero               # clear sip.SSIP -> clears hvip.VSSIP (the source)
    li   s3, 0xBEEF              # mark: VS interrupt handler ran, cause OK
    sret                         # VS-mode SRET -> vsepc (back into the spin loop)
gt_fail:
    ori  t3, t3, 0x300           # write (scause | 0x300) for debugging
    li   t4, 0x80001000
    sw   t3, 0(t4)
4:  j    4b

    .balign 4
m_handler:                       # M-mode trap handler
    csrr t6, mcause
    li   t5, 10                  # expect ECALL-from-VS (cause 10)
    bne  t6, t5, m_fail
    li   t5, 0xBEEF
    bne  s3, t5, m_fail          # the guest interrupt handler must have run first
    li   t0, 1
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

m_fail:                          # write (mcause | 0x200) for debugging
    ori  t6, t6, 0x200
    li   t1, 0x80001000
    sw   t6, 0(t1)
2:  j    2b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
