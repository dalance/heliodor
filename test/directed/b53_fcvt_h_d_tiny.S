// B53: FCVT.H.D of values below the smallest half subnormal 2^-24.
//
// Spec: the result rounds per rm to 0 or +-2^-24 (0x0001 / 0x8001), with
// UF|NX. 0xB035: a wrong result or flags, sub-case mask in [23:16]: bits
// 0-5 inputs that round to +-2^-24, 6 and 7 inputs that round to zero.
#include "common/probe.h"
#include "common/fcvt.h"

#define D "fmv.d.x fa0, t0"
#define H "fmv.x.h a0, fa1"

    .section .text
main:
    FCVT_INIT
    CASE 1, 0x3E68000000000000, D, "fcvt.h.d fa1, fa0, rne", H, 0x0001, 0x03
    CASE 2, 0x3E60000000000001, D, "fcvt.h.d fa1, fa0, rne", H, 0x0001, 0x03
    CASE 3, 0x3E10000000000000, D, "fcvt.h.d fa1, fa0, rup", H, 0x0001, 0x03
    CASE 4, 0xBE10000000000000, D, "fcvt.h.d fa1, fa0, rdn", H, 0xFFFFFFFFFFFF8001, 0x03
    CASE 5, 0x3E60000000000000, D, "fcvt.h.d fa1, fa0, rmm", H, 0x0001, 0x03
    CASE 6, 0xBE68000000000000, D, "fcvt.h.d fa1, fa0, rmm", H, 0xFFFFFFFFFFFF8001, 0x03
    CASE 7, 0x3E60000000000000, D, "fcvt.h.d fa1, fa0, rne", H, 0x0000, 0x03
    CASE 8, 0xBE10000000000000, D, "fcvt.h.d fa1, fa0, rup", H, 0xFFFFFFFFFFFF8000, 0x03
    FCVT_DONE 53
