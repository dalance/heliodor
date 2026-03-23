/* Sv39 MMU 4KB page test for heliodor.
 *
 * Tests 3-level page table walk (4KB pages) with both load and store
 * through the MMU.
 *
 * Flow:
 *   1. M-mode: build 3-level page table (root → L1 → L0)
 *      - VA [0x0000, 0x1000) → PA [0x0000, 0x1000)  (code, RX)
 *      - VA [0x1000, 0x4000) → PA [0x1000, 0x4000)  (data, RW)
 *      - VA [0x7000, 0x9000) → PA [0x7000, 0x9000)  (stack, RW)
 *   2. M-mode: enable Sv39, MRET → S-mode
 *   3. S-mode: store a value to data memory via VA
 *   4. S-mode: load it back and verify
 *   5. S-mode: set x3 = 0xAA (success)
 *
 * Memory layout:
 *   0x0000-0x03FF  code (256 words = 1KB)
 *   0x1000-0x1FFF  root page table (L2)
 *   0x2000-0x2FFF  L1 page table
 *   0x2800-0x2FFF  L0 page table (for VPN[1]=0)
 *   0x7C00-0x83FF  stack
 *
 * Page table structure (Sv39, 3-level):
 *   Root (L2) at 0x1000:  entry[0] → L1 at 0x2000
 *   L1 at 0x2000:         entry[0] → L0 at 0x2800
 *   L0 at 0x2800:         entry[0] → PA 0x0000 (code, RXV)
 *                          entry[1] → PA 0x1000 (data, RWAV)
 *                          entry[2] → PA 0x2000 (data, RWAV)
 *                          entry[3] → PA 0x3000 (data, RWAV)
 *   L1 at 0x2000:         entry[3] → L0_stk (reuse L0 trick: megapage)
 *
 *   Actually, simpler: use megapage for stack region.
 *   L2[0] → L1 at 0x2000 (non-leaf)
 *   L1[0] → L0 at 0x2800 (non-leaf, covers VA 0x0000-0x1FFFFF)
 *   L0[0] → PA 0x0000 (4KB, code, V+R+X+A+D)
 *   L0[1] → PA 0x1000 (4KB, data/PT, V+R+W+A+D)
 *   L0[2] → PA 0x2000 (4KB, data/PT, V+R+W+A+D)
 *   L0[3] → PA 0x3000 (4KB, data, V+R+W+A+D)
 *
 *   For stack at VA 0x7000-0x8FFF:
 *   L0[7]  → PA 0x7000 (V+R+W+A+D)
 *   L0[8]  → PA 0x8000 (V+R+W+A+D)
 *
 * PTE format (Sv39):
 *   [63:54] reserved  [53:10] PPN  [9:8] RSW
 *   [7] D  [6] A  [5] G  [4] U  [3] X  [2] W  [1] R  [0] V
 */

    .section .text.start, "ax"
    .global _start

_start:
    /* Set up stack pointer (physical, M-mode) */
    lui sp, 0x8               /* sp = 0x8000 */

    /* ============================================ */
    /* Build 3-level Sv39 page table                */
    /* ============================================ */

    /* Zero out page table area 0x1000-0x2FFF (2 pages) */
    li t0, 0x1000
    li t1, 0x3000
1:  sd zero, 0(t0)
    addi t0, t0, 8
    blt t0, t1, 1b

    /* --- Root page table (L2) at 0x1000 --- */
    /* L2[0]: non-leaf, points to L1 at PA 0x2000 */
    /* PTE = (PPN=0x2000>>12=2) << 10 | V = 0x801 */
    li t0, 0x1000
    li t1, ((2 << 10) | 0x01)     /* PPN=2, V=1, no RWX (non-leaf) */
    sd t1, 0(t0)

    /* --- L1 page table at 0x2000 --- */
    /* L1[0]: non-leaf, points to L0 at PA 0x2800 */
    /* PTE = (PPN=0x2800>>12=0xA) << 10 | V */
    /* Actually 0x2800 is not page-aligned! L0 must be at page boundary. */
    /* Use 0x2000 + 0x1000 = 0x3000 for L0 if needed... */
    /* But data_mem only goes to 0x2FFF. Let's use offset within data_mem. */
    /* Simpler: put L0 at 0x2000 (same page as L1? No, L1 is at 0x2000). */
    /* Let's reorganize:
     *   Root L2 at 0x1000
     *   L1 at 0x1800 (within 0x1000 page, offset 0x800 = entry 256)
     *     -- Wait, that's same page. PPN must point to page start.
     *
     * Actually PPN points to the PAGE containing the next table.
     * Each table is 512 entries × 8B = 4KB = 1 page.
     * So we need 3 separate pages:
     *   L2 at 0x1000 (page 1)
     *   L1 at 0x2000 (page 2)
     *   L0 at 0x3000 (page 3) -- but data_mem goes to 0x2FFF!
     *
     * Solution: extend data_mem in testbench to cover 0x3000-0x3FFF,
     * or use a different layout. Let's make it simpler:
     * put everything in existing data_mem range by using megapage for
     * most mappings and only 4KB for the specific test page.
     *
     * Alternative simplest approach: use 2-level (megapage) for code/stack,
     * and 3-level (4KB) for just the test data page.
     *
     * Better: L2 at 0x1000, L1 at 0x2000 are both in data_mem range.
     * For L0 we need page 3 (0x3000-0x3FFF). The testbench data_mem
     * is 2048 words = 8KB covering 0x1000-0x2FFF. We need to extend it
     * or pick a different address.
     *
     * Simplest fix: extend data_mem to 3072 words (12KB, 0x1000-0x3FFF).
     * This gives us room for L0 at 0x3000.
     */

    /* Let me redo with clean layout:
     *   L2 at 0x1000 (PA page 1)
     *   L1 at 0x2000 (PA page 2)
     *   L0 at 0x3000 (PA page 3)  -- need to extend data_mem
     *   Test data at 0x3800
     */

    /* --- L1 page table at 0x2000 --- */
    /* L1[0]: non-leaf → L0 at 0x3000 */
    li t0, 0x2000
    li t1, ((3 << 10) | 0x01)     /* PPN=3, V=1 (non-leaf) */
    sd t1, 0(t0)

    /* L1[3]: megapage mapping VA 0x600000-0x7FFFFF → PA same (for stack) */
    /* Wait, stack is at 0x7C00-0x8000. VPN[1]=0 for addr < 0x200000.
     * VPN[1] = VA[29:21]. For addr 0x7C00: VPN[1]=0, VPN[0]=7.
     * So stack falls within L1[0] → L0, and we map it in L0 entries. */

    /* --- L0 page table at 0x3000 --- */
    li t2, 0x3000

    /* L0[0]: VA 0x0000-0x0FFF → PA 0x0000 (code, V+R+X+A+D) */
    /* PTE = (PPN=0) << 10 | D|A|X|R|V = 0x00CB */
    li t1, 0xCB               /* D=1,A=1,X=1,R=1,V=1 (no W for code) */
    sd t1, 0(t2)               /* L0[0] */

    /* L0[1]: VA 0x1000-0x1FFF → PA 0x1000 (L2 PT, V+R+W+A+D) */
    li t1, ((1 << 10) | 0xCF)  /* PPN=1, D=1,A=1,W=1,R=1,V=1 */
    sd t1, 8(t2)               /* L0[1] */

    /* L0[2]: VA 0x2000-0x2FFF → PA 0x2000 (L1 PT, V+R+W+A+D) */
    li t1, ((2 << 10) | 0xCF)  /* PPN=2 */
    sd t1, 16(t2)              /* L0[2] */

    /* L0[3]: VA 0x3000-0x3FFF → PA 0x3000 (L0 PT + test data, V+R+W+A+D) */
    li t1, ((3 << 10) | 0xCF)  /* PPN=3 */
    sd t1, 24(t2)              /* L0[3] */

    /* L0[7]: VA 0x7000-0x7FFF → PA 0x7000 (stack low, V+R+W+A+D) */
    li t1, ((7 << 10) | 0xCF)  /* PPN=7 */
    sd t1, 56(t2)              /* L0[7] */

    /* L0[8]: VA 0x8000-0x8FFF → PA 0x8000 (stack high, V+R+W+A+D) */
    li t1, ((8 << 10) | 0xCF)  /* PPN=8 */
    sd t1, 64(t2)              /* L0[8] */

    /* ============================================ */
    /* Configure trap delegation                    */
    /* ============================================ */
    li t0, 0xFFFF
    csrw medeleg, t0
    li t0, 0x222
    csrw mideleg, t0
    la t0, s_trap_handler
    csrw stvec, t0

    /* ============================================ */
    /* Enable Sv39 MMU                              */
    /* ============================================ */
    /* satp = Sv39(8) | PPN(0x1000>>12 = 1) */
    li t0, 1
    li t1, 8
    slli t1, t1, 60
    or t0, t0, t1
    csrw satp, t0
    sfence.vma zero, zero

    /* ============================================ */
    /* Switch to S-mode                             */
    /* ============================================ */
    li t0, (1 << 11)          /* MPP = S-mode */
    csrw mstatus, t0
    la t0, s_mode_entry
    csrw mepc, t0
    mret

    /* ============================================ */
    /* S-mode code (with Sv39 4KB page translation) */
    /* ============================================ */
s_mode_entry:
    li x3, 0xBB               /* fail marker (overwritten on success) */

    /* Test 1: Store/load doubleword to VA 0x3800 (→ PA 0x3800) */
    /* NOPs work around simulator comb evaluation ordering issue:
     * branch_taken evaluates before mmu_stall propagates in the
     * full_comb_statements DAG sort. Real RTL is correct. */
    li t0, 0x3800
    li t1, 0x12345678
    sd t1, 0(t0)
    nop; nop; nop
    ld t2, 0(t0)
    nop; nop; nop
    bne t1, t2, fail

    /* Test 2: Store/load another value */
    li t1, 0xABCD
    sd t1, 8(t0)
    nop; nop; nop
    ld t2, 8(t0)
    nop; nop; nop
    bne t1, t2, fail

    /* Test 3: Read code through MMU (VA 0x0000 → PA 0x0000) */
    li t0, 0
    ld a1, 0(t0)
    nop; nop; nop
    /* Low 32 bits should be 0x00008137 (LUI sp, 0x8) */
    slli a2, a1, 32
    srli a2, a2, 32
    li t0, 0x8137             /* expected: LUI x2, 0x8 = 0x00008137 */
    bne a2, t0, fail

    /* All tests passed */
    li x3, 0xAA
fail:
    j fail

    /* ============================================ */
    /* S-mode trap handler                          */
    /* ============================================ */
s_trap_handler:
    csrr x4, scause
    li x3, 0xBB
    j s_trap_handler
