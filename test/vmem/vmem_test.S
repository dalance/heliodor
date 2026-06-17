# Phase 12 V1 directed test: unit-stride vector load/store (vle/vse).
#
# Exercises the whole V1 memory datapath end to end:
#   - scalar stores seed a source array (older stores → the vle must see them,
#     i.e. the VU waits for the store buffer to drain = Rule B load ordering)
#   - vle32.v   : unit-stride load of 4 x int32 into a vector register
#   - vmv.x.s   : element-0 readback of the load (observability)
#   - vadd.vx   : compute on the loaded vector (loaded data + scalar)
#   - vse32.v   : unit-stride store of the result back to a second array
#   - scalar lw : read the stored elements back. These loads sit AFTER the vse
#     in program order; the vse's commit forces a redirect that squashes and
#     re-fetches them, so they re-read the freshly stored data (Rule B store
#     ordering).
#
# tohost @ 0x80001000: 1 = PASS; 2..9 = the failing check id.

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000           # tohost address

    # Enable the vector unit: mstatus.VS = Initial (01 in bits [10:9]).
    li   t0, (1 << 9)
    csrs mstatus, t0

    # Source / destination arrays in DRAM (clear of .text and the tohost page).
    li   a0, 0x80010000           # src
    li   a1, 0x80010100           # dst

    # Seed src[0..3] with scalar stores (buffered → must drain before the vle).
    li   t1, 0x11111111
    sw   t1, 0(a0)
    li   t1, 0x22222222
    sw   t1, 4(a0)
    li   t1, 0x33333333
    sw   t1, 8(a0)
    li   t1, 0x44444444
    sw   t1, 12(a0)

    # vsetvli t0, x0, e32, m1 : SEW=32, LMUL=1, AVL=x0 -> vl=VLMAX=4 ; t0 = vl
    vsetvli t0, x0, e32, m1
    li   t1, 4
    bne  t0, t1, fail2            # VLMAX = 128/32 = 4

    # v1 = src[0..3]
    vle32.v v1, (a0)

    # element 0 of the load must equal src[0]
    vmv.x.s a2, v1
    li   t1, 0x11111111
    bne  a2, t1, fail3

    # v2[i] = v1[i] + 0x100
    li   a3, 0x100
    vadd.vx v2, v1, a3

    # store v2 -> dst[0..3]
    vse32.v v2, (a1)

    # verify each stored element = src[i] + 0x100
    lw   a4, 0(a1)
    li   t1, 0x11111211
    bne  a4, t1, fail4
    lw   a4, 4(a1)
    li   t1, 0x22222322
    bne  a4, t1, fail5
    lw   a4, 8(a1)
    li   t1, 0x33333433
    bne  a4, t1, fail6
    lw   a4, 12(a1)
    li   t1, 0x44444544
    bne  a4, t1, fail7

    # Also exercise SEW=64 / vl=2 (a different EEW path) on the same data.
    vsetvli t0, x0, e64, m1       # SEW=64 -> VLMAX = 2
    li   t1, 2
    bne  t0, t1, fail8
    vle64.v v3, (a0)              # v3[0] = src[1..0] packed = 0x2222222211111111
    vmv.x.s a2, v3
    li   t1, 0x22222222
    slli t1, t1, 32
    li   t2, 0x11111111
    or   t1, t1, t2               # 0x2222222211111111
    bne  a2, t1, fail9

    # --- masked store: write only elements where v0[i] == 1 ---
    # Build the mask register v0 with bit pattern 0b0101 (elements 0,2 active).
    li   a5, 0x80010200           # mask-byte scratch
    li   t1, 0x05                 # mask bits [3:0] = 0101
    sb   t1, 0(a5)
    li   t1, 1
    vsetvli t0, t1, e8, m1        # SEW=8, vl=1: load just the mask byte into v0[7:0]
    vle8.v  v0, (a5)              # v0 = ...00_05 (mask bit i = element-i enable)

    # Pre-fill the masked destination with a sentinel.
    li   a6, 0x80010300
    li   t1, 0x77777777
    sw   t1, 0(a6)
    sw   t1, 4(a6)
    sw   t1, 8(a6)
    sw   t1, 12(a6)

    # Masked store v2 (= src+0x100) at SEW=32, vl=4, mask = v0.
    vsetvli t0, x0, e32, m1       # vl = 4
    vse32.v v2, (a6), v0.t        # writes elements 0 and 2 only

    lw   a4, 0(a6)                # element 0: written
    li   t1, 0x11111211
    bne  a4, t1, fail10
    lw   a4, 4(a6)                # element 1: masked off → sentinel preserved
    li   t1, 0x77777777
    bne  a4, t1, fail11
    lw   a4, 8(a6)                # element 2: written
    li   t1, 0x33333433
    bne  a4, t1, fail12
    lw   a4, 12(a6)               # element 3: masked off → sentinel preserved
    li   t1, 0x77777777
    bne  a4, t1, fail13

    li   t0, 1                    # PASS
    sw   t0, 0(t3)
0:  j    0b

fail2:
    li   t0, 2
    sw   t0, 0(t3)
1:  j    1b
fail3:
    li   t0, 3
    sw   t0, 0(t3)
3:  j    3b
fail4:
    li   t0, 4
    sw   t0, 0(t3)
4:  j    4b
fail5:
    li   t0, 5
    sw   t0, 0(t3)
5:  j    5b
fail6:
    li   t0, 6
    sw   t0, 0(t3)
6:  j    6b
fail7:
    li   t0, 7
    sw   t0, 0(t3)
7:  j    7b
fail8:
    li   t0, 8
    sw   t0, 0(t3)
8:  j    8b
fail9:
    li   t0, 9
    sw   t0, 0(t3)
9:  j    9b
fail10:
    li   t0, 10
    sw   t0, 0(t3)
10: j    10b
fail11:
    li   t0, 11
    sw   t0, 0(t3)
11: j    11b
fail12:
    li   t0, 12
    sw   t0, 0(t3)
12: j    12b
fail13:
    li   t0, 13
    sw   t0, 0(t3)
13: j    13b
