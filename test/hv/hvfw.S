# Phase 11-H5.2b: minimal M-mode firmware for the bare-metal hypervisor test.
#
# Loaded into the SoC firmware ROM (PA 0, RESET_PC=0). It sets up M-mode, enables
# Sstc (menvcfg.STCE) so the guest's vstimecmp drives a hardware VS timer, routes
# the HS/guest-handleable traps down out of M (medeleg/mideleg) — including the
# guest-page-faults (20/21/23) that the hypervisor services — and drops to S-mode
# (HS) at the hypervisor entry 0x80000000 with a0=hartid, a1=0. Single hart.
#
# Any M-mode trap is unexpected here (the hypervisor handles its own HS traps and
# the guest's SBI traps to HS); the M handler parks with gp=0xDEAD so the harness
# (which passes on gp==0xAA) shows a distinct failure.

    .section .text.start, "ax"
    .globl _start
_start:
    la   t0, m_trap
    csrw mtvec, t0

    # Delegate to HS: synchronous causes 0-8, ECALL-from-VS (10), page faults
    # (12/13/15) and the guest-page-faults (20/21/23) the hypervisor services.
    li   t0, 0x00B0B5FF
    csrw medeleg, t0
    # Delegate S-level interrupts (sw/timer/ext at 1/5/9) to S.
    li   t0, 0x222
    csrw mideleg, t0

    # menvcfg: STCE(63) | PBMTE(62) | ADUE(61) so Sstc-in-VS + guest Svpbmt/Svadu
    # are available to the HS hypervisor and its guest.
    li   t0, 7
    slli t0, t0, 61
    csrw 0x30A, t0                   # menvcfg

    # mstatus: MPP=01 (S-mode), MPIE=1, SPIE=1, SIE=1, FS=01 (Initial: FP on).
    # FS!=0 is the global FP gate; without it every guest FP instruction (e.g.
    # __fstate_restore's `fld` after the guest sets vsstatus.FS) traps illegal.
    li   t0, (1 << 11) | (1 << 7) | (1 << 5) | (1 << 1) | (1 << 13)
    csrw mstatus, t0

    li   t0, 0x80000000              # HS hypervisor entry
    csrw mepc, t0
    li   a0, 0                       # hartid
    li   a1, 0
    mret

    .balign 4
m_trap:
    li   gp, 0xDEAD
1:  j    1b
