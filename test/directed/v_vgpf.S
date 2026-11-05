// G-stage faults of vector element accesses.
//
// hgatp is Sv39x4 mapping only GPA [2 GiB, 3 GiB) 1:1, vsatp is Bare. A
// vector access to GPA 1 GiB faults in the G-stage.
// Spec: a guest-page fault (cause 21 load, 23 store) with mtval the guest
// virtual address, mtval2 the GPA >> 2, mstatus.GVA set and vstart the
// element index.
// tohost: 1, or the number of the failing check:
//   2  VS-mode vle64.v at 1 GiB
//   3  VS-mode vse64.v at 1 GiB
//   4  VS-mode vlse64.v whose element 1 is at 1 GiB (vstart 1)
//   5  element 0 of 4 was not loaded
//   6  M-mode vle64.v at 1 GiB under MPRV with MPP = S and MPV
#include "common/probe.h"

#define G_ROOT  0x80014000
#define MPV     (1 << 39)
#define GVA     (1 << 38)
#define BAD_GPA 0x40000000

.macro RUN_VS code, back
    la      t6, trap_rec
    sd      zero, 0(t6)
    SET_RESUME \back
    la      t0, \code
    csrw    mepc, t0
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S
    csrs    mstatus, t0
    li      t0, MPV
    csrs    mstatus, t0
    mret
.endm

.macro GFAULT code, cause, vst
    la      t6, trap_rec
    li      a0, \code
    ld      t5, 0(t6)
    li      t4, \cause
    bne     t5, t4, fail
    ld      t5, 8(t6)
    li      t4, BAD_GPA
    bne     t5, t4, fail
    csrr    t5, mtval2
    li      t4, BAD_GPA >> 2
    bne     t5, t4, fail
    csrr    t5, mstatus
    li      t4, GVA
    and     t5, t5, t4
    beqz    t5, fail
    csrr    t5, vstart
    li      t4, \vst
    bne     t5, t4, fail
    csrw    vstart, zero
.endm

    .section .text
main:
    li      t0, G_ROOT
    li      t1, PTE(0x80000000, PTE_LEAF | PTE_U)
    sd      t1, 16(t0)
    li      t0, (8 << 60) | (G_ROOT >> 12)
    csrw    hgatp, t0
    csrw    vsatp, zero
    .word   0x62000073              // hfence.gvma zero, zero
    li      t0, MSTATUS_VS_INIT
    csrs    mstatus, t0
    li      t0, MSTATUS_VS_INIT
    csrs    vsstatus, t0
    vsetivli zero, 2, e64, m1, tu, mu
    vmv.v.i v1, 9
    li      s1, BAD_GPA
    li      s2, SCRATCH
    li      t0, 0x1234
    sd      t0, 0(s2)
    li      s3, BAD_GPA - SCRATCH   // stride from SCRATCH to BAD_GPA

    RUN_VS  vs_vle, c2
c2: GFAULT  2, 21, 0
    RUN_VS  vs_vse, c3
c3: GFAULT  3, 23, 0
    RUN_VS  vs_vlse, c4
c4: GFAULT  4, 21, 1
    li      a0, 5
    vmv.x.s t0, v1
    li      t1, 0x1234
    bne     t0, t1, fail

    la      t6, trap_rec
    sd      zero, 0(t6)
    SET_RESUME c6
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPRV | MSTATUS_MPP_S | MPV
    csrs    mstatus, t0
    vle64.v v2, (s1)
c6: li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    GFAULT  6, 21, 0
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0

vs_vle:
    vle64.v v1, (s1)
    ecall
vs_vse:
    vse64.v v1, (s1)
    ecall
vs_vlse:
    vlse64.v v1, (s2), s3
    ecall
