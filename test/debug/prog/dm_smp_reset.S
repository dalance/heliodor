# Hart program of dbg4/dm_smp_reset (dmi/dm_smp_reset.dmi), run by every
# hart. Each start increments the hart's line of boots, then the hart waits
# for go and adds 1 to shared and to its own line of own with amoadd until
# the script writes stop. It then sets its line of done; hart 0 waits for the
# others and checks that shared - (own[0] + ... + own[3]) is between 0 and
# MAX_CUT: a reset may land between a hart's two amoadds, and the script
# resets harts 1, 2 and 3 once each while the others count. tohost = 1 on
# success, else the number of the failed check.

#define MAX_CUT 3

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, trap
        csrw    mtvec, t0
        csrr    s2, mhartid
        slli    s4, s2, 6
        la      t0, boots
        add     t0, t0, s4
        ld      t1, 0(t0)
        addi    t1, t1, 1
        sd      t1, 0(t0)
        la      t2, go
1:      ld      t3, 0(t2)
        beqz    t3, 1b
        la      s1, shared
        la      t2, own
        add     t2, t2, s4
        la      t5, stop
        li      t6, 1
2:      amoadd.d x0, t6, (s1)
        amoadd.d x0, t6, (t2)
        ld      t3, 0(t5)
        beqz    t3, 2b
        fence   rw, w
        la      t0, done
        add     t0, t0, s4
        sd      t6, 0(t0)
        bnez    s2, 5f
        li      gp, 2
        la      t0, done
        li      t1, 4
3:      ld      t3, 0(t0)
        beqz    t3, 3b
        addi    t0, t0, 64
        addi    t1, t1, -1
        bnez    t1, 3b
        fence   r, r
        la      t0, own
        li      t1, 4
        li      t4, 0
4:      ld      t3, 0(t0)
        beqz    t3, fail                    # every hart counted
        add     t4, t4, t3
        addi    t0, t0, 64
        addi    t1, t1, -1
        bnez    t1, 4b
        li      gp, 3
        ld      t3, 0(s1)
        sub     t3, t3, t4
        bltz    t3, fail
        li      gp, 4
        li      t1, MAX_CUT
        bgt     t3, t1, fail
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
        .globl  shared
shared: .dword  0
        .align  6
        .globl  boots
boots:  .zero   256
        .globl  own
own:    .zero   256
        .globl  done
done:   .zero   256

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
