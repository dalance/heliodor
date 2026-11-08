// An uncached access to a DRAM line is preceded by a CMO request that cleans
// the hart's copy of the line. The CMO answers HIT at once and holds the
// dcache's non-forwarding slot until the clean is done, and the clean of a
// dirty line waits for the writeback to be accepted. With the AXI write buffer
// full of NC stores the access's own request finds the slot held (run under
// a slave with slow write responses: tb/test_axi_dir.veryl).
//
// An Svpbmt NC page aliases a line that is dirty in the dcache.
//   2  an NC load of a dirty line sees its data
//   3  an NC store is seen by a cacheable load of the line
// tohost: 1 on success, else the number of the failing check.
#include "common/probe.h"

#define NCPTE(pa) ((1 << 61) | PTE(pa, PTE_LEAF))

    .section .text
main:
    jal     ra, vm_init
    li      t0, 1 << 62                 // menvcfg.PBMTE
    csrs    menvcfg, t0
    li      t0, PT_L0
    li      t1, NCPTE(SCRATCH)
    sd      t1, 0(t0)
    li      t1, NCPTE(SCRATCH + 0x1000)
    sd      t1, 8(t0)
    sfence.vma
    li      s0, SCRATCH
    li      s1, VM_BASE
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S | MSTATUS_MPRV
    csrs    mstatus, t0

    li      t2, 0x105
    sd      t2, 0x80(s0)
    li      t3, 0x7777
    sd      t3, 0(s1)
    sd      t3, 0x40(s1)
    sd      t3, 0xc0(s1)
    sd      t3, 0x40(s1)
    sd      t3, 0xc0(s1)
    sd      t3, 0x40(s1)
    ld      t1, 0x80(s1)
    li      a0, 2
    bne     t1, t2, fail
    ld      t1, 0(s0)
    li      a0, 3
    bne     t1, t3, fail
    li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    REPORT  1

fail:
    li      t0, MSTATUS_MPRV
    csrc    mstatus, t0
    REPORT_REG a0
