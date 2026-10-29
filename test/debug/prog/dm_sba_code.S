# Hart program of dbg/dm_sba_code (dmi/dm_sba_code.dmi). It calls func once
# (a0 = 1, so func sits in the I-cache) and parks. The script halts it,
# rewrites func and puts an ebreak over bkpt through System Bus Access, and
# resumes it at after: func must now return 2 (the resume runs fence.i), the
# ebreak halts the hart, and after the script restores bkpt the program
# checks s1. tohost = 1 on success, else the number of the failed check.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, trap
        csrw    mtvec, t0
        li      gp, 2
        li      s1, 0
        call    func
        li      t0, 1
        bne     a0, t0, fail
park:   j       park

        .globl  after
after:  addi    gp, gp, 1
        call    func
        li      t0, 2
        bne     a0, t0, fail
        addi    gp, gp, 1
        .globl  bkpt
bkpt:   addi    s1, s1, 7
        li      t0, 7
        bne     s1, t0, fail
        li      gp, 1
fail:   la      t1, tohost
        sw      gp, 0(t1)
1:      j       1b

trap:   li      gp, 99
        j       fail

        .align  6
        .globl  func
func:   li      a0, 1
        ret

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
