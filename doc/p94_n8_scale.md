# P9.4 — N=8 scale (+ L2 banking)

Phase 9 step 5 (see the Phase 9 plan): scale the SMP SoC from 4 harts to
8, and bank the shared L2. This file covers the **N=8 scale** part; L2
banking lands as a separate increment (P9.4.1) once N=8 boots, because its
only benefit is relieving the single-L2-port serialization at high hart
counts — a perf change that needs a working N=8 workload to validate.

## What was already N=8-ready

A readiness audit found almost everything generic:

- `heliodor_soc_smp`, `clint`, `mem_ctrl`, `l2cache` are all
  `for h in 0..N_HARTS` generates with `[N_HARTS]` arrays. The hart-index
  ports are `logic<3>`, which holds exactly 0..7 — **enough for N=8** (only
  N>8 needs widening to `logic<4>`).
- The boot firmware (`linux_boot_fw.S`) is per-hart: each hart branches on
  `mhartid`, parks itself, and the kernel's SBI HSM HART_START wakes it.
  Nothing is hart-count-specific, so the 4-hart firmware is reused verbatim
  (DTB_ADDR = 0x81400000).
- The kernel is already built with `CONFIG_NR_CPUS=8`, so no kernel rebuild
  is needed — only the device tree changes.

## The one RTL gap: memory_bus fairness

The bus's generic arbiter arm (`gen_arb`, taken for N=1 and N>=5) was
**lowest-id-wins** — fine for correctness, but it starves high-id harts.
That is the Phase 5/6 SMP-livelock class (hart 1's msip writes held off
603K cycles), and at N=8 a litmus sense-reversing barrier never completes
if any hart is starved. The dedicated `gen_n2`/`gen_n4` arms already do
round-robin; `gen_arb` did not.

`gen_arb` is now **round-robin on all three channels** (MMIO, DRAM read,
DRAM write), the same rotation shape as `gen_n4` generalized over N: each
channel keeps a `last granted` register and scans the N candidates in
rotated order `(last+1, last+2, …) mod N`, so the most-recently-served hart
has the lowest priority next cycle. The candidate index uses a conditional
wrap (`raw - N`) so it is correct for non-power-of-2 N too; `logic<3>` caps
it at N<=8. `gen_n2`/`gen_n4` are untouched (no regression risk on the
heavily-tested N=2/N=4 boots). The P9.3 AMO-lock removal means there is no
holder pinning to special-case.

## N=8 assets (kernel rebuilt with NR_CPUS=8)

The committed 2/4-hart kernel Images are `CONFIG_NR_CPUS=2/4` — they cap
cpu onlining at 4 even given an 8-cpu DTB (the `heliodor_kernel_2hart.config`
NR_CPUS=8 was a config file never reflected in a built Image). So the kernel
is **rebuilt** with `CONFIG_NR_CPUS=8` (committed config:
`test/c/heliodor_kernel_8hart.config`; rebuild steps in
`doc/linux_boot_hex_build.md` + below).

- **`heliodor_8hart.dts`**: the 4-hart DTS plus `cpu@4..7` nodes and their
  `interrupt-controller`s; the CLINT and PLIC `interrupts-extended` lists
  extend to all 8 harts' M/S contexts. The memory carveout is unchanged
  (top 8KB: firmware scratch `0x81FFE000 + 0x100*hartid` reaches
  `0x81FFE700` at hart 7, per-hart mscratch `0x81FFF000 - 0x80*hartid`
  reaches `0x81FFEC80` — both inside the reserved 8KB).
- **`linux_dram_real_8hart.hex`**: the NR_CPUS=8 kernel Image at offset 0 +
  an 8-cpu DTB at the DTB_ADDR offset (`0x81400000 - 0x80000000 =
  0x1400000`).
- **`linux_boot_fw_8hart.hex`**: the 4-hart firmware rebuilt only with the
  new kernel's `HART_LOTTERY_PA` (= 0x80a85300 for this build) and
  `DTB_ADDR=0x81400000`; otherwise per-hart-agnostic.

### Rebuild (NR_CPUS=8)

1. `git clone --depth 1 --branch v5.15 https://github.com/torvalds/linux.git`
2. `.config` = `test/c/heliodor_kernel_8hart.config` (the 4-hart IKCONFIG
   with `CONFIG_NR_CPUS=8`); rebuild the initramfs cpio the config points at
   (`linux_init.c` → static init that does `sys_reboot(POWER_OFF)`).
3. `make ARCH=riscv CROSS_COMPILE=<linux-gnu>- olddefconfig && make -jN Image`.
4. Read `hart_lottery` from `System.map`, rebuild the firmware with
   `-DHART_LOTTERY_PA=<addr> -DDTB_ADDR=0x81400000`.
5. Assemble `linux_dram_real_8hart.hex` = Image + 8-cpu DTB at 0x1400000.

## Status

- Default suite 153/0 — the `gen_arb` rewrite does not regress N=1/2/4.
- **litmus N=8** (`test_litmus_8hart`, `litmus_n8.hex`): the barrier needs
  all 8 harts to arrive (NH=8 baked in), so it is a direct starvation test
  of the round-robin arm. PASS, all 8 harts' retire counts climbing — the
  N=8 coherence + arbiter fairness are validated.
- **N=8 Linux boot** (`test_soc_smp_linux_boot_8hart`): PASS — boots to SBI
  shutdown (`Run /init as init process` → `reboot: Power down`, hart0 x3==0xAA
  at ~25M cycles). `#[ignore]` (long).

### The N=8 CLINT bug (fixed)

The first N=8 boot brought all 8 cpus online but then hung in post-bringup
init — every cpu idle, kernel_init blocked in `do_initcalls`. The root cause
was a one-bit width truncation in the CLINT's hart-range check:

```veryl
let msip_hart_in_range: logic = msip_hart <: N_HARTS as 3;   // BUG
```

`N_HARTS as 3` truncates `N_HARTS == 8` to `0` (8 = `0b1000`, low 3 bits =
`000`), so the check is `msip_hart <: 0` = **always false** at exactly N=8.
`is_msip`/`is_mtimecmp` were then false for every access, and the CLINT
**silently dropped every msip and mtimecmp write** — no IPIs and no timer
interrupts were ever delivered. The boot limped along only because WFI is a
NOP (idle cpus busy-poll, so HART_START woke via the scratch `jump_addr` poll
and reschedules via `need_resched`); the first thing that strictly needs an
IPI — `kthread_create`'s wakeup of kthreadd in `oom_init`, then a synchronous
`smp_call_function_single` — wedged. litmus N=8 passed throughout because it
never touches the CLINT. N=1/2/4 were unaffected because `1/2/4 as 3` don't
truncate; only `8 as 3` does.

Fix (`clint.veryl`): compare in 4 bits —
`({1'b0, msip_hart} as 4) <: (N_HARTS as 4)` — so N_HARTS up to 8 (the SoC
instantiates N in {1,2,4,8}) compares correctly. With the fix the standard
NR_CPUS=8 kernel boots with no kernel-side workarounds.

## L2 banking (P9.4.1, future)

The single L2 has one lookup-accept and one install per cycle, so at 8
harts it serializes the miss traffic. Address-interleaved banks (select by
a line-address bit) let misses to different banks proceed in parallel. This
needs mem_ctrl per-bank lookup/install ports and the SoC to route the write
channel + directory per bank — a structural change whose payoff is only
measurable against the N=8 boot, so it follows this increment.
