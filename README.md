# Heliodor

RV64GC RISC-V processor core written in [Veryl](https://veryl-lang.org/).

## Status

- In-order 5-stage scalar pipeline
- ISA: **RV64IMAFDC_Zicsr_Zifencei**
- Privilege levels: Machine / Supervisor / User
- Virtual memory: Sv39 with a 16-entry fully-associative TLB
- Caches: separate I-cache / D-cache
- Interrupts / peripherals: CLINT, PLIC, UART
- Boots a mainline Linux 5.15 kernel to userspace init (via OpenSBI)

### Verification

| Suite                                      | Tests | Result |
|--------------------------------------------|-------|--------|
| Unit / integration (`veryl test`, default) | 204   | pass   |
| `riscv-tests` rv64ui/m/a/c/f/d             | 110   | pass (included in the default regression) |
| `riscv-tests` rv64mi / rv64si (privileged) |  24   | pass (included in the default regression) |
| Linux 5.15 boot (`--ignored test_linux_boot`) |  1  | pass   |

## Directory Layout

```
src/
├── core/         Pipeline stages, decode, ALU, FPU, CSR
├── cache/        I-cache / D-cache
├── mmu/          Sv39 MMU
├── peripheral/   CLINT, PLIC, UART
└── pkg/          Shared packages and type definitions
tb/               Veryl native testbenches
test/             Hex programs and riscv-tests harnesses
veryl/            Veryl compiler (git submodule)
```

## Build & Test

The Veryl compiler ships as a submodule and must be built first:

```bash
cd veryl && cargo build --profile release-verylup
```

Then from the project root:

```bash
veryl/target/release-verylup/veryl test          # 204 tests (~2 min)
veryl/target/release-verylup/veryl test --ignored --test test_linux_boot
```

See `CLAUDE.md` for development conventions.
