# Heliodor

RV64GC RISC-V processor core written in [Veryl](https://veryl-lang.org/). It is a
from-scratch out-of-order design (Tomasulo with a physical register file) that
boots a mainline Linux 5.15 SMP kernel through OpenSBI to SBI shutdown.

## Status

The core is a 1-wide pure-Tomasulo, PRF-based out-of-order machine with in-order
commit. It implements **RV64IMAFDC_Zicsr_Zifencei** at all three privilege levels
(M/S/U) with Sv39 virtual memory, private L1 caches, a shared L2, and 1/2/4-hart
SMP. Stock Linux 5.15 boots on all three hart counts and reaches SBI SRST
shutdown.

IPC tuning is intentionally out of scope — the goal is a clean, correct
out-of-order microarchitecture, kept 1-wide.

## Architecture

- **Out-of-order core** (`src/core/`)
  - Pipeline: fetch → decode + rename → issue → execute → commit
  - Register renaming: RAT (speculative + architectural) + 32-entry free list
  - Physical register files: 64-entry integer (`prf_int`) + 64-entry FP (`prf_fp`)
  - 32-entry Reorder Buffer driving in-order retire; precise exceptions via
    epoch-based squash + redirect
  - Issue queues: 8-entry integer / FP / memory (`iq_int` / `iq_fp` / mem)
  - Load queue + store queue (8 + 8) for out-of-order memory access
  - Static (not-taken) branch handling — no predictor (1-wide design)
  - Function units: ALU + branch evaluator (`alu_wrap`) and FPU (`fpu_wrap`:
    FP add / multiply / divide / sqrt, single + double). Integer divide and FP
    divide/sqrt are multi-cycle and non-blocking.
- **ISA**: **RV64IMAFDC_Zicsr_Zifencei** — M (mul/div), A (LR/SC + AMO), F/D
  (single + double FP), C (compressed, expanded in fetch by `c_expander`)
- **Privilege & virtual memory**: Machine / Supervisor / User; Sv39 with a
  16-entry fully-associative TLB and a hardware 3-level page-table walk (separate
  instruction / data MMUs, `SFENCE.VMA`)
- **Caches** (`src/cache/`)
  - L1 I-cache: 4 KB, 4-way, 64 B line, tree-PLRU, blocking on miss (read-only)
  - L1 D-cache: 4 KB, 4-way, 64 B line, write-through / no-write-allocate,
    non-blocking loads via MSHR, tree-PLRU
  - Shared L2: 128 KB, 4-way, 64 B line, write-through, tree-PLRU, per-word
    valid bits; sits between `memory_bus` and the DRAM port
- **SMP** (`heliodor_soc_smp #(N_HARTS = 1 / 2 / 4)`)
  - N private cores share one `memory_bus` DRAM arbiter, the L2, and the
    CLINT / PLIC / UART
  - Coherence via write-through + same-cycle invalidate broadcast; LR/SC and
    AMO are serialized through the bus arbiter
- **Peripherals** (`src/peripheral/`): CLINT, PLIC, UART
- **Boot**: mainline Linux 5.15 SMP via the bundled OpenSBI M-mode firmware

## Verification

| Suite                                                                       | Result |
|-----------------------------------------------------------------------------|--------|
| Default `veryl test` (unit + inline arch suites, on the OoO core)           | 152 passed, 0 failed (17 ignored) |
| Linux 5.15 boot, 1-hart (`--ignored --test test_soc_linux_boot`)            | pass (~26M cycles) |
| Linux 5.15 boot, 2-hart (`--ignored --test test_soc_smp_linux_boot_2hart`)  | pass (~37M cycles) |
| Linux 5.15 boot, 4-hart (`--ignored --test test_soc_smp_linux_boot_4hart`)  | pass (~52M cycles) |

The inline arch suites are the official `riscv-tests` rv64ui / um / ua / mi / si
(integer + privileged) and rv64uf / ud (FP), hand-maintained in
`tb/test_arch_common.veryl` and `tb/test_arch_fp.veryl`; they are not `#[ignore]`,
so they run as part of the default `veryl test`. The Linux boot is additionally
cross-checked on Verilator (see `CLAUDE.md`).

## Microbenchmarks

Bare-metal programs run from the test harness to completion; the cycle count and
retired-instruction count are frozen at completion (IPC = instret / cycles, no
interrupts). IPC tuning is not a goal for the 1-wide core — these track gross
cycle / instret movement across changes.

| Benchmark  | Cycles  | Instret | IPC   |
|------------|---------|---------|-------|
| Dhrystone  | 541,401 | 273,241 | 0.505 |
| memcpy     | 246,159 | 102,051 | 0.415 |
| multiply   |  48,648 |  27,397 | 0.563 |
| median     |  14,092 |   6,875 | 0.488 |

Run individually (all `#[ignore]`):

```bash
veryl/target/release-verylup/veryl test --ignored --test test_dhrystone
veryl/target/release-verylup/veryl test --ignored --test test_bench_memcpy
veryl/target/release-verylup/veryl test --ignored --test test_bench_multiply
veryl/target/release-verylup/veryl test --ignored --test test_bench_median
```

The benchmark hex files are committed under `test/hex/`; rebuild them (requires
`riscv64-unknown-elf-gcc`) with `make -C test/c/dhrystone` and `make -C test/c/bench`.

## Directory Layout

```
src/
├── core/         OoO core: fetch/decode/rename, PRF/RAT/ROB/IQ, ALU, FPU, CSR, SoC
├── cache/        I-cache / D-cache / shared L2 / memory_bus arbiter
├── mmu/          Sv39 MMU (instruction / data) + TLB
├── peripheral/   CLINT, PLIC, UART
└── pkg/          Shared packages and type definitions
tb/               Veryl native testbenches
test/             RISC-V ISA tests and hex programs
veryl/            Veryl compiler (local clone, gitignored)
```

## Build & Test

Veryl is a local clone (gitignored, not a submodule); clone and build it first:

```bash
git clone https://github.com/veryl-lang/veryl.git veryl
cd veryl && cargo build --profile release-verylup
```

Then from the project root:

```bash
veryl/target/release-verylup/veryl test                                                  # 152 tests
veryl/target/release-verylup/veryl test --ignored --test test_soc_linux_boot             # 1-hart Linux boot
veryl/target/release-verylup/veryl test --ignored --test test_soc_smp_linux_boot_2hart   # 2-hart SMP Linux boot
veryl/target/release-verylup/veryl test --ignored --test test_soc_smp_linux_boot_4hart   # 4-hart SMP Linux boot
```

The `riscv-tests` arch hex files are committed under `test/riscv-arch-test/build/`;
rebuild them with `make -C test/riscv-arch-test` (requires `riscv64-unknown-elf-gcc`).

See `CLAUDE.md` for the development workflow (Veryl toolchain modes, regression
steps, Verilator cross-check).

## Development Phases

Development history — the **Architecture** section above describes the current
Phase 7 design:

| Phase | Scope                                    | Status       |
|-------|------------------------------------------|--------------|
| 1     | RV64I scalar pipeline + caches + privilege + MMU + Linux boot | complete |
| 2     | ALU-side OoO: Tomasulo + ROB + RAT, dual-issue, FP RS, multi-cycle FU non-blocking | complete |
| 3     | Memory OoO: Store RS, Load Queue OoO issue, store-to-load forwarding, speculative load | complete |
| 4     | Multi-hart infrastructure: heliodor_core / heliodor_soc split, dcache invalidate broadcast, LR-SC remote flush, AMO bus lock, CLINT / PLIC array, multi-hart DTS / firmware (SBI HSM) | complete |
| 5     | Multi-hart Linux SMP boot: single-port DRAM bus arbitration, AMO data-valid gating, 2-hart Linux 5.15 boot to SBI SRST shutdown | complete |
| 6     | 4-hart SMP (`gen_n4` round-robin, SBI HSM HART_START tuned for `wait_for_completion` timing) + shared 128KB 4-way L2 with tree-PLRU | complete |
| 7     | Clean-slate OoO redesign: a from-scratch 1-wide pure-Tomasulo + PRF core that replaces the earlier OoO datapath, re-validated to RV64GC + 1/2/4-hart SMP Linux boot (the **Architecture** section above) | current |
