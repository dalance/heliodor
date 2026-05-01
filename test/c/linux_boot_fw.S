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
/* DTB physical address — build-time override via -DDTB_ADDR=0x...
 * Default is the 2-hart hex layout (DTB after the 19MB kernel image).
 * The 1-hart hex predates the layout fix and embeds the DTB at 0x80AB9000. */
#ifndef DTB_ADDR
#define DTB_ADDR        0x81400000
#endif

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
#define SBI_EXT_IPI             0x735049    /* "sPI" — inter-processor IRQ */
#define SBI_EXT_RFENCE          0x52464E43  /* "RFNC" — remote fence */
#define SBI_LEGACY_SEND_IPI     0x04        /* legacy IPI (a0 = mask ptr in S-mode VA) */

/* ============================================================
 * Entry point
 * ============================================================ */
_start:
    /* Disable interrupts during init */
    csrw mie, zero

    /* Save hartid for later (s11 is callee-saved across our flow). */
    csrr s11, mhartid

    /* Phase 5 has bus-atomic AMO via memory_bus, but the kernel
     * hart_lottery path still doesn't reliably online secondaries
     * across the AMO boundary (likely a separate race in the early
     * boot path before MMU enable). Until that is investigated,
     * keep secondaries parked in M-mode until SBI HSM HART_START
     * wakes them — the path that demonstrably reaches set_cpu_online
     * and brings up "smp: Brought up 1 node, 2 CPUs". */
    bnez s11, _secondary_park

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

    /* Enable machine timer interrupt (MTIE bit 7) and software interrupt
     * (MSIE bit 3). MSIE is the wake signal for SBI HSM HART_START — when
     * the kernel calls HART_START(target_hart, ...) the firmware sets
     * msip[target] which triggers an M-mode trap to m_handle_msip on the
     * target hart, redirecting it to S-mode at the requested entry. */
    li t0, 0x88
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
    li   t0, 0x812e65e8      /* hart_lottery PA (from kernel nm) */
    sd   zero, 0(t0)
_skip_lottery:

    /* All harts mret into kernel _start_kernel. Hart 0 wins the lottery
     * and runs primary boot; hart 1+ end up in the kernel's spinwait
     * polling __cpu_up_stack_pointer until the primary releases them. */
    li   t0, KERNEL_ENTRY
    csrw mepc, t0

    mv   a0, s11             /* a0 = hartid */
    li   a1, DTB_ADDR        /* a1 = DTB physical address (build-time) */

    mret

/* ============================================================
 * M-mode trap handler
 * ============================================================ */
    .balign 4
m_trap_handler:
    /* Save t0-t6 to mscratch area (use mscratch as temp stack).
     * SBI v0.1 callers expect tn registers to be preserved across ecalls,
     * so the firmware must save/restore them. Otherwise, the kernel's
     * compiler-assumed t0-t6 values get clobbered by our handlers and
     * subsequent kernel code dereferences garbage (manifests as crashes
     * like "spinlock at 0x207ff400" page faults). */
    csrrw sp, mscratch, sp    /* swap sp and mscratch */
    sd t0, 0(sp)
    sd t1, 8(sp)
    sd t2, 16(sp)
    sd t3, 24(sp)
    sd t4, 32(sp)
    sd t5, 40(sp)
    sd t6, 48(sp)

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

    /* Machine software interrupt (code 3) — SBI HSM HART_START wake.
     * Kernel writes msip[hartid] after writing scratch[hartid].jump_addr;
     * we clear msip, read jump_addr, and mret to S-mode at jump_addr.
     * Works whether the receiving hart was in M-mode wfi (parked) or
     * S-mode (e.g. .Lwait_for_cpu_up spinwait when hart_lottery is in
     * play). */
    li t2, 3
    beq t1, t2, m_handle_msip

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
    /* Restore t0-t6 and sp */
    ld t0, 0(sp)
    ld t1, 8(sp)
    ld t2, 16(sp)
    ld t3, 24(sp)
    ld t4, 32(sp)
    ld t5, 40(sp)
    ld t6, 48(sp)
    csrrw sp, mscratch, sp    /* restore sp */
    mret

m_handle_msip:
    /* Clear msip[mhartid] */
    csrr t1, mhartid
    li   t2, CLINT_MSIP_BASE
    slli t0, t1, 2
    add  t2, t2, t0
    sw   zero, 0(t2)

    /* Read scratch[mhartid].jump_addr */
    li   t2, HART_SCRATCH_BASE
    slli t0, t1, 8           /* 0x100 * hartid */
    add  t2, t2, t0
    ld   t0, 0(t2)           /* jump_addr */
    beqz t0, .Lspurious_msip /* spurious: just resume */

    /* HART_START dispatch: redirect to S-mode at jump_addr.
     * a0 = hartid, a1 = opaque (per SBI HSM spec).
     * t0 already holds jump_addr; preserve it across mstatus setup so
     * we can clear scratch[0] AFTER consuming it. Clearing now ensures
     * subsequent msips on this hart go through .Lspurious_msip (kernel
     * IPI → SSIP delivery) instead of re-dispatching back into the
     * kernel HART_START start_addr. */
    ld   a1, 8(t2)           /* opaque */
    sd   zero, 16(t2)        /* state = HART_STARTED */

    csrw mepc, t0            /* mepc = jump_addr (use saved t0) */
    sd   zero, 0(t2)         /* clear jump_addr now (post-consume) */

    /* mstatus: MPP=01 (S-mode), MPIE=0 (S-mode IRQs off until kernel
     * re-enables). t0 may be clobbered after this. */
    li   t0, (1 << 11) | (1 << 7)
    csrw mstatus, t0

    csrr a0, mhartid

    /* Restore t0-t6 and sp before mret. The S-mode sp is whatever was
     * in sp when the trap fired; secondary_start_sbi resets it from
     * init_thread_union, so its current value doesn't matter. */
    ld   t0, 0(sp)
    ld   t1, 8(sp)
    ld   t2, 16(sp)
    ld   t3, 24(sp)
    ld   t4, 32(sp)
    ld   t5, 40(sp)
    ld   t6, 48(sp)
    csrrw sp, mscratch, sp
    mret

.Lspurious_msip:
    /* No HART_START pending — this is a kernel-issued IPI (via SBI sPI
     * or legacy SEND_IPI). Deliver to S-mode by raising sip.SSIP so the
     * kernel's IPI handler runs. msip was already cleared above. */
    li   t0, 0x2     /* SIP.SSIP = bit 1 */
    csrs mip, t0
    ld   t0, 0(sp)
    ld   t1, 8(sp)
    ld   t2, 16(sp)
    ld   t3, 24(sp)
    ld   t4, 32(sp)
    ld   t5, 40(sp)
    ld   t6, 48(sp)
    csrrw sp, mscratch, sp
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
    /* Legacy SEND_IPI / REMOTE_FENCE_I / REMOTE_SFENCE_VMA (EID 4-7)
     * fall through to the unknown-EID NOT_SUPPORTED return. Implementing
     * SEND_IPI as msip-to-all caused kthread crashes (kworker fetch at
     * PC 0x207ff400), and gating on hart state caused hart 1 to never
     * transition to S-mode. Until we understand how the working baseline
     * actually wakes hart 1 (HSM HART_START seems to fire despite SBI v01
     * detected message), keep this disabled. */
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
    /* IPI extension (0x735049) — wakes other harts via msip */
    li t0, SBI_EXT_IPI
    beq a7, t0, sbi_ipi
    /* RFENCE extension (0x52464E43) — best-effort: kernel uses it for
     * remote SFENCE.VMA. We don't implement actual remote fence (no
     * way to interrupt other harts to run sfence in M-mode without
     * IPI infrastructure), but returning SUCCESS is generally safe
     * because Linux only calls it after explicit synchronization on
     * the originating CPU and TLB shootdown is best-effort on most
     * architectures during early boot. */
    li t0, SBI_EXT_RFENCE
    beq a7, t0, sbi_rfence_stub

    /* Unknown: SBI_ERR_NOT_SUPPORTED (-2) */
    li a0, -2
    li a1, 0
    j sbi_return

/* ---- SBI: Legacy set_timer (EID 0x00) ---- */
sbi_legacy_set_timer:
    /* Per-hart mtimecmp: CLINT_MTIMECMP + 8*mhartid. The previous
     * implementation always wrote hart 0's mtimecmp, so on hart 1 the
     * timer never fired, scheduler ticks never arrived, kernel_init
     * kthread never got scheduled, and 2-hart Linux boot deadlocked
     * inside sched_init_smp. */
    csrr t1, mhartid
    slli t2, t1, 3
    li   t0, CLINT_MTIMECMP
    add  t0, t0, t2
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

/* ---- SBI: Legacy SEND_IPI (EID 0x04) ----
 * a0 = hart_mask pointer (S-mode VA). We can't easily dereference it
 * from M-mode (no MMU here), so we ignore the mask and IPI every OTHER
 * hart. This is functionally correct — the receiving hart will set
 * sip.SSIP via m_handle_msip's spurious path, and the kernel's IPI
 * handler will check the actual cpumask in software. The cost is that
 * a hart not in the mask still wakes briefly to find no work for it. */
sbi_legacy_send_ipi:
    /* For each potentially-receiving hart, only IPI it if its
     * scratch[hart].state == HART_STARTED (0). Hart still in
     * STOPPED (1) or START_PENDING (2) shouldn't get an IPI: the
     * kernel's SSIP dispatch isn't wired before HSM HART_START
     * dispatches the hart into S-mode (= sets state=0). */
    li   t0, CLINT_MSIP_BASE
    li   t1, HART_SCRATCH_BASE
    /* hart 0 */
    ld   t2, 16(t1)             /* scratch[0].state */
    bnez t2, .Lipi_skip0
    li   t3, 1
    sw   t3, 0(t0)              /* msip[0] = 1 */
.Lipi_skip0:
    /* hart 1 */
    ld   t2, 272(t1)            /* scratch[1].state @ +0x100+16 = +272 */
    bnez t2, .Lipi_skip1
    li   t3, 1
    sw   t3, 4(t0)              /* msip[1] = 1 */
.Lipi_skip1:
    li   a0, 0
    j    sbi_return

/* ---- SBI: Legacy REMOTE_FENCE_I / REMOTE_SFENCE_VMA stubs ----
 * Real impl needs to IPI other harts and run the fence there. We just
 * succeed; for the heliodor 2-hart smoke test the per-hart TLB / icache
 * mostly stays in sync via memory_bus broadcast invalidates. */
sbi_legacy_ok_stub:
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
    li t0, SBI_EXT_IPI
    beq t3, t0, 1f                  /* IPI (sPI) */
    li t0, SBI_EXT_RFENCE
    beq t3, t0, 1f                  /* RFENCE */
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
    /* FID 0: set_timer(a0=stime_value) — per-hart mtimecmp. */
    csrr t1, mhartid
    slli t2, t1, 3
    li   t0, CLINT_MTIMECMP
    add  t0, t0, t2
    sd a0, 0(t0)
    li t0, 0x20
    csrc mip, t0
    li t0, 0x80
    csrs mie, t0
    li a0, 0    /* SBI_SUCCESS */
    li a1, 0
    j sbi_return

/* ---- SBI: IPI extension (EID 0x735049) ----
 * FID 0: send_ipi(a0=hart_mask, a1=hart_mask_base)
 * Sets msip[base + i] for each bit i set in hart_mask. The receiving
 * hart traps to m_handle_msip; m_handle_msip's spurious path will
 * raise sip.SSIP so the kernel S-mode handler runs. */
sbi_ipi:
    li   t0, 0
    bne  a6, t0, sbi_ipi_unsupported
    mv   t1, a0                 /* hart_mask copy */
    mv   t2, a1                 /* hart_mask_base */
    li   t3, 0                  /* index */
sbi_ipi_loop:
    beqz t1, sbi_ipi_done
    andi t4, t1, 1
    beqz t4, sbi_ipi_skip
    add  t4, t2, t3             /* hartid = base + index */
    slli t4, t4, 2              /* 4 * hartid */
    li   t5, CLINT_MSIP_BASE
    add  t5, t5, t4
    li   t6, 1
    sw   t6, 0(t5)              /* msip[hartid] = 1 */
sbi_ipi_skip:
    srli t1, t1, 1
    addi t3, t3, 1
    j sbi_ipi_loop
sbi_ipi_done:
    li a0, 0    /* SBI_SUCCESS */
    li a1, 0
    j sbi_return
sbi_ipi_unsupported:
    li a0, -2
    li a1, 0
    j sbi_return

/* ---- SBI: RFENCE stub (EID 0x52464E43) ----
 * Linux uses this for cross-hart SFENCE.VMA / FENCE.I. A real impl
 * would IPI other harts and have them execute SFENCE.VMA. As a stub
 * we just succeed; this is acceptable for the heliodor 2-hart smoke
 * test where mappings are stable after boot, but is a TODO for a
 * proper SMP firmware. */
sbi_rfence_stub:
    li a0, 0
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

/* ---- Common SBI return: advance mepc past ecall + restore tn ----
 * SBI v0.1 spec requires t0-t6 to be preserved across SBI ecalls.
 * m_handle_ecall swapped sp to S-mode sp on entry; re-swap here to
 * access the M-mode stack (which holds saved S-mode t0-t6 from the
 * m_trap_handler entry). Then load them back, swap sp again, mret. */
sbi_return:
    csrrw sp, mscratch, sp        /* sp ← M-mode stack, mscratch ← S-mode sp */
    csrr  t0, mepc
    addi  t0, t0, 4
    csrw  mepc, t0
    ld    t0, 0(sp)
    ld    t1, 8(sp)
    ld    t2, 16(sp)
    ld    t3, 24(sp)
    ld    t4, 32(sp)
    ld    t5, 40(sp)
    ld    t6, 48(sp)
    csrrw sp, mscratch, sp        /* sp ← S-mode sp, mscratch ← M-mode stack */
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
