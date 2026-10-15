// B35: PMP must check every byte of a misaligned access.
//
// M-mode with MPRV=1/MPP=S (satp Bare). Entry 0 denies the 4 KiB page
// above PG, entry 1 allows the whole space. "ld" at the last 4 bytes of
// PG straddles into the denied page. Spec: load access fault (cause 5).
// 0xB023: the load completed.
#include "common/probe.h"

#define PG      (SCRATCH + 0x6000)
#define DENY    (PG + 0x1000)

    .section .text
main:
    li      t0, (DENY >> 2) | 0x1ff
    csrw    pmpaddr0, t0
    li      t0, -1
    csrw    pmpaddr1, t0
    li      t0, (0x1f << 8) | 0x18
    csrw    pmpcfg0, t0
    li      s0, PG + 0x1000 - 4
    la      t6, trap_rec
    sd      zero, 0(t6)
    SET_RESUME 1f
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPRV | MSTATUS_MPP_S
    csrs    mstatus, t0
    ld      s1, 0(s0)
    li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    PRINT   'd', s1
    REPORT  CODE_BUG(35)
1:  li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    la      t6, trap_rec
    ld      s2, 0(t6)
    PRINT   'c', s2
    li      t0, 5
    bne     s2, t0, odd
    REPORT  1
odd:
    REPORT  CODE_ODD(0x35)
