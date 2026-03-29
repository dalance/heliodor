/* Stub S-mode kernel for heliodor Linux boot test.
 *
 * Loaded at PA 0x80000000, runs in S-mode.
 * Exercises the full Linux-like boot path:
 *   1. Read DTB pointer from a1
 *   2. Set up Sv39 page tables (2MB megapage identity mapping)
 *   3. Enable MMU
 *   4. Set up S-mode trap handler
 *   5. Enable timer interrupt, wait for tick
 *   6. Print boot message via SBI putchar
 *   7. Call SBI SRST to shutdown (signals test pass)
 *
 * Page table layout (within DRAM, using space at 0x803C0000):
 *   0x803C0000 : L2 page table (root, 4 KB)
 *   0x803C1000 : L1 page table (for VA 0x80000000 range, 4 KB)
 *
 * Virtual address mapping (identity map via 2MB megapages):
 *   VA 0x00000000 → PA 0x00000000 (firmware ROM, for SBI ecall)
 *   VA 0x02000000 → PA 0x02000000 (CLINT, 2 MB megapage)
 *   VA 0x0C000000 → PA 0x0C000000 (PLIC, needs multiple megapages)
 *   VA 0x10000000 → PA 0x10000000 (UART, 2 MB megapage)
 *   VA 0x80000000 → PA 0x80000000 (DRAM 4 MB, 2 megapages)
 *
 * Note: For simplicity, use L1 gigapage (1 GB) entries where possible.
 */

    .section .text.start, "ax"
    .global _start

#define PAGE_TABLE_BASE 0x80030000
#define L2_TABLE        (PAGE_TABLE_BASE)
#define L1_LOW_TABLE    (PAGE_TABLE_BASE + 0x1000)
#define L1_HIGH_TABLE   (PAGE_TABLE_BASE + 0x2000)
#define STACK_TOP       0x8003F000

/* PTE flags */
#define PTE_V   0x01
#define PTE_R   0x02
#define PTE_W   0x04
#define PTE_X   0x08
#define PTE_A   0x40
#define PTE_D   0x80
#define PTE_LEAF_RWXAD (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)

/* SBI calls */
#define SBI_PUTCHAR     0x01
#define SBI_EXT_TIME    0x54494D45
#define SBI_EXT_SRST    0x53525354

_start:
    /* Save DTB pointer */
    mv s0, a1       /* s0 = DTB address */

    /* Set up stack */
    li sp, STACK_TOP

    /* ============================================================
     * Set up Sv39 page tables
     * ============================================================ */

    /* Zero page table area (3 pages = 12 KB) */
    li t0, PAGE_TABLE_BASE
    li t1, PAGE_TABLE_BASE + 0x3000
1:  sd zero, 0(t0)
    addi t0, t0, 8
    blt t0, t1, 1b

    /* L2 (root) page table:
     *   Entry [0]: VA 0x00000000-0x3FFFFFFF → L1_LOW_TABLE (non-leaf)
     *   Entry [2]: VA 0x80000000-0xBFFFFFFF → L1_HIGH_TABLE (non-leaf) */
    li t0, L2_TABLE

    /* L2[0] → L1_LOW_TABLE */
    li t1, (L1_LOW_TABLE >> 12) << 10
    ori t1, t1, PTE_V          /* non-leaf: V only */
    sd t1, 0(t0)               /* entry [0] = 8*0 */

    /* L2[2] → L1_HIGH_TABLE */
    li t1, (L1_HIGH_TABLE >> 12) << 10
    ori t1, t1, PTE_V
    sd t1, 16(t0)              /* entry [2] = 8*2 */

    /* L1_LOW_TABLE: 2 MB megapage entries for low addresses
     *   Entry [0]:   VA 0x00000000 → PA 0x00000000 (firmware, RWXAD)
     *   Entry [16]:  VA 0x02000000 → PA 0x02000000 (CLINT)
     *   Entry [96]:  VA 0x0C000000 → PA 0x0C000000 (PLIC)
     *   Entry [128]: VA 0x10000000 → PA 0x10000000 (UART) */
    li t0, L1_LOW_TABLE

    /* PTE = (PA >> 2) | flags  (since PA>>12<<10 = PA>>2) */
    /* [0]: PA 0x00000000, 2MB megapage */
    li t1, PTE_LEAF_RWXAD       /* PA=0 so PPN=0 */
    sd t1, 0(t0)

    /* [16]: PA 0x02000000, 2MB megapage (CLINT) */
    li t1, (0x02000000 >> 2) | PTE_LEAF_RWXAD
    sd t1, 128(t0)     /* 16 * 8 = 128 */

    /* [96]: PA 0x0C000000, 2MB megapage (PLIC) */
    li t1, (0x0C000000 >> 2) | PTE_LEAF_RWXAD
    sd t1, 768(t0)     /* 96 * 8 = 768 */

    /* [128]: PA 0x10000000, 2MB megapage (UART) */
    li t1, (0x10000000 >> 2) | PTE_LEAF_RWXAD
    sd t1, 1024(t0)    /* 128 * 8 = 1024 */

    /* L1_HIGH_TABLE: entries for 0x80000000+ DRAM
     *   Entry [0]: VA 0x80000000 → PA 0x80000000 (2 MB)
     *   Entry [1]: VA 0x80200000 → PA 0x80200000 (2 MB) */
    li t0, L1_HIGH_TABLE

    /* PTE = (PA >> 2) | flags  (since PA>>12<<10 = PA>>2) */
    li t1, 0x80000000
    srli t1, t1, 2
    ori t1, t1, PTE_LEAF_RWXAD
    sd t1, 0(t0)

    li t1, 0x80200000
    srli t1, t1, 2
    ori t1, t1, PTE_LEAF_RWXAD
    sd t1, 8(t0)

    /* ============================================================
     * Enable Sv39 MMU
     * ============================================================ */
    /* satp = MODE(8=Sv39) | PPN(L2_TABLE >> 12) */
    li t0, L2_TABLE
    srli t0, t0, 12     /* PPN */
    li t1, 8
    slli t1, t1, 60     /* MODE = Sv39 */
    or t0, t0, t1
    csrw satp, t0
    sfence.vma zero, zero

    /* ============================================================
     * Set up S-mode trap handler
     * ============================================================ */
    la t0, s_trap_handler
    csrw stvec, t0

    /* ============================================================
     * Test timer interrupt
     * ============================================================ */
    /* Enable supervisor timer interrupt */
    li t0, 0x20     /* SIE.STIE = bit 5 */
    csrs sie, t0

    /* SBI set_timer(mtime + 100) */
    csrr a0, time
    addi a0, a0, 100
    li a7, 0            /* legacy set_timer */
    ecall

    /* Wait for timer tick (s_tick flag set by handler) */
    li t0, 0
2:  la t1, s_tick
    ld t2, 0(t1)
    beqz t2, 2b

    /* ============================================================
     * Print boot message via SBI putchar
     * ============================================================ */
    la a0, boot_msg
3:  lbu t0, 0(a0)
    beqz t0, 4f
    /* SBI putchar: a0=char, a7=0x01 */
    mv a1, a0       /* save string pointer */
    mv a0, t0       /* char to print */
    li a7, SBI_PUTCHAR
    ecall
    mv a0, a1       /* restore string pointer */
    addi a0, a0, 1
    j 3b

4:
    /* ============================================================
     * Shutdown via SBI SRST
     * ============================================================ */
    li a7, SBI_EXT_SRST
    li a6, 0        /* FID = system_reset */
    li a0, 0        /* SHUTDOWN */
    li a1, 0        /* NO_REASON */
    ecall

    /* Should not reach here */
    li x3, 0xFF
    j .

/* ============================================================
 * S-mode trap handler
 * ============================================================ */
    .balign 4
s_trap_handler:
    csrr t0, scause

    /* Interrupt? (MSB set) */
    srli t1, t0, 63
    beqz t1, s_sync_trap

    /* Timer interrupt (code 5) */
    slli t1, t0, 1
    srli t1, t1, 1
    li t2, 5
    bne t1, t2, s_unexpected

    /* Set tick flag */
    la t1, s_tick
    li t2, 1
    sd t2, 0(t1)

    /* Disable STIE */
    li t0, 0x20
    csrc sie, t0
    sret

s_sync_trap:
    /* Unexpected sync exception */
    csrr x11, scause
    csrr x12, stval
    li x3, 0xCC
    j .

s_unexpected:
    li x3, 0xBB
    j .

/* ============================================================
 * Data section (within DRAM)
 * ============================================================ */
    .balign 8
s_tick:
    .dword 0

    .balign 4
boot_msg:
    .ascii "Heliodor Linux boot test: SBI+Sv39+timer OK\n"
    .byte 0

    .balign 4
