// csrrs/csrrc on the CSRs no other gate sets or clears: pmpcfg0/2,
// pmpaddr0-15, tselect, srmcfg and scountinhibit (menvcfg.CDE = 1, also
// written with csrrw), all in M-mode. Each sub-case s whose read-back is wrong sets bit s-1
// of the mask; tohost is 1 when the mask is 0, else (mask << 8) | 0x42.
//   1 pmpaddr1-15: write 0, set 0xf0, clear 0x30, read 0xc0
//   2 pmpcfg0 entry 1 and pmpcfg2 entry 8: set R (A = OFF), read it, clear
//   3 tselect: set 1, read 1, clear 1, read 0
//   4 srmcfg: set all ones, read the RCID/MCID fields, clear them, read 0
//   5 no access traps (scountinhibit sets and clears bit 0)
#include "common/probe.h"

#define MENVCFG_CDE (1 << 60)
#define SRMCFG_FIELDS 0x0fff0fff

.macro FAIL sub
    li      t0, 1 << (\sub - 1)
    or      s3, s3, t0
.endm

    .section .text
main:
    li      s3, 0
    SET_RESUME trap_odd
    li      t1, 0xf0
    li      t2, 0x30
    li      t3, 0xc0
    li      t4, 0
    csrc    pmpaddr0, t4
    csrs    pmpaddr0, t4
.irp n, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    csrw    pmpaddr\n, zero
    csrs    pmpaddr\n, t1
    csrc    pmpaddr\n, t2
    csrr    t0, pmpaddr\n
    beq     t0, t3, 1f
    FAIL    1
1:
.endr
    li      t1, 0x100
    csrs    pmpcfg0, t1
    csrr    t0, pmpcfg0
    and     t0, t0, t1
    bnez    t0, 1f
    FAIL    2
1:  csrc    pmpcfg0, t1
    li      t1, 0x1
    csrs    pmpcfg2, t1
    csrr    t0, pmpcfg2
    andi    t0, t0, 0xff
    beq     t0, t1, 1f
    FAIL    2
1:  csrc    pmpcfg2, t1
    csrr    t0, pmpcfg2
    andi    t0, t0, 0xff
    beqz    t0, 1f
    FAIL    2
1:  csrsi   tselect, 1
    csrr    t0, tselect
    li      t1, 1
    beq     t0, t1, 1f
    FAIL    3
1:  csrci   tselect, 1
    csrr    t0, tselect
    beqz    t0, 1f
    FAIL    3
1:  csrw    srmcfg, zero
    li      t1, -1
    csrs    srmcfg, t1
    csrr    t0, srmcfg
    li      t2, SRMCFG_FIELDS
    beq     t0, t2, 1f
    FAIL    4
1:  csrc    srmcfg, t1
    csrr    t0, srmcfg
    beqz    t0, 1f
    FAIL    4
1:  li      t0, MENVCFG_CDE
    csrs    menvcfg, t0
    csrw    scountinhibit, zero
    li      t1, 1
    csrs    scountinhibit, t1
    csrc    scountinhibit, t1
    li      t0, MENVCFG_CDE
    csrc    menvcfg, t0
    beqz    s3, 9f
    slli    s3, s3, 8
    ori     s3, s3, 0x42
    REPORT_REG s3
9:  REPORT  1

trap_odd:
    FAIL    5
    slli    s3, s3, 8
    ori     s3, s3, 0x42
    REPORT_REG s3
