// PMP faults of vector element accesses.
//
// PMP entry 0 denies S-mode every access to the 4 KiB page PAGE, entry 1
// allows everything else. S-mode (satp Bare) runs vector loads and stores
// into PAGE, and strided ones whose element 1 is the first in PAGE.
// Spec: an access fault (cause 5 load, 7 store) with mtval the element
// address and vstart the element index; the elements before it complete.
// tohost: 1, or the number of the failing check:
//   2  vle32.v at PAGE: no cause 5, mtval PAGE, vstart 0
//   3  vse32.v at PAGE: no cause 7, mtval PAGE, vstart 0
//   4  vlse32.v from PAGE - 4: no cause 5, mtval PAGE, vstart 1
//   5  element 0 of 4 was not loaded
//   6  vsse32.v from PAGE - 4: no cause 7, mtval PAGE, vstart 1
//   7  element 0 of 6 was not stored, or PAGE was written
#include "common/probe.h"

#define PAGE (SCRATCH + 0x1000)

.macro RUN code, back
    la      t6, trap_rec
    sd      zero, 0(t6)
    sd      zero, 8(t6)
    SET_RESUME \back
    ENTER_S \code
.endm

.macro FAULT code, cause, tval, vst
    la      t6, trap_rec
    li      a0, \code
    ld      t5, 0(t6)
    li      t4, \cause
    bne     t5, t4, fail
    ld      t5, 8(t6)
    li      t4, \tval
    bne     t5, t4, fail
    csrr    t5, vstart
    li      t4, \vst
    bne     t5, t4, fail
    csrw    vstart, zero
.endm

    .section .text
main:
    li      t0, (PAGE >> 2) | 0x1ff
    csrw    pmpaddr0, t0
    li      t0, -1
    csrw    pmpaddr1, t0
    li      t0, 0x1f18
    csrw    pmpcfg0, t0
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    li      s1, PAGE
    li      t0, 0x11
    sw      t0, -4(s1)
    li      t0, 0x22
    sw      t0, 0(s1)
    vsetivli zero, 2, e32, m1, tu, mu
    vmv.v.i v1, 9
    vmv.v.i v2, 7
    li      s2, 4

    RUN     s_vle, c2
c2: FAULT   2, 5, PAGE, 0
    RUN     s_vse, c3
c3: FAULT   3, 7, PAGE, 0
    RUN     s_vlse, c4
c4: FAULT   4, 5, PAGE, 1
    li      a0, 5
    vmv.x.s t0, v1
    li      t1, 0x11
    bne     t0, t1, fail
    RUN     s_vsse, c6
c6: FAULT   6, 7, PAGE, 1
    li      a0, 7
    lw      t0, -4(s1)
    li      t1, 7
    bne     t0, t1, fail
    lw      t0, 0(s1)
    li      t1, 0x22
    bne     t0, t1, fail
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0

s_vle:
    vle32.v v1, (s1)
    ecall
s_vse:
    vse32.v v2, (s1)
    ecall
s_vlse:
    addi    t0, s1, -4
    vlse32.v v1, (t0), s2
    ecall
s_vsse:
    addi    t0, s1, -4
    vsse32.v v2, (t0), s2
    ecall
