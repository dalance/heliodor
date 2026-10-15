// B20: an FP div/sqrt completion colliding with a stream of FP adds.
//
// Issues fdiv.d (then fsqrt.d) followed by 22 independent fadd.d, with
// 0..7 leading nops to slide the burst against the divider's completion.
// Results are compared with the same ops executed alone. Spec: all
// results equal the references and nothing hangs (a hang shows as a
// timeout, tohost 0). 0xB014: a wrong div/sqrt result (sub-case 1) or a
// wrong add result (sub-case 2).
#include "common/probe.h"

#define FREGS 4,5,6,7,8,9,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27

.macro BURST op, n
    \op     f1, f2, f3
    .rept \n
    nop
    .endr
    .irp r, FREGS
    fadd.d  f\r, f10, f11
    .endr
    fmv.x.d t1, f1
    bne     t1, s1, bug_div
    .irp r, FREGS
    fmv.x.d t1, f\r
    bne     t1, s2, bug_add
    .endr
.endm

.macro BURSTS op
    .irp n, 0,1,2,3,4,5,6,7
    BURST   \op, \n
    .endr
.endm

    .section .text
main:
    li      t0, MSTATUS_FS_INIT
    csrs    mstatus, t0
    la      t0, consts
    fld     f2, 0(t0)
    fld     f3, 8(t0)
    fld     f10, 16(t0)
    fld     f11, 24(t0)
    fdiv.d  f1, f2, f3
    fmv.x.d s1, f1
    fadd.d  f4, f10, f11
    fmv.x.d s2, f4
    BURSTS  fdiv.d
    fsqrt.d f1, f2
    fmv.x.d s1, f1
    .irp n, 0,1,2,3,4,5,6,7
    fsqrt.d f1, f2
    .rept \n
    nop
    .endr
    .irp r, FREGS
    fadd.d  f\r, f10, f11
    .endr
    fmv.x.d t1, f1
    bne     t1, s1, bug_div
    .irp r, FREGS
    fmv.x.d t1, f\r
    bne     t1, s2, bug_add
    .endr
    .endr
    REPORT  1
bug_div:
    PRINT   'q', t1
    REPORT  CODE_BUG_SUB(20, 1)
bug_add:
    PRINT   'a', t1
    REPORT  CODE_BUG_SUB(20, 2)

    .section .data
    .align 3
consts:
    .double 1234567.891
    .double 3.0
    .double 1.5
    .double 2.25
