# riscv-tests integration for heliodor

Builds the official riscv-tests rv64ui ISA test suite as `.hex` files
loadable by heliodor and generates one Veryl native testbench per test.

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
make                                                # build all rv64ui hex files
python3 gen_tb.py                                   # regenerate tb/test_arch.veryl
veryl test --ignored --test test_arch_rv64ui         # run all 49 tests
```

## Notes

- The Veryl simulator currently requires `$readmemh` to take a string
  literal, so each test gets its own dedicated harness (cannot be
  parameterised). `gen_tb.py` handles the boilerplate.
- All 49 rv64ui tests pass under JIT on. Under JIT off, 9 tests
  involving signed shifts/comparisons (sra/sraiw/sraw/srai/slt/slti/
  blt/bge/lui) fail — this is a separate Veryl simulator interpreter
  bug to investigate, NOT a heliodor bug.
- The arch tests are marked `#[ignore]` to keep the default `veryl
  test` fast. Run them explicitly via `--ignored --test
  test_arch_rv64ui`.
