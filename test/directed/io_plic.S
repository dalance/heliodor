// PLIC claim rules. The harness pulses PLIC source 10 once, early; M-mode
// polls the M context (0) with interrupts off. The harness's IO monitor
// checks that every device access belongs to exactly one retired access.
//
//   2  source 10 is pending
//   3  a claim read on the wrong path of a mispredicted branch does not
//      reach the device, and a claim read after an older store to the same
//      dword (threshold) is neither forwarded nor repeated: it returns 10
//   4  a second claim returns 0: the first one consumed the source once
// tohost: 1 on success, else the number of the failing check.
#include "common/probe.h"

#define PLIC         0x0c000000
#define PLIC_PRIO10  (PLIC + 0x28)
#define PLIC_PENDING (PLIC + 0x1000)
#define PLIC_EN0     (PLIC + 0x2000)
#define PLIC_THR0    (PLIC + 0x200000)
#define PLIC_CLAIM0  (PLIC + 0x200004)

    .section .text
main:
    li      t0, PLIC_PRIO10
    li      t1, 1
    sw      t1, 0(t0)
    li      t0, PLIC_EN0
    li      t1, 1 << 10
    sw      t1, 0(t0)
    li      s1, PLIC_CLAIM0

    li      t0, PLIC_PENDING
    lw      t1, 0(t0)
    li      a0, 2
    li      t2, 1 << 10
    and     t1, t1, t2
    beqz    t1, fail

    li      t2, 1000
    li      t3, 7
    div     t4, t2, t3
    bnez    t4, 1f
    lw      t5, 0(s1)
    lw      t5, 0(s1)
1:
    li      t0, PLIC_THR0
    sw      zero, 0(t0)
    lw      t5, 0(s1)
    li      a0, 3
    li      t1, 10
    bne     t5, t1, fail
    lw      a1, 0(s1)
    li      a0, 4
    bnez    a1, fail
    sw      t5, 0(s1)
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
