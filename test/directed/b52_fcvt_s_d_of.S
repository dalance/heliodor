// B52: FCVT.S.D overflow caused by rounding.
//
// Inputs at or above the midpoint between FLT_MAX and 2^128 round to
// infinity with OF|NX; RTZ keeps FLT_MAX with NX only unless the input
// itself is 2^128. 0xB034: a wrong result or flags, sub-case mask in
// [23:16]: bits 0-4 rounding overflow, 5-7 controls.
#include "common/probe.h"
#include "common/fcvt.h"

#define D "fmv.d.x fa0, t0"
#define W "fmv.x.w a0, fa1"

    .section .text
main:
    FCVT_INIT
    CASE 1, 0x47EFFFFFF0000000, D, "fcvt.s.d fa1, fa0, rne", W, 0x7F800000, 0x05
    CASE 2, 0x47EFFFFFE0000001, D, "fcvt.s.d fa1, fa0, rup", W, 0x7F800000, 0x05
    CASE 3, 0x47EFFFFFF0000000, D, "fcvt.s.d fa1, fa0, rmm", W, 0x7F800000, 0x05
    CASE 4, 0xC7EFFFFFF0000000, D, "fcvt.s.d fa1, fa0, rne", W, 0xFFFFFFFFFF800000, 0x05
    CASE 5, 0xC7EFFFFFE0000001, D, "fcvt.s.d fa1, fa0, rdn", W, 0xFFFFFFFFFF800000, 0x05
    CASE 6, 0x47EFFFFFF0000000, D, "fcvt.s.d fa1, fa0, rtz", W, 0x7F7FFFFF, 0x01
    CASE 7, 0x47EFFFFFEFFFFFFF, D, "fcvt.s.d fa1, fa0, rne", W, 0x7F7FFFFF, 0x01
    CASE 8, 0x47F0000000000000, D, "fcvt.s.d fa1, fa0, rtz", W, 0x7F7FFFFF, 0x05
    FCVT_DONE 52
