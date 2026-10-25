/* AXI directed test of the error observation (design U46): reads and a
 * write of DRAM addresses the PMA backs but the slave does not (the harness
 * gives the slave 2 MiB of the 4 MiB DRAM region), so the slave answers
 * DECERR on R and B. The core sees no fault; the harness requires both
 * sticky error flags of the SoC. Same mappings as i1.S.
 *
 * tohost = 1 at the end; a trap writes (mcause << 8) | 0xE0.
 */

#define HOLE     0x80300000
#define NC_DELTA 0x40000000

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
    li   a0, HOLE
    li   t0, NC_DELTA
    add  a1, a0, t0
    ld   t2, 0(a0)          /* cacheable line read: DECERR beats */
    li   t1, 0x5a5a
    sd   t1, 64(a1)         /* NC write: DECERR B */
    fence rw, rw
    ld   t2, 64(a1)         /* NC read: DECERR */
    li   t0, 1
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
