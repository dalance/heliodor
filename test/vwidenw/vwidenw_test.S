# Phase 12 V2d-6 directed test: .w-form widening add/sub (vwadd.w family).
# SEW=16: vs2 is already 32-bit (2 regs v4,v5); vs1 is 16-bit (v6), widened
# before the add/sub. Results 32-bit in v8,v9, read back at SEW=32 LMUL=2.
#
#   vs2w = [0x00010000,0x00020000,0xFFFF0000,0x7FFFFFFF,5,0x80000000,0x12340000,0xFFFFFFFF]
#   vs1  = [1, -1, 5, 1, -2, -1, 0x1111, 1]   (int16)
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

    li   a0, 0x80010000          # vs2w (8 x int32)
    li   a1, 0x80010040          # vs1  (8 x int16)
    li   a2, 0x80010080          # dst  (8 x int32)
    li t1,0x00010000; sw t1,0(a0);  li t1,0x00020000; sw t1,4(a0)
    li t1,0xFFFF0000; sw t1,8(a0);  li t1,0x7FFFFFFF; sw t1,12(a0)
    li t1,5;          sw t1,16(a0); li t1,0x80000000; sw t1,20(a0)
    li t1,0x12340000; sw t1,24(a0); li t1,0xFFFFFFFF; sw t1,28(a0)
    li t1,1;  sh t1,0(a1); li t1,0xFFFF; sh t1,2(a1); li t1,5; sh t1,4(a1); li t1,1; sh t1,6(a1)
    li t1,0xFFFE; sh t1,8(a1); li t1,0xFFFF; sh t1,10(a1); li t1,0x1111; sh t1,12(a1); li t1,1; sh t1,14(a1)

    vsetvli t0, x0, e32, m2      # load vs2w into v4,v5
    li   t1, 8
    bne  t0, t1, fail2
    vle32.v v4, (a0)
    vsetvli t0, x0, e16, m1      # load vs1 into v6
    vle16.v v6, (a1)

    # --- vwadd.wv (signed) : check all 8 ---
    vwadd.wv v8, v4, v6
    vsetvli t0, x0, e32, m2
    vse32.v v8, (a2)
    CK 0,  0x00010001, fail3
    CK 4,  0x0001FFFF, fail3
    CK 8,  0xFFFF0005, fail3
    CK 12, 0x80000000, fail3
    CK 16, 3,          fail3
    CK 20, 0x7FFFFFFF, fail3
    CK 24, 0x12341111, fail3
    CK 28, 0,          fail3

    # --- vwaddu.wv (unsigned widen of vs1) ---
    vsetvli t0, x0, e16, m1
    vwaddu.wv v8, v4, v6
    vsetvli t0, x0, e32, m2
    vse32.v v8, (a2)
    CK 4,  0x0002FFFF, fail4   # 0x00020000 + 65535
    CK 16, 0x00010003, fail4   # 5 + 65534
    CK 20, 0x8000FFFF, fail4   # 0x80000000 + 65535

    # --- vwsub.wv (signed) ---
    vsetvli t0, x0, e16, m1
    vwsub.wv v8, v4, v6
    vsetvli t0, x0, e32, m2
    vse32.v v8, (a2)
    CK 0,  0x0000FFFF, fail5   # 0x00010000 - 1
    CK 8,  0xFFFEFFFB, fail5   # 0xFFFF0000 - 5
    CK 20, 0x80000001, fail5   # 0x80000000 - (-1)

    # --- vwsubu.wv (unsigned) ---
    vsetvli t0, x0, e16, m1
    vwsubu.wv v8, v4, v6
    vsetvli t0, x0, e32, m2
    vse32.v v8, (a2)
    CK 4,  0x00010001, fail6   # 0x00020000 - 65535
    CK 20, 0x7FFF0001, fail6   # 0x80000000 - 65535

    li   t0, 1
    sw   t0, 0(t3)
0:  j    0b

fail2:  li t0,2; sw t0,0(t3); 20: j 20b
fail3:  li t0,3; sw t0,0(t3); 30: j 30b
fail4:  li t0,4; sw t0,0(t3); 40: j 40b
fail5:  li t0,5; sw t0,0(t3); 50: j 50b
fail6:  li t0,6; sw t0,0(t3); 60: j 60b
