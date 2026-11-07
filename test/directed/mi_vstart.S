// Vector instructions that start with vstart != 0.
//
// Spec: an arithmetic instruction may raise illegal-instruction when vstart
// is nonzero (this core does, as do the scalar moves); a load or store
// resumes at element vstart and leaves the prestart elements of vd
// undisturbed, and is reserved (illegal on this core) when vstart >= VLMAX.
// An illegal-instruction trap leaves vstart unchanged.
// tohost: 1, or the number of the failing check:
//   2-6  vadd.vv, vmv.x.s, vfadd.vv, vredsum.vs, vmseq.vv at vstart 1: no
//        cause 2 with mtval the instruction, vstart changed or vd written
//   7    vle32.v at vstart 2: elements 0-1 not undisturbed or 2-3 not loaded
//   8    vse32.v at vstart 2: elements 0-1 stored or 2-3 not stored
//   9    vle32.v at vstart 3 >= vl 2: wrote vd, trapped or left vstart
//   10   vle32.v at vstart 4 = VLMAX: no cause 2, or vstart changed
//   11   vl1re32.v at vstart 2: elements 0-1 not undisturbed or 2-3 not
//        loaded
//   12   vstart not 0 after 7, 8, 9 or 11
#include "common/probe.h"

.macro VSTART n
    li      t0, \n
    csrw    vstart, t0
.endm

// The instruction at \lbl trapped with cause 2 and mtval its encoding, and
// vstart still reads \vst.
.macro ILL code, lbl, vst
    la      t6, trap_rec
    li      a0, \code
    ld      t5, 24(t6)
    beqz    t5, fail
    sd      zero, 24(t6)
    ld      t5, 0(t6)
    li      t4, 2
    bne     t5, t4, fail
    ld      t5, 8(t6)
    la      t4, \lbl
    lwu     t4, 0(t4)
    bne     t5, t4, fail
    csrr    t5, vstart
    li      t4, \vst
    bne     t5, t4, fail
    csrw    vstart, zero
.endm

.macro NOTRAP code
    la      t6, trap_rec
    li      a0, \code
    ld      t5, 24(t6)
    bnez    t5, fail
.endm

.macro VSTART0
    li      a0, 12
    csrr    t0, vstart
    bnez    t0, fail
.endm

// Element \i of \vd (e32) reads \val; clobbers t0, t1, v31.
.macro ELEM vd, i, val
    vslidedown.vi v31, \vd, \i
    vmv.x.s t0, v31
    li      t1, \val
    bne     t0, t1, fail
.endm

    .section .text
main:
    li      t0, MSTATUS_VS_INIT | MSTATUS_FS_INIT
    csrs    mstatus, t0
    li      s1, SCRATCH
    li      t0, 0x0000000400000003
    sd      t0, 0(s1)
    li      t0, 0x0000000600000005
    sd      t0, 8(s1)
    sd      zero, 32(s1)
    sd      zero, 40(s1)
    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.i v2, 7
    vmv.v.i v3, 2
    li      t3, 1

    SET_RESUME 1f
    vmv.v.i v1, 9
    VSTART  1
i_vadd:
    vadd.vv v1, v2, v3
1:  ILL     2, i_vadd, 1
    ELEM    v1, 1, 9

    SET_RESUME 1f
    VSTART  1
i_vmvxs:
    vmv.x.s t3, v2
1:  ILL     3, i_vmvxs, 1
    li      t0, 1
    bne     t3, t0, fail

    SET_RESUME 1f
    VSTART  1
i_vfadd:
    vfadd.vv v1, v2, v3
1:  ILL     4, i_vfadd, 1
    ELEM    v1, 1, 9

    SET_RESUME 1f
    VSTART  1
i_vred:
    vredsum.vs v1, v2, v3
1:  ILL     5, i_vred, 1
    ELEM    v1, 0, 9

    SET_RESUME 1f
    VSTART  1
i_vmseq:
    vmseq.vv v1, v2, v3
1:  ILL     6, i_vmseq, 1
    ELEM    v1, 0, 9

    SET_RESUME 1f
    vmv.v.i v1, 9
    VSTART  2
    vle32.v v1, (s1)
1:  NOTRAP  7
    VSTART0
    li      a0, 7
    ELEM    v1, 0, 9
    ELEM    v1, 1, 9
    ELEM    v1, 2, 5
    ELEM    v1, 3, 6

    SET_RESUME 1f
    VSTART  2
    addi    t2, s1, 32
    vse32.v v2, (t2)
1:  NOTRAP  8
    VSTART0
    li      a0, 8
    ld      t0, 32(s1)
    bnez    t0, fail
    ld      t0, 40(s1)
    li      t1, 0x0000000700000007
    bne     t0, t1, fail

    SET_RESUME 1f
    vmv.v.i v1, 9
    vsetivli zero, 2, e32, m1, tu, mu
    VSTART  3
    vle32.v v1, (s1)
1:  NOTRAP  9
    VSTART0
    li      a0, 9
    vsetivli zero, 4, e32, m1, tu, mu
    ELEM    v1, 0, 9
    ELEM    v1, 3, 9

    SET_RESUME 1f
    VSTART  4
i_vle_oob:
    vle32.v v1, (s1)
1:  ILL     10, i_vle_oob, 4
    ELEM    v1, 0, 9

    SET_RESUME 1f
    vmv.v.i v1, 9
    VSTART  2
    vl1re32.v v1, (s1)
1:  NOTRAP  11
    VSTART0
    li      a0, 11
    ELEM    v1, 0, 9
    ELEM    v1, 1, 9
    ELEM    v1, 2, 5
    ELEM    v1, 3, 6
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
