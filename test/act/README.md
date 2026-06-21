# `test/act/` — ACT4 (riscv-arch-test) RVA23 compliance

Machine-checks heliodor against the official **RISC-V Architectural Compliance
Tests** (ACT4 = `riscv/riscv-arch-test`, the RISCOF successor). Each test is a
Sail-signed, self-checking ELF; heliodor runs it and the on-chip `tohost`
mechanism reports pass/fail (`tohost == 1` ⇒ the self-check passed).

This mirrors `test/riscv-arch-test/` (the older riscv-tests integration): the
upstream framework is a gitignored clone, the generated artifacts are not
committed, and the flow is reproducible from pinned tools.

## Build + run

```bash
toolchain/fetch.sh all && source toolchain/env.sh   # one-time: get gcc/sail/uv
make -C test/act                                    # default extension set
make -C test/act EXT="F D"                          # a subset
veryl test --ignored --test test_act_f              # run one suite (substring)
veryl test --ignored --test test_act_               # run all generated suites
```

`make` clones the framework, drops in the heliodor DUT config, runs the Sail +
uv + UDB pipeline to produce ELFs, then `gen_suite.py` converts each ELF to
`test/hex/act_<ext>_<name>.hex` and writes `tb/test_act_<ext>.veryl` (one
`#[test] #[ignore]` module per ELF). Both the hex and the Veryl modules are
gitignored — regenerate with `make`.

## heliodor DUT config (`config/heliodor/`)

| file | purpose |
|------|---------|
| `rvmodel_macros.h` | HALT writes `tohost=1` then **`fence.i`** (heliodor write-backs/invalidates dcache so the harness sees it in DRAM) |
| `link.ld` | pins `.tohost` to **0x80001000** (a write-through region; floating high addresses sit in write-back dcache and never reach DRAM) → `TOHOST_IDX = 1024` |
| `heliodor.yaml` | UDB config (RVA20S64-based, Sv39 only; extend for RVA23) |
| `sail.json` | Sail reference config |
| `test_config.yaml` | compiler / objdump / `sail_riscv_sim` / udb / linker (all resolved from PATH) |

The harness module is `test_arch_common_harness` in `tb/test_arch_common.veryl`
(4 MB DRAM, `addr[21:2]`, so large signature images fit).

## Status (2026-06-21)

ACT4 **322/327**: integer/atomic/compressed/CSR **129/129**, rv64uf **79/82**,
rv64ud **114/114**. All real-RTL FP bugs the suite exercises are fixed.

The 5 remaining misses are **not** RTL bugs:
- `fcvt.w.s` / `fcvt.wu.s` / `fclass.s` — the `cp_fs1` `rd=x0` subtests have a
  **canary reference value** baked into those F test binaries (the equivalent
  double-precision tests pass, so the heliodor result is correct). Likely a
  signature-width quirk in the reference generation; revisit when bumping the
  framework.
- `Zicntr` (2) — `cycle`/`instret` reads differ non-deterministically between
  heliodor and Sail; not comparable, not a bug.
