# Phase 12 V2d-2 directed test: LMUL>1 integer compare (mask accumulation across
# EMUL source register groups into a single mask register).
#
#   v8/v9   = [10,20,30,40,50,60,70,80]   (vs2 at LMUL=2)
#   v12/v13 = [10,99,30,40,50, 5,99,80]   (vs1 at LMUL=2)
# Mask bits span both groups (0-3 from group 0, 4-7 from group 1); read with
# vmv.x.s + andi.
#
# tohost @ 0x80001000: 1 = PASS; 2.. = the failing check id.

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000
    li   t0, (1 << 9)             # mstatus.VS = Initial
    csrs mstatus, t0

    li   a0, 0x80010000           # vs2 src
    li   a1, 0x80010040           # vs1 src
    li   t1,10; sw t1, 0(a0); li t1,20; sw t1, 4(a0); li t1,30; sw t1, 8(a0); li t1,40; sw t1,12(a0)
    li   t1,50; sw t1,16(a0); li t1,60; sw t1,20(a0); li t1,70; sw t1,24(a0); li t1,80; sw t1,28(a0)
    li   t1,10; sw t1, 0(a1); li t1,99; sw t1, 4(a1); li t1,30; sw t1, 8(a1); li t1,40; sw t1,12(a1)
    li   t1,50; sw t1,16(a1); li t1,5;  sw t1,20(a1); li t1,99; sw t1,24(a1); li t1,80; sw t1,28(a1)

    # Load sources LMUL=1 into v8,v9 and v12,v13.
    vsetvli t0, x0, e32, m1
    li   t1, 4
    bne  t0, t1, fail2
    addi a3, a0, 16
    addi a4, a1, 16
    vle32.v v8,  (a0)
    vle32.v v9,  (a3)
    vle32.v v12, (a1)
    vle32.v v13, (a4)

    # --- LMUL=2 vmseq.vv : [eq?] = 0b1001_1101 = 0x9D ---
    vsetvli t0, x0, e32, m2       # SEW=32, LMUL=2 -> vl=8
    li   t1, 8
    bne  t0, t1, fail3
    vmseq.vv v5, v8, v12
    vmv.x.s a5, v5
    andi a5, a5, 0xFF
    li   t1, 0x9D
    bne  a5, t1, fail4

    # --- LMUL=2 vmslt.vv (signed) : bits 1,6 = 0x42 (use v6, keep v5) ---
    vmslt.vv v6, v8, v12
    vmv.x.s a5, v6
    andi a5, a5, 0xFF
    li   t1, 0x42
    bne  a5, t1, fail5

    # --- LMUL=2 masked vmslt into v5 (holds 0x9D): v0=0x0F (active 0-3) ---
    #     bits 0-3 = vmslt = 0b0010; bits 4-7 = old v5 (0x9D) = 0b1001 -> 0x92
    li   a6, 0x80010100
    li   t1, 0x0F; sb t1, 0(a6)
    li   t1, 1
    vsetvli t0, t1, e8, m1
    vle8.v  v0, (a6)             # v0[7:0] = 0x0F
    vsetvli t0, x0, e32, m2
    vmslt.vv v5, v8, v12, v0.t
    vmv.x.s a5, v5
    andi a5, a5, 0xFF
    li   t1, 0x92
    bne  a5, t1, fail6

    # --- LMUL=4 vmseq across 4 groups: all-equal -> 16 bits set = 0xFFFF ---
    vsetvli t0, x0, e32, m4       # SEW=32, LMUL=4 -> vl=16
    li   t1, 16
    bne  t0, t1, fail7
    li   a7, 42
    vmv.v.x v8,  a7             # v8..v11  = 42
    vmv.v.x v12, a7            # v12..v15 = 42
    vmseq.vv v16, v8, v12
    vmv.x.s a5, v16
    li   t5, 0xFFFF
    and  a5, a5, t5
    bne  a5, t5, fail8

    # --- LMUL=4 vmseq all-differ -> 0x0000 ---
    li   a7, 43
    vmv.v.x v12, a7            # v12..v15 = 43
    vmseq.vv v16, v8, v12
    vmv.x.s a5, v16
    and  a5, a5, t5
    bnez a5, fail9

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
