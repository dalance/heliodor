# Phase 11-H B: hstatus.VTVM / VTSR — intercept guest satp/SFENCE.VMA / SRET.
#
# With hstatus.VTVM=1 a VS-mode satp access or SFENCE.VMA, and with VTSR=1 a
# VS-mode SRET, raise a virtual instruction exception (cause 22) so the
# hypervisor can intercept guest paging / return. This test runs a VS-mode
# guest with both controls set; the guest executes the three operations, each of
# which must trap to HS as cause 22, then makes a hypercall (ECALL-from-VS) that
# verifies all three trapped (a counter in HS-private memory).
# tohost @ 0x80001000: 1 = PASS; 0x5xx = unexpected scause; 0x30+n = only n of 3
# operations trapped (a control did not intercept).

    .section .text.init
    .globl _start
_start:
    la   t0, m_handler
    csrw mtvec, t0
    la   t0, hs_handler
    csrw stvec, t0

    li   t0, (1 << 22) | (1 << 10) # delegate virtual-instruction(22) + ecall-from-VS...
    # note: ECALL-from-VS (cause 10) is never delegated to VS; it reaches HS via
    # medeleg here. virtual-instruction(22) is delegated past M to HS.
    csrw medeleg, t0

    li   t0, 0x80002000          # HS-private trap counter = 0
    sw   zero, 0(t0)

    csrw 0x280, zero             # vsatp = Bare
    csrw 0x680, zero             # hgatp = Bare
    li   t0, (1 << 20) | (1 << 22) # hstatus.VTVM (20) + VTSR (22)
    csrs 0x600, t0

    # ---- MRET into VS-mode: MPP=S(01, bit11), MPV=1(bit39) ----
    li   t0, 0x8000000800
    csrs mstatus, t0
    la   t0, guest_entry
    csrw mepc, t0
    mret                         # -> VS-mode @ guest_entry (V=1)

guest_entry:                     # VS-mode (V=1)
    csrr t0, satp                # VTVM: satp access -> cause 22
    sfence.vma zero, zero        # VTVM: SFENCE.VMA -> cause 22
    sret                         # VTSR: SRET -> cause 22
    ecall                        # ECALL-from-VS (cause 10) -> HS verifies count==3
    li   t0, 0x40                # ecall did not trap (bug)
    li   t1, 0x80001000
    sw   t0, 0(t1)
0:  j    0b

    .balign 4
hs_handler:                      # HS-mode handler.
    csrr t0, scause
    li   t1, 22
    beq  t0, t1, vi_trap
    li   t1, 10                  # ECALL-from-VS
    beq  t0, t1, ecall_check
    ori  t0, t0, 0x500           # unexpected scause
    li   t1, 0x80001000
    sw   t0, 0(t1)
5:  j    5b

vi_trap:                         # a VTVM/VTSR trap: bump the counter, skip the op, resume
    li   t1, 0x80002000
    lw   t2, 0(t1)
    addi t2, t2, 1
    sw   t2, 0(t1)
    csrr t0, sepc
    addi t0, t0, 4               # advance past the (4-byte) trapped instruction
    csrw sepc, t0
    sret

ecall_check:                     # verify all three operations trapped
    li   t1, 0x80002000
    lw   t2, 0(t1)
    li   t1, 3
    bne  t2, t1, fail_count
    li   t0, 1                   # PASS
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

fail_count:                      # 0x30 + (number that trapped)
    ori  t2, t2, 0x30
    li   t1, 0x80001000
    sw   t2, 0(t1)
3:  j    3b

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
