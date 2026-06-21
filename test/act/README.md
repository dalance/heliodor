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
| `heliodor.yaml` | UDB config (RVA20S64 base + implemented RVA23 exts: Zba/Zbb/Zbs, Zcb, Zcmop/Zimop, Zicond, Zihintntl/Zihintpause, Zfa, Zfhmin, Zicbom/Zicboz/Zicbop, Zihpm, Zmmul + `MISALIGNED_LDST`/`CACHE_BLOCK_SIZE` params) |
| `sail.json` | Sail reference config |
| `test_config.yaml` | compiler / objdump / `sail_riscv_sim` / udb / linker (all resolved from PATH) |

The harness module is `test_arch_common_harness` in `tb/test_arch_common.veryl`
(4 MB DRAM, `addr[21:2]`, so large signature images fit).

## Status (2026-06-21)

ACT4 **506/506**. On top of the original base+FP **327** (integer/atomic/
compressed/CSR **129/129**, rv64uf **82/82**, rv64ud **114/114**, Zicntr
**2/2**), the RVA23 scalar extensions heliodor implements are now covered too:
**Zba/Zbb/Zbs** (bit-manip) 8/24/8, **Zcb** (+`ZcbM`/`ZcbZba`/`ZcbZbb`) 12,
**Zcmop** 8, **Zimop** 40, **Zicond** 2, **Zihintntl** (+`ZihintntlZca`) 8,
**Zihintpause** 1, **Zfa** (`ZfaF`/`ZfaD`) 22, **Zfhmin** (`Zfhmin`/`ZfhminD`)
12 — these caught one real RTL bug (FCVT.H.S, **now fixed**, see below);
everything else was clean on first run. The cache-block / counter / misaligned
suites are covered too: **Zicbom** 3, **Zicboz** 1, **Zicbop** 3, **Zihpm** 2,
**Zmmul** 5, **Misalign**/`MisalignD`/`MisalignF`/`MisalignZca` 8/2/2/8 — all
clean (`Zicbom`/`Zicboz` need `CACHE_BLOCK_SIZE=64` +
`FORCE_UPGRADE_CBO_INVAL_TO_FLUSH=true`: heliodor's coherent write-back design
treats `cbo.inval/clean/flush` as legal no-ops, so `cbo.inval` never discards
dirty data; the `Misalign*` suites just need `MISALIGNED_LDST=true`).

Still uncovered: the **privileged / virtual-memory** suites (`Sv`, `Svnapot`,
`Svpbmt`, `Svade`/`Svadu`, `Svinval`, `pmp`, `Exceptions*`) — heliodor
implements all of these, but they need an S-mode + page-table harness (the
current `test_arch_common_harness` runs M-mode). The **vector V** suites are
absent from this upstream clone. **Zacas** and **Zabha** are RVA23-mandatory but
**not implemented** in heliodor (a real gap, not just untested).

Two framework-integration fixes were needed to generate these. (1) The upstream
`make` wants `EXTENSIONS` **comma-separated** and strips all spaces, so the
heliodor `Makefile` now translates the space-separated `EXT` to commas
(`EXT_CSV`); a space-separated value silently collapsed to one bogus token and
matched nothing. (2) The `--extensions` filter matches the **test directory
name**, so combined-extension suites are requested by their dir name
(`ZfaF`, `ZfaD`, `ZcbZba`, …), not the base name (`Zfa`, `Zcb`).

The **FCVT.H.S** (single → half) miss was a real heliodor RTL bug in
`fpu_wrap.veryl`, **now fixed**: the narrowing path flushed *every* input with
biased single exponent `< 103` straight to signed zero. But an input with
`xe == 102` (magnitude in `[2^-25, 2^-24)`) is closer to the smallest half
subnormal than to zero, so RNE must round it **up to `0x0001`**, not down to
`0x0000`. Repro (RNE): `fcvt.h.s` of `0x335e20be` (≈5.17e-8) gave `0x0000`,
should be `0x0001`. Fix: drop the `xe < 103` flush and let the tiny **normal**
inputs (`xe` 1..102) fall through to the existing subnormal-rounding path, which
already rounds correctly for every mode; keep an explicit `xe == 0` arm for true
zero and single-subnormal inputs (the latter now also rounds to ±min-subnormal
under RDN/RUP). Verified exhaustively in a Python model of the RTL vs. an exact
`Fraction` reference (≈2 M conversions, 5 rounding modes, 0 value/flag
mismatches), then on hardware: `Zfhmin`/`ZfhminD` 12/12, default `veryl test`
250/0.

### Earlier fixes

The original 3 F misses were a real heliodor RTL bug — **now fixed** (see below).

The 3 F misses (`fcvt.w.s` / `fcvt.wu.s` / `fclass.s`, the `cp_fs1` `rd=x0`
subtest) were a **real heliodor RTL bug, now fixed**: an FP→int / `fclass`
instruction with **`rd=x0`** wrote its result back to `prf[0]` (the arch-zero
hard tie) and a *nearby* reader of `x0` then saw the result instead of hardwired
zero. Root cause: the FP issue-queue `has_rd` dispatch
(`heliodor_core.veryl`) was `fp_writes_fp || fp_writes_int` — it skipped the
`rd!=0` gate that the integer path applies (`dec_op.has_rd = reg_wen && rd!=0`),
so an FP→int op to `x0` still drove `cdb.has_rd=1` and corrupted `prf[0]`. Fix:
gate the `fp_writes_int` term by `rd_arch != 0` (`fp_writes_fp` needs no gate —
`f0` is a real FP register). The bug was **transient/value-dependent** (a read
0–1 instructions later saw the leak, ≥2 away saw 0; FP→int latency shifted the
window), which is why the double-precision `fcvt.w.d` / `fcvt.wu.d` / `fclass.d`
`rd=x0` subtests happened to pass. **Diagnosis trail**: the signature golden for
the slot is correctly `0` (the `0xbaaaaaad…` in the RVCP "Bad Value" is a
cosmetic artifact of the `rd=x0` failure-reporter); the self-checking ELF
**passes on Sail** but failed on **all three Veryl-sim backends AND Verilator**
(SV NBA) → a real RTL bug, not a sim artifact. Repro (pre-fix): `fcvt.w.s x0,
f0` with `f0=0xc5606eda` (→ −3591) then `addi x7, x0, 1` → `x7 != 1`. Verified:
all 3 F tests pass; default `veryl test` 250/0; N=1 boot 4/4; N=2 SMP boot;
litmus-4hart — all green.

The 2 `Zicntr` misses **were a harness gap, now fixed** (`gen_suite.py` sets
`MTIME_EN=1` for the Zicntr suite). The `cp_cntr` `time` subtest reads the
`time` CSR twice and checks it *increments*; the arch harness froze `i_mtime`
at 0 (`MTIME_EN=0` default), so `time` never ticked even though the core's
`time` CSR is correct (Linux boots on its timer). Driving the harness'
free-running mtime makes both pass.
