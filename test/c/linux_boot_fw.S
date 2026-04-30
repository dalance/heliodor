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

#define CLINT_BASE      0x02000000
#define CLINT_MSIP_BASE 0x02000000
#define CLINT_MTIMECMP  0x02004000
#define CLINT_MTIME     0x0200BFF8
#define UART_BASE       0x10000000

#define KERNEL_ENTRY    0x80000000
/* DTB sits after the kernel Image (~19MB at the moment, plus headroom). */
#define DTB_ADDR        0x81400000

/* Per-hart parking scratch: 0x81FFE000 + 0x100*hartid.
 * Layout (256 bytes per hart):
 *   +0x00 : jump_addr  (S-mode entry, written by HART_START SBI)
 *   +0x08 : opaque     (a1 to pass)
 *   +0x10 : state      (0=stopped, 1=started, 2=resumed)
 */
#define HART_SCRATCH_BASE 0x81FFE000

/* SBI extension IDs */
#define SBI_LEGACY_SET_TIMER    0x00
#define SBI_LEGACY_PUTCHAR      0x01
#define SBI_EXT_BASE            0x10
#define SBI_EXT_TIME            0x54494D45
#define SBI_EXT_SRST            0x53525354
#define SBI_EXT_HSM             0x48534D    /* "HSM" */

/* ============================================================
 * Entry point
 * ============================================================ */
_start:
    /* Disable interrupts during init */
    csrw mie, zero

    /* Save hartid for later (s11 is callee-saved across our flow). */
    csrr s11, mhartid

    /* Set up M-mode trap handler (per-hart, but the same handler) */
    la t0, m_trap_handler
    csrw mtvec, t0

    /* Per-hart mscratch: top-of-DRAM minus 0x80*hartid keeps each hart's
     * trap save area independent. */
    li t0, 0x81FFF000
    slli t1, s11, 7
    sub  t0, t0, t1
    csrw mscratch, t0

    /* Allow S-mode to read counters (TIME/CYCLE/INSTRET) */
    li t0, 7
    csrw mcounteren, t0

    /* Delegate misaligned load/store(4,6), illegal(2), ecall-U(8),
     * inst/load/store page fault(12,13,15) to S-mode. */
    li t0, (1 << 2) | (1 << 3) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 12) | (1 << 13) | (1 << 15)
    csrw medeleg, t0

    /* Delegate interrupts to S-mode: SSIP/STIP/SEIP (1,5,9). */
    li t0, 0x222
    csrw mideleg, t0

    /* Per-hart mtimecmp = max */
    li   t0, CLINT_MTIMECMP
    slli t1, s11, 3        /* 8 * hartid */
    add  t0, t0, t1
    li   t1, -1
    sd   t1, 0(t0)

    /* Enable machine timer interrupt (kernel re-enables MTIE via SBI set_timer) */
    li t0, 0x80
    csrw mie, t0

    /* mstatus: MPP=01 (S-mode), MPIE=1, SIE=1 */
    li t0, (1 << 11) | (1 << 7) | (1 << 5) | (1 << 1)
    csrw mstatus, t0

    /* Initial stvec to debug handler (kernel installs its own later) */
    la t0, s_debug_trap
    csrw stvec, t0

    /* hart 0 only: clear hart_lottery so the kernel's amoadd-based boot
     * CPU pick lands deterministically on hart 0. Secondaries don't touch
     * it — when they amoadd they'll get a non-zero return and fall into
     * .Lsecondary_start (the spinwait protocol). */
    bnez s11, _skip_lottery
    li   t0, 0x812e6668      /* hart_lottery PA (from kernel nm) */
    sd   zero, 0(t0)
_skip_lottery:

    /* All harts mret into kernel _start_kernel. Hart 0 wins the lottery
     * and runs primary boot; hart 1+ end up in the kernel's spinwait
     * polling __cpu_up_stack_pointer until the primary releases them. */
    li   t0, KERNEL_ENTRY
    csrw mepc, t0

    mv   a0, s11             /* a0 = hartid */
    li   a1, DTB_ADDR        /* a1 = DTB physical address */

    mret

/* ============================================================
 * M-mode trap handler
 * ============================================================ */
    .balign 4
m_trap_handler:
    /* Save t0-t2 to mscratch area (use mscratch as temp stack) */
    csrrw sp, mscratch, sp    /* swap sp and mscratch */
    sd t0, 0(sp)
    sd t1, 8(sp)
    sd t2, 16(sp)

    csrr t0, mcause

    /* Interrupt? (MSB set) */
    bltz t0, m_handle_irq

    /* Synchronous exception: ECALL from S-mode (cause 9) */
    li t1, 9
    beq t0, t1, m_handle_ecall

    /* Unexpected exception: save debug info and halt */
    csrr x9, mepc       /* x9 = faulting PC */
    csrr x11, mcause    /* x11 = exception cause */
    csrr x12, mtval     /* x12 = faulting instruction encoding */
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
    /* Restore t0-t2 and sp */
    ld t0, 0(sp)
    ld t1, 8(sp)
    ld t2, 16(sp)
    csrrw sp, mscratch, sp    /* restore sp */
    mret

/* ---- ECALL handling (SBI) ---- */
m_handle_ecall:
    /* Restore sp (swapped with mscratch at trap entry) */
    csrrw sp, mscratch, sp
    /* Save caller's a0 in t3 (needed for probe_extension) */
    mv t3, a0

    /* Dispatch by extension ID (a7) */
    /* Legacy extensions */
    li t0, SBI_LEGACY_SET_TIMER
    beq a7, t0, sbi_legacy_set_timer
    li t0, SBI_LEGACY_PUTCHAR
    beq a7, t0, sbi_legacy_putchar
    /* Legacy shutdown (EID 0x08) — reuse SRST halt */
    li t0, 8
    beq a7, t0, sbi_srst
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
    /* HSM extension (0x48534D) */
    li t0, SBI_EXT_HSM
    beq a7, t0, sbi_hsm

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
    li t0, SBI_EXT_HSM
    beq t3, t0, 1f                  /* HSM */
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

/* ---- SBI: Hart State Management extension (EID 0x48534D) ---- */
sbi_hsm:
    /* FID 0: HART_START(a0=hartid, a1=start_addr, a2=opaque)
     * FID 1: HART_STOP
     * FID 2: HART_GET_STATUS
     */
    li t0, 0
    beq a6, t0, sbi_hsm_hart_start
    li t0, 1
    beq a6, t0, sbi_hsm_hart_stop
    li t0, 2
    beq a6, t0, sbi_hsm_hart_get_status
    /* Other FIDs not implemented */
    li a0, -2   /* SBI_ERR_NOT_SUPPORTED */
    li a1, 0
    j sbi_return

sbi_hsm_hart_start:
    /* a0 = target hartid (passed via t3 we saved); but caller layout has
     * already mv'd t3 = a0. Original a0 is in t3 (saved in m_handle_ecall).
     * a1, a2 are still live registers (caller didn't touch them yet).
     */
    /* Per-hart scratch: HART_SCRATCH_BASE + 0x100 * target_hart */
    li   t0, HART_SCRATCH_BASE
    slli t1, t3, 8           /* 0x100 * hartid */
    add  t0, t0, t1
    sd   a1, 0(t0)           /* jump_addr */
    sd   a2, 8(t0)           /* opaque */
    li   t1, 2
    sd   t1, 16(t0)          /* state = HART_START_PENDING */

    /* Send msip to target hart: CLINT_MSIP_BASE + 4*target_hart */
    li   t0, CLINT_MSIP_BASE
    slli t1, t3, 2           /* 4 * hartid */
    add  t0, t0, t1
    li   t1, 1
    sw   t1, 0(t0)           /* msip[target] = 1 */

    li a0, 0    /* SBI_SUCCESS */
    li a1, 0
    j sbi_return

sbi_hsm_hart_stop:
    /* For simplicity: clear our msip and re-enter park */
    li a0, 0
    li a1, 0
    j sbi_return

sbi_hsm_hart_get_status:
    /* Read state from per-hart scratch (HART_SCRATCH_BASE + 0x100 * t3) */
    li   t0, HART_SCRATCH_BASE
    slli t1, t3, 8
    add  t0, t0, t1
    ld   a1, 16(t0)
    li   a0, 0
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

/* ============================================================
 * Secondary hart parking loop.
 *
 * Harts ≥ 1 enter here at reset. They wait for an MSIP wake (HART_START
 * SBI from hart 0). On wake they read jump_addr/opaque from per-hart
 * scratch and mret into S-mode. SBI HSM HART_START itself is not yet
 * wired; until then secondary harts park forever, which is enough for
 * Linux to recognize them via DTB without bringing them online.
 * ============================================================ */
    .balign 4
_secondary_park:
    /* Full M-mode init for secondaries: trap vector, delegation, mtimecmp,
     * per-hart scratch, msip clear, MSIE-only enable. mstatus.MIE stays 0
     * so MSIP wakes wfi without taking a trap (we read scratch + mret to
     * S-mode below).
     */
    csrr  t0, mhartid

    /* Per-hart mscratch (0x81FFF000 - 0x80*hartid) */
    li    t1, 0x81FFF000
    slli  t2, t0, 7
    sub   t1, t1, t2
    csrw  mscratch, t1

    /* Trap vector */
    la    t1, m_trap_handler
    csrw  mtvec, t1

    /* Allow S-mode counter access */
    li    t1, 7
    csrw  mcounteren, t1

    /* Same delegation as hart 0 (medeleg + mideleg) */
    li    t1, (1 << 2) | (1 << 3) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 12) | (1 << 13) | (1 << 15)
    csrw  medeleg, t1
    li    t1, 0x222
    csrw  mideleg, t1

    /* Per-hart mtimecmp = max */
    li    t1, CLINT_MTIMECMP
    slli  t2, t0, 3        /* 8 * hartid */
    add   t1, t1, t2
    li    t2, -1
    sd    t2, 0(t1)

    /* Per-hart parking scratch.
     * SBI HSM state encoding: 0=STARTED, 1=STOPPED, 2=START_PENDING.
     * Secondaries enter park as STOPPED so the kernel calls HART_START.
     */
    li    t1, HART_SCRATCH_BASE
    slli  t2, t0, 8        /* 0x100 * hartid */
    add   t1, t1, t2
    sd    zero, 0(t1)      /* jump_addr = 0 */
    sd    zero, 8(t1)      /* opaque    = 0 */
    li    t3, 1
    sd    t3, 16(t1)       /* state = 1 (HART_STOPPED) */

    /* Clear msip[hartid] */
    li    t1, CLINT_MSIP_BASE
    slli  t2, t0, 2
    add   t1, t1, t2
    sw    zero, 0(t1)

    /* Enable MSIE only (wake signal). mstatus.MIE = 0. */
    li    t1, 0x8          /* MIE.MSIE = bit 3 */
    csrw  mie, t1

    /* Initial stvec for S-mode (until kernel sets its own) */
    la    t1, s_debug_trap
    csrw  stvec, t1

1:  wfi
    /* Wake: check per-hart scratch for a HART_START request */
    csrr  t0, mhartid
    li    t1, HART_SCRATCH_BASE
    slli  t2, t0, 8
    add   t1, t1, t2
    ld    t2, 0(t1)        /* jump_addr */
    beqz  t2, 2f           /* spurious wake */

    /* HART_START: prepare mret into S-mode kernel entry */
    ld    a1, 8(t1)        /* opaque → a1 */
    sd    zero, 16(t1)     /* state = 0 (HART_STARTED) */

    /* Clear msip[hartid] */
    li    t3, CLINT_MSIP_BASE
    slli  t4, t0, 2
    add   t3, t3, t4
    sw    zero, 0(t3)

    /* mstatus: MPP=01 (S-mode), MPIE=0 (IRQs off until kernel re-enables) */
    li    t3, (1 << 11) | (1 << 7)
    csrw  mstatus, t3

    /* mepc = jump_addr; a0 = hartid */
    csrw  mepc, t2
    csrr  a0, mhartid
    mret

2:  /* Spurious wake: clear msip and re-park */
    li    t3, CLINT_MSIP_BASE
    slli  t4, t0, 2
    add   t3, t3, t4
    sw    zero, 0(t3)
    j     1b

/* ============================================================
 * S-mode debug trap handler (initial stvec before kernel sets its own)
 * Captures scause/sepc/stval and halts for debug inspection.
 * ============================================================ */
    .balign 4
s_debug_trap:
    csrr x9, sepc       /* x9 = faulting PC */
    csrr x11, scause    /* x11 = exception cause */
    csrr x12, stval     /* x12 = trap value (faulting addr or instr) */
    li x3, 0xDD         /* signal: S-mode trap caught */
    j .
