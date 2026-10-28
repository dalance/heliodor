# Hart program of dbg/dm_trig_ldst (dmi/dm_trig_ldst.dmi). It parks in a
# loop, where the script halts it, sets load/store triggers and points dpc at
# one of the seg_* accesses (address in a0, store data in a1). Every sequence
# ends in an ebreak, so with dcsr.ebreakm an access that does not match halts
# right after it (cause 1) and a matching one halts before it (cause 2).
# seg_chk reads memory back into a3. buf holds word i = 0x11110000 + i, and
# the CLINT mtimecmp of hart 0 is all ones. `done` writes tohost = 1.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, trap
        csrw    mtvec, t0
        li      t0, 0x02004000
        li      t1, -1
        sd      t1, 0(t0)
park:   j       park

        .globl  seg_lw, seg_sw, seg_ld, seg_amo, seg_lr, seg_sc, seg_cbz, seg_chk, buf, done
seg_lw: lw      a2, 0(a0)
        ebreak
seg_sw: sw      a1, 0(a0)
        ebreak
seg_ld: ld      a2, 0(a0)
        ebreak
seg_amo:
        amoadd.w a2, a1, (a0)
        ebreak
seg_lr: lr.w    a2, (a0)
        ebreak
seg_sc: sc.w    a2, a1, (a0)
        ebreak
seg_cbz:
        .insn   i 0x0f, 2, x0, a0, 4        # cbo.zero (a0)
        ebreak
seg_chk:
        lw      a3, 0(a0)
        ebreak

trap:   li      gp, 99
        j       fail

done:   li      gp, 1
fail:   la      t1, tohost
        sw      gp, 0(t1)
1:      j       1b

        .balign 64
buf:
        .set    i, 0
        .rept   32
        .word   0x11110000 + i
        .set    i, i + 1
        .endr

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
