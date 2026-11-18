// With PMP entries implemented but all OFF, no entry matches, so every S and
// U access fails while M accesses succeed. M-mode drives each sub-case. Each
// sub-case s whose outcome is wrong sets bit s-1 of the mask; tohost is 1
// when the mask is 0, else (mask << 8) | 0x42.
//   1 mret to S: instruction access fault on the first fetch
//   2 ld under MPRV with MPP = S: load access fault
//   3 sd under MPRV with MPP = S: store access fault
//   4 ld in M: no trap
#include "common/probe.h"

.macro CLEAR
    la      t0, trap_cause
    sd      zero, 0(t0)
.endm

.macro CHECK sub, want
    la      t0, trap_cause
    ld      t1, 0(t0)
    li      t2, \want
    beq     t1, t2, 2f
    li      t0, 1 << (\sub - 1)
    or      s3, s3, t0
    PRINT   'c', t1
2:
.endm

    .section .text
main:
    li      s3, 0
    li      s1, SCRATCH
    csrw    pmpcfg0, zero
    csrw    pmpcfg2, zero

    CLEAR
    SET_RESUME 1f
    ENTER_S s_code
1:  CHECK   1, 1

    CLEAR
    SET_RESUME 1f
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S | MSTATUS_MPRV
    csrs    mstatus, t0
    ld      a0, 0(s1)
1:  li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    CHECK   2, 5

    CLEAR
    SET_RESUME 1f
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S | MSTATUS_MPRV
    csrs    mstatus, t0
    sd      zero, 0(s1)
1:  li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    CHECK   3, 7

    CLEAR
    SET_RESUME 1f
    ld      a0, 0(s1)
1:  CHECK   4, 0

    li      t0, 0x1f
    csrw    pmpcfg0, t0
    beqz    s3, 9f
    slli    s3, s3, 8
    ori     s3, s3, 0x42
    REPORT_REG s3
9:  REPORT  1

s_code:
    ecall
