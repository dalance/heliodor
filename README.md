# Heliodor

RV64GC RISC-V processor core written in [Veryl](https://veryl-lang.org/). It is a
from-scratch out-of-order design (Tomasulo with a physical register file) that
boots a mainline Linux 5.15 SMP kernel through OpenSBI to SBI shutdown.

## Status

The core is a 2-wide superscalar, PRF-based out-of-order machine with in-order
(up to 2-wide) commit. It implements **RV64IMAFDC_Zicsr_Zifencei** at all three
privilege levels (M/S/U) with Sv39 virtual memory, branch prediction,
non-blocking write-back private L1 caches kept coherent through a shared L2
with an inclusive MESI directory, and 1/2/4/8-hart SMP. Stock Linux 5.15 boots on
all four hart counts (1/2/4/8) and reaches SBI SRST shutdown.

## Architecture

- **Out-of-order core** (`src/core/`)
  - Pipeline: fetch → decode + rename → issue → execute → commit, 2-wide at
    every stage (fetch bundle, dual rename, dual issue, dual retire of simple
    ops)
  - Register renaming: RAT (speculative + architectural) + free list
  - Physical register files: 64-entry integer (`prf_int`) + 64-entry FP (`prf_fp`)
  - 32-entry Reorder Buffer driving in-order retire; precise exceptions;
    execute-time early redirect with single-cycle checkpoint restore + partial
    ROB/IQ squash for branch mispredicts (commit-time redirect as backstop)
  - Branch prediction: 4096-entry BTB, 8192-entry gshare BHT (13-bit GHR),
    TAGE-lite direction predictor, 512-entry indirect-target BTB
    (path-history-indexed), return-address stack
  - Issue queues: 8-entry integer (oldest-ready, 2-issue: pipe-0 full / pipe-1
    ALU-class + bare-mode hit-only loads) + FP queue
  - Memory pipeline: single AGU/LSU on pipe-0 with memory-dependence
    speculation (load-violation detection + commit-time replay), speculative
    loads under Sv39, store-to-load forwarding from BOTH in-flight (ROB) and
    committed (store-buffer) stores
  - Committed-store buffer: stores retire without waiting for the bus; 4 x 64B
    line entries with byte-granular write-combining, drained as one line-wide
    bus transaction each
  - Function units: 2 ALU/branch lanes (`alu_wrap`) and FPU (`fpu_wrap`:
    FP add / multiply / divide / sqrt, single + double). Integer divide and FP
    divide/sqrt are multi-cycle and non-blocking.
- **ISA**: **RV64IMAFDC_Zicsr_Zifencei** — M (mul/div), A (LR/SC + AMO), F/D
  (single + double FP), C (compressed, expanded in fetch by `c_expander`)
- **Privilege & virtual memory**: Machine / Supervisor / User; Sv39 with a
  16-entry fully-associative TLB and a hardware 3-level page-table walk (separate
  instruction / data MMUs, `SFENCE.VMA`)
- **Caches** (`src/cache/`)
  - L1 I-cache: 16 KB, 4-way, 64 B line, tree-PLRU, non-blocking
    (hit-under-fill, streaming), single-cycle assembly of instructions
    straddling a line boundary; fills coherently through the L2 (recall-on-owned)
    so self-modified code is seen after a FENCE.I with no flush sweep
  - L1 D-cache: 16 KB, 4-way, 64 B line, write-back with a MESI-style inclusive
    L2 directory (per-line ownership, read-for-ownership store fills, dirty
    writeback / recall on eviction; full-line stores stay posted write-through),
    non-blocking (2 MSHRs, hit-under-miss, critical-word-first fill with early
    restart), a second hit-only read port for dual loads, and separate
    read / write bus channels
  - Shared L2: 128 KB, 4-way, 64 B line, line-granular, write-through to DRAM,
    tree-PLRU, with the inclusive coherence directory (per-hart sharer mask +
    owner bit); looked up / installed by the split-transaction read controller
  - Split-transaction DRAM reads (`mem_ctrl`): a line fill is a tagged
    per-hart transaction with modeled latency — L2 hit ≈ 4 cycles to first
    beat, L2 miss ≈ 30 (DRAM wait + 8-beat gather), one outstanding line read
    per hart progressing independently; writes stay 1-cycle posted
    write-through and contend with gathers for the DRAM port
- **SMP** (`heliodor_soc_smp #(N_HARTS = 1 / 2 / 4 / 8)`)
  - N private cores share one `memory_bus` DRAM arbiter (independent read /
    write channels), the L2, and the CLINT / PLIC / UART
  - Coherence via the L2 inclusive directory: write-back L1 D-caches with
    precise invalidate, owner recall (cache-to-cache transfer), and in-cache
    AMO / LR-SC (no bus lock). The instruction side is coherent too — I-cache
    fills and the instruction page-table walker read through the L2 with recall,
    so FENCE.I / SFENCE.VMA / satp need no D$ flush sweep. RVWMO is checked by a
    litmus harness
- **Peripherals** (`src/peripheral/`): CLINT, PLIC, UART
- **Boot**: mainline Linux 5.15 SMP via the bundled OpenSBI M-mode firmware

## Verification

| Suite                                                                       | Result |
|-----------------------------------------------------------------------------|--------|
| Default `veryl test` (unit + inline arch suites + N=2 litmus, on the OoO core) | 155 passed, 0 failed (21 ignored) |
| Linux 5.15 boot, 1-hart (`--ignored --test test_soc_linux_boot`)            | pass (~10.2M cycles) |
| Linux 5.15 boot, 2-hart (`--ignored --test test_soc_smp_linux_boot_2hart`)  | pass (~13.9M cycles) |
| Linux 5.15 boot, 4-hart (`--ignored --test test_soc_smp_linux_boot_4hart`)  | pass (~20.0M cycles) |
| Linux 5.15 boot, 8-hart (`--ignored --test test_soc_smp_linux_boot_8hart`)  | pass (~26.9M cycles) |

The inline arch suites are the official `riscv-tests` rv64ui / um / ua / mi / si
(integer + privileged) and rv64uf / ud (FP), hand-maintained in
`tb/test_arch_common.veryl` and `tb/test_arch_fp.veryl`; they are not `#[ignore]`,
so they run as part of the default `veryl test`. The Linux boot is additionally
cross-checked on Verilator (see `CLAUDE.md`).

## Microbenchmarks

Bare-metal programs run from the test harness to completion; the cycle count and
retired-instruction count are frozen at completion (IPC = instret / cycles, no
interrupts). CoreMark is the upstream EEMBC source (vendored under
`test/c/coremark/`) at ITERATIONS=1.

| Benchmark  | Cycles  | Instret | IPC   |
|------------|---------|---------|-------|
| CoreMark   | 277,275 | 374,359 | 1.350 |
| Dhrystone  | 211,500 | 273,242 | 1.292 |
| memcpy     |  80,118 | 102,052 | 1.274 |
| multiply   |  20,629 |  27,397 | 1.328 |
| median     |   6,776 |   6,875 | 1.015 |

Run individually (all `#[ignore]`):

```bash
veryl/target/release-verylup/veryl test --ignored --test test_coremark
veryl/target/release-verylup/veryl test --ignored --test test_dhrystone
veryl/target/release-verylup/veryl test --ignored --test test_bench_memcpy
veryl/target/release-verylup/veryl test --ignored --test test_bench_multiply
veryl/target/release-verylup/veryl test --ignored --test test_bench_median
```

The benchmark hex files are committed under `test/hex/`; rebuild them (requires
`riscv64-unknown-elf-gcc`) with `make -C test/c/dhrystone`, `make -C test/c/bench`
and `make -C test/c/coremark`.

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
veryl/target/release-verylup/veryl test                                                  # 155 tests
veryl/target/release-verylup/veryl test --ignored --test test_soc_linux_boot             # 1-hart Linux boot
veryl/target/release-verylup/veryl test --ignored --test test_soc_smp_linux_boot_2hart   # 2-hart SMP Linux boot
veryl/target/release-verylup/veryl test --ignored --test test_soc_smp_linux_boot_4hart   # 4-hart SMP Linux boot
veryl/target/release-verylup/veryl test --ignored --test test_soc_smp_linux_boot_8hart   # 8-hart SMP Linux boot
```

The `riscv-tests` arch hex files are committed under `test/riscv-arch-test/build/`;
rebuild them with `make -C test/riscv-arch-test` (requires `riscv64-unknown-elf-gcc`).

See `CLAUDE.md` for the development workflow (Veryl toolchain modes, regression
steps, Verilator cross-check).

## Development Phases

Development history — the **Architecture** section above describes the design
as of Phase 9:

| Phase | Scope                                    | Status       |
|-------|------------------------------------------|--------------|
| 1     | RV64I scalar pipeline + caches + privilege + MMU + Linux boot | complete |
| 2     | ALU-side OoO: Tomasulo + ROB + RAT, dual-issue, FP RS, multi-cycle FU non-blocking | complete |
| 3     | Memory OoO: Store RS, Load Queue OoO issue, store-to-load forwarding, speculative load | complete |
| 4     | Multi-hart infrastructure: heliodor_core / heliodor_soc split, dcache invalidate broadcast, LR-SC remote flush, AMO bus lock, CLINT / PLIC array, multi-hart DTS / firmware (SBI HSM) | complete |
| 5     | Multi-hart Linux SMP boot: single-port DRAM bus arbitration, AMO data-valid gating, 2-hart Linux 5.15 boot to SBI SRST shutdown | complete |
| 6     | 4-hart SMP (`gen_n4` round-robin, SBI HSM HART_START tuned for `wait_for_completion` timing) + shared 128KB 4-way L2 with tree-PLRU | complete |
| 7     | Clean-slate OoO redesign: a from-scratch 1-wide pure-Tomasulo + PRF core that replaces the earlier OoO datapath, re-validated to RV64GC + 1/2/4-hart SMP Linux boot | complete |
| 8     | Microarchitecture build-out on the Phase 7 core: 2-wide superscalar (fetch / rename / issue / commit), branch prediction (BTB + gshare + TAGE-lite + indirect BTB + RAS, execute-time early redirect), non-blocking L1s (MSHRs, hit-under-miss, critical-word-first), memory-dependence speculation + replay, committed-store buffer with line write-combining and store-to-load forwarding, split read/write bus channels — 1-hart boot 26M → 8.6M cycles, 4-hart 52M → 16M | complete |
| 9     | Multi-core memory-system build-out: RVWMO litmus harness (P9.0), split-transaction DRAM read controller + line-granular L2 (P9.1), write-back D$ + MESI inclusive directory (P9.2), cache-to-cache transfer + in-cache AMO/LR-SC (P9.3), N=8 SMP boot (P9.4), PLIC wiring + uncached MMIO + TLB ASID + selective SFENCE.VMA (P9.5), coherent instruction side — I-cache + I-PTW through L2, FENCE.I/SFENCE flush sweep retired (P9.6) | complete |
