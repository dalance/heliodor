# Phase 12 V2c directed test: integer vector multiply / divide (OPMVV/OPMVX).
# vmul / vmulh / vmulhu / vmulhsu / vdivu / vdiv / vremu / vrem, plus vmul.vx and
# a masked vmul.vv (inactive elements undisturbed). SEW=32, vl=4.
#
#   v1 = [12, 0xFFFFFFFF(-1), 0x80000000(INT_MIN), 100]   (vs2 / dividend)
#   v2 = [5,  7,              0xFFFFFFFF(-1),       0xFFFFFFFF(-1/4294967295u)]
#
# Each result is stored with vse32 to a scratch line and read back with lwu
# (bit31 values are zero-extended, so the li compare constants are < 2^32).
#
# tohost @ 0x80001000: 1 = PASS; 2.. = the failing check id.

    .macro CHK4 e0, e1, e2, e3, failL
        lwu  t1, 0(a2);  li t2, \e0; bne t1, t2, \failL
        lwu  t1, 4(a2);  li t2, \e1; bne t1, t2, \failL
        lwu  t1, 8(a2);  li t2, \e2; bne t1, t2, \failL
        lwu  t1, 12(a2); li t2, \e3; bne t1, t2, \failL
    .endm

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000
    li   t0, (1 << 9)             # mstatus.VS = Initial
    csrs mstatus, t0

    li   a0, 0x80010000           # v1 src
    li   a1, 0x80010020           # v2 src
    li   a2, 0x80010040           # dst scratch
    li   t1, 12;         sw t1, 0(a0)
    li   t1, 0xFFFFFFFF; sw t1, 4(a0)
    li   t1, 0x80000000; sw t1, 8(a0)
    li   t1, 100;        sw t1, 12(a0)
    li   t1, 5;          sw t1, 0(a1)
    li   t1, 7;          sw t1, 4(a1)
    li   t1, 0xFFFFFFFF; sw t1, 8(a1)
    li   t1, 0xFFFFFFFF; sw t1, 12(a1)

    vsetvli t0, x0, e32, m1       # SEW=32, vl=4
    li   t1, 4
    bne  t0, t1, fail2
    vle32.v v1, (a0)
    vle32.v v2, (a1)

    # --- vmul.vv (low 32, sign-agnostic) ---
    vmul.vv v5, v1, v2
    vse32.v v5, (a2)
    CHK4 0x3C, 0xFFFFFFF9, 0x80000000, 0xFFFFFF9C, fail3

    # --- vmulh.vv (signed high 32) ---
    vmulh.vv v5, v1, v2
    vse32.v v5, (a2)
    CHK4 0x0, 0xFFFFFFFF, 0x0, 0xFFFFFFFF, fail4

    # --- vmulhu.vv (unsigned high 32) ---
    vmulhu.vv v5, v1, v2
    vse32.v v5, (a2)
    CHK4 0x0, 0x6, 0x7FFFFFFF, 0x63, fail5

    # --- vmulhsu.vv (signed vs2 x unsigned vs1, high 32) ---
    vmulhsu.vv v5, v1, v2
    vse32.v v5, (a2)
    CHK4 0x0, 0xFFFFFFFF, 0x80000000, 0x63, fail6

    # --- vdivu.vv (unsigned) ---
    vdivu.vv v5, v1, v2
    vse32.v v5, (a2)
    CHK4 0x2, 0x24924924, 0x0, 0x0, fail7

    # --- vdiv.vv (signed; INT_MIN/-1 overflow -> dividend) ---
    vdiv.vv v5, v1, v2
    vse32.v v5, (a2)
    CHK4 0x2, 0x0, 0x80000000, 0xFFFFFF9C, fail8

    # --- vremu.vv (unsigned) ---
    vremu.vv v5, v1, v2
    vse32.v v5, (a2)
    CHK4 0x2, 0x3, 0x80000000, 0x64, fail9

    # --- vrem.vv (signed; rem takes sign of dividend, overflow -> 0) ---
    vrem.vv v5, v1, v2
    vse32.v v5, (a2)
    CHK4 0x2, 0xFFFFFFFF, 0x0, 0x0, fail10

    # --- vmul.vx (scalar x = 3) ---
    li   a3, 3
    vmul.vx v5, v1, a3
    vse32.v v5, (a2)
    CHK4 0x24, 0xFFFFFFFD, 0x80000000, 0x12C, fail11

    # --- masked vmul.vv: v0 = 0b0101 -> e0,e2 active; e1,e3 undisturbed (0x77) ---
    li   a5, 0x80010060
    li   t1, 0x05; sb t1, 0(a5)
    li   t1, 1
    vsetvli t0, t1, e8, m1
    vle8.v  v0, (a5)              # v0[7:0] = 0x05
    vsetvli t0, x0, e32, m1
    li   a4, 0x77
    vmv.v.x v6, a4               # v6 = [0x77,0x77,0x77,0x77]
    vmul.vv v6, v1, v2, v0.t     # masked: e0,e2 written, e1,e3 keep 0x77
    vse32.v v6, (a2)
    CHK4 0x3C, 0x77, 0x80000000, 0x77, fail12

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
