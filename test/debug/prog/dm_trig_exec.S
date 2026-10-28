# Hart program of dbg/dm_trig_exec (dmi/dm_trig_exec.dmi). It parks in a
# loop, where the script halts it, sets execute triggers and points dpc at one
# of the seg_* sequences; a matching instruction enters Debug Mode before it
# executes. Each instruction of a sequence adds 1 to a0, so a0 at the halt
# counts the instructions that ran. `done` writes tohost = 1.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, trap
        csrw    mtvec, t0
park:   j       park

        .globl  seg_eq, eq_tgt, seg_rvc, rvc_tgt, seg_st, st_tgt, seg_lin, region, lt_dest, lt_start
        .globl  seg_wp, wp_tgt, done

seg_eq: addi    a0, a0, 1
eq_tgt: addi    a0, a0, 1
        j       park

        .option rvc
seg_rvc:
        c.addi  a0, 1
rvc_tgt:
        c.addi  a0, 1
        c.addi  a0, 1
        .option norvc
        j       park

        # A 32-bit op at the last halfword of a 32-byte (and 16-byte) block,
        # carried into the next block.
        .balign 32
        .option rvc
seg_st: .rept   15
        c.addi  a0, 1
        .endr
        .option norvc
st_tgt: addi    a0, a0, 1
        j       park

        # Four ops below a 16-byte aligned region of four ops.
        .balign 16
seg_lin:
        .rept   4
        addi    a0, a0, 1
        .endr
region: .rept   4
        addi    a0, a0, 1
        .endr
        j       park

lt_dest:
        addi    a0, a0, 1
        j       park
lt_start:
        addi    a0, a0, 1
        j       lt_dest

        # The op after the taken branch runs only on the wrong path.
seg_wp: beq     zero, zero, 1f
wp_tgt: addi    a0, a0, 1
1:      addi    a1, a1, 1
        j       park

trap:   li      gp, 99
        j       fail

done:   li      gp, 1
fail:   la      t1, tohost
        sw      gp, 0(t1)
1:      j       1b

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
