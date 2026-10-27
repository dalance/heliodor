# Hart program of dbg/dm_progbuf (dmi/dm_progbuf.dmi). It parks in a
# one-instruction loop, where the script halts it, runs the program buffer
# and writes buf through autoexecdata, then sets dpc to `done`, which checks
# buf. tohost = 1 on success, else the number of the failed check.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, trap
        csrw    mtvec, t0
        li      gp, 2
park:   j       park

done:   la      t2, buf
        li      t0, 0x1111111111111111
        ld      t1, 0(t2)
        bne     t1, t0, fail
        addi    gp, gp, 1
        li      t0, 0x2222222222222222
        ld      t1, 8(t2)
        bne     t1, t0, fail
        addi    gp, gp, 1
        li      t0, 0x3333333333333333
        ld      t1, 16(t2)
        bne     t1, t0, fail
        addi    gp, gp, 1
        ld      t1, 24(t2)
        bnez    t1, fail
        li      gp, 1
fail:   la      t1, tohost
        sw      gp, 0(t1)
1:      j       1b

trap:   li      gp, 99
        j       fail

        .align  6
        .globl  buf
buf:    .dword  0, 0, 0, 0

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
