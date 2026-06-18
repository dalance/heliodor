# Phase 12 V2d-4 directed test: widening integer add/sub/mul (.vv/.vx).
# SEW=16, LMUL=1 (vl=8) -> result EEW=32, dest spans 2 regs (v8,v9). Results
# are read back at SEW=32 LMUL=2 (vse32) and compared with lwu.
#
#   vs2 (v4) = [1, 2, -1, INT16_MIN, 4, 5, INT16_MAX, 8]
#   vs1 (v6) = [10,20,-1, -1,        40,50, 1,        80]
#
# tohost @ 0x80001000: 1 = PASS; 2.. = the failing check id.

    .macro CK off, val, failL
        lwu  t5, \off(a2); li t6, \val; bne t5, t6, \failL
    .endm

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000
    li   t0, (1 << 9)
    csrs mstatus, t0

    li   a0, 0x80010000          # src2 (8 x int16)
    li   a1, 0x80010020          # src1
    li   a2, 0x80010040          # dst  (8 x int32)
    li t1,1;      sh t1,0(a0); li t1,2; sh t1,2(a0); li t1,0xFFFF; sh t1,4(a0); li t1,0x8000; sh t1,6(a0)
    li t1,4;      sh t1,8(a0); li t1,5; sh t1,10(a0); li t1,0x7FFF; sh t1,12(a0); li t1,8; sh t1,14(a0)
    li t1,10;     sh t1,0(a1); li t1,20; sh t1,2(a1); li t1,0xFFFF; sh t1,4(a1); li t1,0xFFFF; sh t1,6(a1)
    li t1,40;     sh t1,8(a1); li t1,50; sh t1,10(a1); li t1,1; sh t1,12(a1); li t1,80; sh t1,14(a1)

    vsetvli t0, x0, e16, m1
    li   t1, 8
    bne  t0, t1, fail2
    vle16.v v4, (a0)
    vle16.v v6, (a1)

    # --- vwadd.vv (signed) : check all 8 ---
    vwadd.vv v8, v4, v6
    vsetvli t0, x0, e32, m2
    vse32.v v8, (a2)
    CK 0,  11,         fail3
    CK 4,  22,         fail3
    CK 8,  0xFFFFFFFE, fail3   # -1 + -1 = -2
    CK 12, 0xFFFF7FFF, fail3   # INT16_MIN + -1 = -32769
    CK 16, 44,         fail3
    CK 20, 55,         fail3
    CK 24, 0x8000,     fail3   # 32767 + 1 = 32768
    CK 28, 88,         fail3

    # --- vwsub.vv (signed) ---
    vsetvli t0, x0, e16, m1
    vwsub.vv v8, v4, v6
    vsetvli t0, x0, e32, m2
    vse32.v v8, (a2)
    CK 0,  0xFFFFFFF7, fail4   # 1-10 = -9
    CK 8,  0,          fail4   # -1-(-1) = 0
    CK 12, 0xFFFF8001, fail4   # -32768-(-1) = -32767
    CK 24, 0x7FFE,     fail4   # 32767-1 = 32766

    # --- vwmul.vv (signed) ---
    vsetvli t0, x0, e16, m1
    vwmul.vv v8, v4, v6
    vsetvli t0, x0, e32, m2
    vse32.v v8, (a2)
    CK 0,  10,         fail5
    CK 8,  1,          fail5   # -1 * -1 = 1
    CK 12, 0x8000,     fail5   # -32768 * -1 = 32768
    CK 24, 0x7FFF,     fail5   # 32767 * 1
    CK 28, 640,        fail5

    # --- vwmulu.vv (unsigned) ---
    vsetvli t0, x0, e16, m1
    vwmulu.vv v8, v4, v6
    vsetvli t0, x0, e32, m2
    vse32.v v8, (a2)
    CK 8,  0xFFFE0001, fail6   # 65535 * 65535
    CK 12, 0x7FFF8000, fail6   # 32768 * 65535
    CK 24, 0x7FFF,     fail6   # 32767 * 1

    # --- vwmulsu.vv (signed vs2 * unsigned vs1) ---
    vsetvli t0, x0, e16, m1
    vwmulsu.vv v8, v4, v6
    vsetvli t0, x0, e32, m2
    vse32.v v8, (a2)
    CK 8,  0xFFFF0001, fail7   # -1(s) * 65535(u) = -65535
    CK 12, 0x80008000, fail7   # -32768(s) * 65535(u)
    CK 24, 0x7FFF,     fail7

    # --- vwaddu.vv (unsigned) ---
    vsetvli t0, x0, e16, m1
    vwaddu.vv v8, v4, v6
    vsetvli t0, x0, e32, m2
    vse32.v v8, (a2)
    CK 8,  0x1FFFE,    fail8    # 65535 + 65535
    CK 12, 0x17FFF,    fail8    # 32768 + 65535
    CK 24, 0x8000,     fail8    # 32767 + 1

    # --- vwadd.vx (scalar = -1) : widen vs2 and the scalar ---
    vsetvli t0, x0, e16, m1
    li   a3, 0xFFFFFFFFFFFFFFFF  # -1 (SEW=16 -> 0xFFFF)
    vwadd.vx v8, v4, a3
    vsetvli t0, x0, e32, m2
    vse32.v v8, (a2)
    CK 0,  0,          fail9    # 1 + -1 = 0
    CK 8,  0xFFFFFFFE, fail9    # -1 + -1 = -2
    CK 12, 0xFFFF7FFF, fail9    # INT16_MIN + -1
    CK 24, 0x7FFE,     fail9    # 32767 + -1 = 32766

    li   t0, 1
    sw   t0, 0(t3)
0:  j    0b

fail2:  li t0,2; sw t0,0(t3); 20: j 20b
fail3:  li t0,3; sw t0,0(t3); 30: j 30b
fail4:  li t0,4; sw t0,0(t3); 40: j 40b
fail5:  li t0,5; sw t0,0(t3); 50: j 50b
fail6:  li t0,6; sw t0,0(t3); 60: j 60b
fail7:  li t0,7; sw t0,0(t3); 70: j 70b
fail8:  li t0,8; sw t0,0(t3); 80: j 80b
fail9:  li t0,9; sw t0,0(t3); 90: j 90b
