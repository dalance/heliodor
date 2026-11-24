# Verification

Heliodor is checked in layers, from unit tests that take seconds to Linux boots
and compliance suites that take hours. This chapter lists the layers, how to run each one, and what a pass means. The
cycle counts and timings quoted here are for the 2-wide configuration unless a
column says otherwise; [Performance](performance.md) has the full set.

| Layer | What it checks | Where |
|---|---|---|
| [Default test run](#the-default-test-run) | Unit tests, directed tests, the riscv-tests suites, short litmus tests | `veryl test` |
| [Compliance suites](#compliance-suites) | The official riscv-tests and ACT4 (RVA23) suites | `test/riscv-arch-test/`, `test/act/` |
| [Memory-model tests](#memory-model-tests) | RVWMO litmus tests, on four harts and from the official suite | `test/litmus/`, `test/glt/` |
| [Linux and hypervisor boots](#linux-and-hypervisor-boots) | Mainline Linux on 1, 2 and 4 harts, a guest Linux under the hypervisor | `test/linux/`, `test/hv/` |
| [Co-simulation with spike](#co-simulation-with-spike) | Every retired instruction against the spike simulator | `cosim/spike/`, `test/gates/run_gc.py` |
| [Random programs](#random-programs) | Generated instruction streams under the same co-simulation | `test/gr/` |
| [Debug tests](#debug-tests) | The Debug Module, with OpenOCD and GDB | `test/debug/` |
| [Verilator cross-check](#verilator-cross-check) | The same boots on a second simulator | `sim/verilator/` |

## What every test checks

The testbench harnesses watch the core only through its observation ports (see
[Architecture](architecture.md#observation-ports)). A test passes when

- the program reports success: `tohost` is 1 for a bare-metal test, and `x3` is
  `0xAA` at the SBI shutdown for a Linux boot;
- every invariant-checker flag (`o_chk`, from the `chk_*` modules) is zero and the
  AXI error flags are zero;
- where the test runs in lockstep, every retire record agrees with the reference.

The checkers and the retire records exist only when `HELIODOR_CHK` and
`HELIODOR_OBS` are defined; `veryl test` defines both. Every instruction that
retires is described by one retire record: program counter, instruction, register
and memory effects, and trap information. The reference models consume that stream.

## The default test run {#the-default-test-run}

`veryl test` runs every `#[test]` module that is not `#[ignore]`. It covers:

- unit tests of the blocks: the front end, the load/store unit, the caches, the
  TLB and the page-table walker, the PMA table, the configuration constraints;
- directed assembly programs for the privileged architecture, the hypervisor, the
  vector unit, PMP, atomics, interrupts and the debug flow (a scripted Debug Module
  test that drives the APB port);
- the cache-block tests, which check the DRAM contents behind the AXI port after
  `cbo.clean`, `cbo.flush` and `cbo.inval`;
- the multi-hart coherence tests and a short two-hart litmus run;
- the riscv-tests suites, on both configurations (`test_w2_*` and `test_w4_*`).

Most 2-wide arch tests also run in lockstep against golden traces: retire
streams recorded from the previous generation of the core, which was verified
independently. A test fails at the first record that differs.

A full run is about 870 tests and takes well under an hour on a quiet machine. It
needs no cross toolchain, because the hex images are committed, but it does need
the spike component to be buildable (see [Getting started](getting-started.md)).

## Long tests {#long-tests}

These tests are marked `#[ignore]`, so `veryl test` skips them. Run each one with
`veryl test --ignored --test <name>`. The `test_soc_*` tests run the default
(2-wide) core. [Contributing](contributing.md#which-tests-to-run) says which of
them to run for which change.

| Test | Expected | Time | What it catches |
|---|---|---|---|
| `test_litmus_4hart` | pass, 5,122,506 cycles | about 40 min | Memory-model errors, under four-way barrier and bus stress. A hit on a forbidden outcome is a memory-model bug. |
| `test_soc_linux_boot` | pass, 14,695,563 cycles | about 7 min | Errors in a real operating-system boot on one hart |
| `test_w2_linux_boot_lockstep` | pass, 14,619,969 cycles | about 7 min | Any difference in the retired instructions of a whole 1-hart boot, against the golden trace |
| `test_soc_smp_linux_boot_2hart` | pass, 19,446,659 cycles | about 30 min | Errors that appear only with more than one hart |
| `test_soc_smp_linux_boot_4hart` | pass, 25,485,977 cycles | about 3 h | Livelocks and races that no smaller test shows |
| `test_soc_hvlinux` | pass, 18,792,075 cycles | about 10 min | Errors in the two-stage (hypervisor) MMU under load |

`test_soc_hvlinux` needs `test/hv/hv_dram.hex`; see [Running Linux](running-linux.md#guest-linux-under-a-hypervisor).
The 4-wide counterparts are `test_w4_litmus_4hart`, `test_w4_linux_boot`,
`test_w4_smp_linux_boot_2hart`, `test_w4_smp_linux_boot_4hart` and
`test_w4_hvlinux`.

Boot and litmus cycle counts drift with every performance change. A result is
equal to a previous one only to within the 10,000-cycle step of the test's counter;
the harness's `boot:` line has the exact value.

## Compliance suites {#compliance-suites}

### riscv-tests

The official `riscv-software-src/riscv-tests` ISA suites are built into hex images
under `test/riscv-arch-test/build/<suite>/`: `rv64ui`, `rv64um`, `rv64ua`,
`rv64uc`, `rv64uf`, `rv64ud`, the privileged `rv64mi` and `rv64si`, the B
extension suites (`rv64uzba`, `rv64uzbb`, `rv64uzbs`), the cache-block suite
(`rv64mzicbo`), and the user suite run under Sv39 with demand paging. Vector
programs have their own directed suites. The `#[test]` modules are generated by
`test/gates/gen_core_tests.py` from the lists `test/gates/*.list`: edit the lists
and rerun the generator, not the generated files.

```bash
veryl test --test test_w2_rv64ui            # all rv64ui tests on the 2-wide core
```

A test loads its hex into a 1 MiB DRAM at `0x8000_0000`, boots at that address, and
passes when `tohost` is 1; a value above 1 is the number of the failing subtest.

To rebuild the images you need the riscv-tests sources, which the repository does
not contain:

```bash
git clone https://github.com/riscv-software-src/riscv-tests.git test/riscv-arch-test/upstream
(cd test/riscv-arch-test/upstream && git submodule update --init env)
source toolchain/env.sh
make -C test/riscv-arch-test all
```

A rebuilt image differs from the committed one when your compiler version differs
from the one that built it. The lockstep tests compare against golden traces of the
committed images, so rebuild only what you intend to change.

### ACT4 (RVA23)

ACT4 is the RISC-V Architectural Compliance Test framework (`riscv/riscv-arch-test`).
Its tests are self-checking and signed by the Sail reference model, so they check
the RVA23 profile, including the vector, hypervisor, PMP, state-enable and counter
extensions, against the architecture rather than against a second implementation.
Heliodor pins the framework to an exact commit and Sail to 0.16
(`toolchain/versions.env`, `test/act/Makefile`). `test/act/README.md` has the
details of the configuration.

```bash
toolchain/fetch.sh all && source toolchain/env.sh
make -C test/act                                  # generate the images (needs Ruby 3.4+, uv, Sail)
python3 test/gates/run_act.py --core w2                   # run all suites on the 2-wide core
python3 test/gates/run_act.py --core w4 --pass-fail --suite i,zba    # a subset, pass/fail only
```

`run_act.py` writes temporary test modules,
runs them, and judges each result. A test passes when `tohost` is 1 and the
checkers are clean; where a golden trace exists, its final hash must also match.

Result on the pinned suite, 3,749 tests:

| Configuration | Passing | Tests that fail |
|---|---|---|
| 2-wide | 3,745 | one hypervisor test whose Sail 0.16 reference lacks Sscsrind, two Zkt timing tests whose two timed runs differ by one front-end cycle, and one test that writes `mtime` |
| 4-wide | 3,744 | the `mtime` test, the Sscsrind test, two tests that expect a trigger count of 2 (the 4-wide core has 4), and one interrupt-timing test |

Each of these has a known cause and none points at the architecture of the core.
Two Sdtrig tests do not fit the 4 MiB harness memory and are excluded with a note
in the list.

## Memory-model tests {#memory-model-tests}

`test/litmus/litmus.S` is a hand-written RVWMO litmus program: message passing
with fences, address dependencies and acquire/release, store buffering, coherence
(CoRR and CoWW), load buffering with a data dependency, an atomic-counter test,
an LR/SC lock test, and IRIW on four harts. Each test runs thousands of iterations
framed by a barrier, with random jitter so that the harts overlap at varying
offsets. The program writes a histogram and `tohost`: 1 means no forbidden outcome
was seen. The two-hart battery is part of `veryl test`
(`test_w2_litmus_2hart`); the four-hart one is a [long test](#long-tests).

`test/glt/run_glt.py` runs the official RISC-V litmus tests
(`litmus-tests-riscv`) against the herd7 model with `riscv.cat`. It converts the
tests that need up to four threads into programs, runs them, and fails if a final
state occurs that herd7 forbids. About 4,000 tests apply; the families that need
load-acquire and store-release instructions (Zalasr) are not run because the core
does not implement that extension.

```bash
toolchain/fetch.sh glt                                  # litmus tests + herd7 (builds OCaml; needs sockets)
python3 test/glt/run_glt.py herd                                # herd7 on every test
python3 test/glt/run_glt.py run --core w2 --harts 2             # the default set on two harts
```

## Linux and hypervisor boots {#linux-and-hypervisor-boots}

The boots are the largest tests: unmodified Linux 5.15, 6.6 and 7.1 on one, two and
four harts, a 7.1 kernel built with vector support whose `/init` runs a vector
self-test, and a guest Linux under the bundled hypervisor. They are described in
[Running Linux](running-linux.md). A boot runs thousands of instructions through
every part of the system, so it finds the bugs that the directed tests do not.

## Co-simulation with spike {#co-simulation-with-spike}

The core's retire records are compared, one record at a time and field by field,
with the spike instruction-set simulator. This is online: a Veryl component
(`cosim/spike`) steps a spike hart for each retired instruction, makes spike take
each interrupt the core takes, and reports the first difference. With several
harts it runs one spike hart per core over a shared memory and feeds the values of
reads that may observe another hart from the core, since the retire order is not
the coherence order.

spike is not fetched by default. `toolchain/fetch.sh spike` builds the pinned
version, and `veryl build` and `veryl test` need it because `Veryl.toml` declares
the component (set `SPIKE_HOME` to use a spike build elsewhere).

```bash
toolchain/fetch.sh spike
python3 test/gates/run_gc.py --core w2                         # the riscv-tests and directed lists
python3 test/gates/run_act.py --core w2 --cosim                # every ACT4 test
veryl test --ignored --test test_cosim_spike_rv64ui_add   # one cosim testbench
```

The `tb/rvfi_adapter.veryl` module presents the same records as RISC-V Formal
Interface (RVFI) signals, for tools that read RVFI.

## Random programs {#random-programs}

`test/gr/run_gr.py` generates random instruction streams, assembles them and runs
each one under the spike co-simulation. The generator covers scalar integer and
floating-point instructions, privileged code (traps, interrupts, paging, PMP),
vector code, and hypervisor code, alone and in combination, and it reports the
mnemonics no program reached. A program passes when the core writes `tohost` 1 and
the co-simulation sees no difference.

```bash
python3 test/gr/run_gr.py --core w2 --seeds 1-50               # scalar programs
python3 test/gr/run_gr.py --core w2 --priv --seeds 1-50        # privileged
python3 test/gr/run_gr.py --core w2 --vec --seeds 1-50         # vector
python3 test/gr/run_gr.py --core w2 --hyp --seeds 1-50         # hypervisor
python3 test/gr/run_gr.py --fixed test/gr/fixed.list           # the recorded sets, with their record counts
```

The generator is deterministic: a seed gives the same program, so a failure
reproduces with its seed.

## Debug tests {#debug-tests}

The Debug Module is tested in two ways. Scripted tests in `veryl test` drive the
APB port directly and check halt, resume, step, abstract commands, the program
buffer, System Bus Access, triggers, groups and reset. On Verilator, the
riscv-tests debug suite (`gdbserver.py`) runs against the SoC through OpenOCD and
GDB, with a testbench JTAG transport; `test/debug/run_gg.sh` runs it and
`test/debug/` holds the OpenOCD configurations and the list of tests that are
excluded with a reason. See [SoC integration](soc-integration.md#debug).

## Verilator cross-check {#verilator-cross-check}

Boots and litmus runs also run on Verilator. Standard SystemVerilog scheduling is
closer to real hardware than the Veryl simulator, and the two give the same cycle
counts, so a difference points at a simulator problem rather than at the design.
Build with `+define+HELIODOR_CHK+HELIODOR_OBS`, as the harnesses need the retire
records. The wrappers are listed in
[Running Linux](running-linux.md#run-a-boot-on-verilator).

## Coverage and firing counters

Two checks measure whether the tests exercise the design.

- **Event wires.** Every mechanism has a registered event wire in `o_perf`
  (each retry reason, each kind of kill, each forwarding hit). `test/gates/fire_check.py`
  checks a matrix of events against the logs of the tests and fails when an event
  that must fire in a given test does not. A bit-identical result in a test where
  a mechanism never fired says nothing about that mechanism.
- **Coverage.** `test/gates/cov_report.py` reports functional coverage from the
  co-simulation records (instructions by mode, traps by cause, CSR accesses,
  vector types, memory accesses), measured against the set of implemented cases
  so that a hole is a case no test reached. `sim/verilator/run_cov.py` reports
  line and toggle coverage of the RTL on Verilator.
