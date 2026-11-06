# Getting started

This chapter takes you from a fresh checkout to a passing test. The commands are
run from the root of the heliodor repository.

## Requirements

- Linux on x86-64. The prebuilt toolchains are built for glibc 2.34 or newer.
- A Rust toolchain (`cargo`), to build the Veryl compiler.
- [Verilator](https://www.veripool.org/verilator/) 5.x, only for the Verilator flows
  (version 5.050 was used for this book). Install it from your distribution or
  from the Verilator project.
- `make`, `python3`, `git`, `curl`, `tar`, and `dtc` (the device-tree compiler,
  for the Linux image build).
- Ruby 3.4 or newer, only for the ACT4 compliance suites.

## Get Veryl

Heliodor is written in Veryl and is built and tested with the Veryl compiler and
simulator. The project keeps its own clone of the compiler in `./veryl/`. The
directory is ignored by git; it is not a submodule.

```bash
git clone https://github.com/veryl-lang/veryl.git veryl
(cd veryl && cargo build --profile release-verylup)
export PATH="$PWD/veryl/target/release-verylup:$PATH"
veryl --version
```

The `release-verylup` profile builds without link-time optimization and is the
fast release build. Use that binary for all development and testing. The book was
checked with Veryl 0.22.1.

The commands below assume `veryl` is the binary you just built. Some scripts in
the repository read the variable `VERYL` instead of searching the path; set
`VERYL="$PWD/veryl/target/release-verylup/veryl"` if you use them.

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

`toolchain/fetch.sh debug` builds spike, OpenOCD and GDB from pinned sources;
you need them only for the [debug flow](soc-integration.md#debug).
`toolchain/fetch.sh book` fetches the tools that build this book.

Most tests need no toolchain: the hex images of the test programs and of the
Linux boots are committed to the repository.

## Build

```bash
veryl build
```

This transpiles the sources and testbenches to SystemVerilog next to each
`.veryl` file, and writes the file list `heliodor.f` for the Verilator flows. The
first run takes a minute or two.

`veryl check` runs the analyzer without generating files. It currently prints
lint warnings for the testbenches and exits with a non-zero status, so use
`veryl build` as your build gate.

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
veryl test --backend cranelift          # another code-generation backend
veryl test --backend interpret          # the slowest, reference backend
```

The simulator has three code-generation backends: `cc` (the default: emit C and
compile it), `cranelift` (an in-process JIT) and `interpret` (a tree-walking
interpreter). If a result looks suspicious, run the same test on a second
backend. Two independent backends that agree make a simulator bug unlikely.

If a previous `veryl test` was killed, remove the stale lock before running again:

```bash
rm -f .build/lock
```

Run only one `veryl` command at a time in a checkout.

Tests named `test_w2_*` run on the 2-wide core, and tests named `test_w4_*` run
the same programs on the 4-wide core.

## Run on Verilator

The native `#[test]` modules cannot run on Verilator, so thin SystemVerilog
wrappers in `sim/verilator/` instantiate the harnesses that `veryl build`
generates. Verilator uses standard SystemVerilog scheduling, which makes it a
useful cross-check of the Veryl simulator.

```bash
veryl build
verilator --binary --top-module tb_soc_smp_linux_boot_2hart_w2 -f heliodor.f \
          sim/verilator/tb_soc_smp_linux_boot_2hart_w2.sv \
          --timing -Wno-fatal -O3 -j 4 \
          --Mdir sim/verilator/build_n2_w2 -o tb_soc_smp_linux_boot_2hart_w2
sim/verilator/build_n2_w2/tb_soc_smp_linux_boot_2hart_w2
```

Run the simulator from the repository root, because the harnesses read their
hex files by relative path. Delete the `--Mdir` directory when you change the
configuration; a stale build gives confusing results. The wrappers are listed in
[Running Linux](running-linux.md).

## Rebuild test programs

The hex files are committed, so rebuilding is only needed when you change a test
program or want to regenerate it with a different toolchain:

```bash
source toolchain/env.sh
make -C test/riscv-arch-test      # riscv-tests ISA suites
make -C test/act                  # ACT4 (riscv-arch-test) suites; needs sail, uv, ruby
```

## Next steps

- Look at the design in [Architecture](architecture.md).
- Put the core in a system: [SoC integration](soc-integration.md).
- Boot Linux: [Running Linux](running-linux.md).
