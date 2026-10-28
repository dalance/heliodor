# Hart program of dbg/dm_trig_step (dmi/dm_trig_step.dmi). It parks in a
# loop, where the script halts it and single-steps through seg (an
# increment of a0, a load from the address in a1 into a2, an increment)
# with execute, load and icount triggers set. `done` writes tohost = 1.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, trap
        csrw    mtvec, t0
park:   j       park

        .globl  seg, data, done
seg:    addi    a0, a0, 1
        lw      a2, 0(a1)
        addi    a0, a0, 1
        ebreak

trap:   li      gp, 99
        j       fail

done:   li      gp, 1
fail:   la      t1, tohost
        sw      gp, 0(t1)
1:      j       1b

        .balign 8
data:   .word   0x77

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
