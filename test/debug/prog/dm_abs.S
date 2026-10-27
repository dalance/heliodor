# Hart program of dbg/dm_abs (dmi/dm_abs.dmi). It parks in a one-instruction
# loop, where the script halts it and reads and writes registers with Access
# Register commands, then sets dpc to `done`, which checks the values the
# script wrote. tohost = 1 on success, else the number of the failed check.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, trap
        csrw    mtvec, t0
        csrw    mstatus, zero           # FS = Off
        li      s0, 0x0123456789abcdef
        li      s1, 0x7edcba9876543210
        li      a3, 0x33
        li      gp, 2
park:   j       park

done:   li      t0, 0x1122334455667788
        bne     a1, t0, fail
        addi    gp, gp, 1
        li      t0, 0x01234567deadbeef
        bne     s0, t0, fail
        addi    gp, gp, 1
        li      t0, 0x89abcdefcafef00d
        bne     s1, t0, fail
        addi    gp, gp, 1
        li      t0, 0x2468ace013579bdf
        csrr    t1, mscratch
        bne     t1, t0, fail
        addi    gp, gp, 1
        li      t0, 0x0123456789abcdef
        fmv.x.d t1, f5
        bne     t1, t0, fail
        addi    gp, gp, 1
        li      t0, 0x33                # a write ignored while cmderr was set
        bne     a3, t0, fail
        li      gp, 1
fail:   la      t1, tohost
        sw      gp, 0(t1)
1:      j       1b

trap:   li      gp, 99
        j       fail

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
