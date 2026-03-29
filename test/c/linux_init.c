/* Minimal /init for heliodor Linux boot test.
 * No libc dependency — raw syscalls only.
 */

/* RISC-V Linux syscall numbers */
#define SYS_write   64
#define SYS_reboot  142

/* reboot magic numbers */
#define LINUX_REBOOT_MAGIC1     0xfee1dead
#define LINUX_REBOOT_MAGIC2     672274793
#define LINUX_REBOOT_CMD_POWER_OFF 0x4321fedc

static long syscall3(long num, long a0, long a1, long a2) {
    register long _a0 __asm__("a0") = a0;
    register long _a1 __asm__("a1") = a1;
    register long _a2 __asm__("a2") = a2;
    register long _num __asm__("a7") = num;
    __asm__ volatile("ecall"
                     : "+r"(_a0)
                     : "r"(_a1), "r"(_a2), "r"(_num)
                     : "memory");
    return _a0;
}

static long syscall4(long num, long a0, long a1, long a2, long a3) {
    register long _a0 __asm__("a0") = a0;
    register long _a1 __asm__("a1") = a1;
    register long _a2 __asm__("a2") = a2;
    register long _a3 __asm__("a3") = a3;
    register long _num __asm__("a7") = num;
    __asm__ volatile("ecall"
                     : "+r"(_a0)
                     : "r"(_a1), "r"(_a2), "r"(_a3), "r"(_num)
                     : "memory");
    return _a0;
}

static const char msg[] = "Hello from Linux on heliodor!\n";

void _start(void) {
    /* write(stdout=1, msg, len) */
    syscall3(SYS_write, 1, (long)msg, sizeof(msg) - 1);

    /* reboot(POWER_OFF) */
    syscall4(SYS_reboot,
             LINUX_REBOOT_MAGIC1,
             LINUX_REBOOT_MAGIC2,
             LINUX_REBOOT_CMD_POWER_OFF,
             0);

    for (;;)
        ;
}
