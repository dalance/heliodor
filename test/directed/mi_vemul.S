// Register-group rules that RVV 1.0 reserves under the current vtype: the
// EMUL range, group alignment, the widening, narrowing and disjoint-group
// overlaps, v0 under a mask, and the segment register span.
//
// Spec: each reserved case raises illegal-instruction (cause 2, mtval the
// instruction) and leaves vd and vstart unchanged (this core follows the
// Sail model on every case it reserves); each paired legal case runs.
// tohost: 1, or the number of the failing check (a reserved case that did
// not trap with cause 2 and its encoding, or a legal case that trapped):
//   2  vwadd.vv at LMUL 8 (EMUL 16)          3  vfwadd.vv at LMUL 8
//   4  vnsrl.wv at LMUL 8 (source EMUL 16)   5  vadd.vv at LMUL 2, vd v3
//   6  vwadd.vv, vs2 the low half of vd      7  vwadd.vv, vs2 the high half
//                                               of vd (legal)
//   8  vnsrl.wv, vd the high half of vs2     9  vnsrl.wv, vd the low half of
//                                               vs2 (legal)
//   10 vwsll.vv, vs2 the low half of vd      11 vwmacc.vv, vs1 the high
//                                               half of vd
//   12 vadd.vv masked, vd v0                 13 vmseq.vv masked, vd v0 (legal)
//   14 vadd.vv masked, vs2 v0                15 vrgather.vv, vd = vs1
//   16 vslideup.vx, vd = vs2                 17 vlseg8e32.v at LMUL 2
//                                               (NFIELDS*EMUL 16)
//   18 vlseg4e32.v v30 (vd + 4 > 32)         19 vlse64.v at SEW 8, LMUL 2
//                                               (EMUL 16)
//   20 vluxseg2ei32.v, index in a field      21 vl2re32.v v3
//   22 vse32.v masked, vs3 v0                23 vle32.v masked, vd v0
//   24 vwadd.vv at LMUL 4 (legal)            25 vzext.vf2, vd overlapping
//                                               the low half of the source
//                                               group at LMUL 2
#include "common/probe.h"

    .option arch, +zvbb

.macro ILL code, lbl
    li      a0, \code
    la      t6, trap_rec
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
    bnez    t5, fail
.endm

.macro OK code
    li      a0, \code
    la      t6, trap_rec
    ld      t5, 24(t6)
    bnez    t5, fail
.endm

    .section .text
main:
    li      t0, MSTATUS_VS_INIT | MSTATUS_FS_INIT
    csrs    mstatus, t0
    li      s1, SCRATCH
    li      a6, 8

    vsetivli zero, 4, e32, m8, tu, mu
    SET_RESUME 1f
i2: vwadd.vv v16, v0, v8
1:  ILL     2, i2
    SET_RESUME 1f
i3: vfwadd.vv v16, v0, v8
1:  ILL     3, i3
    SET_RESUME 1f
i4: vnsrl.wv v0, v16, v8
1:  ILL     4, i4

    vsetivli zero, 4, e32, m2, tu, mu
    SET_RESUME 1f
i5: vadd.vv v3, v4, v6
1:  ILL     5, i5

    vsetivli zero, 4, e32, m1, tu, mu
    SET_RESUME 1f
i6: vwadd.vv v2, v2, v4
1:  ILL     6, i6
    SET_RESUME 1f
    vwadd.vv v2, v3, v4
1:  OK      7
    SET_RESUME 1f
i8: vnsrl.wv v3, v2, v4
1:  ILL     8, i8
    SET_RESUME 1f
    vnsrl.wv v2, v2, v4
1:  OK      9
    SET_RESUME 1f
i10:vwsll.vv v2, v2, v4
1:  ILL     10, i10
    SET_RESUME 1f
i11:vwmacc.vv v2, v3, v4
1:  ILL     11, i11
    SET_RESUME 1f
i12:vadd.vv v0, v4, v5, v0.t
1:  ILL     12, i12
    SET_RESUME 1f
    vmseq.vv v0, v4, v5, v0.t
1:  OK      13
    SET_RESUME 1f
i14:vadd.vv v4, v0, v5, v0.t
1:  ILL     14, i14
    SET_RESUME 1f
i15:vrgather.vv v4, v5, v4
1:  ILL     15, i15
    SET_RESUME 1f
i16:vslideup.vx v4, v4, a6
1:  ILL     16, i16

    vsetivli zero, 4, e32, m2, tu, mu
    SET_RESUME 1f
i17:vlseg8e32.v v8, (s1)
1:  ILL     17, i17
    vsetivli zero, 4, e32, m1, tu, mu
    SET_RESUME 1f
i18:vlseg4e32.v v30, (s1)
1:  ILL     18, i18
    vsetivli zero, 4, e8, m2, tu, mu
    SET_RESUME 1f
i19:vlse64.v v8, (s1), a6
1:  ILL     19, i19
    vsetivli zero, 4, e32, m1, tu, mu
    SET_RESUME 1f
i20:vluxseg2ei32.v v8, (s1), v9
1:  ILL     20, i20
    SET_RESUME 1f
i21:vl2re32.v v3, (s1)
1:  ILL     21, i21
    SET_RESUME 1f
i22:vse32.v v0, (s1), v0.t
1:  ILL     22, i22
    SET_RESUME 1f
i23:vle32.v v0, (s1), v0.t
1:  ILL     23, i23

    vsetivli zero, 4, e32, m4, tu, mu
    SET_RESUME 1f
    vwadd.vv v8, v4, v16
1:  OK      24
    vsetivli zero, 4, e32, m2, tu, mu
    SET_RESUME 1f
i25:vzext.vf2 v4, v4
1:  ILL     25, i25
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
