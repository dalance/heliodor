# Phase 12 V2d-3 directed test: LMUL>1 unit-stride memory (vle/vse spanning
# multiple vector registers). src[i] = 0x100 + i.
#
#   - LMUL=2 SEW=32 (vl=8) : vle32 -> v8,v9 ; vse32 -> dst1 ; check roundtrip
#                            and the per-register load split (vmv.x.s v8 / v9).
#   - LMUL=4 SEW=32 (vl=16): vle32 -> v16..v19 ; vse32 -> dst2 ; check.
#   - LMUL=2 masked vse (v0=0xA5): only active elements stored; rest keep 0xEE.
#
# tohost @ 0x80001000: 1 = PASS; 2.. = the failing check id.

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000
    li   t0, (1 << 9)             # mstatus.VS = Initial
    csrs mstatus, t0

    # Seed src[0..15] = 0x100 + i  (scalar stores; the vle must observe them).
    li   a0, 0x80010000
    li   t0, 0
    li   t1, 16
    li   t2, 0x100
1:  sw   t2, 0(a0); addi a0, a0, 4; addi t2, t2, 1; addi t0, t0, 1; blt t0, t1, 1b
    li   a0, 0x80010000          # src base
    li   a1, 0x80010080          # dst1
    li   a2, 0x800100C0          # dst2
    li   a3, 0x80010140          # dst3

    # --- LMUL=2 SEW=32 (vl=8): vle32 v8,(a0) ; vse32 v8,(a1) ---
    vsetvli t0, x0, e32, m2
    li   t1, 8
    bne  t0, t1, fail2
    vle32.v v8, (a0)
    vse32.v v8, (a1)
    # check dst1[0..7] == src[0..7]
    li   t0, 0; li t1, 8; li t2, 0x100; mv t4, a1
2:  lwu  t5, 0(t4); bne t5, t2, fail3; addi t4, t4, 4; addi t2, t2, 1; addi t0, t0, 1; blt t0, t1, 2b
    # per-register load split: v8[0]=src[0]=0x100, v9[0]=src[4]=0x104
    vmv.x.s t5, v8;  li t2, 0x100; bne t5, t2, fail4
    vmv.x.s t5, v9;  li t2, 0x104; bne t5, t2, fail4

    # --- LMUL=4 SEW=32 (vl=16): vle32 v16,(a0) ; vse32 v16,(a2) ---
    vsetvli t0, x0, e32, m4
    li   t1, 16
    bne  t0, t1, fail5
    vle32.v v16, (a0)
    vse32.v v16, (a2)
    li   t0, 0; li t1, 16; li t2, 0x100; mv t4, a2
3:  lwu  t5, 0(t4); bne t5, t2, fail6; addi t4, t4, 4; addi t2, t2, 1; addi t0, t0, 1; blt t0, t1, 3b
    # 4-register load split: v16[0]=0x100, v17[0]=0x104, v18[0]=0x108, v19[0]=0x10C
    vmv.x.s t5, v16; li t2, 0x100; bne t5, t2, fail7
    vmv.x.s t5, v17; li t2, 0x104; bne t5, t2, fail7
    vmv.x.s t5, v18; li t2, 0x108; bne t5, t2, fail7
    vmv.x.s t5, v19; li t2, 0x10C; bne t5, t2, fail7

    # --- LMUL=2 masked vse (v0=0xA5 active 0,2,5,7); dst3 pre-filled 0xEE ---
    li   t0, 0; li t1, 8; li t2, 0xEE; mv t4, a3
4:  sw   t2, 0(t4); addi t4, t4, 4; addi t0, t0, 1; blt t0, t1, 4b
    li   a4, 0x800101C0
    li   t1, 0xA5; sb t1, 0(a4)
    li   t1, 1
    vsetvli t0, t1, e8, m1
    vle8.v  v0, (a4)             # v0[7:0] = 0xA5
    vsetvli t0, x0, e32, m2     # vl=8
    vse32.v v8, (a3), v0.t      # store active 0,2,5,7 from v8/v9 (= src)
    # check: active -> src, inactive -> 0xEE
    lwu t5, 0(a3);  li t2, 0x100; bne t5, t2, fail8   # e0 active
    lwu t5, 4(a3);  li t2, 0xEE;  bne t5, t2, fail8   # e1 inactive
    lwu t5, 8(a3);  li t2, 0x102; bne t5, t2, fail8   # e2 active
    lwu t5, 12(a3); li t2, 0xEE;  bne t5, t2, fail8   # e3 inactive
    lwu t5, 16(a3); li t2, 0xEE;  bne t5, t2, fail8   # e4 inactive
    lwu t5, 20(a3); li t2, 0x105; bne t5, t2, fail8   # e5 active
    lwu t5, 24(a3); li t2, 0xEE;  bne t5, t2, fail8   # e6 inactive
    lwu t5, 28(a3); li t2, 0x107; bne t5, t2, fail8   # e7 active

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
