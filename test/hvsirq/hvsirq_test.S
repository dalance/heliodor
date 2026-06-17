# Phase 11-H B: a VS interrupt NOT delegated to VS is taken by HS.
#
# The hypervisor injects a VS external interrupt (hvip.VSEIP, bit 10), enables it
# at the HS level (hie[10]), but does NOT delegate it to the guest (hideleg[10]=0).
# It then enters a VS-mode guest. Because the interrupt is not delegated, it must
# force a guest exit and be taken by HS as a VS-external interrupt (scause =
# interrupt 10), NOT delivered into the guest (which has no handler) and NOT
# dropped. The HS handler checks scause, clears hvip, and reports PASS.
# tohost @ 0x80001000: 1 = PASS; 0x5xx = unexpected scause; 0x40 = the guest ran
# without the interrupt firing (it was dropped — the gap).
#
# hideleg = CSR 0x603, hie = CSR 0x604, hvip = CSR 0x645.

    .section .text.init
    .globl _start
_start:
    la   t0, m_handler
    csrw mtvec, t0
    la   t0, hs_handler
    csrw stvec, t0

    csrw 0x603, zero             # hideleg = 0 : do NOT delegate VS interrupts to VS
    li   t0, (1 << 10)           # hie.VSEIE (bit 10) : enable VS-external at HS
    csrw 0x604, t0
    li   t0, (1 << 10)           # hvip.VSEIP (bit 10) : inject a guest external irq
    csrw 0x645, t0

    csrw 0x280, zero             # vsatp = Bare
    csrw 0x680, zero             # hgatp = Bare

    # ---- MRET into VS-mode: MPP=S(01, bit11), MPV=1(bit39) ----
    li   t0, 0x8000000800
    csrs mstatus, t0
    la   t0, guest_entry
    csrw mepc, t0
    mret                         # -> VS-mode @ guest_entry (V=1)

guest_entry:                     # VS-mode (V=1). The pending non-delegated VS irq
    nop                          # ... forces an exit to HS at the next boundary.
    nop
    li   t0, 0x40                # reached far = the interrupt was dropped (bug)
    li   t1, 0x80001000
    sw   t0, 0(t1)
0:  j    0b

    .balign 4
hs_handler:                      # HS-mode handler (V=0).
    csrr t0, scause
    bgez t0, fail_scause         # MSB must be set (interrupt)
    andi t0, t0, 0x3f            # interrupt number
    li   t1, 10                  # VS-external interrupt
    bne  t0, t1, fail_scause
    csrw 0x645, zero             # clear hvip -> interrupt no longer pending
    li   t0, 1                   # PASS
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

fail_scause:
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
