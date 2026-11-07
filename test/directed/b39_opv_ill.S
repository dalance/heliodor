// B39: OP-V encodings the vector unit does not implement.
//
// Spec: a defined encoding the vector unit does not implement (vclmul.vv
// of Zvbc; on the old vector unit this case was vmv.s.x, which the new one
// implements) and vssubu.vi (a reserved encoding) raise an
// illegal-instruction exception. 0xB027 + sub-case: 3 vclmul.vv completed
// without a trap, 4 vssubu.vi completed without a trap. A wedge at the head
// shows as a timeout (tohost 0).
#include "common/probe.h"

    .section .text
main:
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    vsetivli zero, 2, e64, m1, ta, ma
    SET_RESUME 1f
    .word   0x3221a0d7          // vclmul.vv v1, v2, v3 (Zvbc)
1:  la      t6, trap_rec
    ld      t0, 24(t6)
    beqz    t0, no_trap_a
    ld      t0, 0(t6)
    li      t1, 2
    bne     t0, t1, odd
    sd      zero, 24(t6)
    SET_RESUME 2f
    .word   0x8a20b1d7          // vssubu.vi v3, v2, 1 (reserved)
2:  la      t6, trap_rec
    ld      t0, 24(t6)
    beqz    t0, no_trap_b
    ld      t0, 0(t6)
    li      t1, 2
    bne     t0, t1, odd
    REPORT  1
no_trap_a:
    REPORT  CODE_BUG_SUB(39, 3)
no_trap_b:
    REPORT  CODE_BUG_SUB(39, 4)
odd:
    PRINT   'c', t0
    REPORT  CODE_ODD(0x39)
