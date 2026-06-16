# Phase 11-H Sstc-in-VS: guest hardware timer (vstimecmp -> VSTIP).
#
# M-mode enables Sstc for the guest (menvcfg.STCE & henvcfg.STCE), delegates the
# VS timer interrupt to VS (hideleg[6] = VSTIP), sets htimedelta = 0 (guest time
# == mtime), and MRETs into VS-mode (MPP=S, MPV=1) with vsatp = hgatp = Bare (V=1
# identity addressing). The guest reads `time`, programs stimecmp (= vstimecmp via
# the V=1 alias) a short delta ahead, enables sie.STIE + sstatus.SIE, and spins.
# When guest time reaches vstimecmp the hardware raises VSTIP, delivered as a
# *supervisor timer interrupt* (the VS timer is presented to the guest as the
# standard cause 5) into VS-mode at vstvec, with V still 1. The handler confirms
# scause = (interrupt | 5), reprograms stimecmp to all-1s (Sstc is level-
# triggered: it must move the compare forward or the interrupt re-fires forever),
# marks a flag, and SRETs. Back in the spin loop the (now-disarmed) timer does not
# re-fire; the guest ECALLs (cause 10, ECALL-from-VS) so the M handler confirms
# the whole chain ran. tohost @ 0x80001000: 1 = PASS, else a debug code.
#
# Discriminating: without the vstimecmp hardware source VSTIP never fires and the
# guest spins forever (tohost stays 0, distinct from any failure code). If the
# interrupt were taken in HS/M instead of VS, or the cause not presented as 5, the
# handler's checks fail (writes scause | 0x300). If the handler did not move the
# compare forward, the timer would re-fire immediately and the guest would never
# reach the ECALL.
#
# CSR numbers: time 0xC01, stimecmp 0x14D, vstvec 0x205, hideleg 0x603,
# menvcfg 0x30A, henvcfg 0x60A, htimedelta 0x605, vsatp 0x280, hgatp 0x680.
# The VS timer handler keeps off t1/s3 (the guest's spin-loop registers).

    .section .text.init
    .globl _start
_start:
    la   t0, m_handler
    csrw mtvec, t0
    la   t0, guest_trap
    csrw 0x205, t0               # vstvec

    li   t0, 1
    slli t0, t0, 63              # STCE (bit 63)
    csrs 0x30A, t0               # menvcfg.STCE = 1
    csrs 0x60A, t0               # henvcfg.STCE = 1  (Sstc enabled for the guest)

    li   t0, (1 << 6)            # VSTIP position (VS-level timer interrupt)
    csrw 0x603, t0               # hideleg: delegate VS timer to VS-mode
    csrw 0x605, zero             # htimedelta = 0 (guest time == mtime)
    csrw 0x280, zero             # vsatp = Bare (V=1 identity)
    csrw 0x680, zero             # hgatp = Bare
    li   s3, 0                   # flag: guest timer handler not yet run

    # ---- MRET into VS-mode: MPP=S(01, bit11), MPV=1(bit39) ----
    li   t0, 0x8000000800        # (1<<39)|(1<<11)
    csrs mstatus, t0
    la   t0, guest_entry
    csrw mepc, t0
    mret                         # -> VS-mode @ guest_entry

guest_entry:                     # runs in VS-mode (V=1)
    csrr t0, 0xC01               # time (guest time = mtime + htimedelta)
    li   t2, 0x400
    add  t0, t0, t2              # target = now + 0x400 cycles
    csrw 0x14D, t0               # stimecmp (aliases vstimecmp while V=1)
    li   t0, (1 << 5)            # STIE
    csrs sie, t0                 # vsie.STIE = 1
    li   t1, 0xBEEF
    li   t0, (1 << 1)            # SIE
    csrs sstatus, t0             # vsstatus.SIE = 1 -> pending VSTIP deliverable
    # Spin until the VS timer handler runs (sets s3). The interrupt is taken at an
    # instruction boundary in this loop once guest time reaches vstimecmp.
spin:
    bne  s3, t1, spin
    ecall                        # ECALL from VS -> cause 10 -> M handler

    .balign 4                    # tvec targets must be 4-byte aligned
guest_trap:                      # VS-mode timer handler (reached via vstvec)
    csrr t3, scause              # V=1: scause aliases vscause
    bgez t3, gt_fail             # MSB(63) set => interrupt; clear => unexpected sync trap
    andi t4, t3, 0xff            # low bits = cause number
    li   t5, 5                   # expect supervisor timer interrupt (VSTIP -> 5)
    bne  t4, t5, gt_fail
    li   t0, -1                  # disarm: stimecmp = all-1s (level-triggered source)
    csrw 0x14D, t0               # vstimecmp = max -> guest time never reaches it again
    li   s3, 0xBEEF              # mark: VS timer handler ran, cause OK
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
    bne  s3, t5, m_fail          # the guest timer handler must have run first
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
