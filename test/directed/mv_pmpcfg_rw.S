// pmpcfg writes legalize per byte: the reserved R = 0, W = 1 combination
// drops W and the reserved bits 6:5 read zero. M-mode, no entry locked.
// Each sub-case s whose read-back is wrong sets bit s-1 of the mask; tohost
// is 1 when the mask is 0, else (mask << 8) | 0x42.
//   1 pmpcfg0 <- {0x7f, 0x0b, 0x02, 0x1e}: reads {0x1f, 0x0b, 0x00, 0x1c}
//   2 pmpcfg2 <- {0x16, 0x06}: reads {0x14, 0x04}
#include "common/probe.h"

.macro CHECK sub, csr, want
    csrr    t1, \csr
    li      t2, \want
    beq     t1, t2, 1f
    li      t0, 1 << (\sub - 1)
    or      s3, s3, t0
    PRINT   'r', t1
1:
.endm

    .section .text
main:
    li      s3, 0
    csrr    s1, pmpcfg0
    li      t0, 0x7f0b021e
    csrw    pmpcfg0, t0
    CHECK   1, pmpcfg0, 0x1f0b001c
    csrw    pmpcfg0, s1
    li      t0, 0x1606
    csrw    pmpcfg2, t0
    CHECK   2, pmpcfg2, 0x1404
    csrw    pmpcfg2, zero
    beqz    s3, 9f
    slli    s3, s3, 8
    ori     s3, s3, 0x42
    REPORT_REG s3
9:  REPORT  1
