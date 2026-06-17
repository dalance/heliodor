# Phase 11-H B: VS-mode CSR-access isolation (virtual instruction, cause 22).
#
# A guest (VS-mode, V=1) reaches its supervisor state ONLY through the aliased
# S-CSR addresses (0x1xx -> the vs* shadows). A direct access to a hypervisor
# CSR (0x6xx, e.g. hgatp 0x680) or a VS-level CSR (0x2xx, e.g. vsstatus 0x200)
# must raise a virtual instruction exception (cause 22), not read/write the real
# state. This test, from a VS-mode guest:
#   1. reads sstatus (0x100) — aliased to vsstatus, must NOT trap (proves the
#      legitimate guest path still works);
#   2. reads hgatp (0x680) — a hypervisor CSR — must trap cause 22;
#   3. (after HS resumes it) reads vsstatus (0x200) directly — must trap cause 22.
# tohost @ 0x80001000: 1 = PASS; 0x5xx = unexpected scause; 0x6x = a CSR access
# that did NOT trap; 0x70 = sstatus access wrongly trapped.

    .section .text.init
    .globl _start
_start:
    la   t0, m_handler
    csrw mtvec, t0
    la   t0, hs_handler
    csrw stvec, t0

    li   t0, (1 << 22)           # delegate virtual-instruction (22) to HS
    csrw medeleg, t0

    csrw 0x280, zero             # vsatp = Bare
    csrw 0x680, zero             # hgatp = Bare

    # ---- MRET into VS-mode: MPP=S(01, bit11), MPV=1(bit39) ----
    li   t0, 0x8000000800
    csrs mstatus, t0
    la   t0, guest_entry
    csrw mepc, t0
    mret                         # -> VS-mode @ guest_entry (V=1)

guest_entry:                     # VS-mode (V=1)
    csrr t0, sstatus             # aliased to vsstatus -> must NOT trap
    csrr t0, 0x680               # hgatp (hypervisor CSR) -> cause 22 -> HS
    li   t0, 0x60                # reached = hgatp access did NOT trap (bug)
    li   t1, 0x80001000
    sw   t0, 0(t1)
0:  j    0b

guest_resume:                    # VS-mode again, after the HS handler SRETs
    csrr t0, 0x200               # vsstatus (VS-level CSR) -> cause 22 -> HS
    li   t0, 0x62                # reached = vsstatus access did NOT trap (bug)
    li   t1, 0x80001000
    sw   t0, 0(t1)
8:  j    8b

    .balign 4
hs_handler:                      # HS-mode handler. Dispatches on which guest CSR access.
    csrr t0, scause
    li   t1, 22
    bne  t0, t1, fail_cause      # both traps must be cause 22
    # Which access? sepc tells us. First trap (hgatp) -> resume at guest_resume;
    # second trap (vsstatus) -> PASS.
    csrr t0, sepc
    la   t1, guest_resume
    blt  t0, t1, first_trap      # sepc < guest_resume -> the hgatp access (PASS so far)
    # second trap (vsstatus) -> PASS
    li   t0, 1
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

first_trap:                      # hgatp trapped cause 22. Resume guest at guest_resume.
    la   t0, guest_resume
    csrw sepc, t0
    sret

fail_cause:
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
