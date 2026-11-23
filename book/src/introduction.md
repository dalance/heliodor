# Introduction

Heliodor is an out-of-order RV64 RISC-V application-processor core written in
[Veryl](https://veryl-lang.org/). Veryl transpiles it to SystemVerilog, so the
same source runs in the Veryl simulator, in Verilator, and in any tool that reads
SystemVerilog. It implements every mandatory extension of the RVA23 profile
(RVA23U64 and RVA23S64), boots unmodified mainline Linux (5.15, 6.6 LTS and 7.1)
on one to four harts, and runs a Linux guest under a hypervisor.

This book is for three kinds of reader:

- **Integrators** who put the core in a system: see [SoC integration](soc-integration.md)
  and [Configuration](configuration.md).
- **Users** who simulate the core or run software on it: see
  [Getting started](getting-started.md) and [Running Linux](running-linux.md).
- **Contributors** who change the RTL: see [Architecture](architecture.md) and
  [Contributing](contributing.md).

## Features

- **Two supported core configurations.** A 2-wide core (`cfg_w2`, the default)
  and a 4-wide core (`cfg_w4`). Both are instances of one parameterized design; fetch,
  rename, issue, memory and commit width and every queue size come from a single
  configuration package. See [Configuration](configuration.md).
- **Out-of-order execution.** Register renaming over physical register files, a
  reorder buffer, per-class issue queues with speculative wakeup, a decoupled
  front end with a block-based branch predictor, and a load/store unit with a
  load queue, a store queue and a committed-store buffer.
- **Privileged architecture.** Machine, supervisor and user modes, Sv39 virtual
  memory with hardware page-table walkers, PMP, and the hypervisor extension with
  two-stage translation.
- **Vector unit.** A decoupled, in-order vector unit with a 128-bit vector
  register file.
- **Coherent multi-hart SoC.** `heliodor_soc_smp` puts 1, 2, 4 or 8 cores behind
  private L1 caches and a shared L2 with a coherence directory, together with a
  CLINT, a PLIC and a UART.
- **AXI4 memory interface.** The SoC reaches DRAM and boot ROM through one AXI4
  master port with 64-bit data and 40-bit addresses.
- **Debug.** A RISC-V Debug Module (Debug Specification 1.0) behind an APB slave
  port, with System Bus Access and Sdtrig triggers. OpenOCD and GDB connect
  through a JTAG transport that the integrator supplies.
- **Verification hooks.** Every core outputs one retire record per commit lane
  and sticky invariant-checker flags, so a testbench can compare the core against
  a reference model without touching the RTL. The repository compares every
  retire record against the spike simulator and against the Sail model.
- **Synthesizable.** The observation logic compiles out, leaving the functional
  design. A Vivado flow synthesizes the SoC and the core; see
  [Synthesis](soc-integration.md#synthesis).

## Supported ISA

The base is RV64GC (RV64IMAFDC with Zicsr and Zifencei). On top of it the core
implements the mandatory extensions of RVA23U64 and RVA23S64, and five optional
ones of RVA23.1.

| Group | Extensions |
|---|---|
| Base | RV64I, M, A, F, D, C (including compressed floating-point loads and stores), Zicsr, Zifencei |
| Bit manipulation | B (Zba, Zbb, Zbs), Zicond, Zkt (data-independent latency) |
| Atomics | Zaamo, Zalrsc, Zacas (including the 128-bit `amocas.q`), Zabha (byte and halfword AMOs), Zawrs, Za64rs |
| Floating point | Zfa, Zfhmin (binary16 conversions, loads, stores and moves) |
| Vector | V (RVV 1.0, VLEN = 128, ELEN = 64) with Zvbb (and Zvkb), Zvfhmin and Zvkt |
| Cache and memory | Zicbom, Zicboz, Zicbop, Zic64b, Ziccif, Ziccamoa, Zicclsm, Ziccrse |
| Hints and may-be-operations | Zihintpause, Zihintntl, Zimop, Zcmop, Zcb |
| Counters and state enable | Zicntr, Zihpm, Smstateen and Ssstateen |
| Privilege | Machine, supervisor and user modes; Sv39 (Svnapot, Svpbmt, Svinval, Svade, Svadu); PMP (Smpmp); Sstc; Sscofpmf; Supm, Ssnpm, Smnpm and Smmpm (pointer masking); Ssccptr, Sscounterenw, Sstvala, Sstvecd, Ssu64xl, Svbare |
| Hypervisor | H, with Sha (Shcounterenw, Shvstvala, Shtvala, Shvstvecd, Shvsatpa, Shgatpa) |
| RVA23.1 options | Svrsw60t59b, Ssqosid, Smcsrind and Sscsrind, Smcdeleg and Ssccfg, Ssdbltrp |
| Debug | Debug Specification 1.0 and the Sdtrig triggers (`mcontrol6` and `icount`) |

Instruction fetch, address translation and cache-block operations follow the
physical memory attribute table of the platform; see
[Memory map and PMA](soc-integration.md#memory-map-and-pma).

## Compliance and status

The core passes the official RISC-V riscv-tests integer, privileged, floating-point
and vector suites, and 3,745 of the 3,749 tests of the pinned ACT4 suite in the
2-wide configuration (3,744 in the 4-wide one). Every failing ACT4 test has a
known cause that is not a defect of the core's architecture; see
[Verification](verification.md). Linux 5.15 boots on one, two and four harts,
Linux 6.6 and 7.1 boot with the RVA23 device tree, and a guest Linux boots under
the bundled hypervisor. Eight harts are a declared configuration that has not been
verified on the current core.

## Limits

The design has a small number of declared limits. [Configuration](configuration.md)
lists the ones that matter when you choose a configuration. The ones that matter
to software are:

- Vector arithmetic with `vstart` not zero raises an illegal-instruction exception
  (the vector specification allows this), and misaligned vector accesses trap.
- Zvbc and the vector crypto extensions other than Zvbb, Zvkb and Zvkt are not
  implemented.
- `mcountinhibit` (and so `scountinhibit`) reads zero, and the CLINT `mtime` cannot
  be written.
- The hypervisor has no guest external interrupt files (`GEILEN` is 0). `htinst`
  and `mtinst` are zero except for a guest-page fault of an implicit access of a
  VS-stage walk.
- The physical address is 40 bits wide. An address with a bit set above it is a
  hole, not truncated.
- A supervisor or user access that matches no PMP entry faults. The PMP registers
  reset to zero, so firmware has to program an entry before it enters supervisor
  mode; see [Firmware requirements](soc-integration.md#firmware-requirements).
- At most 8 harts, a power of two, and a fetch width of at most 4 instructions.

## Layout of this book

| Chapter | Content |
|---|---|
| [Getting started](getting-started.md) | Install the tools, build, run the tests |
| [Architecture](architecture.md) | Block diagram, pipeline, module and directory map |
| [Configuration](configuration.md) | The configuration packages and what each value controls |
| [SoC integration](soc-integration.md) | Ports, memory map, AXI4, interrupts, debug |
| [Running Linux](running-linux.md) | Boot images and boot runs, hypervisor guest |
| [Verification](verification.md) | Test ladder, compliance suites, co-simulation and random testing |
| [Performance](performance.md) | Benchmark and boot results |
| [Contributing](contributing.md) | Workflow and conventions |
