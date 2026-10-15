// Pointer masking under Sv39 (Ssnpm for U-mode via senvcfg.PMM, Smnpm for
// S-mode via menvcfg.PMM). Under translation the masked bits are replaced
// by the sign extension of bit XLEN-PMLEN-1, so a tagged pointer reaches the
// page of its untagged form and a non-canonical tag faults when masking is
// off. Unlike the bare M-mode test this is visible without LR/SC: the tag
// decides between a page fault and a load.
//
// VA 0x8000_0000 (megapage) and VA 0xffff_ffc0_0000_0000 (gigapage, the
// lowest of the upper half of Sv39, root entry 256) both map PA 0x8000_0000.
//
//   2  U, PMM off: a tagged load faults (cause 13, tval = the tagged VA)
//   3  U, PMLEN16: the tagged load reads the data
//   4  U, PMLEN16: bit 47 = 1 sign-extends into a canonical high VA
//   5  U, PMLEN7: tag in bits 63:57 is masked
//   6  U, PMLEN7: bit 56 is not masked, the load faults (cause 13)
//   7  U, PMLEN16: a tagged store writes the untagged location
//   8  U, PMLEN16: an SC through a tagged pointer matches the LR's
//      reservation on the untagged one
//   9  S: senvcfg.PMM does not mask S-mode accesses (cause 13)
//  10  S, menvcfg.PMM = PMLEN16: the tagged load reads the data
// tohost: 1 on success, else the number of the failing check.
#include "common/probe.h"

#define DATA     SCRATCH
#define MAGIC    0x5a5a1234c3c35678
#define MAGIC2   0x0123fedc4567ba98
#define PMM_OFF  0
#define PMM_7    (2 << 32)
#define PMM_16   (3 << 32)
#define PMM_MASK (3 << 32)

// Run label in mode (ENTER_U/ENTER_S) after setting the resume point; the
// code ends with ecall. Clears the trap record first.
.macro RUN enter, code, back
    la      t6, trap_rec
    sd      zero, 0(t6)
    sd      zero, 8(t6)
    SET_RESUME \back
    \enter  \code
.endm

// Fail with code unless the recorded trap cause is cause.
.macro CAUSE code, cause
    la      t6, trap_rec
    li      a0, \code
    ld      t5, 0(t6)
    li      t4, \cause
    bne     t5, t4, fail
.endm

.macro SET_PMM csr, val
    li      t0, PMM_MASK
    csrc    \csr, t0
    li      t0, \val
    csrs    \csr, t0
.endm

    .section .text
main:
    li      t0, DATA
    li      t1, MAGIC
    sd      t1, 0(t0)
    sd      zero, 8(t0)
    sd      zero, 16(t0)
    jal     ra, vm_init
    li      a2, PTE_LEAF | PTE_U
    jal     ra, set_leaves

    SET_PMM senvcfg, PMM_OFF
    li      a1, 0x1234000080020000
    RUN     ENTER_U, u_load, c2
c2: CAUSE   2, 13
    ld      t5, 8(t6)
    li      t4, 0x1234000080020000
    bne     t5, t4, fail

    SET_PMM senvcfg, PMM_16
    li      a1, 0x1234000080020000
    RUN     ENTER_U, u_load, c3
c3: CAUSE   3, 8
    li      t0, MAGIC
    bne     s5, t0, fail

    li      a1, 0x5678ffc000020000
    RUN     ENTER_U, u_load, c4
c4: CAUSE   4, 8
    li      t0, MAGIC
    bne     s5, t0, fail

    SET_PMM senvcfg, PMM_7
    li      a1, 0xfe00000080020000
    RUN     ENTER_U, u_load, c5
c5: CAUSE   5, 8
    li      t0, MAGIC
    bne     s5, t0, fail

    li      a1, 0x0100000080020000
    RUN     ENTER_U, u_load, c6
c6: CAUSE   6, 13

    SET_PMM senvcfg, PMM_16
    li      a1, 0xabcd000080020008
    li      a3, MAGIC2
    RUN     ENTER_U, u_store, c7
c7: CAUSE   7, 8
    li      t0, DATA
    ld      t1, 8(t0)
    li      t2, MAGIC2
    bne     t1, t2, fail

    li      a1, 0x4321000080020010
    li      a3, MAGIC
    RUN     ENTER_U, u_lrsc, c8
c8: CAUSE   8, 8
    bnez    s5, fail
    li      t0, DATA
    ld      t1, 16(t0)
    li      t2, MAGIC
    bne     t1, t2, fail

    li      a2, PTE_LEAF
    jal     ra, set_leaves
    li      a1, 0x1234000080020000
    RUN     ENTER_S, s_load, c9
c9: CAUSE   9, 13

    SET_PMM menvcfg, PMM_16
    RUN     ENTER_S, s_load, c10
c10:
    CAUSE   10, 9
    li      t0, MAGIC
    bne     s5, t0, fail
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0

// Leaf flags a2 for the megapage at VA 0x8000_0000 and the gigapage at
// VA 0xffff_ffc0_0000_0000; both map PA 0x8000_0000.
set_leaves:
    li      t0, PT_L1
    li      t1, PTE(0x80000000, 0)
    or      t1, t1, a2
    sd      t1, 0(t0)
    li      t0, PT_ROOT + 256 * 8
    sd      t1, 0(t0)
    sfence.vma
    ret

u_load:
s_load:
    li      s5, 0
    ld      s5, 0(a1)
    ecall
u_store:
    sd      a3, 0(a1)
    ecall
u_lrsc:
    li      t0, DATA + 16
    lr.d    t1, (t0)
    sc.d    s5, a3, (a1)
    ecall
