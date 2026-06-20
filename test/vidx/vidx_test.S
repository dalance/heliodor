# Phase 12 V5g directed test: indexed (gather/scatter) vector load/store.
#
# Exercises mop = 01/11 (indexed-unordered / -ordered), where the per-element
# byte offset comes from the index vector vs2 and the data width is SEW:
#   - vluxei32.v : gather  vd[i] = mem[base + vs2[i]]   (index EEW = SEW = 32)
#   - vsuxei32.v : scatter mem[base + vs2[i]] = vs3[i]
#   - vluxei8.v  : gather with index EEW = 8 != data SEW = 32 (the EEW split)
#   - vloxei32.v : ordered gather (mop=11) — same result in the in-order VU
#
# tohost @ 0x80001000: 1 = PASS; 2..N = the failing check id.

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000           # tohost address

    # Enable the vector unit: mstatus.VS = Initial (01 in bits [10:9]).
    li   t0, (1 << 9)
    csrs mstatus, t0

    # Memory layout (DRAM, clear of .text and the tohost page).
    li   a0, 0x80010000           # gather data[0..3]
    li   a1, 0x80010040           # int32 index array [12,0,8,4]
    li   a2, 0x80010080           # byte  index array [12,0,8,4]
    li   a3, 0x800100c0           # gather readback dst
    li   a4, 0x80010100           # scatter source data[0..3]
    li   a5, 0x80010140           # scatter base

    # Seed gather data: data[i] = 0x100 + i at byte offset 4*i.
    li   t1, 0x00000100
    sw   t1, 0(a0)
    li   t1, 0x00000101
    sw   t1, 4(a0)
    li   t1, 0x00000102
    sw   t1, 8(a0)
    li   t1, 0x00000103
    sw   t1, 12(a0)

    # int32 index array = byte offsets [12, 0, 8, 4].
    li   t1, 12
    sw   t1, 0(a1)
    li   t1, 0
    sw   t1, 4(a1)
    li   t1, 8
    sw   t1, 8(a1)
    li   t1, 4
    sw   t1, 12(a1)

    # byte index array = [12, 0, 8, 4].
    li   t1, 12
    sb   t1, 0(a2)
    li   t1, 0
    sb   t1, 1(a2)
    li   t1, 8
    sb   t1, 2(a2)
    li   t1, 4
    sb   t1, 3(a2)

    # scatter source = [0x600, 0x601, 0x602, 0x603].
    li   t1, 0x00000600
    sw   t1, 0(a4)
    li   t1, 0x00000601
    sw   t1, 4(a4)
    li   t1, 0x00000602
    sw   t1, 8(a4)
    li   t1, 0x00000603
    sw   t1, 12(a4)

    vsetivli t0, 4, e32, m1
    li   t1, 4
    bne  t0, t1, fail2

    # ---- Subtest A: vluxei32 gather (index EEW = SEW = 32) -----------------
    vle32.v   v2, (a1)            # v2 = [12,0,8,4]
    vluxei32.v v4, (a0), v2       # v4[i] = data[ v2[i]/4 ]
    vse32.v   v4, (a3)            # store gather result for scalar readback

    lwu  t1, 0(a3)
    li   t2, 0x00000103
    bne  t1, t2, fail3            # v4[0] = data[12] = 0x103
    lwu  t1, 4(a3)
    li   t2, 0x00000100
    bne  t1, t2, fail4            # v4[1] = data[0]  = 0x100
    lwu  t1, 8(a3)
    li   t2, 0x00000102
    bne  t1, t2, fail5            # v4[2] = data[8]  = 0x102
    lwu  t1, 12(a3)
    li   t2, 0x00000101
    bne  t1, t2, fail6            # v4[3] = data[4]  = 0x101

    # ---- Subtest B: vsuxei32 scatter --------------------------------------
    vle32.v   v6, (a4)            # v6 = [0x600,0x601,0x602,0x603]
    vsuxei32.v v6, (a5), v2       # mem[a5 + v2[i]] = v6[i]

    lwu  t1, 0(a5)
    li   t2, 0x00000601
    bne  t1, t2, fail7           # a5+0  <- v6[1] (v2[1]=0)
    lwu  t1, 4(a5)
    li   t2, 0x00000603
    bne  t1, t2, fail8           # a5+4  <- v6[3] (v2[3]=4)
    lwu  t1, 8(a5)
    li   t2, 0x00000602
    bne  t1, t2, fail9           # a5+8  <- v6[2] (v2[2]=8)
    lwu  t1, 12(a5)
    li   t2, 0x00000600
    bne  t1, t2, fail10          # a5+12 <- v6[0] (v2[0]=12)

    # ---- Subtest C: vluxei8 gather, index EEW=8 != data SEW=32 -------------
    vsetivli t0, 4, e8, m1
    vle8.v    v3, (a2)            # v3 (bytes) = [12,0,8,4]
    vsetivli  t0, 4, e32, m1      # data SEW back to 32
    vluxei8.v v5, (a0), v3        # index EEW=8 (byte), data EEW=SEW=32
    vse32.v   v5, (a3)

    lwu  t1, 0(a3)
    li   t2, 0x00000103
    bne  t1, t2, fail11
    lwu  t1, 4(a3)
    li   t2, 0x00000100
    bne  t1, t2, fail12
    lwu  t1, 12(a3)
    li   t2, 0x00000101
    bne  t1, t2, fail13

    # ---- Subtest D: vloxei32 ordered gather (mop=11) ----------------------
    vloxei32.v v7, (a0), v2       # ordered — identical result in the in-order VU
    vse32.v    v7, (a3)
    lwu  t1, 0(a3)
    li   t2, 0x00000103
    bne  t1, t2, fail14
    lwu  t1, 12(a3)
    li   t2, 0x00000101
    bne  t1, t2, fail15

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
