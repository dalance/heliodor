# Hart program of dbg/dm_sba (dmi/dm_sba.dmi). It stores a pattern to src
# and zeroes dst, so both lines sit dirty in its D-cache, then spins
# incrementing the counter in hot while hot's flag is 0, keeping that line
# dirty too. The script reads src and hot and writes dst and the flag through
# System Bus Access; the program then checks dst. tohost = 1 on success, or
# the number of the failed check.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, trap
        csrw    mtvec, t0
        li      gp, 2
        la      t0, src
        li      t1, 0x0123456789abcdef
        sd      t1, 0(t0)
        li      t1, 0xfedcba9876543210
        sd      t1, 8(t0)
        la      t0, dst
        sd      zero, 0(t0)
        sd      zero, 8(t0)
        sd      zero, 16(t0)
        sd      zero, 24(t0)
        la      t2, hot
spin:   ld      t3, 8(t2)
        bnez    t3, go
        ld      t4, 0(t2)
        addi    t4, t4, 1
        sd      t4, 0(t2)
        j       spin

go:     li      t0, 0x5a5a
        bne     t3, t0, fail
        addi    gp, gp, 1
        la      t2, dst
        li      t0, 0x1122334455667788
        ld      t1, 0(t2)
        bne     t1, t0, fail
        addi    gp, gp, 1
        li      t0, 0xcafef00dbeef00a5
        ld      t1, 8(t2)
        bne     t1, t0, fail
        addi    gp, gp, 1
        li      t0, 0x0000000200000001
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
        .globl  src
src:    .dword  0, 0
        .align  6
        .globl  dst
dst:    .dword  0, 0, 0, 0
        .align  6
        .globl  hot
hot:    .dword  0, 0

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
