# Phase 11-H5.2a: hypervisor with full GPR context save/restore + a guest taking
# a Sstc timer interrupt. The two capabilities a real Linux guest needs that the
# H5.1 trivial hypervisor lacked:
#   (1) the SBI handler PRESERVES all of the guest's registers except a0/a1 (SBI
#       binary convention) via an sscratch-based context save/restore, and
#   (2) the guest is preemptible by a hardware timer (Sstc-in-VS): the guest
#       programs stimecmp (-> vstimecmp) and takes a *supervisor timer interrupt*
#       (cause 5) into its own vstvec while running.
#
# Layering: M-mode _start enables Sstc-for-guest (menvcfg.STCE & henvcfg.STCE),
# sets up the G-stage gigapage + delegation + the context-save area (sscratch),
# and MRETs to the HS-mode hypervisor, which enters the guest (VS-mode).
#
# Guest flow (vsatp=Bare identity for this stage; guest paging is exercised by
# the hmini test and by a real guest's own page tables):
#   - set callee-saved s1=0xCAFE, s2=0xBEEF, then SBI DBCN console_write("P").
#     The hypervisor's handler clobbers every temporary while servicing it; if
#     the context save/restore is correct, s1/s2 survive -> proves (1).
#   - program a Sstc timer a short delta ahead, enable sie.STIE + sstatus.SIE,
#     and spin; the hardware raises VSTIP and the guest takes cause 5 in vstvec,
#     sets a flag, disarms the timer, and SRETs -> proves (2).
#   - SBI DBCN console_write("T"), then SBI SRST shutdown.
# The hypervisor captures the console ("PT") and, on shutdown, checks the guest
# reported context-OK + timer-OK and the console == "PT", then writes tohost=1.
#
# tohost @ 0x80001000: 1 = PASS; 0x6xx wrong console; 0x700 context not preserved;
# 0x800 timer didn't fire (guest spun); 0x5xx unexpected HS scause; M handler 0x2xx.
#
# CSR numbers: hgatp 0x680, vsatp 0x280, hstatus 0x600, menvcfg 0x30A,
# henvcfg 0x60A, time 0xC01, stimecmp 0x14D.

#define CAP_BUF     0x80004000
#define CAP_LEN     0x80004100
#define CTX_AREA    0x80005000      /* 32 * 8 = 256 bytes guest GPR save area */
#define GFLAGS      0x80004200      /* guest-reported status word */
#define SBI_DBCN    0x4442434E
#define SBI_SRST    0x53525354
#define SBI_BASE    0x10

    .section .text.init
    .globl _start
_start:                              # M-mode
    la   t0, m_handler
    csrw mtvec, t0
    la   t0, hs_handler
    csrw stvec, t0

    # ---- enable Sstc for the guest ----
    li   t0, 1
    slli t0, t0, 63                  # STCE (bit 63)
    csrs 0x30A, t0                   # menvcfg.STCE
    csrs 0x60A, t0                   # henvcfg.STCE
    csrw 0x605, zero                 # htimedelta = 0 (guest time == mtime)

    # ---- G-stage gigapage @ 0x80016000, vsatp Bare ----
    li   t0, 0x80016010
    li   t1, 0x200000DF
    sd   t1, 0(t0)
    li   t0, 0x8000000000080016
    csrw 0x680, t0                   # hgatp = Sv39x4
    csrw 0x280, zero                 # vsatp = Bare

    # ---- delegation ----
    li   t0, 0xB5FF                  # medeleg: 0-8,10,12,13,15
    csrw medeleg, t0
    li   t0, 0xB1FF                  # hedeleg: guest exceptions 0-8,12,13,15 -> VS
    csrw 0x602, t0
    li   t0, 0x444                   # hideleg: VS interrupts (2,6,10) -> VS
    csrw 0x603, t0

    # ---- context-save area pointer in sscratch (hypervisor's, not the guest's) ----
    li   t0, CTX_AREA
    csrw sscratch, t0

    sfence.vma zero, zero

    # ---- MRET into HS-mode ----
    li   t0, 0x800
    csrs mstatus, t0
    la   t0, hv_main
    csrw mepc, t0
    mret

hv_main:                             # HS-mode hypervisor
    li   t0, CAP_LEN
    sw   zero, 0(t0)
    li   t0, GFLAGS
    sw   zero, 0(t0)
    # enter guest
    li   t0, (1 << 7)
    csrs 0x600, t0                   # hstatus.SPV = 1
    li   t0, (1 << 8)
    csrs sstatus, t0                 # sstatus.SPP = 1
    la   t0, guest_entry
    csrw sepc, t0
    sret

# ============================================================================
# Guest (VS-mode, V=1). Uses its OWN trap vector (vstvec) for the timer.
# ============================================================================
guest_entry:
    la   t0, guest_tmr
    csrw stvec, t0                   # vstvec (guest timer handler)
    li   s1, 0xCAFE                  # callee-saved canaries
    li   s2, 0xBEEF
    # SBI DBCN console_write("P")
    li   a0, 1
    la   a1, gmsg_p
    li   a6, 0
    li   a7, SBI_DBCN
    ecall
    # verify the SBI call preserved s1/s2 (the hypervisor's context save)
    li   t0, 0xCAFE
    bne  s1, t0, g_ctx_fail
    li   t0, 0xBEEF
    bne  s2, t0, g_ctx_fail
    li   t0, GFLAGS                  # report context-OK (bit 0)
    li   t1, 1
    sw   t1, 0(t0)

    # set up a Sstc timer a short delta ahead
    li   s3, 0                       # tick flag
    csrr t0, 0xC01                   # time
    li   t1, 0x400
    add  t0, t0, t1
    csrw 0x14D, t0                   # stimecmp (-> vstimecmp)
    li   t0, (1 << 5)
    csrs sie, t0                     # sie.STIE
    li   t0, (1 << 1)
    csrs sstatus, t0                 # sstatus.SIE
    li   t1, 0xABCD
g_spin:
    bne  s3, t1, g_spin              # wait for the timer handler to set s3
    # timer fired -> report timer-OK (bit 1)
    li   t0, GFLAGS
    lw   t1, 0(t0)
    ori  t1, t1, 2
    sw   t1, 0(t0)
    # SBI DBCN console_write("T")
    li   a0, 1
    la   a1, gmsg_t
    li   a6, 0
    li   a7, SBI_DBCN
    ecall
    # SBI SRST shutdown
    li   a0, 0
    li   a1, 0
    li   a6, 0
    li   a7, SBI_SRST
    ecall
1:  j    1b

g_ctx_fail:                          # context not preserved -> shutdown w/ marker
    li   t0, GFLAGS
    li   t1, 0x700
    sw   t1, 0(t0)
    li   a0, 0
    li   a6, 0
    li   a7, SBI_SRST
    ecall
2:  j    2b

    .balign 4
guest_tmr:                           # guest's VS-mode timer handler (cause 5)
    # NB: must not clobber the spin loop's registers (s3 flag, t1 constant) —
    # this handler runs as an interrupt, so it uses t5/t6 only.
    csrr t5, scause
    bgez t5, gt_unexpected           # must be an interrupt
    andi t5, t5, 0xff
    li   t6, 5                       # supervisor timer interrupt
    bne  t5, t6, gt_unexpected
    li   t5, -1                      # disarm (level-triggered)
    csrw 0x14D, t5
    li   s3, 0xABCD                  # flag the spin loop
    sret
gt_unexpected:
    li   t0, GFLAGS
    li   t1, 0x900
    sw   t1, 0(t0)
    li   a0, 0
    li   a6, 0
    li   a7, SBI_SRST
    ecall
3:  j    3b

gmsg_p: .ascii "P"
gmsg_t: .ascii "T"
    .balign 4

# ============================================================================
# HS-mode trap handler with full guest GPR context save/restore.
# sscratch holds CTX_AREA on entry; we swap it with the guest sp.
# ============================================================================
    .balign 4
hs_handler:
    csrrw sp, sscratch, sp           # sp = CTX_AREA, sscratch = guest sp
    sd   x1,  1*8(sp)
    sd   x3,  3*8(sp)
    sd   x4,  4*8(sp)
    sd   x5,  5*8(sp)
    sd   x6,  6*8(sp)
    sd   x7,  7*8(sp)
    sd   x8,  8*8(sp)
    sd   x9,  9*8(sp)
    sd   x10, 10*8(sp)
    sd   x11, 11*8(sp)
    sd   x12, 12*8(sp)
    sd   x13, 13*8(sp)
    sd   x14, 14*8(sp)
    sd   x15, 15*8(sp)
    sd   x16, 16*8(sp)
    sd   x17, 17*8(sp)
    sd   x18, 18*8(sp)
    sd   x19, 19*8(sp)
    sd   x20, 20*8(sp)
    sd   x21, 21*8(sp)
    sd   x22, 22*8(sp)
    sd   x23, 23*8(sp)
    sd   x24, 24*8(sp)
    sd   x25, 25*8(sp)
    sd   x26, 26*8(sp)
    sd   x27, 27*8(sp)
    sd   x28, 28*8(sp)
    sd   x29, 29*8(sp)
    sd   x30, 30*8(sp)
    sd   x31, 31*8(sp)
    csrr t0, sscratch                # guest sp
    sd   t0,  2*8(sp)
    csrw sscratch, sp                # restore sscratch = CTX_AREA for the NEXT trap
                                     # (sp still points at CTX_AREA here)

    # --- service the trap (free to clobber; a7/a6/a0/a1 read from saved frame) ---
    csrr t0, scause
    li   t1, 10
    bne  t0, t1, hs_unexpected
    ld   a7, 17*8(sp)                # SBI EID
    ld   a6, 16*8(sp)                # SBI FID
    li   t1, SBI_DBCN
    beq  a7, t1, h_dbcn
    li   t1, SBI_SRST
    beq  a7, t1, h_srst
    li   t1, SBI_BASE
    beq  a7, t1, h_ok
    li   t2, -2                      # NOT_SUPPORTED
    sd   t2, 10*8(sp)                # ret a0
    sd   zero, 11*8(sp)              # ret a1
    j    h_resume

h_dbcn:
    bnez a6, h_ok                    # only FID 0 (write)
    ld   t5, 11*8(sp)                # a1 = guest buffer (identity)
    ld   t6, 10*8(sp)                # a0 = num_bytes
    li   t2, CAP_BUF
    li   t3, CAP_LEN
    lw   t4, 0(t3)
    add  t2, t2, t4
    beqz t6, h_dbcn_done
h_dbcn_loop:
    lb   t0, 0(t5)
    sb   t0, 0(t2)
    addi t5, t5, 1
    addi t2, t2, 1
    addi t6, t6, -1
    bnez t6, h_dbcn_loop
h_dbcn_done:
    ld   t6, 10*8(sp)
    add  t4, t4, t6
    sw   t4, 0(t3)
h_ok:
    sd   zero, 10*8(sp)              # a0 = SBI_SUCCESS
    sd   zero, 11*8(sp)              # a1 = 0
h_resume:
    csrr t0, sepc                    # skip the ecall
    addi t0, t0, 4
    csrw sepc, t0
    # restore guest GPRs
    ld   x1,  1*8(sp)
    ld   x3,  3*8(sp)
    ld   x4,  4*8(sp)
    ld   x5,  5*8(sp)
    ld   x6,  6*8(sp)
    ld   x7,  7*8(sp)
    ld   x8,  8*8(sp)
    ld   x9,  9*8(sp)
    ld   x10, 10*8(sp)
    ld   x11, 11*8(sp)
    ld   x12, 12*8(sp)
    ld   x13, 13*8(sp)
    ld   x14, 14*8(sp)
    ld   x15, 15*8(sp)
    ld   x16, 16*8(sp)
    ld   x17, 17*8(sp)
    ld   x18, 18*8(sp)
    ld   x19, 19*8(sp)
    ld   x20, 20*8(sp)
    ld   x21, 21*8(sp)
    ld   x22, 22*8(sp)
    ld   x23, 23*8(sp)
    ld   x24, 24*8(sp)
    ld   x25, 25*8(sp)
    ld   x26, 26*8(sp)
    ld   x27, 27*8(sp)
    ld   x28, 28*8(sp)
    ld   x29, 29*8(sp)
    ld   x30, 30*8(sp)
    ld   x31, 31*8(sp)
    ld   x2,  2*8(sp)                # guest sp (last; restores sp)
    sret

h_srst:                              # guest shutdown -> verify everything
    li   t0, GFLAGS
    lw   t1, 0(t0)
    li   t2, 3                       # ctx-OK(1) | timer-OK(2)
    bne  t1, t2, hs_gflags_fail
    li   t0, CAP_LEN
    lw   t1, 0(t0)
    li   t2, 2                       # "PT"
    bne  t1, t2, hs_badcon
    li   t0, CAP_BUF
    lb   t1, 0(t0)
    li   t2, 0x50                    # 'P'
    bne  t1, t2, hs_badcon
    lb   t1, 1(t0)
    li   t2, 0x54                    # 'T'
    bne  t1, t2, hs_badcon
    li   t0, 1                       # PASS
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

hs_gflags_fail:                      # t1 holds the bad guest-flags word (0x7xx/0x9xx)
    li   t2, 0x80001000
    sw   t1, 0(t2)
4:  j    4b
hs_badcon:
    li   t0, 0x600
    li   t1, 0x80001000
    sw   t0, 0(t1)
5:  j    5b
hs_unexpected:
    li   t0, 0x500
    csrr t1, scause
    or   t0, t0, t1
    li   t1, 0x80001000
    sw   t0, 0(t1)
6:  j    6b

    .balign 4
m_handler:
    csrr t6, mcause
    ori  t6, t6, 0x200
    li   t1, 0x80001000
    sw   t6, 0(t1)
7:  j    7b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
