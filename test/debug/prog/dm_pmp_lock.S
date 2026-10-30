# Hart program of dbg/dm_pmp_lock (dmi/dm_pmp_lock.dmi). PMP entry 0 is
# locked over both debug memory regions with no permission, which binds M as
# well; the debugger must still halt the hart, run abstract commands and the
# program buffer, and resume it (design doc D.8). Outside Debug Mode a load
# from debug memory still faults. A counting loop then runs while the script
# halts and resumes the hart; the program buffer adds to s3. tohost = 1 on
# success, else the number of the failed check.
#define DM_DATA 0x5000
#define LOOP_N  20000

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, trap
        csrw    mtvec, t0
        li      t0, (0x4000 >> 2) | ((0x2000 >> 3) - 1)
        csrw    pmpaddr0, t0
        li      t0, 0x98                    # L, NAPOT, no R/W/X
        csrw    pmpcfg0, t0
        csrr    t1, pmpcfg0
        li      gp, 2
        bne     t0, t1, fail
        li      gp, 3
        la      a2, 1f
        li      t2, DM_DATA
        lw      t1, 0(t2)                   # access fault (cause 5)
        j       fail
1:      li      gp, 4
        li      s0, 0
        li      s1, 0
        li      s3, 0
        li      t2, LOOP_N
loop:   addi    s0, s0, 1
        addi    s1, s1, 2
        bne     s0, t2, loop
        slli    t3, t2, 1
        bne     s1, t3, fail
        li      gp, 5
        li      t3, 3
        bne     s3, t3, fail                # the program buffer ran once per halt
        li      gp, 1
fail:   la      t1, tohost
        sw      gp, 0(t1)
1:      j       1b
trap:   csrr    t0, mcause
        li      t1, 5
        bne     t0, t1, fail
        csrw    mepc, a2
        mret

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
