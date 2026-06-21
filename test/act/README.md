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

> The ELF-generation step (`make … elfs`) uses Python multiprocessing, which
> needs `AF_UNIX` sockets. A restrictive sandbox blocks those
> (`PermissionError: Operation not permitted`) — run `make -C test/act` outside
> the sandbox (e.g. Claude Code `/sandbox` off). The toolchain fetch, the Veryl
> sim, and everything else run fine sandboxed.

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

ACT4 **324/327**: integer/atomic/compressed/CSR **129/129**, rv64uf **79/82**,
rv64ud **114/114**, Zicntr **fixed**. The 3 remaining F misses are a confirmed
**real heliodor RTL bug** (see below) — NOT a test-binary issue.

The 3 remaining misses (`fcvt.w.s` / `fcvt.wu.s` / `fclass.s`) are a **real
heliodor RTL bug**: an FP→int / `fclass` instruction with **`rd=x0`** leaks its
result to a *nearby* reader of `x0` instead of returning hardwired zero. The
failing subtest is `cp_fs1` `rd=x0` (e.g. `fcvt.w.s x0, f12`); the signature
golden for that slot is correctly **0** (the `0xbaaaaaad…` in the RVCP "Bad
Value" is a cosmetic artifact of the `rd=x0` failure-reporter, not the golden —
the golden in the ELF is `0`). The bug is **transient/timing-dependent**: a
dependent read 0–1 instructions after the FP→int op sees the leaked result,
≥2 instructions away sees the correct 0; it is also value-dependent (varies
with the FP→int latency). **Disambiguation done**: the same self-checking ELF
**passes on the Sail reference**, **fails on all three Veryl-sim backends (cc /
cranelift / interpret)**, and **also fails on Verilator** (standard SV NBA) —
so it is a real RTL bug, not a Veryl-sim artifact. The architectural x0 paths
(RAT skips r0, PRF-write / IQ-wakeup / intra-bundle rename bypass all gate on
`has_rd` & `rd!=0`) are correct on inspection, so the leaking path is a
non-obvious same-cycle forwarding corner — root-cause + fix pending (needs
waveform debug). The double-precision counterparts (`fcvt.w.d` / `fcvt.wu.d` /
`fclass.d`) pass only because their `rd=x0` subtests happen to convert to 0 (or
land outside the leak window). Repro: `fcvt.w.s x0, f0` with `f0=0xc5606eda`
(→ −3591) then `addi x7, x0, 1` → `x7 != 1` (x0 leaked).

The 2 `Zicntr` misses **were a harness gap, now fixed** (`gen_suite.py` sets
`MTIME_EN=1` for the Zicntr suite). The `cp_cntr` `time` subtest reads the
`time` CSR twice and checks it *increments*; the arch harness froze `i_mtime`
at 0 (`MTIME_EN=0` default), so `time` never ticked even though the core's
`time` CSR is correct (Linux boots on its timer). Driving the harness'
free-running mtime makes both pass.
