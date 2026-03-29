/* M-mode SBI firmware for heliodor Linux boot test.
 *
 * Memory layout:
 *   0x00000000 - 0x00003FFF : Firmware ROM (this code)
 *   0x02000000              : CLINT (mtime, mtimecmp, msip)
 *   0x0C000000              : PLIC
 *   0x10000000              : UART (ns16550a)
 *   0x80000000 - 0x803FFFFF : DRAM (4 MB, kernel + DTB)
 *
 * Boot convention:
 *   a0 = hartid (0)
 *   a1 = DTB physical address (0x803E0000)
 *
 * SBI extensions supported:
 *   0x00       : Legacy set_timer
 *   0x01       : Legacy console_putchar
 *   0x10       : Base extension
 *   0x54494D45 : Timer extension (TIME)
 *   0x53525354 : System Reset extension (SRST)
 */

    .section .text.start, "ax"
    .global _start

#define CLINT_MTIMECMP  0x02004000
#define CLINT_MTIME     0x0200BFF8
#define UART_BASE       0x10000000

#define KERNEL_ENTRY    0x80000000
#define DTB_ADDR        0x803E0000

/* SBI extension IDs */
#define SBI_LEGACY_SET_TIMER    0x00
#define SBI_LEGACY_PUTCHAR      0x01
#define SBI_EXT_BASE            0x10
#define SBI_EXT_TIME            0x54494D45
#define SBI_EXT_SRST            0x53525354

/* ============================================================
 * Entry point
 * ============================================================ */
_start:
    /* Disable interrupts during init */
    csrw mie, zero

    /* Set up M-mode trap handler */
    la t0, m_trap_handler
    csrw mtvec, t0

    /* Allow S-mode to read counters (TIME/CYCLE/INSTRET) */
    li t0, 7
    csrw mcounteren, t0

    /* Delegate exceptions to S-mode:
     *   2: illegal instruction
     *   8: ecall from U-mode
     *  12: instruction page fault
     *  13: load page fault
     *  15: store page fault */
    li t0, (1 << 2) | (1 << 8) | (1 << 12) | (1 << 13) | (1 << 15)
    csrw medeleg, t0

    /* Delegate interrupts to S-mode:
     *   1: SSIP, 5: STIP, 9: SEIP */
    li t0, 0x222
    csrw mideleg, t0

    /* Enable machine timer interrupt (for SBI timer delegation) */
    li t0, 0x80    /* MIE.MTIE = bit 7 */
    csrw mie, t0

    /* Set mstatus: MPP=01 (S-mode), MPIE=1, SIE=1 */
    li t0, (1 << 11) | (1 << 7) | (1 << 5) | (1 << 1)
    csrw mstatus, t0

    /* Set kernel entry point */
    li t0, KERNEL_ENTRY
    csrw mepc, t0

    /* a0 = hartid, a1 = DTB address */
    li a0, 0
    li a1, DTB_ADDR

    /* Jump to S-mode kernel */
    mret

/* ============================================================
 * M-mode trap handler
 * ============================================================ */
    .balign 4
m_trap_handler:
    csrr t0, mcause

    /* Interrupt? (MSB set) */
    bltz t0, m_handle_irq

    /* Synchronous exception: ECALL from S-mode (cause 9) */
    li t1, 9
    beq t0, t1, m_handle_ecall

    /* Unexpected exception: halt with debug info */
    csrr x11, mcause
    csrr x12, mtval
    li x3, 0xEE
    j .

/* ---- Interrupt handling ---- */
m_handle_irq:
    /* Extract interrupt code (clear MSB) */
    slli t1, t0, 1
    srli t1, t1, 1

    /* Machine timer interrupt (code 7) */
    li t2, 7
    beq t1, t2, m_handle_timer

    /* Other interrupt: halt */
    li x3, 0xDD
    j .

m_handle_timer:
    /* Inject STIP for S-mode */
    li t0, 0x20     /* MIP.STIP = bit 5 */
    csrs mip, t0
    /* Disable MTIE to prevent re-entry */
    li t0, 0x80     /* MIE.MTIE = bit 7 */
    csrc mie, t0
    mret

/* ---- ECALL handling (SBI) ---- */
m_handle_ecall:
    /* Save caller's a0 in t3 (needed for probe_extension) */
    mv t3, a0

    /* Dispatch by extension ID (a7) */
    /* Legacy extensions */
    li t0, SBI_LEGACY_SET_TIMER
    beq a7, t0, sbi_legacy_set_timer
    li t0, SBI_LEGACY_PUTCHAR
    beq a7, t0, sbi_legacy_putchar

    /* Standard extensions */
    li t0, SBI_EXT_BASE
    beq a7, t0, sbi_base
    /* TIME extension (0x54494D45) */
    li t0, SBI_EXT_TIME
    beq a7, t0, sbi_time
    /* SRST extension (0x53525354) */
    li t0, SBI_EXT_SRST
    beq a7, t0, sbi_srst

    /* Unknown: SBI_ERR_NOT_SUPPORTED (-2) */
    li a0, -2
    li a1, 0
    j sbi_return

/* ---- SBI: Legacy set_timer (EID 0x00) ---- */
sbi_legacy_set_timer:
    li t0, CLINT_MTIMECMP
    sd a0, 0(t0)
    /* Clear STIP */
    li t0, 0x20
    csrc mip, t0
    /* Re-enable MTIE */
    li t0, 0x80
    csrs mie, t0
    li a0, 0
    j sbi_return

/* ---- SBI: Legacy console_putchar (EID 0x01) ---- */
sbi_legacy_putchar:
    li t0, UART_BASE
    sb a0, 0(t0)
    li a0, 0
    j sbi_return

/* ---- SBI: Base extension (EID 0x10) ---- */
sbi_base:
    /* FID in a6 */
    li t0, 0
    beq a6, t0, sbi_base_get_spec_version
    li t0, 1
    beq a6, t0, sbi_base_get_impl_id
    li t0, 2
    beq a6, t0, sbi_base_get_impl_version
    li t0, 3
    beq a6, t0, sbi_base_probe_extension
    li t0, 4
    beq a6, t0, sbi_base_get_mvendorid
    li t0, 5
    beq a6, t0, sbi_base_get_marchid
    li t0, 6
    beq a6, t0, sbi_base_get_mimpid
    /* Unknown FID */
    li a0, -2
    li a1, 0
    j sbi_return

sbi_base_get_spec_version:
    li a0, 0        /* SBI_SUCCESS */
    li a1, 0x02000000   /* SBI spec v2.0 */
    j sbi_return
sbi_base_get_impl_id:
    li a0, 0
    li a1, 0xFF     /* custom implementation */
    j sbi_return
sbi_base_get_impl_version:
    li a0, 0
    li a1, 0x010000 /* v1.0.0 */
    j sbi_return
sbi_base_probe_extension:
    /* t3 = caller's a0 = extension ID to probe (saved at ecall entry) */
    li a0, 0        /* SBI_SUCCESS */
    li a1, 0        /* assume not available */
    /* Check supported extensions */
    beqz t3, 1f                     /* 0x00: legacy set_timer */
    li t0, 1
    beq t3, t0, 1f                  /* 0x01: legacy putchar */
    li t0, SBI_EXT_BASE
    beq t3, t0, 1f                  /* 0x10: base */
    li t0, SBI_EXT_TIME
    beq t3, t0, 1f                  /* TIME */
    li t0, SBI_EXT_SRST
    beq t3, t0, 1f                  /* SRST */
    j sbi_return                    /* not available */
1:  li a1, 1                        /* available */
    j sbi_return

sbi_base_get_mvendorid:
    li a0, 0
    csrr a1, mvendorid
    j sbi_return
sbi_base_get_marchid:
    li a0, 0
    csrr a1, marchid
    j sbi_return
sbi_base_get_mimpid:
    li a0, 0
    csrr a1, mimpid
    j sbi_return

/* ---- SBI: Timer extension (EID 0x54494D45) ---- */
sbi_time:
    /* FID 0: set_timer(a0=stime_value) */
    li t0, CLINT_MTIMECMP
    sd a0, 0(t0)
    li t0, 0x20
    csrc mip, t0
    li t0, 0x80
    csrs mie, t0
    li a0, 0    /* SBI_SUCCESS */
    li a1, 0
    j sbi_return

/* ---- SBI: System Reset extension (EID 0x53525354) ---- */
sbi_srst:
    /* FID 0: system_reset(a0=reset_type, a1=reset_reason) */
    /* Signal success to test harness */
    li x3, 0xAA
    j .         /* halt */

/* ---- Common SBI return: advance mepc past ecall ---- */
sbi_return:
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret
