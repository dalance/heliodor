# Heliodor

RV64GC RISC-V processor core written in [Veryl](https://veryl-lang.org/).

## Status

Phase 2 (ALU-side out-of-order execution) complete.

- **Pipeline**: Tomasulo-style out-of-order with in-order commit
  - 5 logical stages (IF → ID → EX → MEM → WB)
  - Register Alias Table (32-entry RAT)
  - Reorder Buffer (32-entry ROB) driving in-order retire
  - Integer Reservation Station (16 entries) + FP Reservation Station (16 entries)
  - Common Data Bus with 3 wake ports (EX / late-WB / slot1)
  - Dual-issue ALU (slot0 + slot1) via RS dispatch
  - Branch predictor: 256-entry local BHT + 8-entry RAS
  - Speculative execution with epoch-based squash / precise exceptions
- **Memory**:
  - I-cache / D-cache (4-way, non-blocking via MSHR)
  - Store Buffer shadow (E1-d) with partial forwarding
  - Load Queue / Store RS scaffolding (observational — Phase 3 scope)
- **Multi-cycle FUs**: integer divider, FP divider, FP sqrt — all non-blocking
- **ISA**: **RV64IMAFDC_Zicsr_Zifencei**
- **Privilege levels**: Machine / Supervisor / User
- **Virtual memory**: Sv39 with a 16-entry fully-associative TLB
- **Interrupts / peripherals**: CLINT, PLIC, UART
- Boots a mainline Linux 5.15 kernel to userspace init (via OpenSBI)

### Verification

| Suite                                         | Tests | Result |
|-----------------------------------------------|-------|--------|
| Unit / integration (`veryl test`, default)    | 216   | pass   |
| `riscv-tests` rv64ui / m / a / c / f / d      | 110   | pass (included in default regression) |
| `riscv-tests` rv64mi / rv64si (privileged)    | 24    | pass (included in default regression) |
| Linux 5.15 boot (`--ignored test_linux_boot`) | 1     | pass   |

### Microbenchmarks

All run bare-metal from the test harness. IPC = instret / cycle (no interrupts, steady-state).

| Benchmark  | Cycles  | Instret | IPC   | Dominant stall cause         |
|------------|---------|---------|-------|------------------------------|
| Dhrystone  | 407,878 | 277,716 | 0.681 | ds_operand (store-dep chain) |
| memcpy     | 148,965 | 108,896 | 0.731 | load_use + ds_op_store       |
| multiply   |  34,556 |  24,509 | 0.709 | load_use                     |
| median     |  11,549 |   7,619 | 0.660 | branch mispredict (data-dep) |

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
veryl/target/release-verylup/veryl test                                        # 216 tests (~2 min)
veryl/target/release-verylup/veryl test --ignored --test test_linux_boot       # Linux boot
veryl/target/release-verylup/veryl test --ignored --test test_dhrystone        # Dhrystone
veryl/target/release-verylup/veryl test --ignored --test test_bench_memcpy     # memcpy
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
| 3     | Memory OoO: Store RS, Load Queue OoO issue, store-to-load forwarding, speculative load | planned  |

See `CLAUDE.md` for development conventions.
