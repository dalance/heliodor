/* Phase 11-H5.2b: a minimal bare-metal type-1 hypervisor (HS-mode) that boots a
 * guest under heliodor's H extension, with no userspace VMM.
 *
 * The firmware drops to S-mode (HS) at 0x80000000 (hv_start.S -> hv_main). The
 * hypervisor sets up the G-stage, enters the guest in VS-mode, and trap-and-
 * emulates the guest's SBI calls + any G-stage faults.
 *
 * Memory map (host physical / 32 MiB DRAM at 0x80000000):
 *   0x80000000..0x80020000  hypervisor text/data + boot stack (0x80010000) +
 *                           trap stack (0x80018000)
 *   0x80020000..0x80024000  G-stage root table (Sv39x4, 16 KiB)
 *   0x80024000..0x80025000  G-stage L1 table
 *   0x80400000..0x82000000  guest RAM (28 MiB) == guest-physical 0x80000000
 * The G-stage maps guest-physical 0x80000000 -> host 0x80400000 (offset +4 MiB),
 * so the guest's RAM never overlaps the hypervisor. The guest kernel loads at
 * guest-physical 0x80200000 (host 0x80600000); its DTB at guest-physical
 * 0x81000000 (host 0x81400000). */

typedef unsigned long u64;

#define UART 0x10000000UL

#define GUEST_PHYS_BASE  0x80000000UL
#define GUEST_HOST_BASE  0x80400000UL          /* guest-physical 0 maps here */
#define GPA_TO_HPA(g)    ((g) - GUEST_PHYS_BASE + GUEST_HOST_BASE)
#define GUEST_KERNEL_GPA 0x80200000UL
#define GUEST_DTB_GPA    0x81000000UL
#define G_ROOT           0x80020000UL
#define G_L1             0x80024000UL
#define GUEST_MEGAPAGES  14                     /* 14 * 2 MiB = 28 MiB guest RAM */

/* --- SBI extension / function IDs --- */
#define SBI_DBCN  0x4442434EUL
#define SBI_SRST  0x53525354UL
#define SBI_TIME  0x54494D45UL
#define SBI_HSM   0x48534DUL
#define SBI_IPI   0x735049UL
#define SBI_RFNC  0x52464E43UL
#define SBI_BASE  0x10UL

#define CSRR(csr)     ({ u64 v; __asm__ volatile("csrr %0, " csr : "=r"(v)); v; })
#define CSRW(csr, x)  __asm__ volatile("csrw " csr ", %0" :: "r"((u64)(x)))
#define CSRS(csr, x)  __asm__ volatile("csrs " csr ", %0" :: "r"((u64)(x)))

static inline void uart_putc(char c) { *(volatile char *) UART = (unsigned char) c; }
static void uart_puts(const char *s) { while (*s) uart_putc(*s++); }
static void uart_hex(u64 v) {
    uart_puts("0x");
    for (int i = 60; i >= 0; i -= 4) {
        unsigned d = (v >> i) & 0xf;
        uart_putc(d < 10 ? '0' + d : 'a' + d - 10);
    }
}

static void hv_pass(void) {
    __asm__ volatile("li gp, 0xAA");
    for (;;) {}
}
static void hv_fail(u64 code) {
    uart_puts("[HV] FAIL "); uart_hex(code); uart_putc('\n');
    __asm__ volatile("li gp, 0xBAD");
    for (;;) {}
}

void enter_guest(u64 sepc, u64 a0, u64 a1);    /* hv_start.S */

/* Handle one SBI call (ECALL-from-VS). Frame holds the guest GPRs (frame[i]=xi);
 * a0..a7 = frame[10..17]. On return a0/a1 in the frame carry SBI error/value. */
static void sbi_dispatch(u64 *frame) {
    u64 eid = frame[17], fid = frame[16];
    u64 a0 = frame[10], a1 = frame[11], a2 = frame[12];
    (void) a2;
    u64 err = 0, val = 0;

    switch (eid) {
    case SBI_DBCN:
        if (fid == 0) {                        /* console_write(num=a0, base=a1) */
            for (u64 i = 0; i < a0; i++)
                uart_putc(*(volatile char *) GPA_TO_HPA(a1 + i));
            val = a0;
        } else if (fid == 2) {                 /* console_write_byte(a0) */
            uart_putc((char) a0);
        } else if (fid == 1) {                 /* console_read: no input */
            val = 0;
        }
        break;
    case SBI_SRST:
        uart_puts("\n[HV] guest issued SBI system_reset (shutdown)\n");
        hv_pass();
        break;
    case SBI_BASE:
        if (fid == 0) val = 0x01000000;        /* get_spec_version: 1.0 */
        else if (fid == 3)                     /* probe_extension(a0) */
            val = (a0 == SBI_DBCN || a0 == SBI_SRST || a0 == SBI_TIME ||
                   a0 == SBI_HSM || a0 == SBI_IPI || a0 == SBI_RFNC ||
                   a0 == 0x00 || a0 == 0x01 || a0 == 0x08) ? 1 : 0;
        else val = 0;                          /* impl id / version / *vendorid */
        break;
    case SBI_TIME:                             /* set_timer: Sstc fallback */
        CSRW("0x24d", a0);                     /* vstimecmp */
        break;
    case SBI_HSM:
        if (fid == 2) val = 0;                 /* hart_get_status -> STARTED */
        break;                                 /* single hart: start/stop ok */
    case SBI_IPI:
        break;                                 /* single hart: nothing to do */
    case SBI_RFNC:
        __asm__ volatile("sfence.vma");        /* single hart: local fence */
        break;
    case 0x01:                                 /* legacy console_putchar(a0) */
        uart_putc((char) a0);
        break;
    case 0x00:                                 /* legacy set_timer(a0) */
        CSRW("0x24d", a0);
        break;
    case 0x08:                                 /* legacy shutdown */
        hv_pass();
        break;
    case 0x03: case 0x04: case 0x05:           /* legacy clear_ipi / send_ipi / fences */
    case 0x06: case 0x07:
        break;
    default:
        err = (u64) -2;                        /* SBI_ERR_NOT_SUPPORTED */
        break;
    }
    frame[10] = err;
    frame[11] = val;
}

void hv_trap(u64 *frame) {
    u64 scause = CSRR("scause");
    if (scause == 10) {                        /* ECALL-from-VS = SBI */
        sbi_dispatch(frame);
        CSRW("sepc", CSRR("sepc") + 4);        /* step past the ecall */
        return;
    }
    uart_puts("\n[HV] unexpected trap scause="); uart_hex(scause);
    uart_puts(" sepc="); uart_hex(CSRR("sepc"));
    uart_puts(" stval="); uart_hex(CSRR("stval"));
    uart_putc('\n');
    hv_fail(scause);
}

void hv_main(unsigned long hartid, unsigned long dtb) {
    (void) hartid; (void) dtb;
    uart_puts("[HV] hypervisor up on heliodor H-extension\n");

    /* G-stage page table: guest-physical [0x80000000, +28 MiB) -> host
     * [0x80400000, ...) via 2 MiB megapages. */
    volatile u64 *l1 = (volatile u64 *) G_L1;
    for (int i = 0; i < GUEST_MEGAPAGES; i++) {
        u64 ppn = (GUEST_HOST_BASE + (u64) i * 0x200000) >> 12;
        l1[i] = (ppn << 10) | 0xDF;            /* V|R|W|X|U|A|D megapage */
    }
    volatile u64 *root = (volatile u64 *) G_ROOT;
    for (int i = 0; i < 2048; i++) root[i] = 0;
    root[2] = ((G_L1 >> 12) << 10) | 0x01;     /* non-leaf -> L1 (GPA bits[31:30]=10) */

    CSRW("0x680", 0x8000000000080020UL);       /* hgatp = Sv39x4, PPN=0x80020 */
    CSRW("0x24d", 0xFFFFFFFFFFFFFFFFUL);        /* vstimecmp = max (timer disarmed) */
    CSRW("0x60a", (1UL << 63));                 /* henvcfg.STCE (Sstc-in-VS) */
    CSRW("0x602", 0xB1FFUL);                    /* hedeleg: guest exceptions -> VS */
    CSRW("0x603", 0x444UL);                     /* hideleg: VS interrupts -> VS */
    CSRS("0x600", (1UL << 8));                  /* hstatus.SPVP = 1 (VS-supervisor) */
    __asm__ volatile("sfence.vma");

    uart_puts("[HV] entering guest at "); uart_hex(GUEST_KERNEL_GPA); uart_putc('\n');
    enter_guest(GUEST_KERNEL_GPA, hartid, GUEST_DTB_GPA);
}
