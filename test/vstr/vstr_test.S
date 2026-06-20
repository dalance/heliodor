# Phase 12 V5h directed test: strided vector load/store (vlse/vsse).
#
# Exercises mop = 10, where each element's address is base + i*stride and the
# (signed, byte) stride comes from the 2nd int scalar x[rs2] (delivered to the
# VU on the new prf_int read port and read at the ROB head):
#   - vlse32.v positive stride (skip every other word)
#   - vsse32.v positive stride scatter (leaves gaps untouched)
#   - vlse32.v negative stride (reverses the array)
#   - vlse32.v zero stride via x0 (every element reads the same address)
#
# tohost @ 0x80001000: 1 = PASS; 2..N = the failing check id.

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000           # tohost address

    # Enable the vector unit: mstatus.VS = Initial (01 in bits [10:9]).
    li   t0, (1 << 9)
    csrs mstatus, t0

    li   a0, 0x80010000           # data (8 words, stride playground)
    li   a1, 0x80010100           # data2 (4 words, for negative stride)
    li   a2, 0x80010200           # readback dst
    li   a3, 0x80010300           # scatter source (4 words)
    li   a4, 0x80010400           # scatter base

    # Seed data[0..7] = 0xA0..0xA7 at byte offsets 0,4,...,28.
    li   t1, 0x000000a0
    sw   t1, 0(a0)
    li   t1, 0x000000a1
    sw   t1, 4(a0)
    li   t1, 0x000000a2
    sw   t1, 8(a0)
    li   t1, 0x000000a3
    sw   t1, 12(a0)
    li   t1, 0x000000a4
    sw   t1, 16(a0)
    li   t1, 0x000000a5
    sw   t1, 20(a0)
    li   t1, 0x000000a6
    sw   t1, 24(a0)
    li   t1, 0x000000a7
    sw   t1, 28(a0)

    # Seed data2[0..3] = 0xC0..0xC3.
    li   t1, 0x000000c0
    sw   t1, 0(a1)
    li   t1, 0x000000c1
    sw   t1, 4(a1)
    li   t1, 0x000000c2
    sw   t1, 8(a1)
    li   t1, 0x000000c3
    sw   t1, 12(a1)

    # Scatter source = [0xB0,0xB1,0xB2,0xB3].
    li   t1, 0x000000b0
    sw   t1, 0(a3)
    li   t1, 0x000000b1
    sw   t1, 4(a3)
    li   t1, 0x000000b2
    sw   t1, 8(a3)
    li   t1, 0x000000b3
    sw   t1, 12(a3)

    vsetivli t0, 4, e32, m1
    li   t1, 4
    bne  t0, t1, fail2

    # ---- Subtest A: vlse32 positive stride = 8 (skip every other word) -----
    li   t4, 8
    vlse32.v v4, (a0), t4         # v4[i] = data[i*8/4] = [a0,a2,a4,a6]
    vse32.v  v4, (a2)
    lwu  t1, 0(a2)
    li   t2, 0x000000a0
    bne  t1, t2, fail3
    lwu  t1, 4(a2)
    li   t2, 0x000000a2
    bne  t1, t2, fail4
    lwu  t1, 8(a2)
    li   t2, 0x000000a4
    bne  t1, t2, fail5
    lwu  t1, 12(a2)
    li   t2, 0x000000a6
    bne  t1, t2, fail6

    # ---- Subtest B: vsse32 positive stride = 8 scatter --------------------
    vle32.v  v6, (a3)            # v6 = [0xB0,0xB1,0xB2,0xB3]
    li   t4, 8
    vsse32.v v6, (a4), t4         # mem[a4 + i*8] = v6[i]
    lwu  t1, 0(a4)
    li   t2, 0x000000b0
    bne  t1, t2, fail7
    lwu  t1, 8(a4)
    li   t2, 0x000000b1
    bne  t1, t2, fail8
    lwu  t1, 16(a4)
    li   t2, 0x000000b2
    bne  t1, t2, fail9
    lwu  t1, 24(a4)
    li   t2, 0x000000b3
    bne  t1, t2, fail10

    # ---- Subtest C: vlse32 negative stride = -4 (reverse data2) ------------
    addi a6, a1, 12               # base = &data2[3]
    li   t4, -4
    vlse32.v v5, (a6), t4         # v5[i] = data2[3 - i] = [0xC3,0xC2,0xC1,0xC0]
    vse32.v  v5, (a2)
    lwu  t1, 0(a2)
    li   t2, 0x000000c3
    bne  t1, t2, fail11
    lwu  t1, 4(a2)
    li   t2, 0x000000c2
    bne  t1, t2, fail12
    lwu  t1, 12(a2)
    li   t2, 0x000000c0
    bne  t1, t2, fail13

    # ---- Subtest D: vlse32 zero stride (rs2 = x0) -------------------------
    vlse32.v v7, (a0), x0         # every element reads mem[a0] = 0xA0
    vse32.v  v7, (a2)
    lwu  t1, 0(a2)
    li   t2, 0x000000a0
    bne  t1, t2, fail14
    lwu  t1, 12(a2)
    li   t2, 0x000000a0
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
