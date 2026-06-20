# Phase 12 V5f directed test: whole-register + mask vector load/store.
#
# Exercises the unit-stride-family memory variants the VU now re-decodes from
# the lumop/sumop field:
#   - vl1re32.v / vs1r.v : whole-register move of ONE register (4 x int32).
#       Run with vl=1 to prove whole-register transfers ignore vl (all 4
#       elements move regardless).
#   - vl2re32.v / vs2r.v : whole-register move of TWO registers (8 x int32),
#       exercising the nf>0 (NREG=2) register-spanning path.
#   - vlm.v / vsm.v      : mask load/store of ceil(vl/8) bytes (EEW=8).
#
# tohost @ 0x80001000: 1 = PASS; 2..N = the failing check id.

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000           # tohost address

    # Enable the vector unit: mstatus.VS = Initial (01 in bits [10:9]).
    li   t0, (1 << 9)
    csrs mstatus, t0

    # Arrays in DRAM (clear of .text and the tohost page).
    li   a0, 0x80010000           # whole-register src (8 x int32 = 32 B)
    li   a1, 0x80010100           # whole-register dst
    li   a2, 0x80010200           # mask src (2 B)
    li   a3, 0x80010300           # mask dst

    # Seed src[0..7] with scalar stores (buffered → drain before the vector load).
    li   t1, 0x12340000
    sw   t1, 0(a0)
    li   t1, 0x12340001
    sw   t1, 4(a0)
    li   t1, 0x12340002
    sw   t1, 8(a0)
    li   t1, 0x12340003
    sw   t1, 12(a0)
    li   t1, 0x12340004
    sw   t1, 16(a0)
    li   t1, 0x12340005
    sw   t1, 20(a0)
    li   t1, 0x12340006
    sw   t1, 24(a0)
    li   t1, 0x12340007
    sw   t1, 28(a0)

    # ---- Whole-register single (vl1re32 / vs1r) ----------------------------
    # vl=1 deliberately: a whole-register move must transfer the FULL register
    # (4 x int32) regardless of the current vl.
    vsetivli t0, 1, e32, m1
    li   t1, 1
    bne  t0, t1, fail2

    vl1re32.v v8, (a0)            # v8 <- src[0..3] (all 4, vl ignored)
    vs1r.v    v8, (a1)            # dst[0..3] <- v8 (16 B, EEW=8)

    lwu  a4, 0(a1)
    li   t1, 0x12340000
    bne  a4, t1, fail3
    lwu  a4, 4(a1)
    li   t1, 0x12340001
    bne  a4, t1, fail4
    lwu  a4, 8(a1)
    li   t1, 0x12340002
    bne  a4, t1, fail5
    lwu  a4, 12(a1)
    li   t1, 0x12340003
    bne  a4, t1, fail6

    # ---- Whole-register pair (vl2re32 / vs2r, NREG=2) ----------------------
    li   a1, 0x80010140           # fresh dst for the 2-register move
    vl2re32.v v8, (a0)            # v8 <- src[0..3], v9 <- src[4..7]
    vs2r.v    v8, (a1)            # dst[0..7] <- {v8,v9} (32 B)

    lwu  a4, 0(a1)
    li   t1, 0x12340000
    bne  a4, t1, fail7
    lwu  a4, 12(a1)
    li   t1, 0x12340003
    bne  a4, t1, fail8           # last element of v8
    lwu  a4, 16(a1)
    li   t1, 0x12340004
    bne  a4, t1, fail9           # first element of v9
    lwu  a4, 28(a1)
    li   t1, 0x12340007
    bne  a4, t1, fail10          # last element of v9

    # ---- Mask load/store (vlm / vsm, ceil(vl/8) bytes) ---------------------
    # vsetivli e8, AVL=16 -> vl=16 -> evl = ceil(16/8) = 2 bytes.
    vsetivli t0, 16, e8, m1
    li   t1, 16
    bne  t0, t1, fail11

    li   t1, 0x5a
    sb   t1, 0(a2)
    li   t1, 0xc3
    sb   t1, 1(a2)

    vlm.v v1, (a2)               # v1 <- 2 mask bytes
    vsm.v v1, (a3)               # dst <- v1 (2 bytes)

    lbu  a4, 0(a3)
    li   t1, 0x5a
    bne  a4, t1, fail12
    lbu  a4, 1(a3)
    li   t1, 0xc3
    bne  a4, t1, fail13

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

done:
    j done
