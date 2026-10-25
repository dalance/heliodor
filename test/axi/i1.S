/* AXI directed test I1: a read of DRAM must not pass an earlier write that
 * the slave has accepted but not finished. Run behind a slave whose W and B
 * are slow and whose R is fast, so a read that passes the write returns the
 * old value. Hart 0 boots at 0x80000000 in M-mode, maps VA 0x80000000
 * cacheable, VA 0xC0000000 NC and VA 0x100000000 IO over the same PA
 * (Svpbmt) and runs ROUNDS rounds in S-mode, each on a fresh line:
 *
 *   step 1: NC store, fence, NC load of the same dword
 *   step 2: NC store, fence, cacheable load of the same dword (an L2 miss)
 *   step 3: IO store, IO load of the same dword (no fence)
 *
 * A wrong value writes tohost = (round << 16) | (step << 8) | 0x02; a trap
 * writes (mcause << 8) | 0xE0. tohost = 1 at the end.
 */

#ifndef ROUNDS
#define ROUNDS 16
#endif

#define DATA     0x80020000
#define NC_DELTA 0x40000000
#define IO_DELTA 0x80000000

.section .text.init
.globl _start
_start:
    la   t0, trap_handler
    csrw mtvec, t0

    li   t0, -1
    csrw pmpaddr0, t0
    li   t0, 0x1f
    csrw pmpcfg0, t0
    li   t0, 1
    slli t0, t0, 62
    csrs menvcfg, t0
    la   t0, pt_root
    srli t0, t0, 12
    li   t1, 8
    slli t1, t1, 60
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma
    li   t0, 0x1800
    csrc mstatus, t0
    li   t0, 0x0800
    csrs mstatus, t0
    la   t0, s_main
    csrw mepc, t0
    mret

s_main:
    li   s1, 0
    li   s4, DATA
    li   s5, NC_DELTA
    li   s6, IO_DELTA

round:
    slli t0, s1, 6
    andi t1, s1, 7
    slli t1, t1, 3
    add  t0, t0, t1
    add  a0, s4, t0         /* cacheable VA of this round's dword */
    add  a1, a0, s5         /* NC alias */
    li   t0, 0x10000
    add  a3, a0, t0
    add  a3, a3, s6         /* IO alias, on another line */
    slli a2, s1, 32
    li   t0, 0xA11CE000
    or   a2, a2, t0
    or   a2, a2, s1

    li   s2, 1
    sd   a2, 0(a1)
    fence rw, rw
    ld   t2, 0(a1)
    bne  t2, a2, fail

    li   s2, 2
    addi a2, a2, 0x100
    sd   a2, 0(a1)
    fence rw, rw
    ld   t2, 0(a0)
    bne  t2, a2, fail

    li   s2, 3
    addi a2, a2, 0x100
    sd   a2, 0(a3)
    ld   t2, 0(a3)
    bne  t2, a2, fail

    addi s1, s1, 1
    li   t0, ROUNDS
    bne  s1, t0, round

    li   t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
1:  j    1b

fail:
    slli t0, s1, 16
    slli t1, s2, 8
    or   t0, t0, t1
    ori  t0, t0, 0x02
    la   t1, tohost
    sw   t0, 0(t1)
1:  j    1b

trap_handler:
    csrr t0, mcause
    slli t0, t0, 8
    ori  t0, t0, 0xE0
    la   t1, tohost
    sw   t0, 0(t1)
1:  j    1b

.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost:   .dword 0
.globl fromhost
fromhost: .dword 0

/* Sv39 root: [2] RWX gigapage at PA 0x80000000, [3] the same PA with PBMT =
 * NC, [4] the same PA with PBMT = IO. All entries have A and D set. */
.section .pt, "aw", @progbits
.align 12
pt_root:
    .dword 0
    .dword 0
    .dword (0x80000 << 10) | 0xcf
    .dword (1 << 61) | (0x80000 << 10) | 0xcf
    .dword (2 << 61) | (0x80000 << 10) | 0xcf
    .fill 507, 8, 0
