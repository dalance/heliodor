// mstatus.VS and mstatus.FS updates by vector instructions, and FS = Off for
// vector FP instructions.
//
// Spec: an instruction that changes vector state sets mstatus.VS (and SD)
// to Dirty; vfmv.f.s writes an f register and an FP vector op that raises
// a flag writes fflags, so both set mstatus.FS to Dirty. With mstatus.FS =
// Off a vector FP instruction raises an illegal-instruction exception.
// tohost: 1, or the number of the failing check:
//   2-5  VS is not Dirty (or SD clear) after 2 vadd.vv, 3 vsetvli, 4
//        vle32.v, 5 csrw vxrm, each run with VS = Initial
//   6    FS is not Dirty after vfmv.f.s run with FS = Initial
//   7    FS is not Dirty, or fflags.NX clear, after an inexact vfadd.vv
//   8-10 with FS = Off, 8 vfadd.vv, 9 vfmv.f.s, 10 vfmv.s.f do not trap
//        with cause 2
//   11   the trapped vfmv.f.s of 9 wrote its f register
#include "common/probe.h"

#define SD (1 << 63)

// VS = Initial, so that the next instruction alone can make it Dirty.
.macro VS_INIT
    li      t0, MSTATUS_VS
    csrc    mstatus, t0
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
.endm

.macro FS_SET val
    li      t0, MSTATUS_FS
    csrc    mstatus, t0
    li      t0, \val
    csrs    mstatus, t0
.endm

// Fail with code unless the mstatus field mask reads all ones and SD is set.
.macro DIRTY code, mask
    li      a0, \code
    csrr    t0, mstatus
    li      t1, \mask
    and     t2, t0, t1
    bne     t2, t1, fail
    bgez    t0, fail
.endm

.macro TRAPS code
    la      t6, trap_rec
    li      a0, \code
    ld      t5, 24(t6)
    beqz    t5, fail
    sd      zero, 24(t6)
    ld      t5, 0(t6)
    li      t4, 2
    bne     t5, t4, fail
.endm

    .section .text
main:
    li      t0, MSTATUS_VS_INIT | MSTATUS_FS_INIT
    csrs    mstatus, t0
    vsetivli zero, 2, e32, m1, ta, ma
    li      s1, SCRATCH
    sd      zero, 0(s1)
    li      t0, 0x3f800000          // 1.0f
    fmv.w.x f1, t0
    vfmv.v.f v4, f1
    li      t0, 0x33d6bf95          // 1e-7f
    fmv.w.x f2, t0
    vfmv.v.f v5, f2
    FS_SET  MSTATUS_FS_INIT

    VS_INIT
    vadd.vv v1, v2, v3
    DIRTY   2, MSTATUS_VS
    VS_INIT
    vsetivli zero, 2, e32, m1, ta, ma
    DIRTY   3, MSTATUS_VS
    VS_INIT
    vle32.v v1, (s1)
    DIRTY   4, MSTATUS_VS
    VS_INIT
    csrwi   vxrm, 1
    DIRTY   5, MSTATUS_VS

    FS_SET  MSTATUS_FS_INIT
    vfmv.f.s f3, v4
    DIRTY   6, MSTATUS_FS
    csrw    fflags, zero
    FS_SET  MSTATUS_FS_INIT
    vfadd.vv v6, v4, v5
    DIRTY   7, MSTATUS_FS
    csrr    t0, fflags
    andi    t0, t0, 1
    beqz    t0, fail

    fmv.w.x f7, zero
    li      t0, MSTATUS_FS
    csrc    mstatus, t0
    SET_RESUME 1f
    vfadd.vv v6, v4, v5
1:  TRAPS   8
    SET_RESUME 1f
    vfmv.f.s f7, v4
1:  TRAPS   9
    SET_RESUME 1f
    vfmv.s.f v6, f1
1:  TRAPS   10
    FS_SET  MSTATUS_FS_INIT
    li      a0, 11
    fmv.x.w t0, f7
    bnez    t0, fail
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
