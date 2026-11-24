# Heliodor

**Heliodor** is a from-scratch, out-of-order RV64 RISC-V application-processor core
written in [Veryl](https://veryl-lang.org/). It implements every mandatory
extension of the **RVA23** profile (RVA23U64 and RVA23S64): RV64GCB, the vector (V)
extension and the hypervisor (H) extension, in machine, supervisor and user modes.
It boots unmodified mainline Linux (5.15, 6.6 LTS and 7.1) on 1, 2 and 4 harts
through a small M-mode SBI firmware to an SBI shutdown, and boots a guest Linux under a
bare-metal type-1 hypervisor.

## Documentation

The documentation is **The Heliodor Book**, in English and Japanese. Build it with
`book/build.sh` (it needs `toolchain/fetch.sh book`) and open
`book/out/en/index.html` or `book/out/ja/index.html`. Its sources are in
`book/src/`.

| Chapter | Content |
|---|---|
| Introduction | Features, the supported ISA, limits |
| Getting started | Install the tools, build, run the tests, run on Verilator |
| Architecture | Pipeline, module map, directory layout |
| Configuration | The 2-wide and 4-wide configurations and what each value controls |
| SoC integration | Ports, AXI4 memory interface, memory map, interrupts, debug, firmware requirements, synthesis |
| Running Linux | Boot images, boots on the Veryl simulator and Verilator, the hypervisor guest |
| Verification | Long tests, riscv-tests, ACT4, litmus, spike co-simulation, random programs |
| Performance | Benchmark and boot cycle counts |
| Contributing | Workflow and conventions |

## Status

A parameterized, PRF-based out-of-order core in two supported configurations:
**W2** (2-wide, the default) and **W4** (4-wide). It has non-blocking write-back L1
caches kept coherent through a MESI-directory L2, an AXI4 memory port, Sv39 virtual
memory, a decoupled in-order vector unit (VLEN = 128), the two-stage MMU of the
hypervisor extension, a RISC-V Debug Module and a coherent 1, 2 or 4-hart SoC
(8 harts is a declared configuration, not yet verified). The design synthesizes
with Vivado (`synth/vivado/`).

It passes the official riscv-tests suites and 3,745 of the 3,749 tests of the
pinned ACT4 RVA23 suite (W2; W4: 3,744), and its retire stream is compared with
spike and the Sail model. The Linux boots, a guest boot, and the RVWMO litmus tests
pass.

| Benchmark | W2 | W4 |
|---|---|---|
| CoreMark (1 iteration) | 384,011 cycles, IPC 0.975 | 316,724 cycles, IPC 1.182 |
| Dhrystone | 271,031 cycles, IPC 0.977 | 207,221 cycles, IPC 1.278 |

## Quick start

Heliodor needs Veryl 0.22.1 or newer ([install](https://veryl-lang.org/install/)),
and spike for the co-simulation component that `Veryl.toml` declares:

```bash
toolchain/fetch.sh spike
veryl build
veryl test --test test_w2_rv64ui_add       # four tests, about 30 seconds
```

The book's Contributing chapter describes the development workflow and which tests
to run for a change.

## Repository layout

```
src/        the core (src/core), caches (src/cache), MMU (src/mmu), peripherals (src/peripheral),
            shared packages (src/pkg), and the frozen previous core (src/v14, not used by the SoC)
tb/         Veryl testbenches and harnesses
sim/        Verilator wrappers
cosim/      the spike co-simulation component
synth/      Vivado synthesis scripts
test/       test programs and runners: riscv-tests, ACT4, Linux images, hypervisor,
            litmus, random programs
toolchain/  pinned cross toolchains and tools (fetched, not committed)
book/       the user book
doc/        design records (in Japanese)
```

## References

- **[ReOVE]** Masayuki Kimura and Ryota Shioya, "ReOVE: Restricted Out-of-Order
  Execution for Superscalar Processors with Vector Extension," in *Proc. ACM/IEEE
  International Symposium on Low Power Electronics and Design (ISLPED '24)*,
  Newport Beach, CA, USA, 2024.
  DOI: [10.1145/3665314.3670805](https://doi.org/10.1145/3665314.3670805). The
  decoupled, in-order vector unit follows this scheme.
