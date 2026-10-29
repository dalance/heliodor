# Hart program of the N = 2 SBA coherence test (dmi/sba_coh2.dmi), run by
# both harts. Phase 1: both spin reading shr, so the line is shared by two
# L1s, until the script writes it through System Bus Access; the write must
# invalidate both copies. Phase 2: hart 1 spins incrementing own's counter
# (the line dirty in its L1) until the script writes own's flag, which must
# recall the line from hart 1; hart 1 then sets done1, and hart 0, waiting
# for it, writes tohost = 1. A failed check writes its number to tohost.

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
        bnez    s0, hart1

        la      t2, done1
2:      ld      t3, 0(t2)
        beqz    t3, 2b
        li      gp, 1
        j       fail

hart1:  la      t2, own
3:      ld      t3, 8(t2)
        bnez    t3, 4f
        ld      t4, 0(t2)
        addi    t4, t4, 1
        sd      t4, 0(t2)
        j       3b
4:      li      t0, 0x77
        bne     t3, t0, fail
        la      t2, done1
        li      t0, 1
        sd      t0, 0(t2)
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
        .globl  own
own:    .dword  0, 0
        .align  6
        .globl  done1
done1:  .dword  0

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
