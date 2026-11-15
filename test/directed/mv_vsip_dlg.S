// vsip.SSIP is read-only zero while hideleg.VSSI (bit 2) is clear, so a
// write to it, from HS/M as vsip or from VS as sip, must leave hvip.VSSIP
// alone. Each sub-case s whose hvip read-back is wrong sets bit s-1 of the
// mask; tohost is 1 when the mask is 0, else (mask << 8) | 0x42.
//   1 hideleg 0, M: csrw vsip, 2: hvip reads 0
//   2 hideleg 0, M: csrs vsip, 2: hvip reads 0
//   3 hideleg 0, VS: csrw sip, 2: hvip reads 0
//   4 hideleg 4, M: csrw vsip, 2: hvip reads 4
#include "common/probe.h"

.macro CHECK sub, want
    csrr    t1, hvip
    li      t2, \want
    beq     t1, t2, 1f
    li      t0, 1 << (\sub - 1)
    or      s3, s3, t0
    PRINT   'h', t1
1:  csrw    hvip, zero
.endm

    .section .text
main:
    li      s3, 0
    csrw    hideleg, zero
    csrw    hvip, zero
    li      t0, 2
    csrw    vsip, t0
    CHECK   1, 0
    csrsi   vsip, 2
    CHECK   2, 0
    csrw    vsatp, zero
    csrw    hgatp, zero
    SET_RESUME 3f
    la      t0, 2f
    csrw    mepc, t0
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S | (1 << 39)
    csrs    mstatus, t0
    mret
2:  li      t0, 2
    csrw    sip, t0
    ecall
3:  CHECK   3, 0
    li      t0, 4
    csrw    hideleg, t0
    li      t0, 2
    csrw    vsip, t0
    CHECK   4, 4
    csrw    hideleg, zero
    beqz    s3, 9f
    slli    s3, s3, 8
    ori     s3, s3, 0x42
    REPORT_REG s3
9:  REPORT  1
