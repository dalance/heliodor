# A dense stream of INDEPENDENT double FMAs, so several sit in the FP issue queue at
# once and freed low slots are refilled while an older FMA is still in flight. That is
# the shape that lets the queue present a different FMA mid-flight; a multi-cycle FMA
# that reads its writeback fields from the live head then writes one FMA's result into
# another's destination. Every result is distinct, so any cross-delivery fails a check.
# M-mode, tohost @ 0x80001000.  1 = PASS, 3 = FAIL.

    .section .text.init
    .globl _start
_start:
    li        t0, (1 << 13)
    csrs      mstatus, t0

    li        t0, 0x3FF0000000000000
    fmv.d.x   f1, t0                 # 1.0
    li        t0, 0x4000000000000000
    fmv.d.x   f2, t0                 # 2.0
    li        t0, 0x4008000000000000
    fmv.d.x   f3, t0                 # 3.0
    li        t0, 0x4014000000000000
    fmv.d.x   f4, t0                 # 5.0

    fmadd.d   f10, f1, f2, f3        # 1*2+3  = 5
    fmadd.d   f11, f2, f3, f4        # 2*3+5  = 11
    fmadd.d   f12, f3, f4, f1        # 3*5+1  = 16
    fmadd.d   f13, f4, f4, f2        # 5*5+2  = 27
    fmadd.d   f14, f2, f2, f2        # 2*2+2  = 6
    fmadd.d   f15, f3, f3, f3        # 3*3+3  = 12
    fmadd.d   f16, f4, f3, f2        # 5*3+2  = 17
    fmadd.d   f17, f1, f4, f4        # 1*5+5  = 10
    fmsub.d   f18, f3, f4, f1        # 3*5-1  = 14
    fnmadd.d  f19, f2, f3, f1        # -(2*3)-1 = -7

    fmv.x.d   t1, f10
    li        t2, 0x4014000000000000
    bne       t1, t2, fail
    fmv.x.d   t1, f11
    li        t2, 0x4026000000000000
    bne       t1, t2, fail
    fmv.x.d   t1, f12
    li        t2, 0x4030000000000000
    bne       t1, t2, fail
    fmv.x.d   t1, f13
    li        t2, 0x403B000000000000
    bne       t1, t2, fail
    fmv.x.d   t1, f14
    li        t2, 0x4018000000000000
    bne       t1, t2, fail
    fmv.x.d   t1, f15
    li        t2, 0x4028000000000000
    bne       t1, t2, fail
    fmv.x.d   t1, f16
    li        t2, 0x4031000000000000
    bne       t1, t2, fail
    fmv.x.d   t1, f17
    li        t2, 0x4024000000000000
    bne       t1, t2, fail
    fmv.x.d   t1, f18
    li        t2, 0x402C000000000000
    bne       t1, t2, fail
    fmv.x.d   t1, f19
    li        t2, 0xC01C000000000000
    bne       t1, t2, fail

    li        t0, 1
    li        t1, 0x80001000
    sw        t0, 0(t1)
done:
    j         done
fail:
    li        t0, 3
    li        t1, 0x80001000
    sw        t0, 0(t1)
fail_done:
    j         fail_done

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
