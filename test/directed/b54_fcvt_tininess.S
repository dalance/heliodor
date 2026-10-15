// B54: narrowing conversions of a value just below the smallest normal.
//
// RISC-V detects tininess after rounding: an input that rounds (with an
// unbounded exponent) up to the smallest normal is not tiny, so the
// result is that normal with NX only. 0xB036: a wrong result or flags,
// sub-case mask in [23:16]: bits 0, 1 FCVT.S.D, 3, 4 FCVT.H.S, 6, 7
// FCVT.H.D; bits 2 and 5 are tiny inputs (controls, UF|NX).
#include "common/probe.h"
#include "common/fcvt.h"

#define D "fmv.d.x fa0, t0"
#define S "fmv.w.x fa0, t0"
#define W "fmv.x.w a0, fa1"
#define H "fmv.x.h a0, fa1"

    .section .text
main:
    FCVT_INIT
    CASE 1, 0x380FFFFFF0000000, D, "fcvt.s.d fa1, fa0, rne", W, 0x00800000, 0x01
    CASE 2, 0x380FFFFFFFF80000, D, "fcvt.s.d fa1, fa0, rup", W, 0x00800000, 0x01
    CASE 3, 0x380FFFFFE0000000, D, "fcvt.s.d fa1, fa0, rne", W, 0x00800000, 0x03
    CASE 4, 0x387FF000, S, "fcvt.h.s fa1, fa0, rne", H, 0x0400, 0x01
    CASE 5, 0x387FFFFE, S, "fcvt.h.s fa1, fa0, rup", H, 0x0400, 0x01
    CASE 6, 0x387FE000, S, "fcvt.h.s fa1, fa0, rne", H, 0x0400, 0x03
    CASE 7, 0x3F0FFE0000000000, D, "fcvt.h.d fa1, fa0, rne", H, 0x0400, 0x01
    CASE 8, 0x3F0FFFFFFFFFFF80, D, "fcvt.h.d fa1, fa0, rup", H, 0x0400, 0x01
    FCVT_DONE 54
