// An SC is translated with store permission whether or not it would
// succeed: an SC to a page it may not write takes a store/AMO page fault
// (cause 15), with or without a reservation, and writes nothing.
//
// S-mode, Sv39. VA page RO (VM_BASE + 0x1000): V|R|A. VA page CLEAN
// (VM_BASE + 0x2000): V|R|W|A with D = 0 (Svade: a store must fault).
// VA page NONE (VM_BASE + 0x3000): invalid.
//
//   2  sc.d to RO without a reservation: cause 15, tval = VA
//   3  lr.d on RO succeeds, then sc.d to it: cause 15
//   4  sc.d to CLEAN without a reservation: cause 15
//   5  sc.d to NONE: cause 15
//   6  none of them wrote memory
// tohost: 1 on success, else the number of the failing check.
#include "common/probe.h"

#define VA_RO    (VM_BASE + 0x1000)
#define VA_CLEAN (VM_BASE + 0x2000)
#define VA_NONE  (VM_BASE + 0x3000)
#define OLD      0x1122334455667788

.macro RUN_S code, back
    la      t6, trap_rec
    sd      zero, 0(t6)
    sd      zero, 8(t6)
    SET_RESUME \back
    ENTER_S \code
.endm

.macro EXPECT code, cause, tval
    la      t6, trap_rec
    li      a0, \code
    ld      t5, 0(t6)
    li      t4, \cause
    bne     t5, t4, fail
    ld      t5, 8(t6)
    li      t4, \tval
    bne     t5, t4, fail
.endm

    .section .text
main:
    li      t0, VA_RO
    li      t1, OLD
    sd      t1, 0(t0)
    li      t0, VA_CLEAN
    sd      t1, 0(t0)
    jal     ra, vm_init
    li      t0, PT_L0
    li      t1, PTE(VA_RO, PTE_V | PTE_R | PTE_A)
    sd      t1, 1 * 8(t0)
    li      t1, PTE(VA_CLEAN, PTE_V | PTE_R | PTE_W | PTE_A)
    sd      t1, 2 * 8(t0)
    sd      zero, 3 * 8(t0)
    sfence.vma

    li      a1, VA_RO
    RUN_S   s_sc, c2
c2: EXPECT  2, 15, VA_RO

    li      a1, VA_RO
    RUN_S   s_lrsc, c3
c3: EXPECT  3, 15, VA_RO

    li      a1, VA_CLEAN
    RUN_S   s_sc, c4
c4: EXPECT  4, 15, VA_CLEAN

    li      a1, VA_NONE
    RUN_S   s_sc, c5
c5: EXPECT  5, 15, VA_NONE

    li      a0, 6
    li      t2, OLD
    li      t0, VA_RO
    ld      t1, 0(t0)
    bne     t1, t2, fail
    li      t0, VA_CLEAN
    ld      t1, 0(t0)
    bne     t1, t2, fail
    REPORT  1

fail:
    PRINT   'f', a0
    REPORT_REG a0

s_sc:
    li      t1, 0x7777
    sc.d    t2, t1, (a1)
    ecall
s_lrsc:
    lr.d    t2, (a1)
    li      t1, 0x7777
    sc.d    t2, t1, (a1)
    ecall
