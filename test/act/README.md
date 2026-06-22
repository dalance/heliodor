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

### Privileged / virtual-memory suites

The mode-switching `priv/` suites (run in S/U-mode via `mret`) total **50/50**:
the `Svnapot`/`Svade`/`Svbare`/`Svpbmt`/`Svinval`/`Svadu` group below (**17/17**)
plus the general Sv39 `Sv` suite (**33/33**).

The `priv/` suites (`Svnapot`, `Svpbmt`, `Svade`/`Svadu`, `Svinval`, `Svbare`,
…) run in S/U-mode and mode-switch via `mret`. They were unblocked by defining
**`STANDARD_SM_SUPPORTED`** in `rvmodel_macros.h`: heliodor implements the
mandatory M-mode spec (it boots Linux), so it uses the framework's standard Sm
boot + trap-handler infrastructure (the prolog that initializes `mscratch`, the
trampolines, `xtvec`, the `GOTO_*MODE` calls). Without it `mscratch` stays 0 and
the tests' mode-switch loads fault into a trap loop — even on the Sail reference.
Enabling it does **not** regress the 506 M-mode suites (re-verified 506/0). The
DUT config also needs Sv39-only (`sail.json` `Sv48` → false) and the
`Svnapot`/`Svpbmt`/`Svadu`/`Svinval` flags enabled.

Result: **priv 17/17** — `Svnapot` 4/4, `Svade` 2/2, `Svbare` 3/3, `Svpbmt` 4/4,
`Svinval` 2/2, `Svadu` 2/2. The suite caught **7 real heliodor RTL bugs, all now
fixed**:

| was failing | bug (fix commit) |
|---|---|
| `Svpbmt` nonleaf (×2) | `PBMT != 0` (or reserved `N`) in a **non-leaf** Sv39 PTE is reserved → page fault (`4bb654f`). |
| `Svinval` (×2) | `SFENCE.W.INVAL`/`SFENCE.INVAL.IR` must raise illegal in U-mode but, unlike `SFENCE.VMA`, must **not** be trapped by `mstatus.TVM` — a privilege-checked path (`is_svinval_fence`) distinct from `is_sfence`; landed with `mstatus.SD` + illegal-instruction `mtval` (`178cbba`). |
| `Svbare` mprv (×1) | `mstatus.MPRV` + `MPP=S/U` + `satp=Bare` effective-privilege path — fixed as a side effect of the SD / `mtval` work (`178cbba`). |
| `Svadu` (×2) | hardware A/D update: the instruction-fetch A-bit write-back is injected coherently through the dcache store-drain port (`98100fc`). |

### General Sv39 page-table suite (`Sv`)

The big `Sv` suite (134 tests, of which **33 are the sv39_* subset** heliodor's
Sv39-only config generates — the sv32/sv48/sv57 and svnapot/svpbmt-disabled-when-
implemented variants are filtered out) exercises every Sv39 PTE corner case:
canonical VAs, invalid/global/misaligned/RSW PTEs, `mstatus.MPRV`/`MXR`/`SUM`,
reserved fields, and non-leaf PTE rules. **`Sv` 33/33.** It caught **5 more real
heliodor MMU RTL bugs in `src/mmu/mmu.veryl`, all now fixed** — the walk accepted
several reserved/illegal Sv39 encodings that the spec (and the Sail reference)
require to page-fault:

| was failing | bug |
|---|---|
| `sv39_canonical` (×2) | A non-canonical Sv39 VA (bits [63:39] not a sign-extension of bit 38) must fault before the walk; heliodor ignored [63:39]. Fixed with `va_noncanonical`, which gates the TLB-hit fast path AND the walk start (the TLB tags only VA[38:12], so a non-canonical VA could otherwise alias a cached entry). |
| `sv39_nleaf_pte_DAU` (×2) | A non-leaf (pointer) PTE with `D`/`A`/`U` set is a reserved encoding → fault; heliodor followed the pointer. (`G` at bit 5 IS allowed on non-leaf and still propagates.) |
| `sv39_pte_reserved_field` (×1) | PTE bits [60:54] are reserved and must be zero in every PTE → fault. |
| `sv39_pte_reserved_rwx` (×2) | The `W=1,R=0` R/W/X encodings (010 / 110) are reserved → fault, at any level (heliodor treated 010 as a pointer and 110 as an executable leaf, looping / mis-translating instead of faulting). |
| `sv39_svpbmt_disabled` (×1) | With `menvcfg.PBMTE=0` the implementation behaves as if Svpbmt were not implemented, so a **non-zero PBMT field is reserved → fault** (heliodor only faulted PBMT==11 and only when PBMTE=1). This also corrected heliodor's own directed `test/svpbmt/svpbmt_test.S`, which had assumed PBMTE=0 *ignored* PBMT — the spec/Sail fault, so the test now expects it. |

These suites are **not** in the default `make` EXT (the default stays green at
506); generate them with `make -C test/act EXT="Sv Svnapot Svpbmt Svade Svadu
Svinval Svbare"`.

### Zabha (byte/halfword atomics)

**`Zabha` 18/18.** heliodor now implements the byte/halfword AMOs
(`amo{add,and,or,xor,swap,min,max,minu,maxu}.{b,h}`). The AMO compute datapath
in `alu_wrap.veryl` was generalized from 2 widths (`.W`/`.D`) to 4
(`.B`/`.H`/`.W`/`.D`): the target sub-word is right-aligned out of the 8-byte
load by the byte offset, both operands are zero/sign-extended at the access
width (so one 64-bit datapath + comparator serves every width), and the new
sub-word stays right-aligned so the existing 4-size commit-time wstrb generator
writes exactly the target bytes; `rd` gets the sign-extended old sub-word.
Generate with `make -C test/act EXT="Zabha"` (`Zabha` enabled in `heliodor.yaml`
+ `sail.json`).

### Zacas (compare-and-swap, incl. 128-bit pair)

**`Zacas` 3/3 + `ZacasZabha` 2/2** — `amocas.{b,h,w,d,q}`. amocas is invasive in an
OoO core: it reads `rd` as a THIRD source (the comparison/expected value) and
`amocas.q` operates on the 128-bit even/odd register pair `rd:rd+1` / `rs2:rs2+1`.

- **`amocas.{b,h,w,d}`** (single register). The comparison value is the OLD value
  of `rd` — which is exactly the physical register `rat[rd]` captures at rename as
  `old_rd_pdst`. Since an AMO issues only at the ROB head, that value's producer
  has committed, so it is always ready (no IQ wakeup tracking): a spare `prf_int`
  read port (`rd8`, fed by a new `iq_int` `o_issue_rd_old_pdst`) supplies it to
  `alu_wrap` as `i_rd_cmp_data`. `alu_wrap` compares at the access width and gates
  the commit store on the match (a mismatching CAS leaves memory unchanged); `rd`
  gets the sign-extended old sub-word via the normal writeback.
- **`amocas.q`** (128-bit pair) is handled as a serializing op. It does not rename
  `rd:rd+1`; at execute it loads the 128-bit value (lo via `i_load_data`, hi via
  `i_load_data_next` — 16-byte aligned ⇒ one cache line) and carries it to commit.
  Register operands are read at commit from the architectural file (`arch_regs`,
  authoritative at the ROB head): compare `{rd+1,rd}` vs the loaded pair, and on a
  match store `{rs2+1,rs2}` via a 128-bit extension of the in-cache AMO merge
  (`dcache.veryl` `i_wen_excl_q`/`i_wdata_hi` writes the adjacent lane). The old
  pair is written into `rd:rd+1` in place (two commit-time `prf_int` write ports +
  `arch_regs`), then a commit flush re-fetches so younger readers see the new
  values. The read is held until the store buffer drains (its two-dword read isn't
  covered by the single-dword store-overlap gate). **x0 rule:** when a pair BASE is
  `x0` the WHOLE pair reads as 0 (`rd=x0` ⇒ compare `{0,0}` + no writeback; `rs2=x0`
  ⇒ store `{0,0}`).

Generate with `make -C test/act EXT="Zacas ZacasZabha"` (`Zacas` enabled in
`heliodor.yaml` + `sail.json`; `ZacasZabha` needs both `Zacas` and `Zabha`). With
this, **all RVA23-mandatory scalar atomics are covered**.

### PMP (Smpmp) enforcement — PMPS 9/9 (native Veryl sim + Verilator)

heliodor enforces PMP on the load / store / fetch paths (16 entries, OFF / TOR /
NA4 / NAPOT matching, lowest-match priority, R/W/X, lock bits, M-mode bypass of
unlocked entries; combinational `src/mmu/pmp_check.veryl`, boot-safe all-OFF =
inactive). Three real RTL bugs were fixed to make the **PMPS suite pass 9/9**
(cfg_A_off, cfg_XWR, csr_access, mprv_check_01/02, napot_legal_lxwr_01/02,
tor_legal_lxwr_01/02): (1) `medeleg` is fully writable so an access fault
(cause 1/5/7) is **delegated to the S-mode trap handler** as the Sail reference
does (the framework sets `medeleg=0x0FCB0FF`); (2) a **bare-mode fast store** (it
drains via the dcache store-drain port, bypassing the `dmem_mmu` `i_wen` PMP
check) gets a dedicated commit-time `pmp_check` on its PA; (3) a **PMP-denied
load** suppresses its dcache read (`o_dmem_ren`) and is excluded from MSHR replay
so it cannot deadlock the dcache on a fill it must never perform.

PMPS 9/9 passes on the **native Veryl sim** (`veryl test --ignored --test
test_act_pmps`, `tohost=1 pass=1`) on the **cc** and **cranelift** backends; the
**interpret** backend agrees but is the slowest reference path (~7 min per test).
`--backend-validate` (cc vs cranelift) shows no divergence, and Verilator (real
SV NBA, no UNOPTFLAT) also passes all nine. Generate the hex with `make -C
test/act EXT="pmp/pmp64/PMPS"` (or the dir the PMPS ELFs land under); a Verilator
cross-check is available via `sim/verilator/tb_act_pmps_cfg_xwr.sv` (one test) or
`sim/verilator/run_pmp_all.sh` (all nine; re-templates one wrapper per hex).
>
> A previously-reported "native Veryl sim hangs on the PMP-active M-mode cleanup"
> was a **stale `veryl` binary**, not a sim bug — a clean rebuild of veryl HEAD
> (`cargo build --profile release-verylup`) runs all nine natively. Always
> rebuild veryl after touching its source before trusting a native-sim result.
> Still TODO: `SvPMP` (PTW PMP — PTE reads need a PMP check), `PMPU`/`PMPSm`.

### LR/SC & AMO PMP + misaligned atomics — PMPZalrsc 1/1, PMPZaamo 1/1

**`PMPZaamo` 1/1 + `PMPZalrsc` 1/1.** Atomics (LR/SC/AMO) on a PMP-protected,
write-denied region must fault, and a *misaligned* atomic must fault too — both
as access faults, matching the Sail reference. Two real RTL gaps were closed:

- **SC write-permission, reservation-independent.** A store-conditional whose
  reservation is invalid clears its store flag at execute, so it never reaches
  the commit-time exclusive-write `pmp_check` (which is gated by the store
  firing). The spec / Sail still require a store access fault (cause 7) when the
  SC's address is W-denied, *regardless of the reservation* (Sail translates the
  SC address for Write before consulting the reservation). heliodor now runs a
  dedicated issue-time `pmp_check` on the SC's bare PA (`u_pmp_sc_issue`) and
  folds a deny into the SC's CDB store-fault (`alu_wrap` `i_sc_acc_fault`) — the
  recorded `is_sfault`/`fault_acc` trap cause 7 at commit even with no store.
- **Misaligned atomics → access fault (cause 5 LR / 7 SC·AMO).** heliodor
  handles misaligned *plain* loads/stores in hardware, but atomics must be
  naturally aligned. `alu_wrap` now computes `amo_misalign` from the funct3 width
  (`.W` needs `addr[1:0]==0`, `.D` needs `addr[2:0]==0`, Zabha `.H`/`.Q` likewise)
  and routes it to the existing access-fault path — `is_lfault` for an LR
  (cause 5), `is_sfault` for an SC/AMO (cause 7) — and suppresses the commit
  store so a faulting misaligned AMO/SC never writes memory. This matches Sail,
  which for atomics takes the access-fault path, **not** the cause-4/6
  misaligned-address path (verified against `sail_riscv_sim --trace-exception`:
  every PMPZalrsc trap is a load/store-amo **access** fault).

Generate with `make -C test/act EXT="PMPZaamo PMPZalrsc"`. Regression-safe
(default 250/0, all atomic suites — `zalrsc` 4/4, `zaamo` 18/18, `zacas` 5/5,
`zabha` 18/18 — and the PMP suites unchanged): the new checks are inert for
aligned atomics and all-OFF PMP (boot / litmus).

### Remaining suites (each needs a feature heliodor doesn't yet implement)

The suites still uncovered all require a sizeable feature, or are absent from the
upstream clone — they are NOT a matter of generating/running more tests:

- **PMP, the VM/cache variants** (`SvPMP` 16, `SvPMPZicbo` 32, `SvaduPMP` 8) — the
  base `PMPS` suite passes 9/9 (see "PMP (Smpmp) enforcement" above), but these add
  PMP on the **page-table-walk path** (the implicit PTE reads need their own PMP
  check) plus the Svadu A/D write-back, which heliodor's PMP integration does not
  yet cover.
- **`ExceptionsSv` / `ExceptionsSvZaamo` / `ExceptionsSvZalrsc` / `SvZicbo`** (the
  `_Umode` + access-fault cases) — these `LI(a0, RVMODEL_ACCESS_FAULT_ADDRESS)` a
  PA that must raise an **access fault**, but heliodor raises no load/store/fetch
  access fault (cause 1/5/7) for an unmapped/PMA-denied PA (the address is left
  `#undef` in `config/heliodor/rvmodel_macros.h` for this reason). Passing these
  needs PMA / access-fault support. (Sv39-translation `_Smode` cases that don't
  use that address are covered by the `Sv` suite above.)
- **Vector V** — absent from this upstream clone (no V test directory).

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
