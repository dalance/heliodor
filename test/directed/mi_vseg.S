// Segment loads and stores: the strided, indexed and fault-only-first
// forms, EMUL > 1, and a fault inside a segment and the resume at vstart.
//
// PMP entry 0 denies S-mode the 4 KiB page PAGE (as in v_vpmp). SRC holds
// word i = 0x100 + i; the four words below PAGE are 0x201-0x204 and the
// first word of PAGE is 0x205.
// Spec: field f of segment i goes to element i of register group vd +
// f*EMUL (EMUL = EEW/SEW*LMUL, indexed: LMUL). A fault inside segment i
// traps with vstart = i, after every field of the segments before i; a
// resume at vstart = i leaves the earlier segments of vd (or of memory)
// undisturbed. A fault-only-first segment load that faults in segment i > 0
// trims vl to i instead.
// tohost: 1, or the number of the failing check:
//   2  vlsseg2e32.v: wrong field element or tail written
//   3  vlsseg2e32.v masked: inactive segment written or active not loaded
//   4  vssseg2e32.v: wrong memory
//   5  vluxseg3e32.v / vloxseg2ei32.v: wrong field element
//   6  vsoxseg2ei32.v: wrong memory
//   7  vlseg2e32.v at LMUL 2: wrong element in the second register of a field
//   8  vsseg3e32.v at LMUL 2: wrong memory
//   9  vlseg2e32.v at SEW 16 (EMUL 2): wrong element
//   10 vluxseg2ei32.v at LMUL 2: wrong element
//   11 vlseg2e32.v faulting in field 1 of segment 1: no cause 5, mtval
//      PAGE, vstart 1, or segment 0 not loaded
//   12 vlseg2e32.v at vstart 1: segment 0 written or 1-3 not loaded
//   13 vsseg2e32.v faulting in field 1 of segment 1: no cause 7, mtval
//      PAGE, vstart 1, segment 0 not stored, or PAGE written
//   14 vsseg2e32.v at vstart 1: segment 0 stored or segment 1 not stored
//   15 vlsseg3e32.v faulting in field 2 of segment 1: no cause 5, vstart 1,
//      or segment 0 not loaded
//   16 vluxseg2ei32.v faulting in field 0 of segment 2: no cause 5, vstart
//      2, or segment 1 not loaded
//   17 vlseg2e32ff.v faulting in segment 2: trapped, vl not 2, or segment 1
//      not loaded
//   18 vlseg2e32ff.v faulting in field 1 of segment 0: no cause 5, vstart 0
#include "common/probe.h"

#define SRC  SCRATCH
#define DST  (SCRATCH + 0x400)
#define DST2 (SCRATCH + 0x600)
#define DUMP (SCRATCH + 0x800)
#define IDX  (SCRATCH + 0x900)
#define PAGE (SCRATCH + 0x1000)

// Word \i of register \vr reads \val; clobbers t0, t1.
.macro WORD vr, i, val
    li      t0, DUMP
    vs1r.v  \vr, (t0)
    lwu     t0, (4 * \i)(t0)
    li      t1, \val
    bne     t0, t1, fail
.endm

// The word at \addr + \off reads \val; clobbers t0, t1.
.macro MEMW addr, off, val
    li      t0, \addr
    lwu     t0, \off(t0)
    li      t1, \val
    bne     t0, t1, fail
.endm

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

// Zero 64 words at \addr; clobbers t0, t1.
.macro CLEAR addr
    li      t0, \addr
    addi    t1, t0, 256
1:  sw      zero, 0(t0)
    addi    t0, t0, 4
    bltu    t0, t1, 1b
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
    li      t0, SRC
    li      t1, 0x100
    li      t2, 0x140
1:  sw      t1, 0(t0)
    addi    t0, t0, 4
    addi    t1, t1, 1
    bltu    t1, t2, 1b
    li      s1, PAGE
    li      t0, 0x201
    sw      t0, -16(s1)
    li      t0, 0x202
    sw      t0, -12(s1)
    li      t0, 0x203
    sw      t0, -8(s1)
    li      t0, 0x204
    sw      t0, -4(s1)
    li      t0, 0x205
    sw      t0, 0(s1)
    CLEAR   DST
    CLEAR   DST2
    li      s2, SRC
    li      s3, DST
    li      s4, DST2
    li      a6, 16
    li      a7, 0x55

    li      a0, 2
    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.x v4, a7
    vmv.v.x v5, a7
    vsetivli zero, 3, e32, m1, tu, mu
    vlsseg2e32.v v4, (s2), a6
    WORD    v4, 1, 0x104
    WORD    v5, 2, 0x109
    WORD    v5, 3, 0x55

    li      a0, 3
    vmv.v.i v0, 5
    vmv.v.x v6, a7
    vmv.v.x v7, a7
    vlsseg2e32.v v6, (s2), a6, v0.t
    WORD    v6, 0, 0x100
    WORD    v6, 1, 0x55
    WORD    v7, 1, 0x55
    WORD    v7, 2, 0x109

    li      a0, 4
    vssseg2e32.v v4, (s3), a6
    MEMW    DST, 0, 0x100
    MEMW    DST, 4, 0x101
    MEMW    DST, 8, 0
    MEMW    DST, 20, 0x105
    MEMW    DST, 36, 0x109

    li      a0, 5
    li      t0, IDX
    li      t1, 12
    sw      t1, 0(t0)
    sw      zero, 4(t0)
    li      t1, 40
    sw      t1, 8(t0)
    vle32.v v8, (t0)
    vluxseg3ei32.v v12, (s2), v8
    WORD    v12, 0, 0x103
    WORD    v13, 0, 0x104
    WORD    v14, 1, 0x102
    WORD    v14, 2, 0x10c
    vloxseg2ei32.v v16, (s2), v8
    WORD    v17, 2, 0x10b

    li      a0, 6
    vsoxseg2ei32.v v12, (s4), v8
    MEMW    DST2, 12, 0x103
    MEMW    DST2, 16, 0x104
    MEMW    DST2, 4, 0x101
    MEMW    DST2, 44, 0x10b
    MEMW    DST2, 8, 0

    li      a0, 7
    vsetivli zero, 6, e32, m2, tu, mu
    vlseg2e32.v v4, (s2)
    WORD    v5, 1, 0x10a
    WORD    v7, 0, 0x109
    WORD    v6, 3, 0x107

    li      a0, 8
    CLEAR   DST
    vmv.v.x v8, a7
    vsetivli zero, 5, e32, m2, tu, mu
    vsseg3e32.v v4, (s3)
    MEMW    DST, 48, 0x108
    MEMW    DST, 56, 0x55
    MEMW    DST, 40, 0x107
    MEMW    DST, 60, 0

    li      a0, 9
    vsetivli zero, 6, e16, m1, tu, mu
    vlseg2e32.v v8, (s2)
    WORD    v9, 1, 0x10a
    WORD    v11, 0, 0x109
    WORD    v10, 2, 0x105

    li      a0, 10
    vsetivli zero, 6, e32, m2, tu, mu
    vid.v   v16
    vsll.vi v16, v16, 3
    vmv.v.i v4, 0
    vmv.v.i v6, 0
    vluxseg2ei32.v v4, (s2), v16
    WORD    v5, 1, 0x10a
    WORD    v7, 0, 0x109
    WORD    v4, 2, 0x104

    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.x v4, a7
    vmv.v.x v5, a7
    RUN     s_vlseg, c11
c11:FAULT   11, 5, PAGE, 1
    WORD    v4, 0, 0x202
    WORD    v5, 0, 0x203

    li      a0, 12
    vmv.v.x v4, a7
    vmv.v.x v5, a7
    li      t0, 1
    csrw    vstart, t0
    vlseg2e32.v v4, (s2)
    csrr    t0, vstart
    bnez    t0, fail
    WORD    v4, 0, 0x55
    WORD    v5, 0, 0x55
    WORD    v4, 1, 0x102
    WORD    v5, 1, 0x103
    WORD    v5, 3, 0x107

    RUN     s_vsseg, c13
c13:FAULT   13, 7, PAGE, 1
    MEMW    PAGE - 12, 0, 0x55
    MEMW    PAGE - 12, 4, 0x55
    MEMW    PAGE, 0, 0x205

    li      a0, 14
    CLEAR   DST2
    li      t0, 1
    csrw    vstart, t0
    vsseg2e32.v v4, (s4)
    MEMW    DST2, 0, 0
    MEMW    DST2, 4, 0
    MEMW    DST2, 8, 0x102
    MEMW    DST2, 12, 0x103

    li      t0, 0x201
    sw      t0, -16(s1)
    li      t0, 0x202
    sw      t0, -12(s1)
    li      t0, 0x203
    sw      t0, -8(s1)
    li      t0, 0x204
    sw      t0, -4(s1)
    li      a5, 8
    RUN     s_vlsseg, c15
c15:FAULT   15, 5, PAGE, 1
    WORD    v12, 0, 0x201
    WORD    v13, 0, 0x202
    WORD    v14, 0, 0x203

    li      t0, IDX
    sw      zero, 0(t0)
    li      t1, 4
    sw      t1, 4(t0)
    li      t1, 16
    sw      t1, 8(t0)
    vle32.v v8, (t0)
    RUN     s_vluxseg, c16
c16:FAULT   16, 5, PAGE, 2
    WORD    v12, 1, 0x202
    WORD    v13, 1, 0x203

    li      s6, 0
    RUN     s_vlsegff, c17
c17:li      a0, 17
    la      t6, trap_rec
    ld      t5, 0(t6)
    li      t4, 9
    bne     t5, t4, fail
    li      t0, 2
    bne     s6, t0, fail
    WORD    v4, 1, 0x203
    WORD    v5, 1, 0x204

    vsetivli zero, 4, e32, m1, tu, mu
    RUN     s_vlsegff0, c18
c18:FAULT   18, 5, PAGE, 0
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0

s_vlseg:
    addi    t0, s1, -12
    vlseg2e32.v v4, (t0)
    ecall
s_vsseg:
    addi    t0, s1, -12
    vsseg2e32.v v4, (t0)
    ecall
s_vlsseg:
    addi    t0, s1, -16
    vlsseg3e32.v v12, (t0), a5
    ecall
s_vluxseg:
    addi    t0, s1, -16
    vluxseg2ei32.v v12, (t0), v8
    ecall
s_vlsegff:
    addi    t0, s1, -16
    vlseg2e32ff.v v4, (t0)
    csrr    s6, vl
    ecall
s_vlsegff0:
    addi    t0, s1, -4
    vlseg2e32ff.v v4, (t0)
    ecall
