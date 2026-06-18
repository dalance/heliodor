# Phase 12 V2d-1 directed test: LMUL>1 integer arithmetic (register-serial VU).
# Source data is loaded with LMUL=1 into individual registers, then arithmetic
# runs at LMUL=2 (spanning 2 vregs) / LMUL=4 (4 vregs); results are read back
# with LMUL=1 vse and compared (lwu, bit31-safe).
#
#   v8=[10,20,30,40] v9=[50,60,70,80]   (vs2 group at LMUL=2)
#   v12=[1,2,3,4]    v13=[5,6,7,8]      (vs1 group at LMUL=2)
#
# tohost @ 0x80001000: 1 = PASS; 2.. = the failing check id.

    .macro CHK8 e0,e1,e2,e3,e4,e5,e6,e7,failL
        lwu t1, 0(a2);  li t2,\e0; bne t1,t2,\failL
        lwu t1, 4(a2);  li t2,\e1; bne t1,t2,\failL
        lwu t1, 8(a2);  li t2,\e2; bne t1,t2,\failL
        lwu t1,12(a2);  li t2,\e3; bne t1,t2,\failL
        lwu t1,16(a2);  li t2,\e4; bne t1,t2,\failL
        lwu t1,20(a2);  li t2,\e5; bne t1,t2,\failL
        lwu t1,24(a2);  li t2,\e6; bne t1,t2,\failL
        lwu t1,28(a2);  li t2,\e7; bne t1,t2,\failL
    .endm

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000
    li   t0, (1 << 9)             # mstatus.VS = Initial
    csrs mstatus, t0

    li   a0, 0x80010000           # vs2 src (8 words)
    li   a1, 0x80010040           # vs1 src (8 words)
    li   a2, 0x80010080           # dst scratch (8 words)
    li   t1,10; sw t1, 0(a0); li t1,20; sw t1, 4(a0); li t1,30; sw t1, 8(a0); li t1,40; sw t1,12(a0)
    li   t1,50; sw t1,16(a0); li t1,60; sw t1,20(a0); li t1,70; sw t1,24(a0); li t1,80; sw t1,28(a0)
    li   t1,1;  sw t1, 0(a1); li t1,2;  sw t1, 4(a1); li t1,3;  sw t1, 8(a1); li t1,4;  sw t1,12(a1)
    li   t1,5;  sw t1,16(a1); li t1,6;  sw t1,20(a1); li t1,7;  sw t1,24(a1); li t1,8;  sw t1,28(a1)

    # Load sources with LMUL=1 (4 elems each) into v8,v9 and v12,v13.
    vsetvli t0, x0, e32, m1
    li   t1, 4
    bne  t0, t1, fail2
    addi a3, a0, 16
    addi a4, a1, 16
    vle32.v v8,  (a0)
    vle32.v v9,  (a3)
    vle32.v v12, (a1)
    vle32.v v13, (a4)

    # --- LMUL=2 vadd.vv v4,v8,v12 -> v4,v5 ---
    vsetvli t0, x0, e32, m2       # SEW=32, LMUL=2 -> vl=8
    li   t1, 8
    bne  t0, t1, fail3
    vadd.vv v4, v8, v12
    vsetvli t0, x0, e32, m1
    vse32.v v4, (a2)
    addi a5, a2, 16
    vse32.v v5, (a5)
    CHK8 11,22,33,44,55,66,77,88, fail4

    # --- LMUL=2 vsub.vv v6,v8,v12 -> v6,v7 ---
    vsetvli t0, x0, e32, m2
    vsub.vv v6, v8, v12
    vsetvli t0, x0, e32, m1
    vse32.v v6, (a2)
    vse32.v v7, (a5)
    CHK8 9,18,27,36,45,54,63,72, fail5

    # --- LMUL=2 vmul.vv v4,v8,v12 -> v4,v5 (mul LMUL>1) ---
    vsetvli t0, x0, e32, m2
    vmul.vv v4, v8, v12
    vsetvli t0, x0, e32, m1
    vse32.v v4, (a2)
    vse32.v v5, (a5)
    CHK8 10,40,90,160,250,360,490,640, fail6

    # --- LMUL=2 vmv.v.x broadcast (merge LMUL>1) -> v4,v5 = 0x99 ---
    vsetvli t0, x0, e32, m2
    li   a6, 0x99
    vmv.v.x v4, a6
    vsetvli t0, x0, e32, m1
    vse32.v v4, (a2)
    vse32.v v5, (a5)
    CHK8 0x99,0x99,0x99,0x99,0x99,0x99,0x99,0x99, fail7

    # --- LMUL=2 masked vadd: v0=0x69 (active 0,3,5,6), inactive keep 0x99 ---
    li   a7, 0x80010100
    li   t1, 0x69; sb t1, 0(a7)
    li   t1, 1
    vsetvli t0, t1, e8, m1
    vle8.v  v0, (a7)              # v0[7:0] = 0x69
    vsetvli t0, x0, e32, m2
    li   a6, 0x99
    vmv.v.x v4, a6               # preload v4,v5 = 0x99
    vadd.vv v4, v8, v12, v0.t    # active 0,3,5,6 -> sum; else keep 0x99
    vsetvli t0, x0, e32, m1
    vse32.v v4, (a2)
    vse32.v v5, (a5)
    CHK8 11,0x99,0x99,44,0x99,66,77,0x99, fail8

    # --- LMUL=4 vmv.v.x + vadd.vx (4 register groups, va_reg 0..3) ---
    vsetvli t0, x0, e32, m4       # SEW=32, LMUL=4 -> vl=16
    li   t1, 16
    bne  t0, t1, fail9
    li   a6, 7
    vmv.v.x v16, a6              # v16..v19 = 7
    li   a6, 3
    vadd.vx v20, v16, a6        # v20..v23 = 10
    vsetvli t0, x0, e32, m1
    vse32.v v20, (a2)           # v20 = [10,10,10,10]
    li   t1, 10
    lwu  t2, 0(a2);  bne t2, t1, fail10
    lwu  t2, 12(a2); bne t2, t1, fail10
    vse32.v v23, (a2)           # v23 = group 3 = [10,10,10,10]
    lwu  t2, 0(a2);  bne t2, t1, fail10
    lwu  t2, 12(a2); bne t2, t1, fail10

    li   t0, 1
    sw   t0, 0(t3)
0:  j    0b

fail2:  li t0,2;  sw t0,0(t3); 20: j 20b
fail3:  li t0,3;  sw t0,0(t3); 30: j 30b
fail4:  li t0,4;  sw t0,0(t3); 40: j 40b
fail5:  li t0,5;  sw t0,0(t3); 50: j 50b
fail6:  li t0,6;  sw t0,0(t3); 60: j 60b
fail7:  li t0,7;  sw t0,0(t3); 70: j 70b
fail8:  li t0,8;  sw t0,0(t3); 80: j 80b
fail9:  li t0,9;  sw t0,0(t3); 90: j 90b
fail10: li t0,10; sw t0,0(t3); 100: j 100b
