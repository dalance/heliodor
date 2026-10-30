# Cross-check of the action-0 trigger cases against spike (design doc U35):
# M-mode software sets one trigger (tselect 0, dmode 0, action 0) per case,
# runs one operation and records what the breakpoint handler saw. Each case
# owns a 4-dword slot {mcause, mepc, mtval, case id}; a case
# that does not trap leaves {-1, -1, -1, id}. The program sets `done` when
# all cases have run. run_xcheck.sh reads the slots from both simulators.

        .option norvc
        .section .text.init
        .globl _start
_start:
        # M-mode action-0 triggers need tcontrol.mte where tcontrol exists
        # (heliodor) and mstatus.MIE where it does not (spike); set both.
        # mie stays 0, so no interrupt is taken.
        la      t0, 1f
        csrw    mtvec, t0
        li      t0, 8
        csrw    tcontrol, t0                # traps to 1f without tcontrol
        .balign 4
1:      la      t0, handler
        csrw    mtvec, t0
        csrw    mie, zero
        csrsi   mstatus, 8
        csrw    tselect, zero
        la      s11, sig
        la      s10, data
        li      s9, 0                       # case id

.macro SLOT
        addi    s9, s9, 1
        li      t0, -1
        sd      t0, 0(s11)
        sd      t0, 8(s11)
        sd      t0, 16(s11)
        sd      s9, 24(s11)
.endm
.macro ARM t1v, t2v
        li      t0, \t1v
        csrw    tdata1, zero
        csrw    tdata2, \t2v
        csrw    tdata1, t0
.endm
.macro NEXT
        csrw    tdata1, zero
        addi    s11, s11, 32
.endm

        # 1: execute, 32-bit op
        SLOT
        li      s7, 4
        la      t1, x1
        ARM     0x6000000000000044, t1
x1:     addi    a0, a0, 1
        NEXT
        # 2: execute, 16-bit op at an odd halfword
        SLOT
        li      s7, 2
        la      t1, x2
        ARM     0x6000000000000044, t1
        .option rvc
        c.nop
x2:     c.addi  a0, 1
        .option norvc
        NEXT
        # 3: load, byte 2 of a word load
        SLOT
        li      s7, 4
        addi    t1, s10, 2
        ARM     0x6000000000000041, t1
        lw      a0, 0(s10)
        NEXT
        # 4: store, byte 5 of a dword store
        SLOT
        addi    t1, s10, 5
        ARM     0x6000000000000042, t1
        sd      zero, 0(s10)
        NEXT
        # 5: load trigger on a load at the byte after the access (no match)
        SLOT
        addi    t1, s10, 4
        ARM     0x6000000000000041, t1
        lw      a0, 0(s10)
        NEXT
        # 6: AMO, load bit only
        SLOT
        addi    t1, s10, 8
        ARM     0x6000000000000041, t1
        addi    t2, s10, 8
        amoadd.d a0, zero, (t2)
        NEXT
        # 7: AMO, store bit only
        SLOT
        addi    t1, s10, 8
        ARM     0x6000000000000042, t1
        addi    t2, s10, 8
        amoadd.d a0, zero, (t2)
        NEXT
        # 8: LR, load bit
        SLOT
        addi    t1, s10, 16
        ARM     0x6000000000000041, t1
        addi    t2, s10, 16
        lr.d    a0, (t2)
        NEXT
        # 9: SC, store bit (no reservation)
        SLOT
        addi    t1, s10, 16
        ARM     0x6000000000000042, t1
        addi    t2, s10, 16
        sc.d    a0, zero, (t2)
        NEXT
        # 10: LR, store bit only
        SLOT
        addi    t1, s10, 16
        ARM     0x6000000000000042, t1
        addi    t2, s10, 16
        lr.d    a0, (t2)
        NEXT
        # 11: cbo.zero, store bit, tdata2 inside the line
        SLOT
        addi    t1, s10, 72
        ARM     0x6000000000000042, t1
        addi    t2, s10, 64
        cbo.zero (t2)
        NEXT
        # 12: cbo.zero, load bit only
        SLOT
        addi    t1, s10, 72
        ARM     0x6000000000000041, t1
        addi    t2, s10, 64
        cbo.zero (t2)
        NEXT
        # 13: cbo.clean, store bit
        SLOT
        addi    t1, s10, 72
        ARM     0x6000000000000042, t1
        addi    t2, s10, 64
        cbo.clean (t2)
        NEXT
        # 14: cbo.clean, load bit only
        SLOT
        addi    t1, s10, 72
        ARM     0x6000000000000041, t1
        addi    t2, s10, 64
        cbo.clean (t2)
        NEXT
        # 15: cbo.flush, store bit
        SLOT
        addi    t1, s10, 72
        ARM     0x6000000000000042, t1
        addi    t2, s10, 64
        cbo.flush (t2)
        NEXT
        # 16: cbo.inval, store bit
        SLOT
        addi    t1, s10, 72
        ARM     0x6000000000000042, t1
        addi    t2, s10, 64
        cbo.inval (t2)
        NEXT
        # 17: cbo.zero with rs1 in the middle of the line, tdata2 at its start
        SLOT
        addi    t1, s10, 64
        ARM     0x6000000000000042, t1
        addi    t2, s10, 88
        cbo.zero (t2)
        NEXT
        # 18: line-crossing dword load, tdata2 in the upper line
        SLOT
        addi    t1, s10, 194
        ARM     0x6000000000000041, t1
        addi    t2, s10, 188
        ld      a0, 0(t2)
        NEXT
        # 19: line-crossing dword load, tdata2 in the lower line
        SLOT
        addi    t1, s10, 189
        ARM     0x6000000000000041, t1
        addi    t2, s10, 188
        ld      a0, 0(t2)
        NEXT
        # 20: match 2 (>=): access [data+32, data+40), tdata2 = data+39
        SLOT
        addi    t1, s10, 39
        ARM     0x6000000000000141, t1
        ld      a0, 32(s10)
        NEXT
        # 21: match 3 (<): access [data+32, data+40), tdata2 = data+33
        SLOT
        addi    t1, s10, 33
        ARM     0x60000000000001c1, t1
        ld      a0, 32(s10)
        NEXT
        # 22: match 1 (NAPOT 16 bytes at data+48), word access at data+60
        SLOT
        addi    t1, s10, 55
        ARM     0x60000000000000c1, t1
        lw      a0, 60(s10)
        NEXT
        # 23: icount 1 in M (action 0)
        SLOT
        li      s7, 0
        li      t0, 0x3000000000000600
        csrw    tdata1, t0
        addi    a0, a0, 1
        addi    a0, a0, 1
        addi    a0, a0, 1
        NEXT

        la      t0, done
        li      t1, 1
        sw      t1, 0(t0)
1:      j       1b

# Records mcause, mepc and mtval, disables the
# trigger and skips the operation by s7 bytes. mret restores mte.
        .balign 4
handler:
        csrr    t0, mcause
        sd      t0, 0(s11)
        csrr    t0, mepc
        sd      t0, 8(s11)
        add     t0, t0, s7
        csrw    mepc, t0
        csrr    t0, mtval
        sd      t0, 16(s11)
        csrw    tdata1, zero
        mret

        .balign 4096
data:   .space  256
        .balign 64
sig:    .space  32 * 32
done:   .word   0
