# Phase 12 V4i permute directed test: vrgather(.vv/.vx/.vi), vrgatherei16.vv,
# vslideup/vslidedown(.vi), vslide1up/vslide1down(.vx), vcompress.vm, and an
# LMUL=2 cross-register vrgather (reverse). Exercises the data-dependent
# vs1->idx->vs2 gather read that the VINT_PIPE FETCH cut splits across two cycles
# (so this is the correctness gate for that flip — the result must be identical
# whether the gather addressing is live or registered).
#
# Base data v2 = [10, 20, 30, 40] (SEW=32, vl=VLMAX=4).
#
# tohost @ 0x80001000: 1 = PASS; 2.. = the failing check id.

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000           # tohost
    li   t0, (1 << 9)             # mstatus.VS = Initial
    csrs mstatus, t0

    li   a0, 0x80010000           # m1 data src
    li   a1, 0x80010040           # scratch (indices / masks / presets)
    li   a2, 0x80010080           # dst scratch

    # m1 data = [10, 20, 30, 40]
    li   t1, 10; sw t1, 0(a0)
    li   t1, 20; sw t1, 4(a0)
    li   t1, 30; sw t1, 8(a0)
    li   t1, 40; sw t1, 12(a0)

    vsetvli t0, x0, e32, m1       # SEW=32, vl=VLMAX=4
    li   t1, 4
    bne  t0, t1, fail99

    vle32.v v2, (a0)              # v2 = [10,20,30,40]

    # ---- T1: vrgather.vv idx=[3,0,2,1] -> [40,10,30,20] ----
    li   t1, 3; sw t1, 0(a1)
    li   t1, 0; sw t1, 4(a1)
    li   t1, 2; sw t1, 8(a1)
    li   t1, 1; sw t1, 12(a1)
    vle32.v v1, (a1)
    vrgather.vv v3, v2, v1
    vse32.v v3, (a2)
    lwu t1, 0(a2);  li t2, 40; bne t1, t2, fail2
    lwu t1, 4(a2);  li t2, 10; bne t1, t2, fail2
    lwu t1, 8(a2);  li t2, 30; bne t1, t2, fail2
    lwu t1, 12(a2); li t2, 20; bne t1, t2, fail2

    # ---- T2: vrgather.vx idx=2 (broadcast) -> [30,30,30,30] ----
    li   t4, 2
    vrgather.vx v3, v2, t4
    vse32.v v3, (a2)
    lwu t1, 0(a2);  li t2, 30; bne t1, t2, fail3
    lwu t1, 12(a2); li t2, 30; bne t1, t2, fail3

    # ---- T3: vrgather.vi idx=1 (broadcast) -> [20,20,20,20] ----
    vrgather.vi v3, v2, 1
    vse32.v v3, (a2)
    lwu t1, 0(a2);  li t2, 20; bne t1, t2, fail4
    lwu t1, 8(a2);  li t2, 20; bne t1, t2, fail4

    # ---- T4: vrgather.vv OOB idx=[4,5,0,100] -> [0,0,10,0] ----
    li   t1, 4;   sw t1, 0(a1)
    li   t1, 5;   sw t1, 4(a1)
    li   t1, 0;   sw t1, 8(a1)
    li   t1, 100; sw t1, 12(a1)
    vle32.v v1, (a1)
    vrgather.vv v3, v2, v1
    vse32.v v3, (a2)
    lwu t1, 0(a2);  li t2, 0;  bne t1, t2, fail5
    lwu t1, 4(a2);  li t2, 0;  bne t1, t2, fail5
    lwu t1, 8(a2);  li t2, 10; bne t1, t2, fail5
    lwu t1, 12(a2); li t2, 0;  bne t1, t2, fail5

    # ---- T5: vrgatherei16.vv 16b idx [3,0,2,1] -> [40,10,30,20] ----
    # packed 16b: word0 = (idx1<<16)|idx0 = 0x00000003, word1 = (idx3<<16)|idx2 = 0x00010002
    li   t1, 0x00000003; sw t1, 0(a1)
    li   t1, 0x00010002; sw t1, 4(a1)
    li   t1, 0;          sw t1, 8(a1)
    li   t1, 0;          sw t1, 12(a1)
    vle32.v v5, (a1)
    vrgatherei16.vv v3, v2, v5
    vse32.v v3, (a2)
    lwu t1, 0(a2);  li t2, 40; bne t1, t2, fail6
    lwu t1, 4(a2);  li t2, 10; bne t1, t2, fail6
    lwu t1, 8(a2);  li t2, 30; bne t1, t2, fail6
    lwu t1, 12(a2); li t2, 20; bne t1, t2, fail6

    # ---- T6: vslideup.vi off=1, preset vd=[99,99,99,99] -> [99,10,20,30] ----
    li   t1, 99; sw t1, 0(a1); sw t1, 4(a1); sw t1, 8(a1); sw t1, 12(a1)
    vle32.v v3, (a1)             # preset v3 (undisturbed prefix source)
    vslideup.vi v3, v2, 1
    vse32.v v3, (a2)
    lwu t1, 0(a2);  li t2, 99; bne t1, t2, fail7
    lwu t1, 4(a2);  li t2, 10; bne t1, t2, fail7
    lwu t1, 8(a2);  li t2, 20; bne t1, t2, fail7
    lwu t1, 12(a2); li t2, 30; bne t1, t2, fail7

    # ---- T7: vslidedown.vi off=1 -> [20,30,40,0] ----
    vslidedown.vi v3, v2, 1
    vse32.v v3, (a2)
    lwu t1, 0(a2);  li t2, 20; bne t1, t2, fail8
    lwu t1, 4(a2);  li t2, 30; bne t1, t2, fail8
    lwu t1, 8(a2);  li t2, 40; bne t1, t2, fail8
    lwu t1, 12(a2); li t2, 0;  bne t1, t2, fail8

    # ---- T8: vslide1up.vx scalar=7 -> [7,10,20,30] ----
    li   t4, 7
    vslide1up.vx v3, v2, t4
    vse32.v v3, (a2)
    lwu t1, 0(a2);  li t2, 7;  bne t1, t2, fail9
    lwu t1, 4(a2);  li t2, 10; bne t1, t2, fail9
    lwu t1, 12(a2); li t2, 30; bne t1, t2, fail9

    # ---- T9: vslide1down.vx scalar=7 -> [20,30,40,7] ----
    li   t4, 7
    vslide1down.vx v3, v2, t4
    vse32.v v3, (a2)
    lwu t1, 0(a2);  li t2, 20; bne t1, t2, fail10
    lwu t1, 8(a2);  li t2, 40; bne t1, t2, fail10
    lwu t1, 12(a2); li t2, 7;  bne t1, t2, fail10

    # ---- T10: vcompress.vm mask=0xA (elems 1,3), preset vd=[88,88,88,88] -> [20,40,88,88] ----
    li   t1, 0xA; sw t1, 0(a1)   # vs1 bits[3:0]=1010
    li   t1, 0;   sw t1, 4(a1); sw t1, 8(a1); sw t1, 12(a1)
    vle32.v v1, (a1)             # v1 = compress mask
    li   t1, 88; sw t1, 0(a1); sw t1, 4(a1); sw t1, 8(a1); sw t1, 12(a1)
    vle32.v v3, (a1)             # preset v3 = [88,88,88,88]
    vcompress.vm v3, v2, v1
    vse32.v v3, (a2)
    lwu t1, 0(a2);  li t2, 20; bne t1, t2, fail11
    lwu t1, 4(a2);  li t2, 40; bne t1, t2, fail11
    lwu t1, 8(a2);  li t2, 88; bne t1, t2, fail11
    lwu t1, 12(a2); li t2, 88; bne t1, t2, fail11

    # ---- T11: LMUL=2 vrgather.vv reverse [10..80] idx [7..0] -> [80,70,..,10] ----
    li   a3, 0x80010100          # m2 data
    li   a4, 0x80010140          # m2 index
    li   t1, 10; sw t1, 0(a3)
    li   t1, 20; sw t1, 4(a3)
    li   t1, 30; sw t1, 8(a3)
    li   t1, 40; sw t1, 12(a3)
    li   t1, 50; sw t1, 16(a3)
    li   t1, 60; sw t1, 20(a3)
    li   t1, 70; sw t1, 24(a3)
    li   t1, 80; sw t1, 28(a3)
    li   t1, 7; sw t1, 0(a4)
    li   t1, 6; sw t1, 4(a4)
    li   t1, 5; sw t1, 8(a4)
    li   t1, 4; sw t1, 12(a4)
    li   t1, 3; sw t1, 16(a4)
    li   t1, 2; sw t1, 20(a4)
    li   t1, 1; sw t1, 24(a4)
    li   t1, 0; sw t1, 28(a4)
    vsetvli t0, x0, e32, m2       # SEW=32, LMUL=2, vl=VLMAX=8
    li   t1, 8
    bne  t0, t1, fail98
    vle32.v v4, (a3)             # v4:v5 = [10..80]
    vle32.v v2, (a4)             # v2:v3 = [7..0]
    vrgather.vv v6, v4, v2       # v6:v7 = reverse
    vse32.v v6, (a2)
    lwu t1, 0(a2);  li t2, 80; bne t1, t2, fail12
    lwu t1, 4(a2);  li t2, 70; bne t1, t2, fail12
    lwu t1, 8(a2);  li t2, 60; bne t1, t2, fail12
    lwu t1, 12(a2); li t2, 50; bne t1, t2, fail12
    lwu t1, 16(a2); li t2, 40; bne t1, t2, fail12
    lwu t1, 20(a2); li t2, 30; bne t1, t2, fail12
    lwu t1, 24(a2); li t2, 20; bne t1, t2, fail12
    lwu t1, 28(a2); li t2, 10; bne t1, t2, fail12

    # ---- all passed ----
    li   t0, 1
    sw   t0, 0(t3)
    j    done

fail2:  li t0, 2;  sw t0, 0(t3); j done
fail3:  li t0, 3;  sw t0, 0(t3); j done
fail4:  li t0, 4;  sw t0, 0(t3); j done
fail5:  li t0, 5;  sw t0, 0(t3); j done
fail6:  li t0, 6;  sw t0, 0(t3); j done
fail7:  li t0, 7;  sw t0, 0(t3); j done
fail8:  li t0, 8;  sw t0, 0(t3); j done
fail9:  li t0, 9;  sw t0, 0(t3); j done
fail10: li t0, 10; sw t0, 0(t3); j done
fail11: li t0, 11; sw t0, 0(t3); j done
fail12: li t0, 12; sw t0, 0(t3); j done
fail98: li t0, 98; sw t0, 0(t3); j done
fail99: li t0, 99; sw t0, 0(t3); j done

done:
    fence
1:  j 1b

    .section .tohost
    .align 3
tohost: .dword 0
