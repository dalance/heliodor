# Hart program of the N = 4 SBA coherence test dbg4/dm_smp_sba_coh
# (dmi/sba_coh4.dmi), run by every hart. Phase 1: all harts spin reading shr,
# so the line is shared by four L1s, until the script writes it through
# System Bus Access; the write must invalidate every copy. Phase 2: harts 1-3
# each count in their own line own + 64 * hartid (dirty in their L1) until
# the script writes the flag at +8 of that line, which must recall it; the
# hart then sets its byte of done, and hart 0, waiting for all three, writes
# tohost = 1. A failed check writes its number to tohost.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, trap
        csrw    mtvec, t0
        csrr    s0, mhartid
        li      gp, 2
        la      t2, shr
1:      ld      t3, 0(t2)
        beqz    t3, 1b
        li      t0, 0x0123456789abcdef
        bne     t3, t0, fail
        addi    gp, gp, 1
        bnez    s0, harts

        la      t2, done
        li      t0, 0x01010100
2:      lw      t3, 0(t2)
        bne     t3, t0, 2b
        li      gp, 1
        j       fail

harts:  la      t2, own
        slli    t0, s0, 6
        add     t2, t2, t0
3:      ld      t3, 8(t2)
        bnez    t3, 4f
        ld      t4, 0(t2)
        addi    t4, t4, 1
        sd      t4, 0(t2)
        j       3b
4:      li      t0, 0x77
        bne     t3, t0, fail
        la      t2, done
        add     t2, t2, s0
        li      t0, 1
        sb      t0, 0(t2)
5:      j       5b

fail:   la      t1, tohost
        sw      gp, 0(t1)
6:      j       6b

trap:   li      gp, 99
        j       fail

        .align  6
        .globl  shr
shr:    .dword  0
        .align  6
        .globl  done
done:   .dword  0
        .align  6
        .globl  own
own:    .zero   256

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
