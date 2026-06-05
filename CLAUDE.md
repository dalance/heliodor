# Heliodor

RISC-V processor core written in [Veryl](https://veryl-lang.org/).
The ultimate goal is a Linux-capable RV64GC core.

## Veryl Compiler

Use the Veryl compiler from the `veryl/` submodule — do **not** use a system-installed version.

```bash
cd veryl && cargo build                          # debug build
cd veryl && cargo build --profile release-verylup # fast release build (no LTO, parallel codegen)
cd veryl && cargo build --release                 # full release build (slow, max optimization)
```

- **Fast release build**: `veryl/target/release-verylup/veryl` — use for heliodor development and testing. Much faster to compile than `--release` (no LTO, 256 codegen units) while still being optimized.
- **Debug build**: `veryl/target/debug/veryl` — use only when debugging the Veryl compiler/simulator itself.
- When modifying the simulator, use debug builds first to catch compilation errors quickly, then switch to `--profile release-verylup` for verification.

Key commands:

| Command       | Description                              |
|---------------|------------------------------------------|
| `veryl check` | Analyze (type check, lint)               |
| `veryl build` | Transpile to SystemVerilog               |
| `veryl fmt`   | Format source files                      |
| `veryl test`  | Run native testbenches (uses debug binary)|
| `veryl clean` | Remove build artifacts                   |

The compiler itself may be debugged or patched as needed.
Refer to `veryl/testcases/veryl/` for language feature examples.

## Directory Structure

```
heliodor/
├── CLAUDE.md
├── Veryl.toml              # Project configuration
├── src/
│   ├── core/               # Pipeline stages, decode, ALU, etc.
│   ├── cache/              # I-Cache / D-Cache
│   ├── mmu/                # MMU (Sv39 / Sv48)
│   ├── peripheral/         # UART, CLINT, PLIC, etc.
│   └── pkg/                # Shared packages & type definitions
├── tb/                     # Testbenches (Veryl native test)
├── test/                   # RISC-V ISA test programs
├── doc/                    # Documentation
└── veryl/                  # Veryl compiler (git submodule)
```

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
  2. `veryl test --ignored --test test_soc_smp_linux_boot_2hart` — N=2 SMP Linux boot
     (~37M cycles, minutes). N=1 single-hart is `--ignored --test test_soc_linux_boot`.
  3. `veryl test --ignored --test test_soc_smp_linux_boot_4hart` — N=4 SMP Linux boot
     (~52M cycles, ~1h).
- **Formatting**: `veryl fmt`
- **Stale lock**: If a previous `veryl test` was killed, delete `.build/lock` before re-running: `rm -f .build/lock`
- **Veryl compiler/simulator bugs**: Do NOT work around bugs by modifying heliodor source code. Report the issue and fix it in the `veryl/` submodule.

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

## Development Roadmap

| Phase | Target                                                              |
|-------|---------------------------------------------------------------------|
| 1     | RV64I base integer ISA — basic pipeline                             |
| 2     | M extension (multiply / divide) and pipeline optimization           |
| 3     | Privilege specification (M/S/U modes, CSRs)                         |
| 4     | MMU (Sv39), I-Cache / D-Cache                                       |
| 5     | A extension (atomics), interrupts & exceptions (CLINT / PLIC)       |
| 6     | C extension (compressed instructions)                               |
| 7     | F/D extensions (floating-point) — full GC compliance                |
| 8     | Linux boot integration test                                         |

## Sandbox Restrictions

- **Do NOT use `ps`** to check for running processes. The `ps` command does not work correctly inside the sandbox and produces misleading results (e.g., empty output even when processes are running). Instead, wait for command completion via the shell's return or use the timeout mechanism.

## RISC-V Reference

- **ISA**: RV64GC (`RV64IMAFDCZicsr_Zifencei`)
- **Privilege levels**: Machine / Supervisor / User
- **Virtual memory**: Sv39 (minimum), Sv48 (optional)
