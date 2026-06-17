# Phase 12 V2b directed test: integer vector compares (→ mask register) +
# vmerge / vmv.v.{x,i}. Element 2 of v1 is 0xFFFFFFFF (= -1) so signed vs
# unsigned compares differ.
#
# v1 = [8, 16, 0xFFFFFFFF, 100]   v2 = [3, 16, 2, 7]   (SEW=32, vl=4)
# A compare writes one mask bit per element into vd[3:0]; read it with
# vmv.x.s then mask the low 4 bits (the tail bits are undisturbed).
#
# tohost @ 0x80001000: 1 = PASS; 2.. = the failing check id.

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000
    li   t0, (1 << 9)             # mstatus.VS = Initial
    csrs mstatus, t0

    li   a0, 0x80010000           # v1 src
    li   a1, 0x80010020           # v2 src
    li   a2, 0x80010040           # dst scratch
    li   t1, 8;          sw t1, 0(a0)
    li   t1, 16;         sw t1, 4(a0)
    li   t1, 0xFFFFFFFF; sw t1, 8(a0)
    li   t1, 100;        sw t1, 12(a0)
    li   t1, 3;  sw t1, 0(a1)
    li   t1, 16; sw t1, 4(a1)
    li   t1, 2;  sw t1, 8(a1)
    li   t1, 7;  sw t1, 12(a1)

    vsetvli t0, x0, e32, m1       # SEW=32, vl=4
    li   t1, 4
    bne  t0, t1, fail2
    vle32.v v1, (a0)
    vle32.v v2, (a1)

    # --- vmseq.vv : [8==3,16==16,-1==2,100==7] = 0b0010 = 0x2 ---
    vmseq.vv v5, v1, v2
    vmv.x.s a4, v5
    andi a4, a4, 0xF
    li   t1, 0x2
    bne  a4, t1, fail3

    # --- vmsne.vv : ~vmseq within vl = 0b1101 = 0xD ---
    vmsne.vv v5, v1, v2
    vmv.x.s a4, v5
    andi a4, a4, 0xF
    li   t1, 0xD
    bne  a4, t1, fail4

    # --- vmslt.vv (signed) : [8<3,16<16,-1<2,100<7] = 0b0100 = 0x4 ---
    vmslt.vv v5, v1, v2
    vmv.x.s a4, v5
    andi a4, a4, 0xF
    li   t1, 0x4
    bne  a4, t1, fail5

    # --- vmsltu.vv (unsigned) : -1 is huge so element2=0 → 0b0000 = 0x0 ---
    vmsltu.vv v5, v1, v2
    vmv.x.s a4, v5
    andi a4, a4, 0xF
    li   t1, 0x0
    bne  a4, t1, fail6

    # --- vmsle.vv (signed) : [8<=3,16<=16,-1<=2,100<=7] = 0b0110 = 0x6 ---
    vmsle.vv v5, v1, v2
    vmv.x.s a4, v5
    andi a4, a4, 0xF
    li   t1, 0x6
    bne  a4, t1, fail7

    # --- vmsleu.vv (unsigned) : [0,1,0,0] = 0b0010 = 0x2 ---
    vmsleu.vv v5, v1, v2
    vmv.x.s a4, v5
    andi a4, a4, 0xF
    li   t1, 0x2
    bne  a4, t1, fail8

    # --- vmsgt.vx (signed, x=7) : [8>7,16>7,-1>7,100>7] = 0b1011 = 0xB ---
    li   a3, 7
    vmsgt.vx v5, v1, a3
    vmv.x.s a4, v5
    andi a4, a4, 0xF
    li   t1, 0xB
    bne  a4, t1, fail9

    # --- vmsgtu.vx (unsigned, x=7) : element2 -1 is >7 → 0b1111 = 0xF ---
    vmsgtu.vx v5, v1, a3
    vmv.x.s a4, v5
    andi a4, a4, 0xF
    li   t1, 0xF
    bne  a4, t1, fail10

    # --- vmerge.vvm : v0 mask = 0b0101 → [v1,v2,v1,v2] = [8,16,0xFFFFFFFF,7] ---
    li   a5, 0x80010060
    li   t1, 0x05; sb t1, 0(a5)
    li   t1, 1
    vsetvli t0, t1, e8, m1
    vle8.v  v0, (a5)             # v0[7:0] = 0x05
    vsetvli t0, x0, e32, m1
    vmerge.vvm v6, v2, v1, v0    # vd[i] = mask[i] ? v1[i] : v2[i]
    vse32.v v6, (a2)
    lwu  t1, 0(a2);  li t2, 8;          bne t1, t2, fail11
    lwu  t1, 4(a2);  li t2, 16;         bne t1, t2, fail11
    lwu  t1, 8(a2);  li t2, 0xFFFFFFFF; bne t1, t2, fail11
    lwu  t1, 12(a2); li t2, 7;          bne t1, t2, fail11

    # --- vmv.v.x : broadcast a scalar ---
    li   a6, 0x55
    vmv.v.x v7, a6
    vse32.v v7, (a2)
    lwu  t1, 0(a2);  li t2, 0x55; bne t1, t2, fail12
    lwu  t1, 12(a2); li t2, 0x55; bne t1, t2, fail12

    # --- vmv.v.i : broadcast an immediate ---
    vmv.v.i v7, 5
    vse32.v v7, (a2)
    lwu  t1, 0(a2);  li t2, 5; bne t1, t2, fail13
    lwu  t1, 8(a2);  li t2, 5; bne t1, t2, fail13

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
