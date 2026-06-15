# P10 Zihpm (hardware performance monitor) directed test.
#
# Runs under test_arch_common_harness (M-mode, riscv-tests tohost @ 0x80001000).
#
#   mhpmcounter3 counts event 5 (mem-port-busy) — a loop of loads/stores must
#                drive it > 0.
#   mhpmcounter4 selects event 0 (disabled) — it must stay frozen at 0 even
#                while the same loop runs.
#
# tohost @ 0x80001000:  1 = PASS, 3 = FAIL.

#define MHPMEVENT3   0x323
#define MHPMEVENT4   0x324
#define MHPMCOUNTER3 0xb03
#define MHPMCOUNTER4 0xb04

    .section .text.init
    .globl _start
_start:
    csrw    MHPMEVENT3, x0          # clear, then select...
    li      t0, 5
    csrw    MHPMEVENT3, t0          # counter3 <- event 5 (mem-port busy)
    csrw    MHPMEVENT4, x0          # counter4 <- event 0 (frozen)
    csrw    MHPMCOUNTER3, x0        # zero the counters
    csrw    MHPMCOUNTER4, x0

    li      t1, 64                  # generate memory traffic
    li      t2, 0x80002000          # scratch line (clear of code/tohost)
loop:
    sw      t1, 0(t2)
    lw      t3, 0(t2)
    addi    t1, t1, -1
    bnez    t1, loop

    csrr    t4, MHPMCOUNTER3        # mem-busy count — must be > 0
    csrr    t5, MHPMCOUNTER4        # frozen count   — must be 0
    beqz    t4, fail
    bnez    t5, fail

    li      t0, 1                   # PASS
    li      t1, 0x80001000
    sw      t0, 0(t1)
done:
    j       done

fail:
    li      t0, 3                   # FAIL
    li      t1, 0x80001000
    sw      t0, 0(t1)
fail_done:
    j       fail_done

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
