/* SMP Svadu directed test: hardware A/D updates (menvcfg.ADUE = 1) on one
 * line of leaf PTEs while every hart walks the same PTEs and flips their
 * software bits with AMOs. All harts boot at 0x80000000 in M-mode, map
 * 0x80000000 with a dirty gigapage and VA 0x40000000 with eight 4 KiB
 * leaves (one 64-byte line of L0 PTEs), and run ROUNDS rounds in S-mode:
 *
 *   hart 0 resets the eight PTEs (A = D = 0, RSW = 0); barrier; sfence.vma
 *   pass 1: for page i, amoxor.d bit (8 + hart % 2) into PTE i, then a load
 *           or a store to page i (alternating with i, round and hart)
 *   pass 2: for page i, amoxor.d the same bit into PTE i for odd i, then a
 *           store to page i (a load-installed entry needs its D bit)
 *   barrier; hart 0 checks every PTE: the reset value | A | D | the RSW bits
 *           of the flips, and the dword every hart stored in every page
 *
 * A lost flip or a lost A/D bit means an A/D update overwrote a newer PTE.
 * Any failure writes tohost = (code << 16) | (phase << 8) | 2; a trap writes
 * (mcause << 8) | 0xE0. Hart 0 writes tohost = 1 at the end.
 *
 * Build-time config: -DNH=<harts>.
 */

#ifndef NH
#define NH 2
#endif
#ifndef ROUNDS
#define ROUNDS 24
#endif

/* Each RSW bit is flipped once per pass 1 by every hart of its parity, and
 * once more in pass 2 on odd pages. */
#if NH == 2
#define RSW_EVEN 0x300
#else
#define RSW_EVEN 0
#endif

#define VA_BASE  0x40000000
#define PG_BASE  0x80020   /* PPN of page 0 */
#define PTE_RWV  0x7

.macro JITTER
    andi t0, s6, 1
    srli s6, s6, 1
    beqz t0, 98f
    li   t1, 0xB400
    xor  s6, s6, t1
98:
    andi t0, s6, 0x1f
97:
    beqz t0, 96f
    addi t0, t0, -1
    j    97b
96:
.endm

.macro FAIL ph, reg
    slli t0, \reg, 16
    li   t1, (\ph << 8) | 2
    or   t0, t0, t1
    la   t1, tohost
    sw   t0, 0(t1)
99: j    99b
.endm

.section .text.init
.globl _start
_start:
    la   t0, trap_handler
    csrw mtvec, t0
    csrr s0, mhartid
    li   s3, 0x80006000
    li   s7, 0
    li   s6, 0xACE1
    li   t0, 0x1234
    mul  t1, t0, s0
    add  s6, s6, t1

    li   t0, -1
    csrw pmpaddr0, t0
    li   t0, 0x1f
    csrw pmpcfg0, t0
    li   t0, 1
    slli t0, t0, 61
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
    la   s4, pt_l0
    li   s5, VA_BASE
    li   s1, 0              /* round */
    andi t0, s0, 1
    li   s8, 0x100
    sll  s8, s8, t0         /* this hart's RSW bit */
    slli s9, s0, 3          /* this hart's dword in every page */

round:
    bnez s0, 2f
    li   t2, 0
1:  li   t0, PG_BASE
    add  t0, t0, t2
    slli t0, t0, 10
    ori  t0, t0, PTE_RWV
    slli t1, t2, 3
    add  t1, t1, s4
    sd   t0, 0(t1)
    addi t2, t2, 1
    li   t0, 8
    bne  t2, t0, 1b
    fence rw, rw
2:  call barrier_fn
    sfence.vma
    JITTER

    /* pass 1 */
    li   t2, 0
p1:
    slli t1, t2, 3
    add  t1, t1, s4
    amoxor.d x0, s8, (t1)
    slli a0, t2, 12
    add  a0, a0, s5
    add  a0, a0, s9
    add  t0, t2, s1
    add  t0, t0, s0
    andi t0, t0, 1
    beqz t0, 1f
    ld   t3, 0(a0)
    j    2f
1:  slli t3, s1, 32
    or   t3, t3, a0
    sd   t3, 0(a0)
2:  addi t2, t2, 1
    li   t0, 8
    bne  t2, t0, p1

    /* pass 2 */
    li   t2, 0
p2:
    andi t0, t2, 1
    beqz t0, 1f
    slli t1, t2, 3
    add  t1, t1, s4
    amoxor.d x0, s8, (t1)
1:  slli a0, t2, 12
    add  a0, a0, s5
    add  a0, a0, s9
    slli t3, s1, 32
    or   t3, t3, a0
    sd   t3, 0(a0)
    addi t2, t2, 1
    li   t0, 8
    bne  t2, t0, p2

    call barrier_fn
    bnez s0, next

    /* check (hart 0) */
    li   t2, 0
c1:
    li   t0, PG_BASE
    add  t0, t0, t2
    slli t0, t0, 10
    ori  t0, t0, PTE_RWV | 0xc0
    andi t1, t2, 1
    bnez t1, 1f
    li   t1, RSW_EVEN
    or   t0, t0, t1
1:  slli t1, t2, 3
    add  t1, t1, s4
    ld   t3, 0(t1)
    beq  t3, t0, 2f
    addi t4, t2, 1
    FAIL 1, t4
2:  li   t4, 0              /* hart */
3:  slli a0, t2, 12
    add  a0, a0, s5
    slli t1, t4, 3
    add  a0, a0, t1
    slli t3, s1, 32
    or   t3, t3, a0
    ld   t1, 0(a0)
    beq  t1, t3, 4f
    addi t4, t2, 0x11
    FAIL 2, t4
4:  addi t4, t4, 1
    li   t1, NH
    bne  t4, t1, 3b
    addi t2, t2, 1
    li   t0, 8
    bne  t2, t0, c1

next:
    call barrier_fn
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

/* Sv39: root[2] is a dirty RWX gigapage at 0x80000000, root[1] points to
 * pt_l1, pt_l1[0] to pt_l0 (written by hart 0 every round). */
.section .pt, "aw", @progbits
.align 12
pt_root:
    .dword 0
    .dword (0x80011 << 10) | 1
    .dword (0x80000 << 10) | 0xcf
    .fill 509, 8, 0
pt_l1:
    .dword (0x80012 << 10) | 1
    .fill 511, 8, 0
pt_l0:
    .fill 512, 8, 0
