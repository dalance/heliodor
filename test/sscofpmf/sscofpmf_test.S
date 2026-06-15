# P10 Sscofpmf: hardware performance-monitor count overflow + mode filtering.
#
# Extends Zihpm. Exercises, in bare M-mode (event 5 = mem-port-busy, driven by a
# load loop — same event the Zihpm test validated):
#   A. mhpmevent3.MINH (bit 62) inhibits counting in M-mode; clearing it resumes.
#   B. A counter wrap sets mhpmevent3.OF (bit 63), pends the local counter-overflow
#      interrupt (LCOFI, mip/mie bit 13, cause 13), and shows up in scountovf.
#
# tohost @ 0x80001000: 1 = PASS, else = failing check id. Scratch DRAM 0x80002000.

#define MSTATUS      0x300
#define MIE          0x304
#define MTVEC        0x305
#define MCOUNTEREN   0x306
#define MCAUSE       0x342
#define MHPMEVENT3   0x323
#define MHPMCOUNTER3 0xb03
#define SCOUNTOVF    0xda0

    .section .text.init
    .globl _start
_start:
    la      t0, mtrap
    csrw    MTVEC, t0
    li      s5, 0x80002000          # scratch

    # ===== A. filtering: MINH inhibits M-mode counting =====
    li      t0, 5
    li      t1, 1
    slli    t1, t1, 62              # MINH (bit 62)
    or      t0, t0, t1
    csrw    MHPMEVENT3, t0          # event 5 | MINH
    csrw    MHPMCOUNTER3, x0
    li      t1, 64
A_loop:
    ld      t3, 0(s5)
    addi    t1, t1, -1
    bnez    t1, A_loop
    csrr    t4, MHPMCOUNTER3
    li      t6, 31
    bnez    t4, fail                # MINH in M-mode → counter must stay 0

    # clear MINH → counting resumes
    li      t0, 5
    csrw    MHPMEVENT3, t0
    csrw    MHPMCOUNTER3, x0
    li      t1, 64
B_loop:
    ld      t3, 0(s5)
    addi    t1, t1, -1
    bnez    t1, B_loop
    csrr    t4, MHPMCOUNTER3
    li      t6, 32
    beqz    t4, fail                # no MINH → counter must advance

    # ===== B. overflow → OF + LCOFI =====
    li      t0, 5
    csrw    MHPMEVENT3, t0          # event 5, OF clear
    li      t0, -1
    csrw    MHPMCOUNTER3, t0        # preload all-1s (next event wraps it)
    li      t0, 8
    csrw    MCOUNTEREN, t0          # mcounteren[3]=1 → scountovf bit3 visible
    li      t0, 1
    slli    t0, t0, 13
    csrw    MIE, t0                 # mie.LCOFIE (bit 13)
    csrsi   MSTATUS, 8              # mstatus.MIE (bit 3)
    li      t1, 64
C_loop:
    ld      t3, 0(s5)               # mem-busy event → counter wraps → LCOFI
    addi    t1, t1, -1
    bnez    t1, C_loop
    li      t6, 33                  # reached here without trapping → bug
    j       fail

mtrap:
    csrr    t6, MCAUSE
    li      t5, 1
    slli    t5, t5, 63
    ori     t5, t5, 13              # (1<<63) | 13  = LCOFI
    bne     t6, t5, fail_bad
    # OF bit (mhpmevent3 bit 63) must be set
    csrr    t0, MHPMEVENT3
    srli    t0, t0, 63
    li      t6, 34
    beqz    t0, fail
    # scountovf bit 3 must be set
    csrr    t0, SCOUNTOVF
    srli    t0, t0, 3
    andi    t0, t0, 1
    li      t6, 35
    beqz    t0, fail
    # PASS
    li      t0, 1
    li      t1, 0x80001000
    sw      t0, 0(t1)
1:  j       1b

fail_bad:
    li      t6, 36                  # trap with unexpected cause
fail:
    li      t1, 0x80001000
    sw      t6, 0(t1)
2:  j       2b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
