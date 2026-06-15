# P10 Sstc (supervisor timer compare) directed test.
#
# Runs under test_arch_common_harness with MTIME_EN=1 (i_mtime is a free-running
# per-cycle counter), the standard riscv-tests tohost protocol at 0x80001000.
#
# Phase A (negative — STIP gating):
#   menvcfg.STCE = 0, stimecmp = 0 (already <= mtime), M-mode with mie.STIE and
#   mstatus.MIE enabled. The supervisor timer interrupt MUST NOT fire: with the
#   feature disabled, mip.STIP stays software-controlled (0). A spurious trap to
#   mtvec (= fail) would write tohost = 3.
#
# Phase B (positive — Sstc S-mode timer):
#   menvcfg.STCE = 1, delegate the supervisor timer interrupt (cause 5) to S,
#   enter S-mode, program stimecmp = time + margin. Hardware raises mip.STIP when
#   mtime >= stimecmp; the supervisor timer interrupt is taken to s_handler,
#   which checks scause == (interrupt | 5) and writes tohost = 1 (PASS).
#
# tohost @ 0x80001000 (word index 1024):  1 = PASS, 3 = FAIL.

#define STIMECMP 0x14d
#define MENVCFG  0x30a
#define TIME     0xc01

    .section .text.init
    .globl _start
_start:
    # ---- Phase A: STIP gating with STCE = 0 ----
    csrw    MENVCFG, x0             # STCE = 0 (Sstc disabled)
    csrw    STIMECMP, x0            # stimecmp = 0 (mtime exceeds it at once)
    la      t0, fail
    csrw    mtvec, t0               # any M-mode trap during phase A => fail
    li      t0, (1 << 5)
    csrw    mie, t0                 # mie.STIE
    li      t0, (1 << 3)
    csrs    mstatus, t0             # mstatus.MIE
    li      t1, 200
pa_loop:
    addi    t1, t1, -1
    bnez    t1, pa_loop             # spin; STIP must stay 0 (STCE = 0)
    li      t0, (1 << 3)
    csrc    mstatus, t0             # clear MIE before phase B

    # ---- Phase B: Sstc S-mode timer ----
    li      t0, 1
    slli    t0, t0, 63
    csrw    MENVCFG, t0             # STCE = 1 (Sstc enabled)
    li      t0, (1 << 5)
    csrw    mideleg, t0             # delegate supervisor timer (cause 5) to S
    li      t0, -1
    csrw    STIMECMP, t0            # park high until S-mode programs it
    la      t0, s_handler
    csrw    stvec, t0
    li      t0, (1 << 5)
    csrw    sie, t0                 # sie.STIE (S view of mie[5])
    li      t0, (1 << 1)
    csrs    sstatus, t0             # sstatus.SIE
    li      t0, (1 << 11)
    csrs    mstatus, t0             # MPP = 01 (S) for mret
    la      t0, s_main
    csrw    mepc, t0
    mret

s_main:                            # runs in S-mode
    csrr    t0, TIME               # current mtime
    li      t1, 400
    add     t0, t0, t1
    csrw    STIMECMP, t0           # fire ~400 cycles from now
sm_loop:
    j       sm_loop                # wait for the supervisor timer interrupt

s_handler:                         # S-mode supervisor-timer trap
    csrr    t0, scause
    li      t1, 1
    slli    t1, t1, 63
    ori     t1, t1, 5              # expected scause = (1 << 63) | 5
    bne     t0, t1, fail
    li      t0, 1                  # PASS
    li      t1, 0x80001000
    sw      t0, 0(t1)
done:
    j       done

fail:
    li      t0, 3                  # FAIL
    li      t1, 0x80001000
    sw      t0, 0(t1)
fail_done:
    j       fail_done

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
