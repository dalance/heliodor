# Introduction

Heliodor is an out-of-order RISC-V application-processor core written in
[Veryl](https://veryl-lang.org/). Veryl transpiles it to SystemVerilog, so the
same source runs in the Veryl simulator, in Verilator, and in any tool that reads
SystemVerilog. Heliodor boots unmodified mainline Linux on one to four harts and
runs a Linux guest under a hypervisor.

This book is for three kinds of reader:

- **Integrators** who put the core in a system: see [SoC integration](soc-integration.md)
  and [Configuration](configuration.md).
- **Users** who simulate the core or run software on it: see
  [Getting started](getting-started.md) and [Running Linux](running-linux.md).
- **Contributors** who change the RTL: see [Architecture](architecture.md) and
  [Contributing](contributing.md).

## Features

- **Two supported core configurations.** A 2-wide core (`cfg_w2`) and a 4-wide
  core (`cfg_w4`). Both are instances of one parameterized design; fetch,
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
  master port with 64-bit data and 56-bit addresses.
- **Debug.** A RISC-V Debug Module (Debug Specification 1.0) behind an APB slave
  port, with System Bus Access and Sdtrig triggers. OpenOCD and GDB connect
  through a JTAG transport that the integrator supplies.
- **Verification hooks.** Every core outputs one retire record per commit lane
  and sticky invariant-checker flags, so a testbench can compare the core against
  a reference model without touching the RTL.

## Supported ISA

*To be written once the ISA and extension set is final.*

## Limits

The design has a small number of declared limits, for example the hart count
(at most 8, a power of two) and the fetch width (at most 4 instructions).
[Configuration](configuration.md) lists the ones that matter when you choose a
configuration.

## Layout of this book

| Chapter | Content |
|---|---|
| [Getting started](getting-started.md) | Install the tools, build, run the tests |
| [Architecture](architecture.md) | Block diagram, pipeline, module and directory map |
| [Configuration](configuration.md) | The configuration packages and what each value controls |
| [SoC integration](soc-integration.md) | Ports, memory map, AXI4, interrupts, debug |
| [Running Linux](running-linux.md) | Boot images and boot runs, hypervisor guest |
| [Verification](verification.md) | Test ladder and compliance suites |
| [Performance](performance.md) | Benchmark results |
| [Contributing](contributing.md) | Workflow and conventions |
