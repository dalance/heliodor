# riscv-tests integration for heliodor

Builds the official riscv-tests ISA test suites as `.hex` files loadable by
heliodor. Suites built: `rv64ui`, `rv64um`, `rv64ua`, `rv64uc`, `rv64uf`,
`rv64ud`, plus `rv64mi` / `rv64si` privilege tests.

## Layout

- `upstream/` — clone of https://github.com/riscv-software-src/riscv-tests
  (not a git submodule; cloned manually so the heliodor repo stays
  self-contained). The `env/` directory inside `upstream/` is itself a
  submodule of riscv/riscv-test-env that must also be initialised.
- `Makefile` — builds the suites using the `p` (physical) env's `link.ld`
  (loads at PA 0x80000000) and produces `build/<suite>/*.hex` via the
  `test/c/bin2hex.py` helper.
- `build/` — output directory (gitignored).

The Veryl test modules are **hand-maintained inline** in `tb/test_arch_common.veryl`
(rv64ui/um/ua/mi/si) and `tb/test_arch_fp.veryl` (rv64uf/ud): each `#[test]`
module instantiates `test_arch_common_harness` with its own `HEX_FILE` path
into `build/`. (The old `gen_tb.py` generator targeted the v1 core and was
removed in the P7 cleanup.)

## First-time setup

```bash
git clone https://github.com/riscv-software-src/riscv-tests.git upstream
cd upstream && git submodule update --init env
```

## Build & run

```bash
make                                          # build every suite -> build/<suite>/*.hex
# or one at a time: make rv64ui / rv64um / rv64ua / rv64uc / rv64uf / rv64ud
veryl test                                    # arch suites run by default (not #[ignore])
veryl test --test test_arch_rv64ui            # narrow to one suite
veryl test --test test_arch_rv64ui_add        # one test
```

The arch tests run on the OoO core (`src/core/heliodor_core`) and are part of
the default `veryl test` fast regression. Pass/fail uses the standard
riscv-tests `tohost` protocol (write to PA 0x80001000: `1` = all subtests
passed, `>1` = the subtest with that id failed).

## Notes

- The Veryl simulator requires `$readmemh` to take a string literal, so each
  test gets its own dedicated `#[test]` module (the path cannot be a runtime
  parameter); they share `test_arch_common_harness`.
