// MI: WARL and alias behaviour of CSR fields that ACT4 checks, written from
// M-mode. Each sub-case s that reads back a wrong value sets bit s-1 of the
// mask; tohost is 1 when the mask is 0, else (mask << 8) | 0x42.
//   1 mstatus <- ~0: only the implemented fields (no XS, SPELP, SDT, MPELP,
//     MDT, UBE/SBE/MBE), with SXL/UXL 2 and SD
//   2 sstatus <- ~0: SIE, SPIE, SPP, VS, FS, SUM, MXR, UXL 2 and SD
//   3 vsstatus <- ~0: the same fields as sstatus
//   4 mie <- ~0: the S, M and VS interrupts and LCOFIE (no SGEIE: GEILEN 0)
//   5 medeleg <- ~0: no ecall from M (11) or reserved bit
//   6 vsepc <- ~0: bit 0 reads zero
//   7 vstart <- ~0: below VLMAX of VLEN 128 (7 bits)
//   8 hie <- ~0 with mie 0: VSSIE, VSTIE, VSEIE, and they are the mie bits
//   9 mip <- VSSIP: an alias of hvip.VSSIP
//  10 henvcfg <- ~0 with menvcfg 0: STCE and PBMTE read zero
//  11 vsie <- ~0: SSIE, STIE, SEIE (LCOFIE is not delegable to VS)
//  12 scountovf in M: the OF bit of mhpmevent3 shows with mcounteren 0
//  13 mseccfg <- ~0: only PMM (Smmpm)
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
    li      t0, MSTATUS_VS_INIT | MSTATUS_FS_INIT
    csrs    mstatus, t0
    csrr    s1, mstatus
    li      t0, -1
    csrw    mstatus, t0
    CHECK   1, mstatus, 0x800000ca007e7faa
    csrw    mstatus, s1
    li      t0, -1
    csrw    sstatus, t0
    CHECK   2, sstatus, 0x80000002000c6722
    csrw    mstatus, s1
    li      t0, -1
    csrw    vsstatus, t0
    CHECK   3, vsstatus, 0x80000002000c6722
    csrw    vsstatus, zero
    li      t0, -1
    csrw    mie, t0
    CHECK   4, mie, 0x2eee
    csrw    mie, zero
    li      t0, -1
    csrw    medeleg, t0
    CHECK   5, medeleg, 0xfcb7ff
    csrw    medeleg, zero
    li      t0, -1
    csrw    vsepc, t0
    CHECK   6, vsepc, -2
    li      t0, -1
    csrw    vstart, t0
    CHECK   7, vstart, 0x7f
    csrw    vstart, zero
    li      t0, -1
    csrw    hie, t0
    CHECK   8, hie, 0x444
    CHECK   8, mie, 0x444
    csrw    mie, zero
    li      t0, 4
    csrw    mip, t0
    CHECK   9, mip, 4
    CHECK   9, hvip, 4
    csrw    mip, zero
    CHECK   9, hvip, 0
    csrw    menvcfg, zero
    li      t0, -1
    csrw    henvcfg, t0
    csrr    t1, henvcfg
    srli    t1, t1, 62
    beqz    t1, 2f
    li      t0, 1 << 9
    or      s3, s3, t0
2:  csrw    henvcfg, zero
    li      t0, -1
    csrw    vsie, t0
    CHECK   11, vsie, 0x222
    csrw    vsie, zero
    csrw    mcounteren, zero
    li      t0, 1
    slli    t0, t0, 63
    csrw    mhpmevent3, t0
    CHECK   12, scountovf, 8
    csrw    mhpmevent3, zero
    li      t0, -1
    csrw    mseccfg, t0
    CHECK   13, mseccfg, 0x300000000
    csrw    mseccfg, zero
    beqz    s3, pass
    slli    s3, s3, 8
    ori     s3, s3, 0x42
    REPORT_REG s3
pass:
    REPORT  1
