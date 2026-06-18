# Phase 12 V3j directed test: widening vector FP fused multiply-add.
# vfwmacc / vfwnmacc / vfwmsac / vfwnmsac (.vv) + vfwmacc.vf — both
# multiplicands are single (s2d-widened), the accumulator is the old vd
# (already double, read at dest geometry).
#
#   vs1 = [2.0, 3.0, -1.0, 0.5], vs2 = [1.5, 2.0, 4.0, -2.0]  (single, e32)
#   vd  = [10.0, 20.0, -5.0, 1.0]  (double accumulator, reloaded each test)
#
# tohost @ 0x80001000: 1 = PASS; N = the failing check id.
#
# NOTE: kept as its OWN small test module rather than folded into vfarith,
# because the cumulative vfarith image has outgrown a code-size threshold that
# trips a (pre-existing) vector-load liveness stall in the core; see the topic
# memory. This test stays well under that size.

    .macro CK64 off, val, failL
        ld   t5, \off(a2); li t6, \val; bne t5, t6, \failL
    .endm

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000
    li   t0, (1 << 9) | (1 << 13)       # mstatus.VS | mstatus.FS
    csrs mstatus, t0

    li   a0, 0x80010E00          # vs1 (single)
    li   a1, 0x80010E40          # vs2 (single)
    li   a3, 0x80010E80          # vd init (double = 2 regs)
    li   a2, 0x80010F00          # dst (double = 2 regs)
    li t1,0x40000000; sw t1,0(a0);  li t1,0x40400000; sw t1,4(a0)
    li t1,0xBF800000; sw t1,8(a0);  li t1,0x3F000000; sw t1,12(a0)
    li t1,0x3FC00000; sw t1,0(a1);  li t1,0x40000000; sw t1,4(a1)
    li t1,0x40800000; sw t1,8(a1);  li t1,0xC0000000; sw t1,12(a1)
    li t1,0x4024000000000000; sd t1,0(a3)    # 10.0
    li t1,0x4034000000000000; sd t1,8(a3)    # 20.0
    li t1,0xC014000000000000; sd t1,16(a3)   # -5.0
    li t1,0x3FF0000000000000; sd t1,24(a3)   # 1.0
    vsetvli t0, x0, e32, m1
    vle32.v v6, (a0)             # vs1
    vle32.v v4, (a1)             # vs2

    # vfwmacc.vv: vd += vs1*vs2 -> [13.0, 26.0, -9.0, 0.0]
    vsetvli t0, x0, e64, m2
    vle64.v v8, (a3)
    vsetvli t0, x0, e32, m1
    vfwmacc.vv v8, v6, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x402A000000000000, fail2    # 13.0
    CK64 8,  0x403A000000000000, fail2    # 26.0
    CK64 16, 0xC022000000000000, fail2    # -9.0
    CK64 24, 0x0000000000000000, fail2    # 0.0

    # vfwnmacc.vv: vd = -(vs1*vs2) - vd -> [-13.0, -26.0, 9.0, 0.0]
    vsetvli t0, x0, e64, m2
    vle64.v v8, (a3)
    vsetvli t0, x0, e32, m1
    vfwnmacc.vv v8, v6, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0xC02A000000000000, fail3    # -13.0
    CK64 8,  0xC03A000000000000, fail3    # -26.0
    CK64 16, 0x4022000000000000, fail3    # 9.0
    CK64 24, 0x0000000000000000, fail3    # 0.0

    # vfwmsac.vv: vd = (vs1*vs2) - vd -> [-7.0, -14.0, 1.0, -2.0]
    vsetvli t0, x0, e64, m2
    vle64.v v8, (a3)
    vsetvli t0, x0, e32, m1
    vfwmsac.vv v8, v6, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0xC01C000000000000, fail4    # -7.0
    CK64 8,  0xC02C000000000000, fail4    # -14.0
    CK64 16, 0x3FF0000000000000, fail4    # 1.0
    CK64 24, 0xC000000000000000, fail4    # -2.0

    # vfwnmsac.vv: vd = -(vs1*vs2) + vd -> [7.0, 14.0, -1.0, 2.0]
    vsetvli t0, x0, e64, m2
    vle64.v v8, (a3)
    vsetvli t0, x0, e32, m1
    vfwnmsac.vv v8, v6, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x401C000000000000, fail5    # 7.0
    CK64 8,  0x402C000000000000, fail5    # 14.0
    CK64 16, 0xBFF0000000000000, fail5    # -1.0
    CK64 24, 0x4000000000000000, fail5    # 2.0

    # vfwmacc.vf: vd += 2.0*vs2 -> [13.0, 24.0, 3.0, -3.0]
    flw fa1, 0(a0)               # 2.0 (= vs1[0])
    vsetvli t0, x0, e64, m2
    vle64.v v8, (a3)
    vsetvli t0, x0, e32, m1
    vfwmacc.vf v8, fa1, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x402A000000000000, fail6    # 13.0
    CK64 8,  0x4038000000000000, fail6    # 24.0
    CK64 16, 0x4008000000000000, fail6    # 3.0
    CK64 24, 0xC008000000000000, fail6    # -3.0

    li   t0, 1
    sw   t0, 0(t3)
0:  j    0b

fail2:  li t0,2;  sw t0,0(t3); 20: j 20b
fail3:  li t0,3;  sw t0,0(t3); 30: j 30b
fail4:  li t0,4;  sw t0,0(t3); 40: j 40b
fail5:  li t0,5;  sw t0,0(t3); 50: j 50b
fail6:  li t0,6;  sw t0,0(t3); 60: j 60b
