/* SMP directed test: an uncached read of DRAM must see a dirty line held by
 * another hart. All harts boot at 0x80000000 in M-mode, enable Svpbmt and
 * map VA 0x80000000 with a cacheable gigapage and VA 0xC0000000 with an NC
 * gigapage over the same PA, then run ROUNDS rounds in S-mode:
 *
 *   writer = round % NH stores a round-tagged dword to DATA (cacheable), so
 *   its L1 holds the line dirty; barrier; every other hart loads the dword
 *   through the NC alias and checks it; barrier
 *
 * A stale read writes tohost = (round << 16) | 0x102; a trap writes
 * (mcause << 8) | 0xE0. Hart 0 writes tohost = 1 at the end.
 *
 * Build-time config: -DNH=<harts>.
 */

#ifndef NH
#define NH 2
#endif
#ifndef ROUNDS
#define ROUNDS 16
#endif

#define DATA     0x80007000
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
    li   s1, 0              /* round */
    li   s4, DATA
    li   t0, NC_DELTA
    add  s5, s4, t0         /* NC alias of DATA */

round:
    andi t0, s1, 7
    slli t0, t0, 3
    add  a0, s4, t0         /* cacheable dword of this round */
    add  a1, s5, t0         /* its NC alias */
    slli a2, s1, 32
    li   t0, 0xC0DE00
    or   a2, a2, t0
    li   t0, NH
    remu t1, s1, t0
    or   a2, a2, t1         /* round-tagged value */
    bne  t1, s0, 1f
    sd   a2, 0(a0)
1:  call barrier_fn
    li   t0, NH
    remu t1, s1, t0
    beq  t1, s0, 2f
    ld   t2, 0(a1)
    beq  t2, a2, 2f
    slli t0, s1, 16
    ori  t0, t0, 0x102
    la   t1, tohost
    sw   t0, 0(t1)
99: j    99b
2:  call barrier_fn
    addi s1, s1, 1
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
