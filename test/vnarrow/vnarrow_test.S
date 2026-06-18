# Phase 12 V2d-5 directed test: narrowing shifts vnsrl / vnsra (.wv/.wx/.wi).
# SEW=16 (result), source vs2 is 32-bit (2 regs v4,v5). Shift amounts > 16 make
# the sign-fill of vnsra reach the low 16 bits, distinguishing it from vnsrl.
#
#   src32 = [0x12345678, 0xFFFF0000, 0x00FF00FF, 0x80000000,
#            0xABCD1234, 0x0000FFFF, 0xFFFFFFFF, 0x40000000]
#   sh16  = [4, 20, 8, 24, 12, 0, 28, 18]
#
# tohost @ 0x80001000: 1 = PASS; 2.. = the failing check id.

    .macro CKH off, val, failL
        lhu  t5, \off(a2); li t6, \val; bne t5, t6, \failL
    .endm

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000
    li   t0, (1 << 9)
    csrs mstatus, t0

    li   a0, 0x80010000          # src32 (8 x int32)
    li   a1, 0x80010040          # sh16  (8 x int16)
    li   a2, 0x80010080          # dst   (8 x int16)
    li t1,0x12345678; sw t1,0(a0);  li t1,0xFFFF0000; sw t1,4(a0)
    li t1,0x00FF00FF; sw t1,8(a0);  li t1,0x80000000; sw t1,12(a0)
    li t1,0xABCD1234; sw t1,16(a0); li t1,0x0000FFFF; sw t1,20(a0)
    li t1,0xFFFFFFFF; sw t1,24(a0); li t1,0x40000000; sw t1,28(a0)
    li t1,4;  sh t1,0(a1); li t1,20; sh t1,2(a1); li t1,8;  sh t1,4(a1); li t1,24; sh t1,6(a1)
    li t1,12; sh t1,8(a1); li t1,0;  sh t1,10(a1); li t1,28; sh t1,12(a1); li t1,18; sh t1,14(a1)

    vsetvli t0, x0, e32, m2      # load 8 int32 source into v4,v5
    li   t1, 8
    bne  t0, t1, fail2
    vle32.v v4, (a0)
    vsetvli t0, x0, e16, m1      # load 8 int16 shifts into v6
    li   t1, 8
    bne  t0, t1, fail2
    vle16.v v6, (a1)

    # --- vnsrl.wv (logical) ---
    vnsrl.wv v8, v4, v6
    vse16.v v8, (a2)
    CKH 0,  0x4567, fail3
    CKH 2,  0x0FFF, fail3
    CKH 4,  0xFF00, fail3
    CKH 6,  0x0080, fail3
    CKH 8,  0xBCD1, fail3
    CKH 10, 0xFFFF, fail3
    CKH 12, 0x000F, fail3
    CKH 14, 0x1000, fail3

    # --- vnsra.wv (arithmetic; sign-fill differs at e1,e3,e6) ---
    vnsra.wv v8, v4, v6
    vse16.v v8, (a2)
    CKH 0,  0x4567, fail4
    CKH 2,  0xFFFF, fail4   # 0xFFFF0000 >>>20
    CKH 4,  0xFF00, fail4
    CKH 6,  0xFF80, fail4   # 0x80000000 >>>24
    CKH 8,  0xBCD1, fail4
    CKH 12, 0xFFFF, fail4   # 0xFFFFFFFF >>>28
    CKH 14, 0x1000, fail4

    # --- vnsrl.wx (scalar shift = 8) ---
    li   a3, 8
    vnsrl.wx v8, v4, a3
    vse16.v v8, (a2)
    CKH 0,  0x3456, fail5   # 0x12345678 >>8
    CKH 6,  0x0000, fail5   # 0x80000000 >>8 -> 0x00800000
    CKH 12, 0xFFFF, fail5   # 0xFFFFFFFF >>8 -> 0x00FFFFFF

    # --- vnsra.wi (imm shift = 20) ---
    vnsra.wi v8, v4, 20
    vse16.v v8, (a2)
    CKH 0,  0x0123, fail6   # 0x12345678 >>>20
    CKH 2,  0xFFFF, fail6   # 0xFFFF0000 >>>20
    CKH 6,  0xF800, fail6   # 0x80000000 >>>20

    li   t0, 1
    sw   t0, 0(t3)
0:  j    0b

fail2:  li t0,2; sw t0,0(t3); 20: j 20b
fail3:  li t0,3; sw t0,0(t3); 30: j 30b
fail4:  li t0,4; sw t0,0(t3); 40: j 40b
fail5:  li t0,5; sw t0,0(t3); 50: j 50b
fail6:  li t0,6; sw t0,0(t3); 60: j 60b
