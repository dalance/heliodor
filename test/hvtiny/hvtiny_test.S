# Phase 11-H5.1: a minimal bare-metal type-1 hypervisor running a trivial guest.
#
# This is the first step toward booting a real Linux guest under a hand-written
# HS-mode hypervisor (no userspace VMM). It validates the core hypervisor loop:
# G-stage setup + delegation, VS-mode guest entry, and trap-and-emulate of the
# guest's SBI calls.
#
# Layering: M-mode _start sets up two-stage state and delegation, then MRETs to
# the HS-mode hypervisor (V=0). The hypervisor enters a trivial guest in VS-mode
# (SRET with hstatus.SPV=1). The guest issues two SBI calls (ECALL-from-VS, cause
# 10, delegated to HS via medeleg[10]):
#   1. DBCN console_write("HI", 2)  -> HS appends the bytes to a capture buffer,
#   2. SRST system_reset(shutdown)  -> HS verifies the captured console == "HI"
#      and writes tohost=1 (PASS).
# G-stage is a 1 GiB identity gigapage and vsatp=Bare, so the trivial guest runs
# at GVA == GPA == HPA (the guest is just a few instructions in this same image).
# The SBI console buffer pointer the guest passes is therefore directly readable
# by the hypervisor. (Real Linux passes a guest-PHYSICAL DBCN buffer, also
# covered by the identity G-stage; full GPR context save/restore and a separated
# guest RAM region come with the real-guest milestone.)
#
# tohost @ 0x80001000: 1 = PASS, else a debug code (0x5xx unexpected HS scause,
# 0x6xx wrong captured console; M handler 0x2xx).
#
# CSR numbers: hgatp 0x680, vsatp 0x280, hstatus 0x600.

#define UART_BASE   0x10000000
#define CAP_BUF     0x80004000      /* host capture buffer for the guest console */
#define CAP_LEN     0x80004100      /* host capture length (word) */
#define SBI_DBCN    0x4442434E
#define SBI_SRST    0x53525354
#define SBI_BASE    0x10

    .section .text.init
    .globl _start
_start:                              # M-mode
    la   t0, m_handler
    csrw mtvec, t0
    la   t0, hs_handler
    csrw stvec, t0                   # HS-mode trap vector

    # ---- G-stage page table (Sv39x4), 1 GiB identity gigapage @ 0x80016000 ----
    li   t0, 0x80016010              # G L2[2] -> HPA 0x80000000, V|R|W|X|U|A|D
    li   t1, 0x200000DF
    sd   t1, 0(t0)
    li   t0, 0x8000000000080016      # hgatp = Sv39x4, PPN=0x80016
    csrw 0x680, t0
    csrw 0x280, zero                 # vsatp = Bare (guest VS-stage identity)

    # ---- delegation ----
    # medeleg: route the guest-level synchronous causes out of M down to HS. Bit
    # 10 (ECALL-from-VS) reaches HS as the hypercall; 0-8 (the common exceptions
    # incl. ECALL-from-U/VU) and 12/13/15 (page faults) too.
    li   t0, 0xB5FF                  # bits 0-8,10,12,13,15
    csrw medeleg, t0
    # hedeleg (exceptions): of those, the ones a *guest* services itself (its own
    # VS-stage page faults 12/13/15 and ECALL-from-VU=8) are delegated on to VS.
    # ECALL-from-VS (10) is NOT delegatable to VS (the hypercall) and stays at HS.
    li   t0, 0xB1FF                  # bits 0-8,12,13,15
    csrw 0x602, t0                   # hedeleg
    # hideleg (interrupts): delegate the guest's VS software/timer/external
    # interrupts (positions 2/6/10) to VS so the guest takes its own ticks.
    li   t0, 0x444                   # bits 2,6,10
    csrw 0x603, t0                   # hideleg

    sfence.vma zero, zero            # make the page-table writes visible to walks

    # ---- MRET into HS-mode: MPP=S(01, bit11), MPV=0 (V=0, HS) ----
    li   t0, 0x800
    csrs mstatus, t0
    la   t0, hv_main
    csrw mepc, t0
    mret                             # -> HS-mode @ hv_main

hv_main:                             # HS-mode (V=0) — the hypervisor
    li   t0, CAP_LEN
    sw   zero, 0(t0)                 # capture length = 0
    # enter the guest: hstatus.SPV=1 (SRET -> V=1), sstatus.SPP=1 (S-level -> VS)
    li   t0, (1 << 7)
    csrs 0x600, t0                   # hstatus.SPV = 1
    li   t0, (1 << 8)
    csrs sstatus, t0                 # sstatus.SPP = 1
    la   t0, guest_entry
    csrw sepc, t0
    sret                             # -> VS-mode @ guest_entry

guest_entry:                         # VS-mode (V=1), GVA==GPA==HPA identity
    # SBI DBCN console_write(num_bytes=2, base_lo=&guest_msg, base_hi=0)
    li   a0, 2                       # num_bytes
    la   a1, guest_msg               # buffer (guest-physical == identity)
    li   a2, 0
    li   a6, 0                       # FID 0 = console_write
    li   a7, SBI_DBCN
    ecall                            # -> cause 10 -> HS
    # SBI SRST system_reset(type=shutdown, reason=0)
    li   a0, 0
    li   a1, 0
    li   a6, 0                       # FID 0 = system_reset
    li   a7, SBI_SRST
    ecall                            # -> HS verifies + tohost
1:  j    1b

guest_msg:
    .ascii "HI"
    .balign 4

hs_handler:                          # HS-mode trap handler (V=0)
    csrr t0, scause
    li   t1, 10                      # ECALL-from-VS (the only expected trap)
    bne  t0, t1, hs_unexpected
    li   t1, SBI_DBCN
    beq  a7, t1, sbi_dbcn
    li   t1, SBI_SRST
    beq  a7, t1, sbi_srst
    li   t1, SBI_BASE
    beq  a7, t1, sbi_ok              # probe extensions -> success
    j    sbi_err

sbi_dbcn:
    bnez a6, sbi_ok                  # only FID 0 (write) is handled; rest ok-stub
    # append a0 bytes from [a1] to CAP_BUF at CAP_LEN
    li   t2, CAP_BUF
    li   t3, CAP_LEN
    lw   t4, 0(t3)                   # current length
    add  t2, t2, t4                  # dest = CAP_BUF + len
    mv   t5, a1                      # src (guest buffer, identity)
    mv   t6, a0                      # remaining count
    beqz t6, .dbcn_done
.dbcn_loop:
    lb   t0, 0(t5)
    sb   t0, 0(t2)
    addi t5, t5, 1
    addi t2, t2, 1
    addi t6, t6, -1
    bnez t6, .dbcn_loop
.dbcn_done:
    add  t4, t4, a0                  # new length
    sw   t4, 0(t3)
    li   a0, 0                       # SBI_SUCCESS
    li   a1, 0
    j    sbi_resume

sbi_ok:
    li   a0, 0                       # SBI_SUCCESS
    li   a1, 0
    j    sbi_resume
sbi_err:
    li   a0, -2                      # SBI_ERR_NOT_SUPPORTED
    li   a1, 0
    j    sbi_resume

sbi_resume:
    csrr t0, sepc                    # skip the guest's ecall, resume in VS-mode
    addi t0, t0, 4
    csrw sepc, t0
    sret                             # hstatus.SPV=1 still -> V=1 guest

sbi_srst:                            # guest shutdown -> verify + signal PASS
    li   t0, CAP_LEN
    lw   t1, 0(t0)
    li   t2, 2
    bne  t1, t2, hs_badcon           # exactly 2 bytes captured?
    li   t0, CAP_BUF
    lb   t1, 0(t0)
    li   t2, 0x48                    # 'H'
    bne  t1, t2, hs_badcon
    lb   t1, 1(t0)
    li   t2, 0x49                    # 'I'
    bne  t1, t2, hs_badcon
    li   t0, 1                       # PASS
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

hs_unexpected:
    li   t0, 0x500
    csrr t1, scause
    or   t0, t0, t1
    li   t1, 0x80001000
    sw   t0, 0(t1)
2:  j    2b
hs_badcon:
    li   t0, 0x600
    li   t1, 0x80001000
    sw   t0, 0(t1)
3:  j    3b

    .balign 4
m_handler:                           # unexpected M-mode trap
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
