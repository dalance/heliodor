// Pointer masking of vector element addresses (Smmpm, M-mode, Bare).
//
// Spec: with mseccfg.PMM = PMLEN16 (PMLEN7) the top 16 (7) bits of every
// effective address, vector element addresses included, are ignored (zero
// extended without translation); with PMM off a tagged address is out of
// range and the access faults.
// tohost: 1, or the number of the failing check:
//   2  PMM off: tagged vle64.v did not raise cause 5 with mtval the tagged
//      address
//   3  PMLEN16: tagged vle64.v did not read the data
//   4  PMLEN16: tagged vse64.v did not write the untagged location
//   5  PMLEN16: tagged vlse64.v did not read both elements
//   6  PMLEN16: tagged vluxei64.v did not read the data
//   7  PMLEN7: a tag in bits 63:57 was not ignored
//   8  PMLEN7: bit 56 set did not raise cause 5
#include "common/probe.h"

#define MAGIC   0x5a5a1234c3c35678
#define MAGIC2  0x0123fedc4567ba98
#define PMM_7   (2 << 32)
#define PMM_16  (3 << 32)
#define TAG16   0xabcd000000000000
#define TAG7    0xfe00000000000000

.macro SET_PMM val
    li      t0, PMM_16
    csrc    mseccfg, t0
    li      t0, \val
    csrs    mseccfg, t0
.endm

// Fail with code unless element 0 of v1 is val.
.macro ELEM0 code, val
    li      a0, \code
    vmv.x.s t0, v1
    li      t1, \val
    bne     t0, t1, fail
.endm

    .section .text
main:
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    li      s1, SCRATCH
    li      t0, MAGIC
    sd      t0, 0(s1)
    li      t0, MAGIC2
    sd      t0, 8(s1)
    sd      zero, 16(s1)
    vsetivli zero, 1, e64, m1, tu, mu
    vmv.v.i v1, 0

    SET_PMM 0
    li      s2, TAG16 | SCRATCH
    SET_RESUME 1f
    vle64.v v1, (s2)
1:  la      t6, trap_rec
    li      a0, 2
    ld      t5, 24(t6)
    beqz    t5, fail
    sd      zero, 24(t6)
    ld      t5, 0(t6)
    li      t4, 5
    bne     t5, t4, fail
    ld      t5, 8(t6)
    bne     t5, s2, fail
    csrw    vstart, zero

    SET_PMM PMM_16
    vle64.v v1, (s2)
    ELEM0   3, MAGIC
    li      a0, 4
    li      t0, MAGIC2
    vmv.v.x v2, t0
    addi    t1, s2, 16
    vse64.v v2, (t1)
    ld      t0, 16(s1)
    li      t1, MAGIC2
    bne     t0, t1, fail
    li      a0, 5
    vsetivli zero, 2, e64, m1, tu, mu
    li      t2, 8
    vlse64.v v1, (s2), t2
    vslidedown.vi v3, v1, 1
    vmv.x.s t0, v3
    li      t1, MAGIC2
    bne     t0, t1, fail
    ELEM0   5, MAGIC
    vsetivli zero, 1, e64, m1, tu, mu
    li      t0, 8
    vmv.v.x v4, t0
    vluxei64.v v1, (s2), v4
    ELEM0   6, MAGIC2

    SET_PMM PMM_7
    li      s2, TAG7 | SCRATCH
    vle64.v v1, (s2)
    ELEM0   7, MAGIC
    li      s2, (1 << 56) | SCRATCH
    SET_RESUME 1f
    vle64.v v1, (s2)
1:  la      t6, trap_rec
    li      a0, 8
    ld      t5, 24(t6)
    beqz    t5, fail
    ld      t5, 0(t6)
    li      t4, 5
    bne     t5, t4, fail
    SET_PMM 0
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0
