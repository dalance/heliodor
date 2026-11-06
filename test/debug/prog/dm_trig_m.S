# Hart program of dbg/dm_trig_m (dmi/dm_trig_m.dmi): triggers set by M-mode
# software (dmode 0, action 0, the breakpoint exception). It waits until the
# script has set s9 (after giving trigger 1 to Debug Mode: dmode 1, execute
# at 0x1234), then checks the trigger CSRs, the reentrancy rule (an action-0
# trigger does not match in M while mstatus.MIE is 0, so not in the handler),
# execute, load and store breakpoints (cause 3, mepc, mtval), and an icount
# breakpoint in U-mode. It ends in an ebreak, which the script catches (dcsr.ebreakm);
# `done` writes tohost = 1. A failed check writes its number instead.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, handler
        csrw    mtvec, t0
wait:   beqz    s9, wait

        # The Debug Mode trigger is read-only to M-mode (spec dmode).
        li      gp, 2
        csrr    t0, tinfo
        li      t1, 0x01008048
        bne     t0, t1, fail
        li      gp, 3
        li      t0, 1
        csrw    tselect, t0
        csrr    t1, tselect
        bne     t0, t1, fail
        csrr    t2, tdata1
        csrw    tdata1, zero
        csrw    tdata2, zero
        csrr    t3, tdata1
        bne     t2, t3, fail
        csrr    t3, tdata2
        li      t1, 0x1234
        bne     t3, t1, fail
        li      t1, 0x6800000000001044
        bne     t2, t1, fail

        # dmode and action 1 are not writable outside Debug Mode.
        li      gp, 4
        csrw    tselect, zero
        li      t0, 0x6800000000001044
        csrw    tdata1, t0
        csrr    t1, tdata1
        li      t0, 0x6000000000000044
        bne     t0, t1, fail

        # Execute breakpoint: no match in M while mstatus.MIE = 0. mie is
        # 0, so MIE = 1 takes no interrupt.
        li      gp, 5
        csrw    mie, zero
        csrci   mstatus, 8
        li      s7, 4                       # the handler skips the op
        la      t0, bp1
        csrw    tdata2, t0
        jal     ra, bp_call
        bnez    s5, fail
        csrsi   mstatus, 8                  # MIE
        jal     ra, bp_call
        li      gp, 6
        li      t0, 1
        bne     s5, t0, fail
        li      t0, 3
        bne     s2, t0, fail
        la      t0, bp1
        bne     s3, t0, fail
        bne     s4, t0, fail                # mtval: the op's address
        li      gp, 7
        li      t0, 0x80                    # in the handler: MPIE = 1, MIE = 0
        bne     s6, t0, fail
        csrr    t0, mstatus                 # after mret: MIE = MPIE
        andi    t0, t0, 0x88
        li      t1, 0x88
        bne     t0, t1, fail
        bnez    a0, fail                    # bp1 did not run the second time
        li      gp, 8
        csrr    t0, tdata1
        li      t1, 0x6000000000400044      # hit
        bne     t0, t1, fail

        # Load breakpoint on a byte inside the access: mtval is the access.
        li      gp, 9
        la      a1, data
        addi    t0, a1, 2
        csrw    tdata2, t0
        li      t0, 0x6000000000000041      # m, load
        csrw    tdata1, t0
        li      a2, 77
bp_ld:  lw      a2, 0(a1)
        li      t0, 2
        bne     s5, t0, fail
        li      t0, 77
        bne     a2, t0, fail
        la      t0, bp_ld
        bne     s3, t0, fail
        bne     s4, a1, fail

        # Store breakpoint: memory unchanged.
        li      gp, 10
        li      t0, 0x6000000000000042      # m, store
        csrw    tdata1, t0
        li      t1, -1
bp_st:  sw      t1, 0(a1)
        li      t0, 3
        bne     s5, t0, fail
        la      t0, bp_st
        bne     s3, t0, fail
        bne     s4, a1, fail
        lw      t0, 0(a1)
        li      t1, 0x5555
        bne     t0, t1, fail

        # icount, action 0, U-mode only, count 2: the breakpoint is taken
        # before the third U-mode op (mepc), with mtval 0.
        li      gp, 11
        li      t0, -1
        csrw    pmpaddr0, t0
        li      t0, 0x1f                    # NAPOT, RWX
        csrw    pmpcfg0, t0
        li      t0, 0x3000000000000841      # icount, count 2, u; action 1 reads 0
        csrw    tdata1, t0
        li      s7, 0                       # resume at mepc
        la      s8, back
        la      t0, ucode
        csrw    mepc, t0
        li      t0, 0x1800
        csrc    mstatus, t0                 # MPP = U
        li      a0, 0
        mret
back:   li      gp, 12
        li      t0, 5
        bne     s5, t0, fail                # the breakpoint and the ecall
        li      t0, 3                       # ucode ran in full
        bne     a0, t0, fail
        li      gp, 13
        csrr    t0, tdata1
        li      t1, 0x3000000001000040      # hit, count 0, not pending, action 0
        bne     t0, t1, fail
fin:    ebreak

done:   li      gp, 1
fail:   la      t1, tohost
        sw      gp, 0(t1)
1:      j       1b

bp_call:
bp1:    addi    a0, a0, 1
        li      a0, 0
        ret

ucode:  addi    a0, a0, 1
        addi    a0, a0, 1
ubp:    addi    a0, a0, 1
        ecall

        # Records mcause, mepc, mtval and mstatus.MIE/MPIE, counts the traps, returns
        # to mepc + s7, or to s8 in M after an ecall from U.
handler:
        csrr    s2, mcause
        csrr    s3, mepc
        csrr    s4, mtval
        csrr    s6, mstatus
        andi    s6, s6, 0x88
        addi    s5, s5, 1
        li      t0, 8
        beq     s2, t0, from_u
        li      t0, 3
        bne     s2, t0, fail
        bnez    s7, 1f
        la      t0, ubp                     # the icount breakpoint
        bne     s3, t0, fail
        bnez    s4, fail
        csrr    t0, mstatus
        srli    t0, t0, 11
        andi    t0, t0, 3
        bnez    t0, fail                    # taken from U
1:      add     t0, s3, s7
        csrw    mepc, t0
        mret
from_u: csrw    mepc, s8
        li      t0, 0x1800
        csrs    mstatus, t0                 # MPP = M
        mret

        .balign 8
data:   .word   0x5555

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
