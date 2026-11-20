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
│   ├── core/               # The core (configs W2 default, W4), shared blocks (decoder, FPU, CSR, VU), SoC
│   ├── v14/                # Old core (v14_ prefix), frozen and kept for reference; no longer used by the SoC
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
- **Regression testing**: After modifying heliodor or veryl, run the multi-step regression.
  The default core is the W2 config (2-wide); each ladder test below runs it. W4 (4-wide)
  has explicit counterparts (`test_w4_litmus_4hart`, `test_w4_smp_linux_boot_2hart`,
  `test_w4_hvlinux`, `test_w4_linux_boot`); run them too when a change can differ
  between the configs. Cycle counts are the W2 values; wall times are from this
  shared box and vary with its load.
  1. `veryl test`: fast tests **+ the arch suite** (~830 tests, tens of minutes).
     The riscv-tests arch suites run on the default core as the `test_w2_*` modules
     (`tb/test_w2_rv64*.veryl`, with W4 copies in `tb/test_w4_*`), most of them in
     golden lockstep. It also runs the CBO visibility tests (`test_*_cbo_vis_*`),
     which check the DRAM behind the AXI port after cbo.clean/flush/inval. Fix any
     failures before proceeding.
  2. `veryl test --ignored --test test_litmus_4hart`: RVWMO litmus battery at N=4
     (IRIW + 4-way barrier/bus stress; **5,022,440 cycles**). The N=2 battery
     (`test_w2_litmus_2hart`) already runs in step 1. Any forbidden-outcome hit is a
     memory-model bug; see `test/litmus/litmus.S` for the tohost encoding.
  3. `veryl test --ignored --test test_soc_smp_linux_boot_2hart` — N=2 SMP Linux boot
     (**19,382,030 cycles**, ~30 min). N=1 single-hart is `--ignored --test
     test_soc_linux_boot` (**14,633,581 cycles**, ~7 min). The N=1 boot in golden
     lockstep (retire-count mtime, trace hash checked against the old-core golden) is
     `--ignored --test test_w2_linux_boot_lockstep` (14,571,787 cycles, ~7 min); run it
     after any change that can alter the retire stream.
  4. `veryl test --ignored --test test_soc_smp_linux_boot_4hart`: N=4 SMP Linux boot
     (**24,988,093 cycles**, ~2.6 h at ~2.7k cy/s). W4 is `test_w4_smp_linux_boot_4hart` (22,634,564
     cycles, ~5 h at ~1.3k cy/s). The Verilator wrappers give identical cycle counts
     and serve as the NBA cross-check, not the gate.
  5. `veryl test --ignored --test test_soc_hvlinux`: guest Linux under the type-1
     hypervisor (**18,679,320 cycles**, ~10 min; the guest runs 2,048 CBOs, the
     5.15 boots none, 6.6 4,096 and 7.1 2,048). The only gate that runs the
     two-stage (V=1) MMU under load; the native boots never leave single-stage
     translation, so a change to the dmem MMU or the load path can pass steps 1-4
     and still deadlock here. Needs `test/hv/hv_dram.hex` (gitignored; see the
     Verilator table for its `make -C test/hv` line).
- **Microbenchmarks**: `tb/test_core_bench.veryl` has `#[ignore]` perf tests for the
  default core, `test_cbench_w2_{dhrystone,coremark,fpmm,spmv}` and the
  `test_cbench_w4_*` counterparts, that print cycles + retired instructions
  (IPC = instret / cycles, frozen at `tohost`). NOT a regression gate; run
  individually, e.g. `veryl test --ignored --test test_cbench_w2_coremark`. Current
  numbers are in README.md. CoreMark runs ITERATIONS=1 with the upstream EEMBC
  sources vendored under `test/c/coremark/` (port layer: core_portme.*,
  start.S, link.ld; tohost at PA 0x80008000 → TOHOST_IDX 8192).
  `tb/test_bench.veryl` is the old (V14) core's bench, kept but `#[ignore]` and
  no longer tracked.
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
under `build/<suite>/`. The Veryl `#[test]` modules for the default core are
`tb/test_w2_<suite>.veryl` (and `tb/test_w4_<suite>.veryl`), generated by
`test/gates/gen_core_tests.py` from the lists in `test/gates/*.list`.

Build the hex files (one-time, requires riscv64-unknown-elf-gcc):

```bash
make -C test/riscv-arch-test
```

Run all rv64ui ISA tests:

```bash
veryl test --test test_w2_rv64ui            # substring filter, all rv64ui tests
```

Each test loads its hex into a 1 MB DRAM mapped at PA 0x80000000 and
boots heliodor at that address. Pass/fail is signalled via the standard
riscv-tests `tohost` mechanism (write to PA 0x80001000): `tohost == 1`
means all subtests passed; `tohost > 1` means subtest with that ID
failed. The harness is `test_arch_common_harness` in
`tb/test_arch_common.veryl`, selected per core with its `CORE` param; most
W2 tests also run in lockstep against golden checkpoint files under
`test/golden/arch/`. The tests are NOT `#[ignore]`, so they run as part of the
default `veryl test`; `--test test_w2_rv64ui` just narrows the run. Edit the
lists and rerun the generator rather than the generated files. The old-core
arch modules still in `tb/test_arch_common.veryl` and `tb/test_arch_fp.veryl`
duplicate these and are `#[ignore]`.

## Running Tests on Verilator

The Veryl native simulator is the primary flow, but the Linux boot is also
cross-checked on Verilator — standard SV NBA semantics are closer to real
hardware and have caught bugs the Veryl sim's multi-instance evaluation masked
(e.g. the SMP LR/SC read_lock livelock fixed in `heliodor_core` sc_may_clear).

Native Veryl `#[test]` modules use `$tb::clock_gen`/`reset_gen` and cannot run
on Verilator, so thin SV wrappers in `sim/verilator/` instantiate the harness
modules `veryl build` emits to `tb/*.sv`:

All wrappers drive `heliodor_boot_soc_harness` except `tb_soc_linux_boot*.sv`,
which use `heliodor_test_soc_linux_boot_harness` (itself a thin layer over it).
The unsuffixed wrappers use the default core (W2); the `_w2`/`_w4` variants pin
`CORE`.

| Wrapper                                   | Config | Notes |
|-------------------------------------------|--------|-------|
| `tb_soc_linux_boot{,_w2,_w4}.sv`          | N=1    | 5.15 boot |
| `tb_soc_smp_linux_boot_2hart{,_w2,_w4}.sv`| N=2    | 5.15 SMP boot |
| `tb_soc_smp_linux_boot_4hart{,_w2,_w4}.sv`| N=4    | 5.15 SMP boot; ladder step 4 (`-O1 -j 2`) |
| `tb_soc_smp_linux_boot_8hart.sv`          | N=8    | not verified on the current core |
| `tb_litmus_4hart{,_w2,_w4}.sv`            | N=4    | RVWMO litmus |
| `tb_soc_hvlinux{,_w2,_w4}.sv`             | V=1    | type-1 hypervisor + guest Linux; `make -C test/hv GUEST=Image GUEST_DTB=guest.dtb` first |

Build + run (from the project root, so the harness `$readmemh` paths resolve):

```bash
veryl build                                         # emit tb/*.sv + heliodor.f
verilator --binary --top-module tb_soc_smp_linux_boot_2hart -f heliodor.f \
          sim/verilator/tb_soc_smp_linux_boot_2hart.sv --timing -Wno-fatal -O3 \
          --Mdir sim/verilator/build_n2 -o tb_soc_smp_linux_boot_2hart
sim/verilator/build_n2/tb_soc_smp_linux_boot_2hart  # prints "... PASSED ..." on x3==0xAA
```

The 4-hart tops need `-O1 -j 2` instead of `-O3` (`-O3` ICEs on them).
Comment lines must not start with the word `verilator` (Verilator parses
`// verilator ...` as a pragma — `BADVLTPRAGMA`). The `build_*/` output dirs are
gitignored. Add a new wrapper by copying one of the above and rewiring the ports.

## Sandbox Restrictions

- **Do NOT use `ps`** to check for running processes. The `ps` command does not work correctly inside the sandbox and produces misleading results (e.g., empty output even when processes are running). Instead, wait for command completion via the shell's return or use the timeout mechanism.
- **Run long simulations outside the sandbox.** The sandbox kills detached `gcc`, so the
  cc backend's compiled `.so` may never land and the run silently falls back to a path
  10-100x slower. For boots and N=4 runs use `VERYL_AOT_C_ASYNC=0 VERYL_BACKEND_DIAG=1
  veryl test ... --format json` and check that the JSON reports `fell_back: 0`.
  `--format json` holds all `$display` output until the test ends.
