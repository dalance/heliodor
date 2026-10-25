/* AXI directed test I4: a write granted while another hart gathers the
 * same line from DRAM must keep the gathered line out of the L2 and the
 * requester's L1 (install_ok). Two harts, same boot and mappings as
 * ../coh/unc.S. In each round, on a fresh line:
 *
 *   hart 0 loads dword 0 cacheable (an L2 miss, gathered from DRAM)
 *   hart 1 waits round * GAP loop iterations, then NC-stores to dword 1,
 *   so that over the rounds the store sweeps across the gather window
 *   barrier; hart 0 loads dword 1 cacheable and must see the stored value
 *
 * A line installed from a gather that a write overtook would hold the old
 * dword 1 in the L2 and in hart 0's L1, and no later write repairs it.
 *
 * Run behind a slow slave so that the gather window is long. A stale value
 * writes tohost = (round << 16) | 0x402; a trap (mcause << 8) | 0xE0.
 */

#define NH 2
#ifndef ROUNDS
#define ROUNDS 32
#endif
#ifndef GAP
#define GAP 6
#endif

#define DATA     0x80020000
#define NC_DELTA 0x40000000

.section .text.init
.globl _start
_start:
    la   t0, trap_handler
    csrw mtvec, t0
    csrr s0, mhartid
    li   s3, 0x80006000
    li   s7, 0

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

round:
    slli t0, s1, 6
    add  a0, s4, t0         /* cacheable VA of this round's line */
    add  a1, a0, s5         /* NC alias */
    slli a2, s1, 32
    li   t0, 0x14000
    or   a2, a2, t0         /* the value hart 1 stores */
    call barrier_fn
    bnez s0, 2f
    nop
    nop
    ld   t2, 0(a0)
    j    3f
2:  li   t0, GAP
    mul  t4, s1, t0         /* delay sweeps the store across the gather */
6:  beqz t4, 7f
    addi t4, t4, -1
    j    6b
7:  sd   a2, 8(a1)
    fence rw, rw
3:  call barrier_fn
    bnez s0, 5f
    ld   t2, 8(a0)
    beq  t2, a2, 5f
    slli t0, s1, 16
    ori  t0, t0, 0x402
    la   t1, tohost
    sw   t0, 0(t1)
99: j    99b
5:  addi s1, s1, 1
    li   t0, ROUNDS
    bne  s1, t0, round

    bnez s0, park
    li   t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
park:
    j    park

barrier_fn:
    xori s7, s7, 1
    li   t0, 1
    amoadd.w.aqrl t1, t0, (s3)
    li   t2, NH-1
    beq  t1, t2, 95f
94:
    lw   t3, 64(s3)
    bne  t3, s7, 94b
    j    93f
95:
    sw   x0, 0(s3)
    fence w, w
    sw   s7, 64(s3)
93:
    fence rw, rw
    ret

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

.section .barrier, "aw", @progbits
barrier_count: .word 0
.align 6
barrier_sense: .word 0
.align 6

/* Sv39: root[2] is a dirty RWX gigapage at 0x80000000, root[3] the same PA
 * with PBMT = NC. */
.section .pt, "aw", @progbits
.align 12
pt_root:
    .dword 0
    .dword 0
    .dword (0x80000 << 10) | 0xcf
    .dword (1 << 61) | (0x80000 << 10) | 0xcf
    .fill 508, 8, 0
