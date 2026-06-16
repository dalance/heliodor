# Phase 11-H3: VS-mode trap delegation + ECALL-from-VS (cause 10).
#
# Enters VS-mode via MRET (MPP=S, MPV=1) with vsatp=hgatp=Bare, so V=1 is plain
# identity addressing (no guest page tables needed). The guest executes an
# illegal instruction; with medeleg[2] (delegated past M) and hedeleg[2]
# (delegated past HS) set, that trap is delivered into VS-mode at vstvec with
# V still 1. The guest handler reads scause (which aliases vscause under V=1),
# confirms cause 2, then ECALLs — which traps to M as cause 10 (ECALL from VS),
# distinct from ECALL-from-HS (9). The M handler confirms cause 10 + that the
# guest handler ran. tohost @ 0x80001000: 1 = PASS, else FAIL.
#
# Discriminating: if the illegal-instr trap were NOT delegated to VS it would go
# to M directly with cause 2 (not 10) -> M handler sees cause 2 -> FAIL.
#
# vstvec = CSR 0x205, hedeleg = CSR 0x602, vsatp = 0x280, hgatp = 0x680.

    .section .text.init
    .globl _start
_start:
    la   t0, m_handler
    csrw mtvec, t0
    la   t0, guest_trap
    csrw 0x205, t0               # vstvec
    li   t0, (1 << 2)            # delegate illegal-instruction (cause 2)
    csrw medeleg, t0             # ... past M
    csrw 0x602, t0               # hedeleg ... past HS -> reaches VS
    csrw 0x280, zero             # vsatp = Bare (V=1 identity)
    csrw 0x680, zero             # hgatp = Bare
    li   s3, 0                   # flag: guest handler not yet run

    # ---- MRET into VS-mode: MPP=S(01, bit11), MPV=1(bit39) ----
    li   t0, 0x8000000800        # (1<<39)|(1<<11)
    csrs mstatus, t0
    la   t0, guest_entry
    csrw mepc, t0
    mret                         # -> VS-mode @ guest_entry

guest_entry:                     # runs in VS-mode (V=1)
    .word 0                      # illegal instruction -> cause 2 -> (deleg) VS
    li   t0, 20                  # reached here = NO trap occurred (debug 20)
    li   t1, 0x80001000
    sw   t0, 0(t1)
0:  j    0b

    .balign 4                    # tvec targets must be 4-byte aligned (low 2 bits = MODE)
guest_trap:                      # VS-mode trap handler (reached via vstvec)
    csrr t0, scause              # V=1: scause aliases vscause
    li   t1, 2                   # expect illegal-instruction
    beq  t0, t1, gt_ok
    ori  t0, t0, 0x100           # mismatch: write (scause | 0x100) for debug
    li   t1, 0x80001000
    sw   t0, 0(t1)
4:  j    4b
gt_ok:
    li   s3, 0xACED              # mark: guest handler ran, cause OK
    ecall                        # ECALL from VS -> cause 10 -> M handler

    .balign 4
m_handler:                       # M-mode trap handler
    csrr t6, mcause
    li   t5, 10                  # expect ECALL-from-VS (cause 10)
    bne  t6, t5, m_fail
    li   t5, 0xACED
    bne  s3, t5, m_fail          # guest handler must have run first
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
