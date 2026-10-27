# Hart program of dbg/dm_counters (dmi/dm_counters.dmi). It counts in a loop,
# where the script halts it and reads mcycle, minstret, time and the CLINT
# mtime with dcsr.stopcount and dcsr.stoptime off and on, then sets dpc to
# `done`, which checks that mtime runs again. tohost = 1 on success, else the
# number of the failed check.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, trap
        csrw    mtvec, t0
        li      gp, 2
park:   addi    a5, a5, 1
        j       park

done:   rdtime  t0
        li      t1, 200
1:      addi    t1, t1, -1
        bnez    t1, 1b
        rdtime  t2
        beq     t0, t2, fail
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
