# Heliodor

RV64GC RISC-V processor core written in [Veryl](https://veryl-lang.org/).

## Status

Phase 5 (multi-hart SMP) complete. 2-hart SMP Linux 5.15 boots through to userspace and
issues `reboot: Power down` (SBI SRST) deterministically on both Veryl native sim and
Verilator.

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
- **Multi-hart SMP** (Phase 5):
  - `param N_HARTS: u32` (1 / 2) instantiates `heliodor_soc` with N private
    cores sharing CLINT / PLIC / UART
  - Single-port DRAM bus arbitrated by `memory_bus` (round-robin + AMO lock)
  - Write-through D-cache with same-cycle invalidate broadcast for coherence
  - Per-hart `o_data_valid` gates the AMO read-side latch so that
    `amo_saved_rdata` cannot snapshot another hart's bus rdata mid-fill
  - SBI HSM HART_START via the bundled M-mode firmware
  - Boots stock Linux 5.15 SMP to userspace and reaches SBI SRST shutdown
- **ISA**: **RV64IMAFDC_Zicsr_Zifencei**
- **Privilege levels**: Machine / Supervisor / User
- **Virtual memory**: Sv39 with a 16-entry fully-associative TLB
- **Interrupts / peripherals**: CLINT, PLIC, UART
- Boots a mainline Linux 5.15 kernel to userspace init (via OpenSBI)

### Verification

| Suite                                                   | Tests | Result |
|---------------------------------------------------------|-------|--------|
| Unit / integration (`veryl test`, default)              | 217   | pass   |
| `riscv-tests` rv64ui / m / a / c / f / d                | 110   | pass (included in default regression) |
| `riscv-tests` rv64mi / rv64si (privileged)              | 24    | pass (included in default regression) |
| Linux 5.15 boot, 1-hart (`--ignored test_linux_boot`)   | 1     | pass   |
| Linux 5.15 boot, 2-hart (`--ignored test_smp_linux_boot`)| 1    | pass (Veryl sim + Verilator) |

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
├── core/         Pipeline stages, decode, ALU, FPU, CSR, RS / ROB / RAT
├── cache/        I-cache / D-cache
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
veryl/target/release-verylup/veryl test                                          # 217 tests (~2 min)
veryl/target/release-verylup/veryl test --ignored --test test_linux_boot         # 1-hart Linux boot
veryl/target/release-verylup/veryl test --ignored --test test_smp_linux_boot     # 2-hart SMP Linux boot (~5 min)
veryl/target/release-verylup/veryl test --ignored --test test_dhrystone          # Dhrystone
veryl/target/release-verylup/veryl test --ignored --test test_bench_memcpy       # memcpy
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

See `CLAUDE.md` for development conventions.
