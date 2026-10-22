/* SMP coherence directed test. All harts boot at 0x80000000 in M-mode (no
 * MMU), branch on mhartid and run the same sequence of phases separated by
 * a sense-reversing barrier. Any failure writes tohost = (code << 16) |
 * (phase << 8) | 2 and parks; hart 0 writes tohost = 1 at the end.
 *
 *   1  CoRR with a late-address first load: the younger load of the same
 *      address executes first, so a remote store between the two executions
 *      must make the CoRR scan replay it. Forbidden: (r1, r2) = (1, 0).
 *   2  Reservation: a remote plain store, AMO or SC between LR and SC must
 *      make the SC fail; an uncontended LR/SC pair succeeds; an LR/SC
 *      counter incremented by every hart (with plain stores to the other
 *      words of the line) loses no update.
 *   3  Watch: amoadd.w on a line that other harts store to; every old value
 *      returned is unique (bitmap) and the sum is exact.
 *   4  Drain starvation: all harts store to and load from the same lines
 *      (one shared line, then 24 lines that overflow the store buffer);
 *      each loop must finish within a cycle bound.
 *   5  Full-line write-through drain: a store to a line held shared keeps
 *      the drain busy while 8 dword stores merge into one full SB entry,
 *      which then drains by write-through. The writer (line shared or not
 *      cached) re-reads the line, and the other harts read it too; the
 *      merged line must come back whole.
 *   6  PLIC claim contention: two sources are pending, every hart claims at
 *      once; the non-zero claims are distinct and cover both sources.
 *
 * Build-time config: -DNH=<harts>.
 */

#ifndef NH
#define NH 2
#endif
#ifndef ITER_CORR
#define ITER_CORR 150
#endif
#ifndef REP_RSV
#define REP_RSV 5
#endif
#ifndef K_CNT
#define K_CNT 48
#endif
#ifndef K_AMO
#define K_AMO 64
#endif
#ifndef K_SHARED
#define K_SHARED 64
#endif
#ifndef K_LINES
#define K_LINES 8
#endif
#ifndef ITER_WT
#define ITER_WT 48
#endif
#ifndef LIM_SHARED
#define LIM_SHARED 40000
#endif
#ifndef LIM_LINES
#define LIM_LINES 60000
#endif

#define NLINES 24
#define RETRY_MAX 2

#define PLIC   0x0c000000

.macro JITTER
    andi t0, s6, 1
    srli s6, s6, 1
    beqz t0, 98f
    li   t1, 0xB400
    xor  s6, s6, t1
98:
    andi t0, s6, 0x3f
97:
    beqz t0, 96f
    addi t0, t0, -1
    j    97b
96:
.endm

/* FAIL phase, reg: record the failure and park. */
.macro FAIL ph, reg
    slli t0, \reg, 16
    li   t1, (\ph << 8) | 2
    or   t0, t0, t1
    la   t1, tohost
    sw   t0, 0(t1)
99: j    99b
.endm

.macro FAILI ph, code
    li   t2, \code
    FAIL \ph, t2
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

/* ---------------- 1: CoRR, late-address first load ------------------- */
    la   a5, v_x
    li   s1, ITER_CORR
p1_loop:
    call barrier_fn
    bnez s0, p1_rd
    JITTER
    li   t0, 1
    sw   t0, 0(a5)
    j    p1_sync
p1_rd:
    JITTER
    li   t0, 0x7fffffff
    div  t1, t0, t0
    addi t1, t1, -1
    add  t3, a5, t1
    lw   a1, 0(t3)
    lw   a2, 0(a5)
p1_sync:
    call barrier_fn
    beqz s0, p1_reset
    li   t0, 1
    bne  a1, t0, p1_next
    bnez a2, p1_next
    FAILI 1, 1
p1_reset:
    sw   x0, 0(a5)
    fence w, w
p1_next:
    addi s1, s1, -1
    bnez s1, p1_loop

/* ---------------- 2: reservation ------------------------------------ */
    la   a5, v_rx
    la   a7, v_f2
    li   s2, 0
p2_kind:
    li   s1, REP_RSV
p2_loop:
    bnez s0, 1f
    sw   x0, 0(a5)
    sw   x0, 0(a7)
    fence w, w
1:  call barrier_fn
    beqz s0, p2_h0
    li   t0, 1
    beq  s0, t0, p2_h1
    j    p2_sync
p2_h0:
    lr.w t0, (a5)
1:  lw   t3, 0(a7)
    beqz t3, 1b
    li   t2, 99
    sc.w t1, t2, (a5)
    bnez t1, p2_sync
    addi t2, s2, 1
    FAIL 2, t2
p2_h1:
    li   t0, 600
1:  addi t0, t0, -1
    bnez t0, 1b
    li   t0, 5
    beqz s2, p2_k0
    li   t1, 1
    beq  s2, t1, p2_k1
p2_k2:
    lr.w t0, (a5)
    addi t0, t0, 5
    sc.w t1, t0, (a5)
    bnez t1, p2_k2
    j    p2_kd
p2_k0:
    sw   t0, 0(a5)
    j    p2_kd
p2_k1:
    amoadd.w t1, t0, (a5)
p2_kd:
    fence w, w
    li   t0, 1
    sw   t0, 0(a7)
p2_sync:
    call barrier_fn
    bnez s0, p2_next
    lw   t0, 0(a5)
    li   t1, 5
    beq  t0, t1, p2_next
    addi t2, s2, 0x11
    FAIL 2, t2
p2_next:
    addi s1, s1, -1
    bnez s1, p2_loop
    addi s2, s2, 1
    li   t0, 3
    bne  s2, t0, p2_kind

/* 2b: uncontended LR/SC pairs succeed (hart 0 only, the rest wait) */
    bnez s0, p2b_sync
    sw   x0, 0(a5)
    fence w, w
    li   t4, 20
    li   a2, 0
p2b_loop:
    lr.w t0, (a5)
    addi t0, t0, 1
    sc.w t1, t0, (a5)
    beqz t1, p2b_ok
    addi a2, a2, 1
    j    p2b_loop
p2b_ok:
    addi t4, t4, -1
    bnez t4, p2b_loop
    lw   t0, 0(a5)
    li   t1, 20
    beq  t0, t1, 1f
    FAILI 2, 0x21
1:  li   t1, RETRY_MAX
    bgtu a2, t1, p2b_fail
p2b_sync:
    j    p2c
p2b_fail:
    FAIL 2, a2

/* 2c: contended LR/SC counter with plain stores to the rest of the line */
p2c:
    call barrier_fn
    bnez s0, 1f
    sw   x0, 0(a5)
    sw   x0, 4(a5)
    sw   x0, 8(a5)
    sw   x0, 12(a5)
    sw   x0, 16(a5)
    fence w, w
1:  call barrier_fn
    li   t4, K_CNT
p2c_loop:
    lr.w t0, (a5)
    addi t0, t0, 1
    sc.w t1, t0, (a5)
    bnez t1, p2c_loop
    slli t5, s0, 2
    add  t5, t5, a5
    sw   t4, 4(t5)
    addi t4, t4, -1
    bnez t4, p2c_loop
    call barrier_fn
    bnez s0, 1f
    lw   t0, 0(a5)
    li   t1, NH * K_CNT
    beq  t0, t1, 2f
    FAILI 2, 0x31
2:  li   t3, 0
3:  slli t5, t3, 2
    add  t5, t5, a5
    lw   t0, 4(t5)
    li   t1, 1
    beq  t0, t1, 4f
    FAILI 2, 0x32
4:  addi t3, t3, 1
    li   t0, NH
    bne  t3, t0, 3b
1:

/* ---------------- 3: AMO unique old values + neighbor stores --------- */
    la   a5, v_c3
    la   a6, v_bm
    call barrier_fn
    bnez s0, 1f
    sw   x0, 0(a5)
    sw   x0, 4(a5)
    sw   x0, 8(a5)
    sw   x0, 12(a5)
    sw   x0, 16(a5)
    sd   x0, 0(a6)
    sd   x0, 8(a6)
    sd   x0, 16(a6)
    sd   x0, 24(a6)
    fence w, w
1:  call barrier_fn
    li   t4, K_AMO
p3_loop:
    li   t0, 1
    amoadd.w t5, t0, (a5)
    srli t2, t5, 6
    slli t2, t2, 3
    add  t2, t2, a6
    andi t3, t5, 63
    li   t0, 1
    sll  t0, t0, t3
    amoor.d t6, t0, (t2)
    and  t6, t6, t0
    beqz t6, 1f
    FAIL 3, t5
1:  slli t5, s0, 2
    add  t5, t5, a5
    sw   t4, 4(t5)
    addi t4, t4, -1
    bnez t4, p3_loop
    call barrier_fn
    bnez s0, 1f
    lw   t0, 0(a5)
    li   t1, NH * K_AMO
    beq  t0, t1, 2f
    FAILI 3, 0x41
2:  li   t3, 0
3:  slli t5, t3, 2
    add  t5, t5, a5
    lw   t0, 4(t5)
    li   t1, 1
    beq  t0, t1, 4f
    FAILI 3, 0x42
4:  addi t3, t3, 1
    li   t0, NH
    bne  t3, t0, 3b
1:

/* ---------------- 4: drain starvation -------------------------------- */
/* 4a: every hart stores to its own dword of one shared line and loads the
 * next hart's dword. */
    la   a5, v_s
    call barrier_fn
    slli t0, s0, 3
    add  a6, a5, t0
    addi t1, s0, 1
    li   t2, NH
    bne  t1, t2, 1f
    li   t1, 0
1:  slli t1, t1, 3
    add  a7, a5, t1
    csrr s8, mcycle
    li   t4, K_SHARED
p4a_loop:
    sd   t4, 0(a6)
    sd   t4, 0(a6)
    sd   t4, 0(a6)
    sd   t4, 0(a6)
    ld   t0, 0(a7)
    sd   t4, 0(a6)
    sd   t4, 0(a6)
    ld   t0, 0(a7)
    addi t4, t4, -1
    bnez t4, p4a_loop
    fence rw, rw
    csrr t0, mcycle
    sub  t0, t0, s8
    li   t1, LIM_SHARED
    bleu t0, t1, 1f
    FAIL 4, t0
1:  call barrier_fn
    ld   t0, 0(a6)
    li   t1, 1
    beq  t0, t1, 1f
    FAILI 4, 0x51
1:

/* 4b: NLINES lines overflow the store buffer while the other harts read
 * the same lines. */
    la   a5, v_rg
    slli t0, s0, 3
    add  a6, a5, t0
    addi t1, s0, 1
    li   t2, NH
    bne  t1, t2, 1f
    li   t1, 0
1:  slli t1, t1, 3
    add  a7, a5, t1
    call barrier_fn
    csrr s8, mcycle
    li   s1, K_LINES
p4b_loop:
    li   t3, 0
    mv   t5, a6
p4b_st:
    sd   s1, 0(t5)
    addi t5, t5, 64
    addi t3, t3, 1
    li   t0, NLINES
    bne  t3, t0, p4b_st
    li   t3, 0
    mv   t5, a7
p4b_ld:
    ld   t0, 0(t5)
    addi t5, t5, 64
    addi t3, t3, 1
    li   t0, NLINES
    bne  t3, t0, p4b_ld
    addi s1, s1, -1
    bnez s1, p4b_loop
    fence rw, rw
    csrr t0, mcycle
    sub  t0, t0, s8
    li   t1, LIM_LINES
    bleu t0, t1, 1f
    FAIL 4, t0
1:  call barrier_fn
    li   t3, 0
    mv   t5, a6
p4b_chk:
    ld   t0, 0(t5)
    li   t1, 1
    beq  t0, t1, 1f
    FAILI 4, 0x52
1:  addi t5, t5, 64
    addi t3, t3, 1
    li   t0, NLINES
    bne  t3, t0, p4b_chk

/* ---------------- 5: full-line write-through drain ------------------- */
.macro CHK5 k
    ld   t0, 8*\k(a5)
    addi t1, s2, \k + 1
    beq  t0, t1, 91f
    li   t2, \k + 0x61
    FAIL 5, t2
91:
.endm

    la   a5, v_w
    li   s1, 1
p5_loop:
    call barrier_fn
    bnez s0, p5_pre
    andi t0, s1, 1
    beqz t0, p5_pre_done
p5_pre:
    ld   t0, 0(a5)
    ld   t0, 64(a5)
p5_pre_done:
    call barrier_fn
    bnez s0, p5_sync
    slli s2, s1, 8
    sw   s2, 64(a5)
    addi t0, s2, 1
    sd   t0, 0(a5)
    addi t0, s2, 2
    sd   t0, 8(a5)
    addi t0, s2, 3
    sd   t0, 16(a5)
    addi t0, s2, 4
    sd   t0, 24(a5)
    addi t0, s2, 5
    sd   t0, 32(a5)
    addi t0, s2, 6
    sd   t0, 40(a5)
    addi t0, s2, 7
    sd   t0, 48(a5)
    addi t0, s2, 8
    sd   t0, 56(a5)
    andi t0, s1, 2
    beqz t0, 1f
    fence rw, rw
1:  CHK5 0
    CHK5 1
    CHK5 2
    CHK5 3
    CHK5 4
    CHK5 5
    CHK5 6
    CHK5 7
p5_sync:
    call barrier_fn
    beqz s0, p5_next
    slli s2, s1, 8
    CHK5 0
    CHK5 1
    CHK5 2
    CHK5 3
    CHK5 4
    CHK5 5
    CHK5 6
    CHK5 7
p5_next:
    addi s1, s1, 1
    li   t0, ITER_WT + 1
    bne  s1, t0, p5_loop

/* ---------------- 6: PLIC claim contention ---------------------------- */
    call barrier_fn
    bnez s0, 1f
    li   t0, PLIC + 4
    li   t1, 1
    sw   t1, 0(t0)
    li   t0, PLIC + 8
    sw   t1, 0(t0)
    li   t3, 0
2:  slli t4, t3, 8
    li   t0, PLIC + 0x2000
    add  t0, t0, t4
    li   t2, 6
    sw   t2, 0(t0)
    addi t3, t3, 1
    li   t0, NH
    bne  t3, t0, 2b
    fence w, w
1:  call barrier_fn
    li   s9, PLIC + 0x200004
    slli t1, s0, 13
    add  s9, s9, t1
    lw   a1, 0(s9)
    la   t2, v_res
    slli t3, s0, 3
    add  t2, t2, t3
    sd   a1, 0(t2)
    fence rw, rw
    call barrier_fn
    lw   a2, 0(s9)
    la   t2, v_res
    slli t3, s0, 3
    add  t2, t2, t3
    sd   a2, 64(t2)
    beqz a1, 1f
    sw   a1, 0(s9)
1:  fence rw, rw
    call barrier_fn
    bnez s0, p6_done
    li   t3, 0
    li   t4, 0
    la   t2, v_res
3:  slli t5, t3, 3
    add  t5, t5, t2
    ld   t0, 0(t5)
    ld   t6, 64(t5)
    beqz t6, 5f
    FAIL 6, t6
5:  beqz t0, 4f
    li   t1, 2
    bleu t0, t1, 6f
    FAIL 6, t0
6:  li   t1, 1
    sll  t1, t1, t0
    and  t5, t4, t1
    beqz t5, 7f
    FAIL 6, t0
7:  or   t4, t4, t1
4:  addi t3, t3, 1
    li   t0, NH
    bne  t3, t0, 3b
    li   t1, 6
    beq  t4, t1, p6_ok
    FAIL 6, t4
p6_ok:
    li   t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
p6_done:
1:  j    1b

/* Sense-reversing barrier over all NH harts. Clobbers t0-t3. */
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

.section .vars, "aw", @progbits
.align 6
v_x:   .word 0
.align 6
v_rx:  .word 0
.align 6
v_f2:  .word 0
.align 6
v_c3:  .fill 16, 4, 0
v_bm:  .fill 8, 4, 0
.align 6
v_s:   .fill 16, 4, 0
v_w:   .fill 32, 4, 0
v_res: .fill 32, 4, 0
.align 6
v_rg:  .fill NLINES * 16, 4, 0
