# `toolchain/` — pinned prebuilt cross toolchains

Heliodor's test/verification flows need RISC-V cross compilers plus the ACT4
reference model. Rather than depend on whatever is on `$PATH`, this directory
fetches **pinned prebuilt binaries** into gitignored subdirectories. Only the
scripts and the version pins are committed (same policy as the gitignored
`veryl/` clone and `test/riscv-arch-test/upstream/`).

## Quick start

```bash
toolchain/fetch.sh all      # download + extract everything (~1 GB, gitignored)
source toolchain/env.sh     # put the tools on PATH for this shell
```

Then the consumers work:

```bash
make -C test/riscv-arch-test         # riscv-tests ISA suites (uses elf gcc)
make -C test/act                     # ACT4 / RVA23 suites (elf gcc + Sail + uv + UDB)
test/linux/build.sh                  # Linux boot images (linux gcc)
```

## What gets fetched

| dir          | tool                              | used by |
|--------------|-----------------------------------|---------|
| `elf/`       | `riscv64-unknown-elf-gcc` (GCC 16, binutils 2.43) | ACT4, riscv-tests, directed tests, bare hex |
| `linux/`     | `riscv64-unknown-linux-gnu-gcc` (GCC 16, binutils 2.43) | Linux kernel + `/init` (`test/linux`) |
| `sail/`      | `sail_riscv_sim` (Sail RISC-V)    | ACT4 golden reference |
| `uv/`        | `uv`                              | ACT4 Python framework env |

## Debug flow tools (built from source)

`toolchain/fetch.sh debug` builds three tools from pinned sources into
gitignored `spike/`, `openocd/`, `gdb/` (sources under `src/`), then
`source toolchain/env.sh` puts them on `PATH`. They are not part of `all`.

| dir        | tool | pin (`versions.env`) |
|------------|------|----------------------|
| `spike/`   | spike (riscv-isa-sim) | `SPIKE_COMMIT` |
| `openocd/` | riscv-collab/riscv-openocd, remote_bitbang + jtag_dpi | `OPENOCD_COMMIT` |
| `gdb/`     | `riscv64-unknown-elf-gdb` (GNU GDB, no Python) | `GDB_URL`, `GDB_SHA256` |

Why source builds: the riscv-collab prebuilt GDB needs `libpython3.10` and a
newer `libstdc++` than EL9 has, and there is no trustworthy prebuilt OpenOCD or
spike for this host. Build needs only host tools: gcc/g++ >= 11, make,
autoconf/automake/libtool/texinfo (OpenOCD), `dtc` and boost-devel (spike),
gmp/mpfr/ncurses/zlib/expat -devel (GDB). OpenOCD's libjaylink submodule
(gitlab) is skipped, so J-Link is not supported; USB adapters are not built
because `libusb1-devel` is absent, which does not matter for simulation.
The riscv-tests debug suite itself is the `test/riscv-arch-test/upstream/debug/`
clone; its commit and the reference results are recorded under `test/debug/`.

## GLT: litmus tests and herd7

`toolchain/fetch.sh glt` clones the official RISC-V litmus tests
(`LITMUS_COMMIT`) into the gitignored `test/glt/upstream/` and builds herd7 from
herdtools7 (`HERD_COMMIT`, tag 7.58) into the gitignored `herd/`. The build
fetches the pinned `opam` binary, compiles OCaml and the herdtools7 dependencies
listed in `OCAML_PKGS` into an opam root under `herd/opam`, and installs herd7
with its `riscv.cat` model under `herd/bin` and `herd/share`. Nothing is
installed system-wide. dune opens sockets during the build, so run it outside a
sandbox that forbids them. `test/glt/run_glt.py` uses the tools (see its
docstring).

Ruby/UDB use the **system** Ruby (`ruby --version` ≥ 3.4); `env.sh` points
`BUNDLE_PATH` at a writable, gitignored dir so `bundle install` works without a
writable system gem dir.

## Pinning / reproducibility

`versions.env` is the single source of truth: repo, release tag, and an asset
glob per tool. `fetch.sh` resolves the asset via the GitHub API, so the exact
dated filename need not be hard-coded. After the first fetch it prints each
archive's sha256 — paste those into `versions.env` (`*_SHA256=`) to make
subsequent fetches verified.

To bump a toolchain: change `*_TAG` (and keep the `ubuntu-22.04` glob — see
below), clear the `*_SHA256`, refetch, then re-pin the digest.

## EL9 / glibc note

The riscv-collab GCC archives are the **ubuntu-22.04** builds on purpose: they
link against glibc 2.34 and run on EL9 (glibc 2.34). The ubuntu-24.04 builds
need glibc 2.39 and will not run here. Keep the 22.04 variant when bumping.

## Why a single recent `linux/` toolchain

The V-enabled Linux build needs, all at once: RVV `as`, `ld -shared` for the
vDSO, and `ld` ≥ 2.38 so Kconfig's `TOOLCHAIN_HAS_V` auto-detects. An older
linux-gnu `ld` (2.37) forced an elf-CC + linux-LD mix and a Kconfig patch. The
pinned 2026.x linux-gnu toolchain has binutils 2.43, which satisfies all three,
so `test/linux/build.sh` uses one toolchain with no version workaround. See
`test/linux/README.md`.
