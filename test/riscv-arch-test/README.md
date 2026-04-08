# riscv-tests integration for heliodor

Builds the official riscv-tests ISA test suites as `.hex` files
loadable by heliodor and generates one Veryl native testbench per test.
Suites currently built: `rv64ui`, `rv64um`, `rv64ua`, `rv64uc`,
`rv64uf`, `rv64ud` (110 tests total).

## Layout

- `upstream/` — clone of https://github.com/riscv-software-src/riscv-tests
  (not a git submodule; cloned manually so the heliodor repo stays
  self-contained). The `env/` directory inside `upstream/` is itself a
  submodule of riscv/riscv-test-env that must also be initialised.
- `Makefile` — builds the rv64ui tests using the `p` (physical) env's
  `link.ld` (loads at PA 0x80000000) and produces `build/rv64ui/*.hex`
  via the existing `test/c/bin2hex.py` helper.
- `gen_tb.py` — emits `tb/test_arch.veryl` with one harness + `#[test]`
  per built hex file.
- `build/` — output directory (gitignored).

## First-time setup

```bash
git clone https://github.com/riscv-software-src/riscv-tests.git upstream
cd upstream && git submodule update --init env
```

## Build & run

```bash
make                                                  # build every suite
# or one at a time: make rv64ui / rv64um / rv64ua / rv64uc / rv64uf / rv64ud
python3 gen_tb.py                                     # regenerate tb/test_arch.veryl
veryl test --ignored --test test_arch_rv64ui          # one suite
veryl test --ignored --test test_arch_                # every arch test
```

## Current pass rate (2026-04-08)

| Suite   | Passed   | Notes                                                |
|---------|----------|------------------------------------------------------|
| rv64ui  | 49/49    | clean (JIT on/off)                                   |
| rv64um  | 6/13     | div/rem/mulh family fail — RV64M corner cases        |
| rv64ua  | 19/19    | clean — all atomics pass                             |
| rv64uc  | 0/1      | `rvc` — compressed decoder gap(s)                    |
| rv64uf  | 4/11     | heliodor FP 32-bit semantics gaps                    |
| rv64ud  | 1/12     | heliodor FP 64-bit semantics gaps                    |

Failing suites are tracked as heliodor-side bugs to be fixed in a
follow-up phase. All failures go through the same harness, so adding a
fix and re-running `veryl test --ignored --test test_arch_<suite>_<name>`
is the recommended debug loop.

## Notes

- The Veryl simulator currently requires `$readmemh` to take a string
  literal, so each test gets its own dedicated harness (cannot be
  parameterised). `gen_tb.py` handles the boilerplate.
- The arch tests are marked `#[ignore]` to keep the default `veryl
  test` fast. Run them explicitly via `--ignored --test
  test_arch_...`.
