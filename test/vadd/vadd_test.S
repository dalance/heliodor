# Phase 12 V0 directed test: vector config + first arithmetic + vmv.x.s.
#
# Exercises the whole V0 datapath:
#   - mstatus.VS enable (else every vector op traps illegal at commit)
#   - vsetvli (granted vl = VLMAX written to an int rd; vtype set)
#   - vadd.vx (scalar broadcast into a vector, reading v0 = 0)
#   - vadd.vv (vector + vector)
#   - vadd.vi (vector + sign-extended imm5)
#   - vmv.x.s (element 0 -> integer rd, the observability hook)
#
# tohost @ 0x80001000: 1 = PASS; 2/3/4 = the failing check.

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000           # tohost address

    # Enable the vector unit: mstatus.VS = Initial (01 in bits [10:9]).
    li   t0, (1 << 9)
    csrs mstatus, t0

    # vsetvli t0, x0, e64, m1 : SEW=64, LMUL=1, AVL=x0 -> vl=VLMAX=2 ; t0 = vl
    vsetvli t0, x0, e64, m1

    li   a0, 0x11
    li   a1, 0x22

    # v1 = a0 broadcast (v0 resets to 0): v1[i] = v0[i] + a0 = a0
    vadd.vx v1, v0, a0
    # v2 = a1 broadcast
    vadd.vx v2, v0, a1
    # v3[i] = v1[i] + v2[i] = a0 + a1
    vadd.vv v3, v1, v2
    # a2 = v3[element 0]  (sign-extended at SEW=64)
    vmv.x.s a2, v3

    li   t1, 0x33                 # 0x11 + 0x22
    bne  a2, t1, fail2
    li   t1, 2                    # vl must be VLMAX = 2
    bne  t0, t1, fail3

    # vadd.vi v4, v3, 5 -> v4[i] = v3[i] + 5 ; a3 = v4[0] = 0x38
    vadd.vi v4, v3, 5
    vmv.x.s a3, v4
    li   t1, 0x38
    bne  a3, t1, fail4

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
2:  j    2b
fail4:
    li   t0, 4
    sw   t0, 0(t3)
3:  j    3b
