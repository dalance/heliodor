/* /init for the heliodor V-enabled Linux boot test (test_soc_71v_linux_boot).
 *
 * Same as linux_init.c (raw syscalls, no libc) but adds a USER-SPACE RISC-V
 * Vector self-test. The kernel was built with CONFIG_RISCV_ISA_V=y +
 * CONFIG_RISCV_ISA_V_DEFAULT_ENABLE=y, so the first vector instruction here
 * traps into the kernel, which lazily enables vector state for this process
 * and re-executes — exercising heliodor's VU under a real OS (illegal-insn
 * trap, vector context enable, save/restore across the syscalls below).
 *
 * Pass criterion: the vector results are correct -> we issue reboot(POWER_OFF)
 * and the firmware reaches SBI shutdown (x3 == 0xAA). On any mismatch we spin
 * forever so the boot never shuts down and the test times out (fail).
 */

#define SYS_write   64
#define SYS_reboot  142

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

static void writes(const char *s, unsigned long n) {
    syscall3(SYS_write, 1, (long)s, (long)n);
}

/* Volatile so the verify loop is not constant-folded away. */
static volatile unsigned int va[8] = {1, 2, 3, 4, 5, 6, 7, 8};
static volatile unsigned int vb[8] = {100, 200, 300, 400, 500, 600, 700, 800};
static volatile unsigned int vc[8];

/* Returns 1 if the vector unit produced the expected results, else 0. */
static int vec_selftest(void) {
    unsigned long vl;

    /* vl = min(8, VLMAX) for e32/m1; load va,vb; vc = va + vb (vector add). */
    __asm__ volatile(
        "vsetvli %0, %4, e32, m1\n\t"
        "vle32.v v8, (%1)\n\t"
        "vle32.v v9, (%2)\n\t"
        "vadd.vv v10, v8, v9\n\t"
        "vse32.v v10, (%3)\n\t"
        : "=&r"(vl)
        : "r"(va), "r"(vb), "r"(vc), "r"((unsigned long)8)
        : "memory", "v8", "v9", "v10");

    if (vl < 1)
        return 0;
    for (unsigned i = 0; i < vl && i < 8; i++) {
        if (vc[i] != va[i] + vb[i])
            return 0;
    }

    /* Second pass after a syscall (forces a vector context save/restore across
     * the kernel boundary): scale vc by a scalar with vmul.vx and re-check. */
    writes("", 0);
    __asm__ volatile(
        "vsetvli %0, %3, e32, m1\n\t"
        "vle32.v v8, (%1)\n\t"
        "vmul.vx v11, v8, %4\n\t"
        "vse32.v v11, (%2)\n\t"
        : "=&r"(vl)
        : "r"(vc), "r"(vc), "r"((unsigned long)8), "r"((unsigned long)3)
        : "memory", "v8", "v11");
    for (unsigned i = 0; i < vl && i < 8; i++) {
        if (vc[i] != (va[i] + vb[i]) * 3)
            return 0;
    }
    return 1;
}

static const char ok_msg[]   = "VEC OK: heliodor RVV userspace self-test passed\n";
static const char fail_msg[] = "VEC FAIL: vector self-test mismatch\n";

void _start(void) {
    if (vec_selftest()) {
        writes(ok_msg, sizeof(ok_msg) - 1);
        /* reboot(POWER_OFF) -> SBI shutdown -> test PASS (x3 == 0xAA). */
        syscall4(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
                 LINUX_REBOOT_CMD_POWER_OFF, 0);
    } else {
        writes(fail_msg, sizeof(fail_msg) - 1);
        /* Do NOT power off: the boot never shuts down -> test times out (FAIL). */
    }
    for (;;)
        ;
}
