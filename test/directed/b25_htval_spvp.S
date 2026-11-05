// B25: a trap into HS from V = 0 must leave hstatus.SPVP alone, and every
// trap into HS or M that is not a guest-page fault writes 0 to htval or
// mtval2.
//
// hstatus.SPVP and htval are set, U-mode (V = 0) ecalls into HS (cause 8
// delegated), and the HS handler ecalls back to M. Spec: SPVP still 1,
// htval 0, then mtval2 0. 0xB019 with bit 16 (SPVP rewritten), bit 17 (htval
// kept) and bit 18 (mtval2 kept).
#include "common/probe.h"

    .section .text
main:
    li      t0, 1 << 8
    csrs    hstatus, t0             // SPVP
    li      t0, 0x1234
    csrw    htval, t0
    li      t0, 0x5678
    csrw    mtval2, t0
    li      t0, 1 << 8
    csrw    medeleg, t0             // ecall from U -> HS
    la      t0, hs_trap
    csrw    stvec, t0
    SET_RESUME back
    ENTER_U u_code
u_code:
    ecall
    REPORT  CODE_ODD(0x25)

    .align 2
hs_trap:
    csrr    s1, hstatus
    csrr    s2, htval
    ecall                           // cause 9 to M
back:
    csrr    s5, mtval2
    li      s3, 0
    li      t0, 1 << 8
    and     t1, s1, t0
    bnez    t1, 1f
    li      t0, 0x10000
    or      s3, s3, t0
1:  beqz    s2, 1f
    li      t0, 0x20000
    or      s3, s3, t0
1:  beqz    s5, 1f
    li      t0, 0x40000
    or      s3, s3, t0
1:  la      t6, trap_rec
    ld      t1, 0(t6)
    li      t0, 9
    bne     t1, t0, odd
    bnez    s3, bug
    REPORT  1
bug:
    li      t0, CODE_BUG(25)
    or      t0, t0, s3
    REPORT_REG t0
odd:
    PRINT   'c', t1
    REPORT  CODE_ODD(0x25)
