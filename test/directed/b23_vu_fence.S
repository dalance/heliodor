// B23: in VU-mode HFENCE.VVMA, SFENCE.VMA and an access to an S-level CSR,
// and in VS-mode HFENCE.VVMA (hstatus.VTVM clear), are virtual instructions.
//
// Each sub-case enters the guest (vsatp and hgatp Bare) at one instruction
// and records the trap taken to M. Spec: cause 22 every time. 0xB017 with
// bit 15+s for sub-case s (1 VU HFENCE, 2 VU SFENCE, 3 VU csrr sscratch, 4 VS
// HFENCE) that does not trap with cause 22.
#include "common/probe.h"

#define MPV (1 << 39)

    .section .text
main:
    csrw    hgatp, zero
    csrw    vsatp, zero
    li      s3, 0
    li      s4, 0x10000
    la      a0, vu_hf
    jal     ra, run_vu
    la      a0, vu_sf
    jal     ra, run_vu
    la      a0, vu_csr
    jal     ra, run_vu
    la      a0, vs_hf
    jal     ra, run_vs
    bnez    s3, bug
    REPORT  1
bug:
    li      t0, CODE_BUG(23)
    or      t0, t0, s3
    REPORT_REG t0

// Enter the guest at a0 (VU or VS) and fold the trap's cause into s3.
run_vu:
    li      t1, MSTATUS_MPP
    csrc    mstatus, t1
    j       1f
run_vs:
    li      t1, MSTATUS_MPP
    csrc    mstatus, t1
    li      t1, MSTATUS_MPP_S
    csrs    mstatus, t1
1:  li      t1, MPV
    csrs    mstatus, t1
    la      t6, trap_rec
    sd      zero, 0(t6)
    csrw    mepc, a0
    la      t1, 2f
    la      t6, trap_resume
    sd      t1, 0(t6)
    mret
2:  la      t6, trap_rec
    ld      t1, 0(t6)
    li      t2, 22
    beq     t1, t2, 3f
    or      s3, s3, s4
3:  slli    s4, s4, 1
    ret

vu_hf:
    .word   0x22000073              // hfence.vvma zero, zero
    ecall
vu_sf:
    sfence.vma
    ecall
vu_csr:
    csrr    t0, sscratch
    ecall
vs_hf:
    .word   0x22000073
    ecall
