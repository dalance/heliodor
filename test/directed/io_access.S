// IO access rules on the UART (no golden: the golden harness serves no UART
// registers). The harness's IO monitor checks that every device access
// belongs to exactly one retired access.
//
//   2  a load after a store to the same UART offset returns the device's
//      RBR (0), not the stored byte
//   3  lbu of LSR at offset 5 returns THRE|TEMT: the read data sits in the
//      byte lane of its offset
//   4  sb/lbu of IER at offset 1 reads back the written value: the write
//      data is taken from the byte lane of its offset
//   5  a misaligned IO load takes a load access fault (cause 5)
//   6  a misaligned IO store takes a store access fault (cause 7)
//   7  an AMO to IO takes a store/AMO access fault (cause 7)
//   8  an LR to IO takes a load access fault (cause 5)
//   9  a fetch from IO takes an instruction access fault (cause 1)
//  10  none of the faulting accesses wrote the device
// tohost: 1 on success, else the number of the failing check.
#include "common/probe.h"

.macro EXPECT_TRAP code, cause, tval
    la      t6, trap_rec
    li      a0, \code
    ld      t5, 0(t6)
    li      t4, \cause
    bne     t5, t4, fail
    ld      t5, 8(t6)
    li      t4, \tval
    bne     t5, t4, fail
    sd      zero, 0(t6)
.endm

    .section .text
main:
    li      s0, UART_THR
    li      s1, UART_WRCNT

    li      t0, 'x'
    sb      t0, 0(s0)
    lbu     t1, 0(s0)
    li      a0, 2
    bnez    t1, fail

    lbu     t1, 5(s0)
    li      a0, 3
    li      t2, 0x60
    bne     t1, t2, fail

    li      t0, 0x0a
    sb      t0, 1(s0)
    lbu     t1, 1(s0)
    sb      zero, 1(s0)
    li      a0, 4
    bne     t1, t0, fail

    ld      s3, 0(s1)
    SET_RESUME r5
    lh      t1, 1(s0)
    j       unexpected
r5:
    EXPECT_TRAP 5, 5, UART_THR + 1
    SET_RESUME r6
    sh      t0, 1(s0)
    j       unexpected
r6:
    EXPECT_TRAP 6, 7, UART_THR + 1
    SET_RESUME r7
    amoswap.w t1, t0, (s0)
    j       unexpected
r7:
    EXPECT_TRAP 7, 7, UART_THR
    SET_RESUME r8
    lr.w    t1, (s0)
    j       unexpected
r8:
    EXPECT_TRAP 8, 5, UART_THR
    SET_RESUME r9
    jalr    ra, 0(s0)
    j       unexpected
r9:
    EXPECT_TRAP 9, 1, UART_THR
    ld      s4, 0(s1)
    li      a0, 10
    bne     s3, s4, fail
    REPORT  1

unexpected:
    li      a0, 0xff
fail:
    PRINT   'f', a0
    REPORT_REG a0
