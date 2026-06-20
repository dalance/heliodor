# Phase 12 V6 directed test: misa.V advertisement.
#
# Confirms misa now advertises the vector extension (bit 21 = V) alongside the
# pre-existing I/M/A bits, and that a V op actually runs (so the advertised bit
# is backed by a working unit) once mstatus.VS is enabled.
#
# tohost @ 0x80001000: 1 = PASS; 2..N = the failing check id.

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000           # tohost address

    csrr t0, misa

    # V bit (21) must be set.
    li   t1, (1 << 21)
    and  t2, t0, t1
    beqz t2, fail2

    # I bit (8) still set.
    li   t1, (1 << 8)
    and  t2, t0, t1
    beqz t2, fail3

    # M bit (12) still set.
    li   t1, (1 << 12)
    and  t2, t0, t1
    beqz t2, fail4

    # A bit (0) still set.
    li   t1, (1 << 0)
    and  t2, t0, t1
    beqz t2, fail5

    # The advertised V is backed by a working unit: enable VS and run a V op.
    li   t0, (1 << 9)             # mstatus.VS = Initial
    csrs mstatus, t0

    li   a0, 0x80010000
    li   t1, 0x000000aa
    sw   t1, 0(a0)
    li   t1, 0x000000bb
    sw   t1, 4(a0)
    li   t1, 0x000000cc
    sw   t1, 8(a0)
    li   t1, 0x000000dd
    sw   t1, 12(a0)

    vsetivli t0, 4, e32, m1
    li   t1, 4
    bne  t0, t1, fail6
    vle32.v v1, (a0)
    li   a1, 0x10
    vadd.vx v2, v1, a1            # v2 = v1 + 0x10
    vmv.x.s a2, v2
    li   t1, 0x000000ba           # 0xaa + 0x10
    bne  a2, t1, fail7

    li   t0, 1
    sw   t0, 0(t3)
    j    done

fail2:  li t0, 2; sw t0, 0(t3); j done
fail3:  li t0, 3; sw t0, 0(t3); j done
fail4:  li t0, 4; sw t0, 0(t3); j done
fail5:  li t0, 5; sw t0, 0(t3); j done
fail6:  li t0, 6; sw t0, 0(t3); j done
fail7:  li t0, 7; sw t0, 0(t3); j done

done:
    j done
