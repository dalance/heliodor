# Hart program of the N = 4 debug tests dbg4/dm_smp_select, dm_smp_group and
# dm_smp_stoptime (dmi/dm_smp_*.dmi), run by every hart. Each hart keeps its
# hartid in s2, waits for the script to write go, passes tpoint once (counted
# in s3) and counts in its own line of cnt until the script writes stop.
# Hart 0 then checks that every hart counted and writes tohost = 1; a failed
# check writes its number.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, trap
        csrw    mtvec, t0
        csrr    s2, mhartid
        li      s3, 0
        li      gp, 2
        la      t2, go
1:      ld      t3, 0(t2)
        beqz    t3, 1b
        .globl  tpoint
tpoint: addi    s3, s3, 1
        la      t2, cnt
        slli    t0, s2, 6
        add     t2, t2, t0
        la      t5, stop
2:      ld      t3, 0(t5)
        bnez    t3, 3f
        ld      t4, 0(t2)
        addi    t4, t4, 1
        sd      t4, 0(t2)
        j       2b
3:      bnez    s2, 5f
        li      gp, 3
        li      t0, 1
        bne     s3, t0, fail
        li      gp, 4
        la      t2, cnt
        li      t1, 4
4:      ld      t3, 0(t2)
        beqz    t3, fail
        addi    t2, t2, 64
        addi    t1, t1, -1
        bnez    t1, 4b
        li      gp, 1
        j       fail
5:      j       5b

fail:   la      t1, tohost
        sw      gp, 0(t1)
6:      j       6b

trap:   li      gp, 99
        j       fail

        .align  6
        .globl  go
go:     .dword  0
        .align  6
        .globl  stop
stop:   .dword  0
        .align  6
        .globl  cnt
cnt:    .zero   256

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
