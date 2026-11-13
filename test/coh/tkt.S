/* Ticket spinlock stress, the Linux 7.1 RISC-V queued-ticket pattern with
 * Zawrs: lock is amoadd.w.aqrl of the next ticket, the waiter spins on
 * lw + lr.w + wrs.nto, unlock is a per-hart halfword counter update, then
 * lw of the lock word, fence rw,w and a halfword store of the owner. Every
 * hart takes the lock ITER times, increments a shared counter inside it and
 * holds it for up to HOLD loop turns, so the other hart waits in the spin.
 * Hart 0 writes tohost = 1 when the counter is exact, or (count << 16) | 2.
 *
 * Build-time config: -DNH=<harts>.
 */

#ifndef NH
#define NH 2
#endif
#ifndef ITER
#define ITER 2000
#endif
#ifndef HOLD
#define HOLD 0xff
#endif

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
    la   a0, v_lock
    la   a1, v_cnt
    la   a2, v_pcpu
    slli t0, s0, 6
    add  a2, a2, t0
    call barrier_fn
    li   s1, ITER

loop:
    /* lock */
    lui  a5, 0x10
    amoadd.w.aqrl a5, a5, (a0)
    srliw a3, a5, 16
    slli a5, a5, 48
    srli a5, a5, 48
    beq  a3, a5, locked
spin:
    lw   a5, 0(a0)
    addiw a4, a5, 0
    slli a5, a5, 48
    srli a5, a5, 48
    beq  a3, a5, acq
    lr.w a5, (a0)
    xor  a5, a5, a4
    bnez a5, spin
    .insn 4, 0x00d00073
    j    spin
acq:
    fence r, r
    fence rw, rw
locked:
    lhu  a4, 0(a2)
    addiw a4, a4, 1
    sh   a4, 0(a2)

    /* critical section */
    lw   t0, 0(a1)
    addi t0, t0, 1
    sw   t0, 0(a1)
    andi t0, s6, HOLD
1:  beqz t0, 2f
    addi t0, t0, -1
    j    1b
2:
    srli t1, s6, 3
    xor  s6, s6, t1
    slli t1, s6, 7
    xor  s6, s6, t1

    /* unlock */
    lhu  a4, 2(a2)
    beqz a4, 1f
    sh   zero, 2(a2)
    fence o, w
1:
    lhu  a4, 0(a2)
    addiw a4, a4, -1
    sh   a4, 0(a2)
    lw   a5, 0(a0)
    addiw a5, a5, 0
    fence rw, w
    addiw a5, a5, 1
    slli a5, a5, 48
    srli a5, a5, 48
    sh   a5, 0(a0)

    JITTER
    addi s1, s1, -1
    bnez s1, loop

    call barrier_fn
    bnez s0, park
    lw   t0, 0(a1)
    li   t1, NH * ITER
    beq  t0, t1, pass
    slli t0, t0, 16
    ori  t0, t0, 2
    la   t1, tohost
    sw   t0, 0(t1)
    j    park
pass:
    li   t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
park:
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
v_lock: .word 0
#ifdef SAME_LINE
        .word 0
v_cnt:  .word 0
#else
.align 6
v_cnt:  .word 0
#endif
.align 6
v_pcpu: .fill NH * 16, 4, 0
