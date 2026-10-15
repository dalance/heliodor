// B50: FCVT.W.D / FCVTMOD.W.D flags at the int32 boundaries.
//
// A value whose rounded result is 2^31 is out of range (NV, result
// 0x7fffffff); a value below -2^31 that rounds or truncates to -2^31 is
// in range (NX only). 0xB032: a wrong result or flags, sub-case mask in
// [23:16]: bits 0-2 the round-up to 2^31, 3, 4 and 7 the round to -2^31,
// 5 FCVTMOD of -(2^31+0.5), 6 the round below -2^31 (control, NV).
#include "common/probe.h"
#include "common/fcvt.h"

#define D "fmv.d.x fa0, t0"

    .section .text
main:
    FCVT_INIT
    CASE 1, 0x41DFFFFFFFE00000, D, "fcvt.w.d a0, fa0, rne", nop, 0x7FFFFFFF, 0x10
    CASE 2, 0x41DFFFFFFFD00000, D, "fcvt.w.d a0, fa0, rup", nop, 0x7FFFFFFF, 0x10
    CASE 3, 0x41DFFFFFFFE00000, D, "fcvt.w.d a0, fa0, rmm", nop, 0x7FFFFFFF, 0x10
    CASE 4, 0xC1E0000000100000, D, "fcvt.w.d a0, fa0, rne", nop, 0xFFFFFFFF80000000, 0x01
    CASE 5, 0xC1E0000000180000, D, "fcvt.w.d a0, fa0, rtz", nop, 0xFFFFFFFF80000000, 0x01
    CASE 6, 0xC1E0000000100000, D, "fcvtmod.w.d a0, fa0, rtz", nop, 0xFFFFFFFF80000000, 0x01
    CASE 7, 0xC1E0000000080000, D, "fcvt.w.d a0, fa0, rdn", nop, 0xFFFFFFFF80000000, 0x10
    CASE 8, 0xC1E0000000180000, D, "fcvt.w.d a0, fa0, rup", nop, 0xFFFFFFFF80000000, 0x01
    FCVT_DONE 50
