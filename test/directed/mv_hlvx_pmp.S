// HLVX reads memory that PMP must grant both read and execute permission
// (hstatus.SPVP = 1, vsatp and hgatp Bare, M-mode). Each sub-case s whose
// outcome is wrong sets bit s-1 of the mask; tohost is 1 when the mask is
// 0, else (mask << 8) | 0x42.
//   1 hlvx.wu on an X-only page: load access fault
//   2 hlvx.wu on an R-only page: load access fault
//   3 hlvx.hu on an R-only page: load access fault
//   4 hlvx.wu on an RX page: no trap
//   5 hlv.w on an R-only page: no trap
#include "common/probe.h"

#define PG_X  SCRATCH
#define PG_R  (SCRATCH + 0x1000)
#define PG_RX (SCRATCH + 0x2000)

// Run insn; the sub-case is right when it trapped with cause `want`
// (0: did not trap).
.macro EXPECT sub, want, insn:vararg
    la      t0, trap_cnt
    sd      zero, 0(t0)
    la      t0, trap_cause
    sd      zero, 0(t0)
    SET_RESUME 1f
    \insn
1:  la      t0, trap_cause
    ld      t1, 0(t0)
    li      t2, \want
    beq     t1, t2, 2f
    li      t0, 1 << (\sub - 1)
    or      s3, s3, t0
2:
.endm

    .section .text
main:
    li      s3, 0
    csrw    vsatp, zero
    csrw    hgatp, zero
    li      t0, 1 << 8
    csrs    hstatus, t0
    li      t0, (PG_X >> 2) | 0x1ff
    csrw    pmpaddr0, t0
    li      t0, (PG_R >> 2) | 0x1ff
    csrw    pmpaddr1, t0
    li      t0, (PG_RX >> 2) | 0x1ff
    csrw    pmpaddr2, t0
    li      t0, -1
    csrw    pmpaddr3, t0
    li      t0, 0x1f1d191c
    csrw    pmpcfg0, t0
    li      s1, PG_X
    li      s2, PG_R
    li      s4, PG_RX
    EXPECT  1, 5, hlvx.wu a0, (s1)
    EXPECT  2, 5, hlvx.wu a0, (s2)
    EXPECT  3, 5, hlvx.hu a0, (s2)
    EXPECT  4, 0, hlvx.wu a0, (s4)
    EXPECT  5, 0, hlv.w a0, (s2)
    beqz    s3, 9f
    slli    s3, s3, 8
    ori     s3, s3, 0x42
    REPORT_REG s3
9:  REPORT  1
