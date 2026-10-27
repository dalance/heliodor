# Writes tohost = 1, then spins: a hart for DMI scripts that only need it to run.
        .section .text.init
        .globl _start
_start:
        li      t0, 1
        la      t1, tohost
        sw      t0, 0(t1)
1:      addi    t2, t2, 1
        j       1b

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
