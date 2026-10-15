// B49: FCVT.L.D / FCVT.LU.D with |x| in [2^53, 2^63].
//
// Spec: the exact integer value, no flags; 2^63 saturates with NV for
// FCVT.L.D and converts exactly for FCVT.LU.D. 0xB031: a wrong result or
// flags, sub-case mask in [23:16] (bits 0-4 in range, 5-7 the +-2^63
// limits).
#include "common/probe.h"
#include "common/fcvt.h"

#define D "fmv.d.x fa0, t0"

    .section .text
main:
    FCVT_INIT
    CASE 1, 0xC340000000000000, D, "fcvt.l.d a0, fa0, rtz", nop, 0xFFE0000000000000, 0
    CASE 2, 0x4340000000000000, D, "fcvt.l.d a0, fa0, rne", nop, 0x0020000000000000, 0
    CASE 3, 0x43D0000000000001, D, "fcvt.l.d a0, fa0, rtz", nop, 0x4000000000000400, 0
    CASE 4, 0xC3DFFFFFFFFFFFFF, D, "fcvt.l.d a0, fa0, rne", nop, 0x8000000000000400, 0
    CASE 5, 0x4378000000000000, D, "fcvt.l.d a0, fa0, rtz", nop, 0x0180000000000000, 0
    CASE 6, 0x43E0000000000000, D, "fcvt.l.d a0, fa0, rtz", nop, 0x7FFFFFFFFFFFFFFF, 0x10
    CASE 7, 0xC3E0000000000000, D, "fcvt.l.d a0, fa0, rtz", nop, 0x8000000000000000, 0
    CASE 8, 0x43E0000000000000, D, "fcvt.lu.d a0, fa0, rtz", nop, 0x8000000000000000, 0
    FCVT_DONE 49
