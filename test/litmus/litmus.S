/* P9.0: RVWMO litmus-test program for the heliodor SMP SoC.
 *
 * All harts boot at 0x80000000 in M-mode (no MMU) and branch on mhartid.
 * Each litmus test runs ITER iterations; every iteration is framed by a
 * sense-reversing barrier (amoadd.w.aqrl arrive + sense spin, full fence on
 * exit) so the racing accesses of one iteration cannot bleed into the next.
 * A per-hart 16-bit LFSR inserts a 0..63-cycle jitter delay in front of each
 * hart's litmus body so the two (or four) instruction streams overlap at
 * varying offsets across iterations.
 *
 * The observer hart of each test records the outcome in a histogram at
 * RESULT_BASE (word[test*16 + slot]); after all tests, hart0 scans the
 * forbidden-outcome table and writes tohost:
 *   tohost = 1                          all forbidden counts zero  -> PASS
 *   tohost = ((test<<8|slot)<<4) | 2    a forbidden outcome was observed
 *   tohost = (mcause<<8) | 0xE0        unexpected trap on any hart
 * The harness additionally dumps all non-zero histogram slots, so the
 * observed-outcome distribution (including allowed weak outcomes) is visible
 * on every run.
 *
 * Tests (x/y on separate cache lines, reset to 0 between iterations):
 *   0  CoRR        P0: x=1            P1: r1=x; r2=x            forbid (1,0)
 *   1  CoWW        P0: x=1; x=2       P1: r1=x; r2=x            forbid value
 *                  reversal (1,0)(2,0)(2,1) + final x != 2
 *   2  MP+fence    P0: x=1; fence w,w; y=1
 *                  P1: r1=y; fence r,r; r2=x                    forbid (1,0)
 *   3  MP+addrdep  P0: as test 2      P1: r1=y; r2=*(x + (r1&0)) forbid (1,0)
 *   4  SB+fence    P0: x=1; fence rw,rw; r1=y
 *                  P1: y=1; fence rw,rw; r2=x                   forbid (0,0)
 *   5  LB+datadep  P0: r1=x; y=r1     P1: r2=y; x=r2            forbid (1,1)
 *   6  MP+aq/rl    P0: x=1; amoswap.w.rl y,1
 *                  P1: r1=lr.w.aq(y); r2=x                      forbid (1,0)
 *   7  AMO total   P0+P1: amoadd.w(x,1) xAMO_ITER  -> x must be 2*AMO_ITER
 *   8  LR/SC lock  P0+P1: lock(x); y++; unlock(x) xLOCK_ITER -> y == 2*LOCK
 *   9  SB plain    SB without fences: ALL outcomes allowed (RVWMO permits
 *                  (0,0)); sanity that the harness can OBSERVE weak behavior
 *   10 IRIW+fence  (NH>=4) P0: x=1  P1: y=1
 *                  P2: r1=x; fence rw,rw; r2=y
 *                  P3: r3=y; fence rw,rw; r4=x        forbid (1,0,1,0)
 *
 * Build-time config (see Makefile): -DNH=<harts> -DITER=<iterations>.
 */

#ifndef NH
#define NH 2
#endif
#ifndef ITER
#define ITER 1000
#endif
#ifndef AMO_ITER
#define AMO_ITER 1000
#endif
#ifndef LOCK_ITER
#define LOCK_ITER 500
#endif

/* Register conventions (whole program):
 *   s0  mhartid                  s1  iteration counter
 *   s3  barrier base             s4  vars base (x @+0, y @+64)
 *   s5  result base              s6  LFSR state
 *   s7  barrier local sense      s9  scratch base
 *   a1,a2  litmus-observed values (live across barriers)
 *   a3,a4  record_fn args (test, slot)
 *   t0-t6  temporaries (clobbered by barrier_fn/record_fn/JITTER)
 */

/* 0..63-cycle pseudo-random delay; steps the 16-bit Fibonacci LFSR (taps
 * 0xB400) in s6. Clobbers t0, t1. */
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

.section .text.init
.globl _start
_start:
    la   t0, trap_handler
    csrw mtvec, t0
    csrr s0, mhartid
    li   s3, 0x80002000          /* barrier: count @+0, sense @+64 */
    li   s4, 0x80003000          /* vars: x @+0, y @+64 */
    li   s5, 0x80004000          /* result histogram */
    li   s9, 0x80005000          /* scratch handoff */
    li   s7, 0                   /* barrier local sense */
    li   s6, 0xACE1              /* LFSR seed, offset per hart */
    li   t0, 0x1234
    mul  t1, t0, s0
    add  s6, s6, t1

/* ---------------- test 0: CoRR -------------------------------------- */
    li   s1, ITER
t0_loop:
    call barrier_fn
    beqz s0, t0_p0
    li   t0, 1
    beq  s0, t0, t0_p1
    j    t0_sync
t0_p0:
    JITTER
    li   t0, 1
    sw   t0, 0(s4)               /* x = 1 */
    j    t0_sync
t0_p1:
    JITTER
    lw   a1, 0(s4)               /* r1 = x */
    lw   a2, 0(s4)               /* r2 = x */
t0_sync:
    call barrier_fn
    beqz s0, t0_reset
    li   t0, 1
    bne  s0, t0, t0_next
    slli a4, a1, 1
    or   a4, a4, a2
    li   a3, 0
    call record_fn
    j    t0_next
t0_reset:
    sw   x0, 0(s4)
    sw   x0, 64(s4)
    fence w, w
t0_next:
    addi s1, s1, -1
    bnez s1, t0_loop

/* ---------------- test 1: CoWW (+ final-value check) ----------------- */
    li   s1, ITER
t1_loop:
    call barrier_fn
    beqz s0, t1_p0
    li   t0, 1
    beq  s0, t0, t1_p1
    j    t1_sync
t1_p0:
    JITTER
    li   t0, 1
    sw   t0, 0(s4)               /* x = 1 */
    li   t0, 2
    sw   t0, 0(s4)               /* x = 2 */
    j    t1_sync
t1_p1:
    JITTER
    lw   a1, 0(s4)
    lw   a2, 0(s4)
t1_sync:
    call barrier_fn
    beqz s0, t1_reset
    li   t0, 1
    bne  s0, t0, t1_next
    slli t0, a1, 1               /* slot = r1*3 + r2 (r in 0..2) */
    add  t0, t0, a1
    add  a4, t0, a2
    li   a3, 1
    call record_fn
    j    t1_next
t1_reset:
    lw   t0, 0(s4)               /* final x must be 2 */
    li   t1, 2
    beq  t0, t1, t1_reset_ok
    li   a3, 1
    li   a4, 9                   /* slot 9 = final-value mismatch */
    call record_fn
t1_reset_ok:
    sw   x0, 0(s4)
    sw   x0, 64(s4)
    fence w, w
t1_next:
    addi s1, s1, -1
    bnez s1, t1_loop

/* ---------------- test 2: MP + fences -------------------------------- */
    li   s1, ITER
t2_loop:
    call barrier_fn
    beqz s0, t2_p0
    li   t0, 1
    beq  s0, t0, t2_p1
    j    t2_sync
t2_p0:
    JITTER
    li   t0, 1
    sw   t0, 0(s4)               /* x = 1 */
    fence w, w
    sw   t0, 64(s4)              /* y = 1 */
    j    t2_sync
t2_p1:
    JITTER
    lw   a1, 64(s4)              /* r1 = y */
    fence r, r
    lw   a2, 0(s4)               /* r2 = x */
t2_sync:
    call barrier_fn
    beqz s0, t2_reset
    li   t0, 1
    bne  s0, t0, t2_next
    slli a4, a1, 1
    or   a4, a4, a2
    li   a3, 2
    call record_fn
    j    t2_next
t2_reset:
    sw   x0, 0(s4)
    sw   x0, 64(s4)
    fence w, w
t2_next:
    addi s1, s1, -1
    bnez s1, t2_loop

/* ---------------- test 3: MP + address dependency -------------------- */
    li   s1, ITER
t3_loop:
    call barrier_fn
    beqz s0, t3_p0
    li   t0, 1
    beq  s0, t0, t3_p1
    j    t3_sync
t3_p0:
    JITTER
    li   t0, 1
    sw   t0, 0(s4)
    fence w, w
    sw   t0, 64(s4)
    j    t3_sync
t3_p1:
    JITTER
    lw   a1, 64(s4)              /* r1 = y */
    and  t0, a1, x0              /* t0 = 0, syntactic addr dep on r1 */
    add  t0, t0, s4
    lw   a2, 0(t0)               /* r2 = x, address depends on r1 */
t3_sync:
    call barrier_fn
    beqz s0, t3_reset
    li   t0, 1
    bne  s0, t0, t3_next
    slli a4, a1, 1
    or   a4, a4, a2
    li   a3, 3
    call record_fn
    j    t3_next
t3_reset:
    sw   x0, 0(s4)
    sw   x0, 64(s4)
    fence w, w
t3_next:
    addi s1, s1, -1
    bnez s1, t3_loop

/* ---------------- test 4: SB + fences (3-barrier: P0 hands r1 over) -- */
    li   s1, ITER
t4_loop:
    call barrier_fn
    beqz s0, t4_p0
    li   t0, 1
    beq  s0, t0, t4_p1
    j    t4_sync
t4_p0:
    JITTER
    li   t0, 1
    sw   t0, 0(s4)               /* x = 1 */
    fence rw, rw
    lw   a1, 64(s4)              /* r1 = y */
    j    t4_sync
t4_p1:
    JITTER
    li   t0, 1
    sw   t0, 64(s4)              /* y = 1 */
    fence rw, rw
    lw   a2, 0(s4)               /* r2 = x */
t4_sync:
    call barrier_fn
    bnez s0, t4_handoff_done
    sw   a1, 0(s9)               /* hart0: publish r1 ... */
    sw   x0, 0(s4)               /* ... and reset vars */
    sw   x0, 64(s4)
    fence w, w
t4_handoff_done:
    call barrier_fn
    li   t0, 1
    bne  s0, t0, t4_next
    lw   t0, 0(s9)               /* r1 from hart0 */
    slli a4, t0, 1
    or   a4, a4, a2
    li   a3, 4
    call record_fn
t4_next:
    addi s1, s1, -1
    bnez s1, t4_loop

/* ---------------- test 5: LB + data dependency ------------------------ */
    li   s1, ITER
t5_loop:
    call barrier_fn
    beqz s0, t5_p0
    li   t0, 1
    beq  s0, t0, t5_p1
    j    t5_sync
t5_p0:
    JITTER
    lw   a1, 0(s4)               /* r1 = x */
    sw   a1, 64(s4)              /* y = r1 (data dep) */
    j    t5_sync
t5_p1:
    JITTER
    lw   a2, 64(s4)              /* r2 = y */
    sw   a2, 0(s4)               /* x = r2 (data dep) */
t5_sync:
    call barrier_fn
    bnez s0, t5_b3
    sw   a1, 0(s9)               /* hart0: publish r1, reset vars */
    sw   x0, 0(s4)
    sw   x0, 64(s4)
    fence w, w
t5_b3:
    call barrier_fn
    li   t0, 1
    bne  s0, t0, t5_next
    lw   t0, 0(s9)
    slli a4, t0, 1
    or   a4, a4, a2
    li   a3, 5
    call record_fn
t5_next:
    addi s1, s1, -1
    bnez s1, t5_loop

/* ---------------- test 6: MP + amoswap.rl / lr.aq --------------------- */
    li   s1, ITER
t6_loop:
    call barrier_fn
    beqz s0, t6_p0
    li   t0, 1
    beq  s0, t0, t6_p1
    j    t6_sync
t6_p0:
    JITTER
    li   t0, 1
    sw   t0, 0(s4)               /* x = 1 */
    addi t1, s4, 64
    amoswap.w.rl x0, t0, (t1)    /* y = 1, release */
    j    t6_sync
t6_p1:
    JITTER
    addi t1, s4, 64
    lr.w.aq a1, (t1)             /* r1 = y, acquire */
    lw   a2, 0(s4)               /* r2 = x */
t6_sync:
    call barrier_fn
    beqz s0, t6_reset
    li   t0, 1
    bne  s0, t0, t6_next
    slli a4, a1, 1
    or   a4, a4, a2
    li   a3, 6
    call record_fn
    j    t6_next
t6_reset:
    sw   x0, 0(s4)
    sw   x0, 64(s4)
    fence w, w
t6_next:
    addi s1, s1, -1
    bnez s1, t6_loop

/* ---------------- test 7: AMO atomicity (no iteration loop) ----------- */
    call barrier_fn
    li   t0, 2
    bgeu s0, t0, t7_sync         /* only harts 0,1 participate */
    li   t1, AMO_ITER
    li   t2, 1
    addi t3, s4, 0
t7_amo:
    amoadd.w x0, t2, (t3)
    addi t1, t1, -1
    bnez t1, t7_amo
t7_sync:
    call barrier_fn
    bnez s0, t7_done
    lw   t0, 0(s4)
    li   t1, 2*AMO_ITER
    beq  t0, t1, t7_ok
    li   a3, 7
    li   a4, 1                   /* slot 1 = lost AMO update(s) */
    call record_fn
t7_ok:
    sw   x0, 0(s4)
    sw   x0, 64(s4)
    fence w, w
t7_done:

/* ---------------- test 8: LR/SC spinlock mutual exclusion ------------- */
    call barrier_fn
    li   t0, 2
    bgeu s0, t0, t8_sync         /* only harts 0,1 participate */
    addi t3, s4, 0               /* lock @ x */
    li   t4, LOCK_ITER
t8_outer:
t8_acq:
    lr.w.aq t0, (t3)
    bnez t0, t8_acq
    li   t1, 1
    sc.w t2, t1, (t3)
    bnez t2, t8_acq
    lw   t5, 64(s4)              /* critical section: plain y++ */
    addi t5, t5, 1
    sw   t5, 64(s4)
    amoswap.w.rl x0, x0, (t3)    /* unlock, release */
    addi t4, t4, -1
    bnez t4, t8_outer
t8_sync:
    call barrier_fn
    bnez s0, t8_done
    lw   t0, 64(s4)
    li   t1, 2*LOCK_ITER
    beq  t0, t1, t8_ok
    li   a3, 8
    li   a4, 1                   /* slot 1 = critical-section race */
    call record_fn
t8_ok:
    sw   x0, 0(s4)
    sw   x0, 64(s4)
    fence w, w
t8_done:

/* ---------------- test 9: SB plain (sanity: weak outcomes ALLOWED) ---- */
    li   s1, ITER
t9_loop:
    call barrier_fn
    beqz s0, t9_p0
    li   t0, 1
    beq  s0, t0, t9_p1
    j    t9_sync
t9_p0:
    JITTER
    li   t0, 1
    sw   t0, 0(s4)               /* x = 1 */
    lw   a1, 64(s4)              /* r1 = y (no fence!) */
    j    t9_sync
t9_p1:
    JITTER
    li   t0, 1
    sw   t0, 64(s4)              /* y = 1 */
    lw   a2, 0(s4)               /* r2 = x (no fence!) */
t9_sync:
    call barrier_fn
    bnez s0, t9_handoff_done
    sw   a1, 0(s9)
    sw   x0, 0(s4)
    sw   x0, 64(s4)
    fence w, w
t9_handoff_done:
    call barrier_fn
    li   t0, 1
    bne  s0, t0, t9_next
    lw   t0, 0(s9)
    slli a4, t0, 1
    or   a4, a4, a2
    li   a3, 9
    call record_fn
t9_next:
    addi s1, s1, -1
    bnez s1, t9_loop

#if NH >= 4
/* ---------------- test 10: IRIW + fences (4 harts) -------------------- */
    li   s1, ITER
t10_loop:
    call barrier_fn
    beqz s0, t10_p0
    li   t0, 1
    beq  s0, t0, t10_p1
    li   t0, 2
    beq  s0, t0, t10_p2
    li   t0, 3
    beq  s0, t0, t10_p3
    j    t10_sync
t10_p0:
    JITTER
    li   t0, 1
    sw   t0, 0(s4)               /* x = 1 */
    j    t10_sync
t10_p1:
    JITTER
    li   t0, 1
    sw   t0, 64(s4)              /* y = 1 */
    j    t10_sync
t10_p2:
    JITTER
    lw   a1, 0(s4)               /* r1 = x */
    fence rw, rw
    lw   a2, 64(s4)              /* r2 = y */
    j    t10_sync
t10_p3:
    JITTER
    lw   a1, 64(s4)              /* r3 = y */
    fence rw, rw
    lw   a2, 0(s4)               /* r4 = x */
t10_sync:
    call barrier_fn
    beqz s0, t10_reset
    li   t0, 2
    bne  s0, t0, t10_b3
    slli t0, a1, 1               /* hart2: publish (r1<<1)|r2 */
    or   t0, t0, a2
    sw   t0, 0(s9)
    j    t10_b3
t10_reset:
    sw   x0, 0(s4)
    sw   x0, 64(s4)
    fence w, w
t10_b3:
    call barrier_fn
    li   t0, 3
    bne  s0, t0, t10_next
    lw   t0, 0(s9)               /* hart3: slot = (r1,r2,r3,r4) */
    slli a4, t0, 2
    slli t1, a1, 1
    or   t1, t1, a2
    or   a4, a4, t1
    li   a3, 10
    call record_fn
t10_next:
    addi s1, s1, -1
    bnez s1, t10_loop
#endif

/* ---------------- final: hart0 checks the forbidden table ------------- */
    call barrier_fn
    bnez s0, park
    la   t6, forbidden_table
chk_loop:
    lw   t0, 0(t6)
    bltz t0, all_ok
    srli t1, t0, 8               /* test */
    andi t2, t0, 0xff            /* slot */
    slli t3, t1, 6
    add  t3, t3, s5
    slli t4, t2, 2
    add  t3, t3, t4
    lw   t5, 0(t3)
    bnez t5, fail_found
    addi t6, t6, 4
    j    chk_loop
fail_found:
    slli t0, t0, 4               /* tohost = ((test<<8|slot)<<4) | 2 */
    ori  t0, t0, 2
    la   t1, tohost
    sw   t0, 0(t1)
    j    park
all_ok:
    li   t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
park:
1:  j 1b

/* Sense-reversing barrier over all NH harts. Full memory barrier on exit
 * (amoadd.w.aqrl arrive + trailing fence rw,rw). Clobbers t0-t3, keeps a*. */
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
    sw   x0, 0(s3)               /* last arriver: reset count ... */
    fence w, w
    sw   s7, 64(s3)              /* ... then flip sense (release) */
93:
    fence rw, rw
    ret

/* Histogram increment: word[RESULT_BASE + a3*64 + a4*4] += 1.
 * Single-writer per test (the observer hart), so plain lw/sw is race-free.
 * Clobbers t0-t2. */
record_fn:
    slli t0, a3, 6
    add  t0, t0, s5
    slli t1, a4, 2
    add  t0, t0, t1
    lw   t2, 0(t0)
    addi t2, t2, 1
    sw   t2, 0(t0)
    ret

/* Any trap = test failure: tohost = (mcause<<8) | 0xE0 (even -> fail). */
trap_handler:
    csrr t0, mcause
    slli t0, t0, 8
    ori  t0, t0, 0xE0
    la   t1, tohost
    sw   t0, 0(t1)
1:  j 1b

/* Forbidden outcomes: word = (test<<8) | slot, terminated by -1. */
.align 3
forbidden_table:
    .word 0x002                  /* CoRR        (r1,r2)=(1,0)          */
    .word 0x103                  /* CoWW        (1,0)                  */
    .word 0x106                  /* CoWW        (2,0)                  */
    .word 0x107                  /* CoWW        (2,1)                  */
    .word 0x109                  /* CoWW        final x != 2           */
    .word 0x202                  /* MP+fence    (1,0)                  */
    .word 0x302                  /* MP+addrdep  (1,0)                  */
    .word 0x400                  /* SB+fence    (0,0)                  */
    .word 0x503                  /* LB+datadep  (1,1)                  */
    .word 0x602                  /* MP+aq/rl    (1,0)                  */
    .word 0x701                  /* AMO         lost update            */
    .word 0x801                  /* LR/SC lock  critical-section race  */
#if NH >= 4
    .word 0xA0A                  /* IRIW+fence  (1,0,1,0)              */
#endif
    .word -1

.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost:   .dword 0
.globl fromhost
fromhost: .dword 0

/* Shared data, zero-initialized in the binary image (no runtime BSS clear). */
.section .barrier, "aw", @progbits
barrier_count: .word 0
.align 6
barrier_sense: .word 0
.align 6

.section .vars, "aw", @progbits
var_x: .word 0
.align 6
var_y: .word 0
.align 6

.section .result, "aw", @progbits
result_hist: .fill 256, 4, 0     /* 16 tests x 16 slots, words */

.section .scratch, "aw", @progbits
scratch0: .dword 0
.align 6
