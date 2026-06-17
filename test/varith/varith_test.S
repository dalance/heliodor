# Phase 12 V2a directed test: integer vector ALU (OPIVV/VX/VI) + vta/vma/mask.
#
# Loads two source vectors, runs each ALU op, stores the result, and checks the
# stored elements with scalar loads. Element 2 of src1 is 0xFFFFFFFF (= -1) so
# the signed vs unsigned ops (vsra/vsrl, vmin/vminu, vmax/vmaxu) are
# distinguished. Also checks masked (v0) and tail (vl<VLMAX) undisturbed merge.
#
# src1 = [8, 16, 0xFFFFFFFF, 100]   src2 = [3, 4, 2, 7]
#
# tohost @ 0x80001000: 1 = PASS; 2.. = the failing check id.

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000           # tohost
    li   t0, (1 << 9)             # mstatus.VS = Initial
    csrs mstatus, t0

    li   a0, 0x80010000           # src1
    li   a1, 0x80010020           # src2
    li   a2, 0x80010040           # dst (result scratch)

    # src1 = [8, 16, 0xFFFFFFFF, 100]
    li   t1, 8;          sw t1, 0(a0)
    li   t1, 16;         sw t1, 4(a0)
    li   t1, 0xFFFFFFFF; sw t1, 8(a0)
    li   t1, 100;        sw t1, 12(a0)
    # src2 = [3, 4, 2, 7]
    li   t1, 3;  sw t1, 0(a1)
    li   t1, 4;  sw t1, 4(a1)
    li   t1, 2;  sw t1, 8(a1)
    li   t1, 7;  sw t1, 12(a1)

    vsetvli t0, x0, e32, m1       # SEW=32, vl=VLMAX=4
    li   t1, 4
    bne  t0, t1, fail2

    vle32.v v1, (a0)              # v1 = src1
    vle32.v v2, (a1)              # v2 = src2

    # --- vsub.vv : v1 - v2 = [5, 12, 0xFFFFFFFD, 93] ---
    vsub.vv v3, v1, v2
    vse32.v v3, (a2)
    lwu  t1, 0(a2);  li t2, 5;          bne t1, t2, fail3
    lwu  t1, 4(a2);  li t2, 12;         bne t1, t2, fail3
    lwu  t1, 8(a2);  li t2, 0xFFFFFFFD; bne t1, t2, fail3
    lwu  t1, 12(a2); li t2, 93;         bne t1, t2, fail3

    # --- vor.vv element 0 : 8 | 3 = 0xB ---
    vor.vv  v3, v1, v2
    vse32.v v3, (a2)
    lwu  t1, 0(a2);  li t2, 0xB; bne t1, t2, fail4

    # --- vsll.vv : [8<<3=64, _, 0xFFFFFFFF<<2=0xFFFFFFFC, _] ---
    vsll.vv v3, v1, v2
    vse32.v v3, (a2)
    lwu  t1, 0(a2);  li t2, 64;         bne t1, t2, fail5
    lwu  t1, 8(a2);  li t2, 0xFFFFFFFC; bne t1, t2, fail5

    # --- vsra.vv (signed) : element 2 = -1 >>> 2 = 0xFFFFFFFF ---
    vsra.vv v3, v1, v2
    vse32.v v3, (a2)
    lwu  t1, 8(a2);  li t2, 0xFFFFFFFF; bne t1, t2, fail6
    lwu  t1, 0(a2);  li t2, 1;          bne t1, t2, fail6   # 8>>3 = 1

    # --- vsrl.vv (unsigned) : element 2 = 0xFFFFFFFF >> 2 = 0x3FFFFFFF ---
    vsrl.vv v3, v1, v2
    vse32.v v3, (a2)
    lwu  t1, 8(a2);  li t2, 0x3FFFFFFF; bne t1, t2, fail7

    # --- vmin.vv (signed) : element 2 = min(-1, 2) = 0xFFFFFFFF ---
    vmin.vv v3, v1, v2
    vse32.v v3, (a2)
    lwu  t1, 8(a2);  li t2, 0xFFFFFFFF; bne t1, t2, fail8

    # --- vminu.vv (unsigned) : element 2 = min(0xFFFFFFFF, 2) = 2 ---
    vminu.vv v3, v1, v2
    vse32.v v3, (a2)
    lwu  t1, 8(a2);  li t2, 2; bne t1, t2, fail9

    # --- vmax.vv (signed) : element 2 = max(-1, 2) = 2 ---
    vmax.vv v3, v1, v2
    vse32.v v3, (a2)
    lwu  t1, 8(a2);  li t2, 2; bne t1, t2, fail10

    # --- vmaxu.vv (unsigned) : element 2 = max(0xFFFFFFFF, 2) = 0xFFFFFFFF ---
    vmaxu.vv v3, v1, v2
    vse32.v v3, (a2)
    lwu  t1, 8(a2);  li t2, 0xFFFFFFFF; bne t1, t2, fail11

    # --- vadd.vi element 0 : 8 + 5 = 13 ---
    vadd.vi v3, v1, 5
    vse32.v v3, (a2)
    lwu  t1, 0(a2);  li t2, 13; bne t1, t2, fail12

    # --- vrsub.vx element 0 : 10 - 8 = 2 ---
    li   a3, 10
    vrsub.vx v3, v1, a3
    vse32.v v3, (a2)
    lwu  t1, 0(a2);  li t2, 2; bne t1, t2, fail13

    # --- masked vadd.vv: mask v0 = 0b0101 (elements 0,2 active) ---
    li   a4, 0x80010060           # mask byte scratch
    li   t1, 0x05; sb t1, 0(a4)
    li   t1, 1
    vsetvli t0, t1, e8, m1        # vl=1
    vle8.v  v0, (a4)              # v0[7:0] = 0x05
    vsetvli t0, x0, e32, m1       # back to SEW=32 vl=4
    # pre-fill v5 = [0x99999999 x4] (zero vector v6 = v1-v1)
    vsub.vv v6, v1, v1
    li   a5, 0x99999999
    vadd.vx v5, v6, a5
    # masked add: elements 0,2 = v1+v2, elements 1,3 undisturbed (0x99999999)
    vadd.vv v5, v1, v2, v0.t
    vse32.v v5, (a2)
    lwu  t1, 0(a2);  li t2, 11;         bne t1, t2, fail14   # 8+3
    lwu  t1, 4(a2);  li t2, 0x99999999; bne t1, t2, fail14   # masked off
    lwu  t1, 8(a2);  li t2, 1;          bne t1, t2, fail14   # 0xFFFFFFFF+2 = 1
    lwu  t1, 12(a2); li t2, 0x99999999; bne t1, t2, fail14   # masked off

    # --- tail undisturbed: vl=2, vadd, elements 2,3 keep old value ---
    li   a5, 0x88888888
    vadd.vx v7, v6, a5            # v7 = [0x88888888 x4] (vl still 4 here)
    li   t1, 2
    vsetvli t0, t1, e32, m1       # vl=2
    vadd.vv v7, v1, v2           # elements 0,1 active; 2,3 = tail (undisturbed)
    vsetvli t0, x0, e32, m1       # vl=4 so vse stores all 4
    vse32.v v7, (a2)
    lwu  t1, 0(a2);  li t2, 11;         bne t1, t2, fail15   # 8+3
    lwu  t1, 4(a2);  li t2, 20;         bne t1, t2, fail15   # 16+4
    lwu  t1, 8(a2);  li t2, 0x88888888; bne t1, t2, fail15   # tail
    lwu  t1, 12(a2); li t2, 0x88888888; bne t1, t2, fail15   # tail

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
fail11: li t0,11; sw t0,0(t3); 110: j 110b
fail12: li t0,12; sw t0,0(t3); 120: j 120b
fail13: li t0,13; sw t0,0(t3); 130: j 130b
fail14: li t0,14; sw t0,0(t3); 140: j 140b
fail15: li t0,15; sw t0,0(t3); 150: j 150b
