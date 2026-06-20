# Phase 12 V5i directed test: vsetvl register form (vtype = x[rs2]).
#
# The register form (funct7 1000000) takes a DYNAMIC vtype from x[rs2] instead
# of an immediate. The VU reads it on the 2nd int-scalar port (the rs2 plumbing
# added for strided vlse/vsse), at the ROB head. Exercises:
#   - vl computation for several dynamic vtypes (SEW/LMUL change VLMAX)
#   - AVL clamping to VLMAX (AVL > VLMAX -> vl = VLMAX)
#   - rs1 = x0 -> request VLMAX
#   - end-to-end: a register-form vsetvl that actually drives a vle32 + vmv.x.s
#
# vtype encoding: bits[2:0]=vlmul, bits[5:3]=vsew. e32,m1 = 0x10; e64,m1 = 0x18;
# e16,m1 = 0x08; e32,m2 = 0x11. VLMAX = VLEN/SEW * LMUL (VLEN=128).
#
# tohost @ 0x80001000: 1 = PASS; 2..N = the failing check id.

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000           # tohost address

    # Enable the vector unit: mstatus.VS = Initial (01 in bits [10:9]).
    li   t0, (1 << 9)
    csrs mstatus, t0

    li   a0, 0x80010000           # data array

    # Seed data[0..3].
    li   t1, 0x11111111
    sw   t1, 0(a0)
    li   t1, 0x22222222
    sw   t1, 4(a0)
    li   t1, 0x33333333
    sw   t1, 8(a0)
    li   t1, 0x44444444
    sw   t1, 12(a0)

    # ---- Check A: vsetvl AVL=3, vtype=e32,m1 -> vl = min(3, VLMAX=4) = 3 ----
    li   a1, 3                    # AVL
    li   a2, 0x10                 # vtype = e32, m1
    vsetvl t0, a1, a2
    li   t1, 3
    bne  t0, t1, fail2

    # ---- Check B: vsetvl rs1=x0, vtype=e64,m1 -> vl = VLMAX = 2 -------------
    li   a2, 0x18                 # vtype = e64, m1
    vsetvl t0, x0, a2
    li   t1, 2
    bne  t0, t1, fail3

    # ---- Check C: vsetvl rs1=x0, vtype=e16,m1 -> vl = VLMAX = 8 -------------
    li   a2, 0x08                 # vtype = e16, m1
    vsetvl t0, x0, a2
    li   t1, 8
    bne  t0, t1, fail4

    # ---- Check D: vsetvl AVL=10 (>VLMAX), vtype=e32,m1 -> vl = VLMAX = 4 ----
    li   a1, 10                   # AVL > VLMAX
    li   a2, 0x10                 # vtype = e32, m1
    vsetvl t0, a1, a2
    li   t1, 4
    bne  t0, t1, fail5

    # ---- Check E: vsetvl rs1=x0, vtype=e32,m2 -> vl = VLMAX = 8 -------------
    li   a2, 0x11                 # vtype = e32, m2 (vlmul=001)
    vsetvl t0, x0, a2
    li   t1, 8
    bne  t0, t1, fail6

    # ---- Check F: register-form vsetvl drives a real vle32 + vmv.x.s -------
    li   a1, 4                    # AVL
    li   a2, 0x10                 # vtype = e32, m1
    vsetvl t0, a1, a2            # vl = 4, SEW = 32
    li   t1, 4
    bne  t0, t1, fail7
    vle32.v v1, (a0)             # v1 = data[0..3]
    vmv.x.s a3, v1
    li   t1, 0x11111111
    bne  a3, t1, fail8           # element 0 = data[0] (proves SEW=32 took effect)

    # All checks passed.
    li   t0, 1
    sw   t0, 0(t3)
    j    done

fail2:  li t0, 2; sw t0, 0(t3); j done
fail3:  li t0, 3; sw t0, 0(t3); j done
fail4:  li t0, 4; sw t0, 0(t3); j done
fail5:  li t0, 5; sw t0, 0(t3); j done
fail6:  li t0, 6; sw t0, 0(t3); j done
fail7:  li t0, 7; sw t0, 0(t3); j done
fail8:  li t0, 8; sw t0, 0(t3); j done

done:
    j done
