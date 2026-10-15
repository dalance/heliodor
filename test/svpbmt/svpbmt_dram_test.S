// Svpbmt NC and IO pages that map DRAM, against cached copies of the same
// line in this hart's dcache.
//
// Three leaf pages alias PA 0x80020000: VA 0x40000000 (NC), 0x40001000 (IO)
// and 0x40002000 (PMA, cacheable). Data accesses run in M-mode with
// MPRV = 1, MPP = S, so they translate. Checked:
//   - an NC or IO load sees a value still dirty in the dcache (the uncached
//     read is preceded by a clean of the line)
//   - a cacheable load sees an NC or IO store, whether or not the line was
//     cached at the time
//   - an S-mode fetch through the NC and the IO page reads the code at the
//     aliased PA
// tohost = 1 on pass, (n << 1) | 1 for a failed check n.

    .section .text.init
    .option norvc
    .globl _start
_start:
    la   t0, mtrap
    csrw mtvec, t0

    li   t0, 0x80010008          # L2[1] -> L1
    li   t1, 0x20004401
    sd   t1, 0(t0)
    li   t0, 0x80011000          # L1[0] -> L0
    li   t1, 0x20004801
    sd   t1, 0(t0)
    li   t0, 0x80012000          # L0[0]: VA 0x40000000 -> PA 0x80020000, NC
    li   t1, 0x20000000200080CF
    sd   t1, 0(t0)
    li   t0, 0x80012008          # L0[1]: VA 0x40001000 -> PA 0x80020000, IO
    li   t1, 0x40000000200080CF
    sd   t1, 0(t0)
    li   t0, 0x80012010          # L0[2]: VA 0x40002000 -> PA 0x80020000, PMA
    li   t1, 0x00000000200080CF
    sd   t1, 0(t0)

    li   t0, 1
    slli t0, t0, 62              # menvcfg.PBMTE
    csrs menvcfg, t0
    li   t0, 0x8000000000080010
    csrw satp, t0
    sfence.vma zero, zero
    li   t0, 0x20800             # MPRV = 1, MPP = S
    csrs mstatus, t0

    li   s0, 0x40000000          # NC
    li   s1, 0x40001000          # IO
    li   s2, 0x40002000          # cacheable

    // 1: an NC load sees a dirty cached dword.
    li   gp, 1
    li   t1, 0x1111
    sd   t1, 0(s2)
    ld   a1, 0(s0)
    bne  a1, t1, fail

    // 2: an IO load sees it too.
    li   gp, 2
    ld   a1, 0(s1)
    bne  a1, t1, fail

    // 3: a cacheable load sees an NC store to a cached line.
    li   gp, 3
    ld   a1, 0(s2)
    li   t1, 0x2222
    sd   t1, 8(s0)
    ld   a1, 8(s2)
    bne  a1, t1, fail
    li   t1, 0x1111
    ld   a1, 0(s2)
    bne  a1, t1, fail

    // 4: dirty cached bytes and an IO store in the same line, read uncached.
    li   gp, 4
    li   t1, 0x3333
    sd   t1, 16(s2)
    li   t2, 0x4444
    sw   t2, 24(s1)
    ld   a1, 16(s0)
    bne  a1, t1, fail
    lwu  a1, 24(s0)
    bne  a1, t2, fail
    ld   a1, 24(s2)
    bne  a1, t2, fail

    // 5: an NC store to a line that is not cached, then a cacheable load.
    li   gp, 5
    li   t1, 0x5555
    sd   t1, 0x400(s0)
    ld   a1, 0x400(s2)
    bne  a1, t1, fail

    // 6/7: S-mode fetch through the NC and the IO page.
    li   gp, 6
    li   a1, 0
    la   s3, back6
    li   t0, 0x40000800
    csrw mepc, t0
    mret
back6:
    li   t1, 0x6666
    bne  a1, t1, fail

    li   gp, 7
    li   a1, 0
    la   s3, back7
    li   t0, 0x40001800
    csrw mepc, t0
    li   t0, 0x1800
    csrc mstatus, t0
    li   t0, 0x800
    csrs mstatus, t0             # MPP = S
    mret
back7:
    li   t1, 0x6666
    bne  a1, t1, fail

    li   t0, 1
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

// An ecall from S-mode returns to s3 in M-mode; any other trap fails.
mtrap:
    csrr t6, mcause
    li   t5, 9
    bne  t6, t5, fail
    jr   s3

fail:
    li   t0, 0x20000
    csrc mstatus, t0
    slli t0, gp, 1
    ori  t0, t0, 1
    li   t1, 0x80001000
    sw   t0, 0(t1)
3:  j    3b

    .section .ncfunc, "ax", @progbits
    li   a1, 0x6666
    ecall

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
