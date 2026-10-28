# Hart program of dbg/dm_icount (dmi/dm_icount.dmi). It parks in a loop,
# where the script halts it, sets an icount trigger and points dpc at seg_cnt
# (eight increments of a0, then an ebreak), seg_trap (a trap whose handler
# counts in a1) or seg_u (run in U-mode). `done` writes tohost = 1.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, handler
        csrw    mtvec, t0
park:   j       park

        .globl  seg_cnt, seg_trap, seg_u, handler, done
seg_cnt:
        .rept   8
        addi    a0, a0, 1
        .endr
        ebreak
seg_trap:
        addi    a0, a0, 1
        .word   0
        ebreak
seg_u:  .rept   4
        addi    a0, a0, 1
        .endr
        ecall

handler:
        addi    a1, a1, 1
        ebreak

done:   li      gp, 1
        la      t1, tohost
        sw      gp, 0(t1)
1:      j       1b

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
