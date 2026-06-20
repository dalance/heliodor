# Phase 12 V5j directed test: segment vector load/store (vlseg/vsseg).
#
# Segment ops (unit-stride family, nf>0) move an array of NF-field structs:
# field f of element i is at base + (i*NF + f)*EEW and lands in register vd+f,
# element i. Exercises:
#   - vlseg2e32.v : deinterleave AoS {x,y} into two registers (x's, y's)
#   - vsseg2e32.v : interleave two registers back to AoS
#   - vlseg3e32.v : NF=3 deinterleave {r,g,b}
#
# tohost @ 0x80001000: 1 = PASS; 2..N = the failing check id.

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000           # tohost address

    # Enable the vector unit: mstatus.VS = Initial (01 in bits [10:9]).
    li   t0, (1 << 9)
    csrs mstatus, t0

    li   a0, 0x80010000           # AoS source {x,y} x 4
    li   a1, 0x80010100           # interleave dst
    li   a2, 0x80010200           # AoS3 source {r,g,b} x 4
    li   a3, 0x80010300           # scalar readback dst

    # Seed AoS {x0,y0, x1,y1, x2,y2, x3,y3} = {10,20,11,21,12,22,13,23}.
    li   t1, 10
    sw   t1, 0(a0)
    li   t1, 20
    sw   t1, 4(a0)
    li   t1, 11
    sw   t1, 8(a0)
    li   t1, 21
    sw   t1, 12(a0)
    li   t1, 12
    sw   t1, 16(a0)
    li   t1, 22
    sw   t1, 20(a0)
    li   t1, 13
    sw   t1, 24(a0)
    li   t1, 23
    sw   t1, 28(a0)

    vsetivli t0, 4, e32, m1
    li   t1, 4
    bne  t0, t1, fail2

    # ---- Subtest A: vlseg2e32 deinterleave -> v2 = x's, v3 = y's ----------
    vlseg2e32.v v2, (a0)         # v2 = [10,11,12,13], v3 = [20,21,22,23]
    # store v2, v3 contiguously and read back to verify the split.
    vse32.v v2, (a3)             # dst[0..3] = x's
    lwu  t1, 0(a3)
    li   t2, 10
    bne  t1, t2, fail3
    lwu  t1, 4(a3)
    li   t2, 11
    bne  t1, t2, fail4
    lwu  t1, 12(a3)
    li   t2, 13
    bne  t1, t2, fail5
    vse32.v v3, (a3)             # dst[0..3] = y's
    lwu  t1, 0(a3)
    li   t2, 20
    bne  t1, t2, fail6
    lwu  t1, 12(a3)
    li   t2, 23
    bne  t1, t2, fail7

    # ---- Subtest B: vsseg2e32 interleave v2,v3 -> AoS at a1 ---------------
    vsseg2e32.v v2, (a1)         # a1: {x0,y0,x1,y1,...} = {10,20,11,21,...}
    lwu  t1, 0(a1)
    li   t2, 10
    bne  t1, t2, fail8
    lwu  t1, 4(a1)
    li   t2, 20
    bne  t1, t2, fail9
    lwu  t1, 8(a1)
    li   t2, 11
    bne  t1, t2, fail10
    lwu  t1, 28(a1)
    li   t2, 23
    bne  t1, t2, fail11          # last = y3 = 23

    # ---- Subtest C: vlseg3e32 NF=3 deinterleave {r,g,b} ------------------
    # Seed AoS3 {r0,g0,b0, r1,g1,b1, r2,g2,b2} = {1,2,3, 4,5,6, 7,8,9}.
    li   t1, 1
    sw   t1, 0(a2)
    li   t1, 2
    sw   t1, 4(a2)
    li   t1, 3
    sw   t1, 8(a2)
    li   t1, 4
    sw   t1, 12(a2)
    li   t1, 5
    sw   t1, 16(a2)
    li   t1, 6
    sw   t1, 20(a2)
    li   t1, 7
    sw   t1, 24(a2)
    li   t1, 8
    sw   t1, 28(a2)
    li   t1, 9
    sw   t1, 32(a2)

    vsetivli t0, 3, e32, m1      # vl = 3 elements
    vlseg3e32.v v4, (a2)         # v4 = r = [1,4,7], v5 = g = [2,5,8], v6 = b = [3,6,9]
    vse32.v v4, (a3)
    lwu  t1, 0(a3)
    li   t2, 1
    bne  t1, t2, fail12
    lwu  t1, 8(a3)
    li   t2, 7
    bne  t1, t2, fail13          # r[2] = 7
    vse32.v v5, (a3)
    lwu  t1, 4(a3)
    li   t2, 5
    bne  t1, t2, fail14          # g[1] = 5
    vse32.v v6, (a3)
    lwu  t1, 8(a3)
    li   t2, 9
    bne  t1, t2, fail15          # b[2] = 9

    # All checks passed.
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
fail13: li t0, 13; sw t0, 0(t3); j done
fail14: li t0, 14; sw t0, 0(t3); j done
fail15: li t0, 15; sw t0, 0(t3); j done

done:
    j done
