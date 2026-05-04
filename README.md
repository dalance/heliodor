# Heliodor

RV64GC RISC-V processor core written in [Veryl](https://veryl-lang.org/).

## Status

Phase 6 (4-hart SMP + shared L2) complete. 4-hart SMP Linux 5.15 boots through to
userspace and issues `reboot: Power down` (SBI SRST) deterministically. The L2 cache
sits between `memory_bus` and the SoC-level DRAM port and absorbs cross-hart traffic
without any change to the per-hart L1 (icache + dcache) hierarchy.

- **Pipeline**: Tomasulo-style out-of-order with in-order commit
  - 5 logical stages (IF → ID → EX → MEM → WB)
  - Register Alias Table (32-entry RAT)
  - Reorder Buffer (32-entry ROB) driving in-order retire
  - Integer Reservation Station (16 entries) + FP Reservation Station (16 entries)
  - Common Data Bus with 3 wake ports (EX / late-WB / slot1)
  - Dual-issue ALU (slot0 + slot1) via RS dispatch
  - Branch predictor: 256-entry local BHT + 8-entry RAS
  - Speculative execution with epoch-based squash / precise exceptions
- **Memory OoO**:
  - I-cache / D-cache (4-way, non-blocking via MSHR)
  - Store Reservation Station (8 entries) — store decouple from direct path
  - Load Queue (8 entries) — OoO load issue with addr/data tracking
  - Store Buffer (8 entries) with byte-granular store-to-load forwarding
  - Speculative load past unresolved store base, with squash/replay on alias
- **Multi-cycle FUs**: integer divider, FP divider, FP sqrt — all non-blocking
- **Multi-hart SMP** (Phase 5 / 6.A):
  - `param N_HARTS: u32` (1 / 2 / 4) instantiates `heliodor_soc` with N
    private cores sharing CLINT / PLIC / UART
  - Single-port DRAM bus arbitrated by `memory_bus` — `gen_n2` 2-way
    round-robin or `gen_n4` 4-way round-robin, AMO holder gets priority lock
  - Write-through D-cache with same-cycle invalidate broadcast for coherence
  - Per-hart `o_data_valid` gates the AMO read-side latch so that
    `amo_saved_rdata` cannot snapshot another hart's bus rdata mid-fill
  - SBI HSM HART_START via the bundled M-mode firmware (with a
    post-`msip` write busy-wait so the boot CPU's `wait_for_completion`
    polling does not fire before the secondary hart reaches the kernel)
  - Boots stock Linux 5.15 SMP (2-hart and 4-hart) to userspace and reaches
    SBI SRST shutdown
- **Shared L2 cache** (Phase 6.E):
  - 128KB 4-way set-associative, 64B line (= L1 dcache line), tree-PLRU
  - Sits between `memory_bus` and the SoC-level DRAM port; absorbs DRAM
    traffic across all harts
  - Write-through, no-write-allocate (matches L1) — write hit byte-merges
    via `wstrb` and forwards to DRAM in the same cycle
  - Per-word valid bits (8 bits per line) lazily fill across the L1's
    8-cycle line-fill burst, so a tag-matching second access already hits
  - Coherence still rides on `memory_bus`'s per-write invalidate broadcast;
    L2-eviction-driven invalidates remain a future optimization
- **ISA**: **RV64IMAFDC_Zicsr_Zifencei**
- **Privilege levels**: Machine / Supervisor / User
- **Virtual memory**: Sv39 with a 16-entry fully-associative TLB
- **Interrupts / peripherals**: CLINT, PLIC, UART
- Boots a mainline Linux 5.15 kernel to userspace init (via OpenSBI)

### Verification

| Suite                                                   | Tests | Result |
|---------------------------------------------------------|-------|--------|
| Unit / integration (`veryl test`, default)              | 220   | pass   |
| `riscv-tests` rv64ui / m / a / c / f / d                | 110   | pass (included in default regression) |
| `riscv-tests` rv64mi / rv64si (privileged)              | 24    | pass (included in default regression) |
| Linux 5.15 boot, 1-hart (`--ignored test_linux_boot`)   | 1     | pass   |
| Linux 5.15 boot, 2-hart (`--ignored test_smp_linux_boot`)| 1    | pass (Veryl sim + Verilator) |
| Linux 5.15 boot, 4-hart (`--ignored test_smp_linux_boot_4hart`) | 1 | pass |

### Microbenchmarks

All run bare-metal from the test harness. IPC = instret / cycle (no interrupts, steady-state).

| Benchmark  | Cycles  | Instret | IPC   | Dominant stall cause         |
|------------|---------|---------|-------|------------------------------|
| Dhrystone  | 437,530 | 288,365 | 0.659 | ds_operand (store-dep chain) |
| memcpy     | 164,976 | 108,884 | 0.660 | load_use + ds_op_store       |
| multiply   |  34,979 |  24,504 | 0.701 | load_use                     |
| median     |  11,090 |   7,621 | 0.687 | branch mispredict (data-dep) |

Run individually with:

```bash
veryl/target/release-verylup/veryl test --ignored --test test_dhrystone
veryl/target/release-verylup/veryl test --ignored --test test_bench_memcpy
veryl/target/release-verylup/veryl test --ignored --test test_bench_multiply
veryl/target/release-verylup/veryl test --ignored --test test_bench_median
```

## Directory Layout

```
src/
├── core/         Pipeline stages, decode, ALU, FPU, CSR, RS / ROB / RAT, heliodor_soc
├── cache/        I-cache / D-cache / shared L2 / memory_bus arbiter
├── mmu/          Sv39 MMU
├── peripheral/   CLINT, PLIC, UART
└── pkg/          Shared packages and type definitions
tb/               Veryl native testbenches
test/             Hex programs, riscv-tests harnesses, C benchmarks
veryl/            Veryl compiler (git submodule)
```

## Build & Test

The Veryl compiler ships as a submodule and must be built first:

```bash
cd veryl && cargo build --profile release-verylup
```

Then from the project root:

```bash
veryl/target/release-verylup/veryl test                                              # 220 tests (~2 min)
veryl/target/release-verylup/veryl test --ignored --test test_linux_boot             # 1-hart Linux boot
veryl/target/release-verylup/veryl test --ignored --test test_smp_linux_boot         # 2-hart SMP Linux boot (~5 min)
veryl/target/release-verylup/veryl test --ignored --test test_smp_linux_boot_4hart   # 4-hart SMP Linux boot
veryl/target/release-verylup/veryl test --ignored --test test_dhrystone              # Dhrystone
veryl/target/release-verylup/veryl test --ignored --test test_bench_memcpy           # memcpy
```

Benchmark hex files are pre-built and committed under `test/hex/`. To rebuild them
(requires `riscv64-unknown-elf-gcc`):

```bash
make -C test/c/dhrystone
make -C test/c/bench
```

## Development Phases

| Phase | Scope                                    | Status       |
|-------|------------------------------------------|--------------|
| 1     | RV64I scalar pipeline + caches + privilege + MMU + Linux boot | complete |
| 2     | ALU-side OoO: Tomasulo + ROB + RAT, dual-issue, FP RS, multi-cycle FU non-blocking | complete |
| 3     | Memory OoO: Store RS, Load Queue OoO issue, store-to-load forwarding, speculative load | complete |
| 4     | Multi-hart infrastructure: heliodor_core / heliodor_soc split, dcache invalidate broadcast, LR-SC remote flush, AMO bus lock, CLINT / PLIC array, multi-hart DTS / firmware (SBI HSM) | complete |
| 5     | Multi-hart Linux SMP boot: single-port DRAM bus arbitration, AMO data-valid gating, 2-hart Linux 5.15 boot to SBI SRST shutdown | complete |
| 6     | 4-hart SMP (`gen_n4` round-robin, SBI HSM HART_START tuned for `wait_for_completion` timing) + shared 128KB 4-way L2 with tree-PLRU | complete |

See `CLAUDE.md` for development conventions.
