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
- **Testing**: Veryl native testbench — always run **both** JIT on and off to catch simulator bugs early:
  ```bash
  veryl test                          # JIT on (default), all tests
  veryl test --disable-jit            # JIT off, all tests
  veryl test --test test_dcache_lbu   # run specific test only (faster for debugging)
  ```
- **Regression testing**: After modifying heliodor or veryl, run the multi-step regression:
  1. `veryl test` — fast tests (~70 tests, seconds). Fix any failures before proceeding.
  2. `veryl test --ignored --test test_arch_rv64ui` — riscv-tests rv64ui (49 tests, ~minute). JIT on is sufficient.
  3. `veryl test --ignored --test test_linux_boot` — Linux boot test (~50M cycles, minutes). Only JIT on is sufficient for this test.
- **Formatting**: `veryl fmt`
- **Stale lock**: If a previous `veryl test` was killed, delete `.build/lock` before re-running: `rm -f .build/lock`
- **Veryl compiler/simulator bugs**: Do NOT work around bugs by modifying heliodor source code. Report the issue and fix it in the `veryl/` submodule.

## ISA Compliance Tests (riscv-tests)

The official `riscv-software-src/riscv-tests` ISA tests are integrated
under `test/riscv-arch-test/`. The upstream is cloned (not a git
submodule) into `upstream/`, the rv64ui suite is built as `.hex` files
under `build/rv64ui/`, and one Veryl harness per test is generated into
`tb/test_arch.veryl`.

Build and (re-)generate the harness:

```bash
# 1. Build hex files (one-time, requires riscv64-unknown-elf-gcc)
make -C test/riscv-arch-test

# 2. Regenerate tb/test_arch.veryl from the built .hex files
python3 test/riscv-arch-test/gen_tb.py
```

Run all rv64ui ISA tests:

```bash
veryl test --ignored --test test_arch_rv64ui          # all 49 tests, JIT on
```

Each test loads its hex into a 1 MB DRAM mapped at PA 0x80000000 and
boots heliodor at that address. Pass/fail is signalled via the standard
riscv-tests `tohost` mechanism (write to PA 0x80001000): `tohost == 1`
means all subtests passed; `tohost > 1` means subtest with that ID
failed. The arch tests are marked `#[ignore]` so they don't run as part
of the default `veryl test`; run them explicitly via `--ignored --test
test_arch_rv64ui` (substring filter matches all 49 tests).

## Running Tests on Verilator

The Veryl native simulator is the default, but tests can also be run on
Verilator for cross-checking simulator bugs or getting faster wall-clock
times on long tests (Linux boot: ~22s on Verilator vs ~125s on Veryl sim).

Native Veryl testbenches (those that use `$tb::clock_gen` / `$tb::reset_gen`)
cannot run directly on Verilator. Instead, SystemVerilog wrappers live in
`sim/verilator/` and instantiate the corresponding `<test>_harness` modules
(which *are* emitted to SV by `veryl build`).

Steps:

1. Generate SystemVerilog from the Veryl sources:
   ```bash
   veryl build
   ```
   This produces `heliodor.f` (file list) and all `.sv` files in `src/` and `tb/`.

2. Build the Verilator binary (re-run after any `.veryl` change):
   ```bash
   cd sim/verilator
   verilator --binary --top tb_linux_boot -f ../../heliodor.f tb_linux_boot.sv \
             --timing -Wno-fatal -O3 --Mdir build_linux -o tb_linux_boot
   ```

3. Run from the heliodor project root (the `$readmemh` paths in the harness
   are relative to the project root):
   ```bash
   cd /home/hatta/work/repos/heliodor
   sim/verilator/build_linux/tb_linux_boot
   ```

Existing Verilator testbenches:

| TB file            | Target harness                          | Purpose                 |
|--------------------|-----------------------------------------|-------------------------|
| `tb_alu.sv`        | `heliodor_test_alu_harness`             | ALU unit test           |
| `tb_fibonacci.sv`  | `heliodor_test_fibonacci_harness`       | Small pipeline integ.   |
| `tb_linux_boot.sv` | `heliodor_test_linux_boot_harness`      | Full Linux boot         |

To add a new Verilator wrapper, copy `tb_fibonacci.sv` as a template, rewire
the ports to the target harness, and use the same `verilator --binary` flags.

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
