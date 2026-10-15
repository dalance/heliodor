// B51: FCVT.WU.D values that round up to 2^32, and negatives near zero.
//
// A rounded result of 2^32 is out of range (NV, result 0xffffffff sign
// extended); -0.25 rounding to 0 is NX only, rounding to -1 is NV with
// result 0. 0xB033: a wrong result or flags, sub-case mask in [23:16]:
// bits 0-2 the round-up to 2^32, 3 and 4 in-range controls, 5 and 6 the
// negative inputs.
#include "common/probe.h"
#include "common/fcvt.h"

#define D "fmv.d.x fa0, t0"

    .section .text
main:
    FCVT_INIT
    CASE 1, 0x41EFFFFFFFF00000, D, "fcvt.wu.d a0, fa0, rne", nop, 0xFFFFFFFFFFFFFFFF, 0x10
    CASE 2, 0x41EFFFFFFFE80000, D, "fcvt.wu.d a0, fa0, rup", nop, 0xFFFFFFFFFFFFFFFF, 0x10
    CASE 3, 0x41EFFFFFFFF00000, D, "fcvt.wu.d a0, fa0, rmm", nop, 0xFFFFFFFFFFFFFFFF, 0x10
    CASE 4, 0x41EFFFFFFFF00000, D, "fcvt.wu.d a0, fa0, rtz", nop, 0xFFFFFFFFFFFFFFFF, 0x01
    CASE 5, 0x41EFFFFFFFE80000, D, "fcvt.wu.d a0, fa0, rne", nop, 0xFFFFFFFFFFFFFFFF, 0x01
    CASE 6, 0xBFD0000000000000, D, "fcvt.wu.d a0, fa0, rne", nop, 0, 0x01
    CASE 7, 0xBFD0000000000000, D, "fcvt.wu.d a0, fa0, rdn", nop, 0, 0x10
    FCVT_DONE 51
