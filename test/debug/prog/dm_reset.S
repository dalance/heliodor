# Hart program of dbg/dm_reset (dmi/dm_reset.dmi). Every start increments
# boots, then the program spins, reading a new line on every pass, until the
# script writes 9 to phase through System Bus Access, and writes tohost = 1.
# The script resets the hart with ndmreset and hartreset and reads boots,
# phase and keep through System Bus Access.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, boots
        ld      t1, 0(t0)
        addi    t1, t1, 1
        sd      t1, 0(t0)
        la      t0, phase
        li      t2, 9
        li      a4, 0x80200000
        li      a3, 0x80100000
spin:   ld      t1, 0(t0)
        ld      t4, 0(a3)                   # a miss on every pass: the quiesce waits for it
        addi    a3, a3, 64
        bltu    a3, a4, 1f
        li      a3, 0x80100000
1:      bne     t1, t2, spin
        li      gp, 1
        la      t1, tohost
        sw      gp, 0(t1)
1:      j       1b

        .align  6
        .globl  phase
phase:  .dword  0
        .align  6
        .globl  boots
boots:  .dword  0
        .align  6
        .globl  keep
keep:   .dword  0

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
