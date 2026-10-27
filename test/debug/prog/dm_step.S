# Hart program of dbg/dm_step (dmi/dm_step.dmi). It parks in a loop, where the
# script halts it, points dpc at one of the seg_* sequences and single-steps
# through it (design doc D.5). The mtimecmp of hart 0 is 0, so the timer
# interrupt is pending whenever the script enables it. `done` writes
# tohost = 1.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, handler
        csrw    mtvec, t0
        csrw    mie, zero
        li      t0, 0x02004000
        sd      zero, 0(t0)
park:   j       park

        .globl  seg_alu, seg_trap, seg_br, br_tgt, j_tgt, seg_wfi, seg_csr, seg_io, seg_irq, seg_eb
seg_alu:
        addi    a0, a0, 1
        addi    a1, a1, 1
        addi    a2, a2, 1
        addi    a3, a3, 1
        j       park
seg_trap:
        .word   0
        j       park
seg_br: beq     zero, zero, br_tgt
        j       park
br_tgt: jal     ra, j_tgt
        j       park
j_tgt:  jalr    zero, 0(ra)
seg_wfi:
        wfi
        j       park
seg_csr:
        csrw    mscratch, a0
        j       park
seg_io: sd      a0, 0(a1)
        ld      a2, 0(a1)
        j       park
seg_irq:
        addi    a0, a0, 1
        addi    a0, a0, 1
        j       park
seg_eb: ebreak
        j       park

handler:
        j       handler

done:   li      gp, 1
        la      t1, tohost
        sw      gp, 0(t1)
1:      j       1b

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
