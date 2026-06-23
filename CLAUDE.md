# Heliodor

RV64GC RISC-V processor core written in [Veryl](https://veryl-lang.org/). Boots
mainline Linux 5.15 (1/2/4-hart SMP) to SBI shutdown. See `README.md` for the
architecture overview, status, and roadmap; this file covers the development
workflow.

## Veryl Toolchain

Heliodor is written in Veryl and needs the Veryl compiler/simulator to build and
test. Veryl lives at `./veryl/` as a **local clone** of veryl-lang/veryl —
gitignored, *not* a git submodule, so heliodor stays self-contained (same policy
as the `riscv-tests` upstream under `test/riscv-arch-test/`). Two situations:

**(1) Standalone heliodor development** — heliodor is the top-level repo and
`./veryl/` is a CHILD clone you check out and build:

```bash
git clone https://github.com/veryl-lang/veryl.git veryl
cd veryl && cargo build --profile release-verylup   # fast release: no LTO, parallel codegen
```

Use that binary — `veryl/target/release-verylup/veryl` — for all development and
testing. Use the debug build (`cargo build`, `veryl/target/debug/veryl`) only
when debugging the compiler/simulator itself; `cargo build --release` is the slow
max-optimization build. You can patch the compiler in this clone and branch/PR it
upstream.

**(2) heliodor as a Veryl test fixture** — this tree is checked out INSIDE the
veryl repo (veryl is an ANCESTOR dir) to test the compiler against a real RV64GC
design. Do NOT clone veryl; the compiler under test is the surrounding repo's
build. The veryl test harness runs heliodor's scripts with `$VERYL` set to that
binary (heliodor's scripts honor `$VERYL`). The clone step in (1) does not apply.

Key commands (run the resolved `veryl` binary from the project root):

| Command       | Description                  |
|---------------|------------------------------|
| `veryl check` | Analyze (type check, lint)   |
| `veryl build` | Transpile to SystemVerilog   |
| `veryl fmt`   | Format source files          |
| `veryl test`  | Run native testbenches       |
| `veryl clean` | Remove build artifacts       |

Refer to `veryl/testcases/veryl/` for language feature examples.

## Directory Structure

```
heliodor/
├── CLAUDE.md
├── Veryl.toml              # Project configuration
├── src/
│   ├── core/               # Pipeline stages, decode, ALU, FPU, CSR, RS/ROB/RAT, SoC
│   ├── cache/              # I-Cache / D-Cache / shared L2 / memory_bus
│   ├── mmu/                # Sv39 MMU
│   ├── peripheral/         # UART, CLINT, PLIC
│   └── pkg/                # Shared packages & type definitions
├── tb/                     # Testbenches (Veryl native test)
├── test/                   # RISC-V ISA tests, hex programs, C benchmarks
│   ├── riscv-arch-test/    # riscv-tests ISA suites (upstream clone + built hex)
│   ├── act/                # ACT4 (riscv-arch-test) RVA23 compliance (see test/act/README.md)
│   └── linux/              # Linux boot image build (sources + build.sh; see test/linux/README.md)
├── toolchain/              # Pinned prebuilt cross toolchains — fetch.sh/env.sh, binaries gitignored
├── doc/                    # Documentation
└── veryl/                  # Veryl compiler — local clone, gitignored (see Veryl Toolchain)
```

## Cross Toolchains (`toolchain/`)

RISC-V cross compilers + the ACT4 Sail reference are **fetched as pinned
prebuilt binaries**, not assumed on `$PATH` (same policy as the gitignored
`veryl/` clone). Only `toolchain/{versions.env,fetch.sh,env.sh,README.md}` are
committed; the binaries are gitignored.

```bash
toolchain/fetch.sh all      # download + extract (elf gcc, linux gcc, Sail, uv)
source toolchain/env.sh     # put them on PATH (+ ACT4 env)
```

- `elf/` riscv64-unknown-elf-gcc (GCC 16) — ACT4, riscv-tests, directed/bare hex.
- `linux/` riscv64-unknown-linux-gnu-gcc (GCC 16, **binutils 2.46**) — the Linux
  build. A single recent linux-gnu toolchain has RVV `as` + `ld -shared` +
  `ld` ≥ 2.38, so the V-kernel build drops the old elf/linux mix and the
  TOOLCHAIN_HAS_V LD-version patch (only a getrandom-vDSO gate remains — a
  gcc-codegen issue, not ld; see test/linux/README.md).
- `sail/`, `uv/` — ACT4 reference model + Python env. Ruby/UDB use system Ruby.

Pins live in `toolchain/versions.env`; keep the **ubuntu-22.04** GCC builds
(glibc 2.34, run on EL9). See `toolchain/README.md`.

## Development Conventions

- **Language**: Veryl (transpiles to SystemVerilog)
- **Comments & documentation**: English
- **Testing**: Veryl native testbench. The simulator chooses a code-generation
  backend with `--backend` (default: `cc`). The old `--disable-jit` flag is gone.
  ```bash
  veryl test                          # default cc backend (emit C + compile), all tests
  veryl test --backend cranelift      # in-process Cranelift JIT
  veryl test --backend interpret      # IR tree-walking interpreter (slowest, reference)
  veryl test --backend-validate       # dual-run cc vs cranelift, panic on divergence
  veryl test --test test_dcache_lbu   # run a specific test only (faster for debugging)
  ```
  To catch simulator/codegen bugs early, cross-check a suspicious result on a
  second backend (e.g. `--backend cranelift` or `--backend interpret`): two
  independent backends agreeing is strong evidence the RTL, not the sim, is at fault.
- **Regression testing**: After modifying heliodor or veryl, run the multi-step regression:
  1. `veryl test` — fast tests **+ the arch suite** (~150 tests, seconds-to-~minute;
     the rv64ui/um/ua/mi/si arch tests in `tb/test_arch_common.veryl` and the
     rv64uf/ud FP tests in `tb/test_arch_fp.veryl` are NOT `#[ignore]` and run here,
     on the OoO core). Fix any failures before proceeding.
  2. `veryl test --ignored --test test_litmus_4hart` — P9.0 RVWMO litmus battery
     at N=4 (IRIW + 4-way barrier/bus stress; **~5.2M cycles** — was ~2.5M at P9.1;
     P9.3.B `7beb31a` retired the bus-wide AMO lock for in-cache MESI atomics, so
     the contended-atomic litmus now pays line-bounce/RFO cost — by design, not a
     regression; N=2 is ~2.1M). On this shared box that is ~10 min, and its probe
     prints only every 5M cycles, so a PASS shows one `cy=0x2710` line then the
     `litmus(N=4): … pass=1` line — "stuck at cy=0x2710" for minutes is NORMAL, not
     a hang. The N=2 battery (`test_litmus_2hart`) already runs in step 1. Any
     forbidden-outcome hit is a memory-model bug — see `test/litmus/litmus.S` for
     the tohost encoding.
  3. `veryl test --ignored --test test_soc_smp_linux_boot_2hart` — N=2 SMP Linux boot
     (~12.3M cycles, ~2 min). N=1 single-hart is `--ignored --test test_soc_linux_boot`
     (~9.1M cycles, ~40 s).
  4. `veryl test --ignored --test test_soc_smp_linux_boot_4hart` — N=4 SMP Linux boot
     (~16.6M cycles, ~10 min). Cycle counts drift with perf work — treat large
     unexplained jumps as regressions (N=4 has a ±1M timing band).
- **Microbenchmarks**: `tb/test_bench.veryl` has 5 `#[ignore]` perf tests
  (`test_dhrystone`, `test_bench_{memcpy,multiply,median}`, `test_coremark`)
  that print cycles + retired instructions (IPC = instret / cycles, frozen at
  `tohost`). NOT a regression gate — run
  individually, e.g. `veryl test --ignored --test test_dhrystone`. Current
  numbers are in README.md. CoreMark runs ITERATIONS=1 with the upstream EEMBC
  sources vendored under `test/c/coremark/` (port layer: core_portme.*,
  start.S, link.ld; tohost at PA 0x80008000 → TOHOST_IDX 8192).
- **Formatting**: `veryl fmt`. Note: bare `veryl fmt` reformats the ENTIRE repo;
  before a focused commit, format by hand in the surrounding style instead.
- **Stale lock**: If a previous `veryl test` was killed, delete `.build/lock` before re-running: `rm -f .build/lock`
- **Veryl compiler/simulator bugs**: Do NOT work around bugs by modifying heliodor
  source code. Fix them in the `veryl/` clone (branch + PR upstream; do not commit
  to veryl `master` directly).

## ISA Compliance Tests (riscv-tests)

The official `riscv-software-src/riscv-tests` ISA tests are integrated
under `test/riscv-arch-test/`. The upstream is cloned (not a git
submodule) into `upstream/`, and the suites are built as `.hex` files
under `build/<suite>/`. The Veryl `#[test]` modules are hand-maintained
inline in `tb/test_arch_common.veryl` + `tb/test_arch_fp.veryl`.

Build the hex files (one-time, requires riscv64-unknown-elf-gcc):

```bash
make -C test/riscv-arch-test
```

Run all rv64ui ISA tests:

```bash
veryl test --test test_arch_rv64ui          # substring filter, all rv64ui tests
```

Each test loads its hex into a 1 MB DRAM mapped at PA 0x80000000 and
boots heliodor at that address. Pass/fail is signalled via the standard
riscv-tests `tohost` mechanism (write to PA 0x80001000): `tohost == 1`
means all subtests passed; `tohost > 1` means subtest with that ID
failed. The OoO-core arch harness + per-test modules live inline in
`tb/test_arch_common.veryl` (rv64ui/um/ua/mi/si) and `tb/test_arch_fp.veryl`
(rv64uf/ud); they are NOT `#[ignore]`, so they run as part of the default
`veryl test`. The `--test test_arch_rv64ui` substring just narrows the run.
The hex files are built by `make -C test/riscv-arch-test` (from the cloned
`upstream/`); the test modules themselves are hand-maintained inline in
`test_arch_common.veryl` / `test_arch_fp.veryl` (the old `gen_tb.py` v1
generator was removed in the cleanup).

## Running Tests on Verilator

The Veryl native simulator is the primary flow, but the Linux boot is also
cross-checked on Verilator — standard SV NBA semantics are closer to real
hardware and have caught bugs the Veryl sim's multi-instance evaluation masked
(e.g. the SMP LR/SC read_lock livelock fixed in `heliodor_core` sc_may_clear).

Native Veryl `#[test]` modules use `$tb::clock_gen`/`reset_gen` and cannot run
on Verilator, so thin SV wrappers in `sim/verilator/` instantiate the harness
modules `veryl build` emits to `tb/*.sv`:

| Wrapper                              | Config | Harness                                  |
|--------------------------------------|--------|------------------------------------------|
| `tb_soc_linux_boot.sv`               | N=1    | `heliodor_test_soc_linux_boot_harness`   |
| `tb_soc_smp_linux_boot_2hart.sv`     | N=2    | `heliodor_test_soc_smp_linux_boot_harness` #(N_HARTS=2) |
| `tb_soc_smp_linux_boot_4hart.sv`     | N=4    | `heliodor_test_soc_smp_linux_boot_harness` #(N_HARTS=4) |
| `tb_soc_smp_linux_boot_8hart.sv`     | N=8    | `heliodor_test_soc_smp_linux_boot_harness` #(N_HARTS=8) |
| `tb_litmus_4hart.sv`                 | N=4    | `heliodor_test_litmus_harness` #(N_HARTS=4) (P9.0 RVWMO litmus) |
| `tb_soc_hvlinux.sv`                  | V=1    | `heliodor_test_soc_hvlinux_harness` (P11-H5.2b type-1 hypervisor + guest Linux; `make -C test/hv GUEST=Image GUEST_DTB=guest.dtb` first) |

Build + run (from the project root, so the harness `$readmemh` paths resolve):

```bash
veryl build                                         # emit tb/*.sv + heliodor.f
verilator --binary --top-module tb_soc_smp_linux_boot_2hart -f heliodor.f \
          sim/verilator/tb_soc_smp_linux_boot_2hart.sv --timing -Wno-fatal -O3 \
          --Mdir sim/verilator/build_n2 -o tb_soc_smp_linux_boot_2hart
sim/verilator/build_n2/tb_soc_smp_linux_boot_2hart  # prints "... PASSED ..." on x3==0xAA
```

Comment lines must not start with the word `verilator` (Verilator parses
`// verilator ...` as a pragma — `BADVLTPRAGMA`). The `build_*/` output dirs are
gitignored. Add a new wrapper by copying one of the above and rewiring the ports.

## Sandbox Restrictions

- **Do NOT use `ps`** to check for running processes. The `ps` command does not work correctly inside the sandbox and produces misleading results (e.g., empty output even when processes are running). Instead, wait for command completion via the shell's return or use the timeout mechanism.
