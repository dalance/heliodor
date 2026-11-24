# Getting started

This chapter takes you from a fresh checkout to a passing test. The commands are
run from the root of the heliodor repository.

## Requirements

- Linux on x86-64. The prebuilt toolchains are built for glibc 2.34 or newer.
- Veryl 0.22.1 or newer (see [Get Veryl](#get-veryl)).
- A Rust toolchain (`cargo`), to build the co-simulation component.
- [Verilator](https://www.veripool.org/verilator/) 5.x, only for the Verilator flows
  (version 5.050 was used for this book). Install it from your distribution or
  from the Verilator project.
- `make`, `python3`, `git`, `curl`, `tar`, and `dtc` (the device-tree compiler,
  for the Linux image build).
- A C++ compiler (GCC 11 or newer) and the Boost development files, to build the
  spike simulator that `veryl build` needs (see [Get spike](#get-spike)).
- Ruby 3.4 or newer, only for the ACT4 compliance suites.

## Get Veryl {#get-veryl}

Heliodor is written in Veryl and is built and tested with the Veryl compiler and
simulator. Install Veryl 0.22.1 or newer by following the instructions on the
[Veryl website](https://veryl-lang.org/install/), then check the version:

```bash
veryl --version
```

The test scripts under `test/` run the compiler named by the variable `VERYL`.
Without it they look for a development build in `./veryl/` (see
[Contributing](contributing.md#compiler-and-simulator-bugs)), so point it at the
installed binary:

```bash
export VERYL="$(command -v veryl)"
```

## Get the cross toolchains

Heliodor does not rely on whatever compiler is on your `PATH`. It fetches pinned,
prebuilt binaries into `toolchain/` (git ignores them):

```bash
toolchain/fetch.sh all      # RISC-V gcc (bare metal and Linux), Sail, uv
source toolchain/env.sh     # put them on PATH for this shell
```

`fetch.sh all` downloads roughly 1 GB. You can fetch one component instead:
`elf` (bare-metal gcc, needed to rebuild test programs), `linux` (the Linux
cross compiler, needed to build kernel images), `sail` and `uv` (ACT4). Every
archive is verified against the sha256 pinned in `toolchain/versions.env`.

`toolchain/fetch.sh book` fetches the tools that build this book.

Most tests need no toolchain: the hex images of the test programs and of the
Linux boots are committed to the repository.

## Get spike {#get-spike}

`Veryl.toml` declares the spike co-simulation component (`cosim/spike`), so the
Veryl compiler builds it, and its build script links against the spike library.
`veryl build` and `veryl test` therefore fail without spike, even for tests that do
not use the co-simulation:

```text
libriscv.so not found under .../toolchain/spike/lib: run `toolchain/fetch.sh spike` or set SPIKE_HOME
```

```bash
toolchain/fetch.sh spike    # builds spike from a pinned commit into toolchain/spike
```

This builds from source and takes a few minutes. The component is a Rust crate, so
the first `veryl build` also downloads its dependencies with `cargo`. To use a spike you built
elsewhere, set `SPIKE_HOME` to its install directory (it needs `lib/libriscv.so`
and `include/`). `toolchain/fetch.sh debug` builds spike, OpenOCD and GDB together;
you need OpenOCD and GDB only for the [debug flow](soc-integration.md#debug).

## Build

```bash
veryl build
```

This transpiles the sources and testbenches to SystemVerilog next to each
`.veryl` file, and writes the file list `heliodor.f` for the Verilator flows. The
first run takes a minute or two.

`veryl check` runs the analyzer without generating files. It currently prints
lint warnings, mostly for the testbenches (unconnected ports) and a few for the
frozen old core under `src/v14/`, and exits with a non-zero status, so use
`veryl build` as your build gate. The design sources of the current core produce no
warnings.

## Run tests

`veryl test` builds and runs the `#[test]` modules in `tb/` on the Veryl
simulator.

```bash
veryl test --test test_w2_rv64ui_add
```

`--test` is a substring filter, so this runs the four `rv64ui` tests whose names
begin with `test_w2_rv64ui_add` (`add`, `addi`, `addiw`, `addw`) on the 2-wide
core. They take about 30 seconds, and the run ends with
`Completed tests : 4 passed, 0 failed`.

Useful forms:

```bash
veryl test                              # all tests that are not #[ignore]
veryl test --ignored --test <name>      # one long test (Linux boots, benchmarks)
```

If a previous `veryl test` was killed, remove the stale lock before running again:

```bash
rm -f .build/lock
```

Run only one `veryl` command at a time in a checkout.

Tests named `test_w2_*` run on the 2-wide core, and tests named `test_w4_*` run
the same programs on the 4-wide core.

## Run on Verilator {#run-on-verilator}

The native `#[test]` modules cannot run on Verilator, so thin SystemVerilog
wrappers in `sim/verilator/` instantiate the harnesses that `veryl build`
generates. Verilator uses standard SystemVerilog scheduling, which makes it a
useful cross-check of the Veryl simulator.

```bash
veryl build
verilator --binary --top-module tb_soc_linux_boot_w2 -f heliodor.f \
          sim/verilator/tb_soc_linux_boot_w2.sv \
          +define+HELIODOR_CHK+HELIODOR_OBS \
          --timing -Wno-fatal -O3 -j 4 \
          --Mdir sim/verilator/build_n1_w2 -o tb_soc_linux_boot_w2
sim/verilator/build_n1_w2/tb_soc_linux_boot_w2
```

The build takes about a minute, and the run (the 5.15 boot on one hart) takes
about 35 minutes and ends with `W2 N=1 LINUX BOOT PASSED on Verilator`.

The two defines are required. The harnesses detect the end of a test from the
core's retire records, and the records, like the invariant checkers, exist only in
a build that defines `HELIODOR_OBS` and `HELIODOR_CHK` (`veryl test` defines them
for you). Without them the design still runs, the kernel prints its console
output, but the retired-instruction count stays 0 and the test never passes.

Run the simulator from the repository root, because the harnesses read their
hex files by relative path. Delete the `--Mdir` directory when you change the
configuration or the defines; a stale build gives confusing results. The wrappers
are listed in [Running Linux](running-linux.md).

## Rebuild test programs {#rebuild-test-programs}

The hex files are committed, so rebuilding is only needed when you change a test
program. A rebuilt image is not byte-identical to the committed one if your
compiler differs from the one that built it, and the lockstep tests compare the
retire stream with golden traces of the committed images, so rebuild only the
programs you intend to change.

The riscv-tests ISA suites need the riscv-tests sources, which the repository does
not contain (git ignores them):

```bash
git clone https://github.com/riscv-software-src/riscv-tests.git test/riscv-arch-test/upstream
(cd test/riscv-arch-test/upstream && git submodule update --init env)
source toolchain/env.sh
make -C test/riscv-arch-test all   # every suite; a suite name (rv64ui) builds one
make -C test/act                   # ACT4 (riscv-arch-test) suites; needs sail, uv, ruby
```

The ACT4 images are not committed. [Verification](verification.md) has the details
of both flows.

## Next steps

- Look at the design in [Architecture](architecture.md).
- Put the core in a system: [SoC integration](soc-integration.md).
- Boot Linux: [Running Linux](running-linux.md).
