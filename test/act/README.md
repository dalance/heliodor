# `test/act/` — ACT4 (riscv-arch-test) RVA23 compliance

Machine-checks heliodor against the official **RISC-V Architectural Compliance
Tests** (ACT4 = `riscv/riscv-arch-test`, the RISCOF successor). Each test is a
Sail-signed, self-checking ELF; heliodor runs it and the on-chip `tohost`
mechanism reports pass/fail (`tohost == 1` ⇒ the self-check passed).

This mirrors `test/riscv-arch-test/` (the older riscv-tests integration): the
upstream framework is a gitignored clone, the generated artifacts are not
committed, and the flow is reproducible from pinned tools. The framework clone
itself is pinned to an exact commit (`ACT_COMMIT` in the `Makefile`) — see
[Framework version pin](#framework-version-pin).

## Build + run

```bash
toolchain/fetch.sh all && source toolchain/env.sh   # one-time: gcc, Sail 0.16, uv
make -C test/act                                    # every suite selected for heliodor
make -C test/act EXT="I Vx8"                        # a subset (suite directory names)
test/gates/run_act.py --core w2                     # GA and GL-C on the new core (W2)
test/gates/run_act.py --core w4 --pass-fail --suite i,zba   # GA only
```

> The ELF-generation steps (`make … elfs`) use Python multiprocessing, which
> needs `AF_UNIX` sockets. A restrictive sandbox blocks those
> (`PermissionError: Operation not permitted`): run `make -C test/act` outside
> the sandbox (e.g. Claude Code `/sandbox` off). The toolchain fetch, the Veryl
> sim, and everything else run fine sandboxed.

`make` fetches the framework at the pinned commit, drops in the heliodor DUT
config, generates the test sources (`make tests vector-tests` upstream: the
vector privileged suites `ExceptionsV*` and `MisalignV` come from a separate
generator), runs the Sail + uv + UDB pipeline to produce the ELFs (`act
--keep-going`, see the napot note below), then `gen_suite.py` converts each ELF
to `test/hex/act_<suite>_<name>.hex` and writes the gate list
`test/gates/mi_act.list`. The hex images are gitignored; the list is
committed. `gen_suite.py --tb` additionally writes the old per-suite
`tb/test_act_<suite>.veryl` modules (default core of the harness).

The framework selects the tests from the UDB config: a suite is generated only
for extensions `heliodor.yaml` declares, so suites of extensions MI implements
later (Zvbb, Zvfhmin) appear once they are declared. Two selected tests are
excluded: the `SdtrigS`/`SdtrigU` `mcontrol6_match_napot` images are 4.3 MiB
and do not fit the 4 MiB harness DRAM (they do not link; the harness DRAM
stays 4 MiB because widening it would change `MAP_ARCH` for every arch test).
`gen_suite.py` records them as `# excluded:` lines of the gate list
(`EXCLUDED`).

### On the new core (GA / GL-C)

`test/gates/mi_act.list` names every generated test with its repo-relative
image, the cycle budget (2M; a passing test stops at tohost) and the lockstep
flag. `run_act.py` writes `#[ignore]` wrappers `tb/test_<core>_act_<suite>.veryl`
(gitignored, deleted after the run) and runs them in batches of whole suites of
at most 400 tests (`--batch`): one `veryl test` process keeps every test it ran
in memory, about 90 MB each, and the 3,640 tests in one process ran the box
out of memory. GA needs tohost == 1 and clean checkers; GL-C compares each
test's final `H` line with `test/golden/act/<suite>.final`.

GL-C at this pin: the finals of the previous pin (keyed by the old suite names,
and different tests under the same names) were removed. Tests the golden model
cannot run carry `lockstep=0`, set by `gen_suite.py`: by suite and name pattern
(`GOLDEN_OFF_*`: every V suite, H and the Sh* suites, Sdtrig, Smstateen and
Ssstateen, and the H/V tests inside the Sm/S/U/Exceptions/Interrupts/Sv*
suites), by test for the 275 tests the golden model fails
(`golden_off.list`, found by running it), and by `SUITE_OPTS`/`TEST_OPTS` for
the suites and tests whose retire stream keeps timing or counter values that
differ between cores (Zicntr, Zkt, InterruptsS, Sstc, two Sscofpmf tests). The
other 720 tests are compared with `test/golden/act/<suite>.final`, made by
`test/golden/run_golden.py test/gates/mi_act.list` in the golden worktree.

## Framework version pin

`riscv/riscv-arch-test`'s default branch `act4` is the moving development tip
(no semver release tags, only rolling `ctp-release-*` tags), so a bare
`git clone` would drift: a clean rebuild could pull different test sources / Sail
signatures and shift the pass/fail counts. The `Makefile` therefore pins the
framework to an exact commit via `ACT_COMMIT` and a shallow fetch-by-sha
(`git init` + `fetch --depth 1 origin <sha>` + `checkout FETCH_HEAD`).

- **Pinned commit:** `8b9ddedcd44a2721dd9153efb4c64fc812090148` (`act4`,
  2026-11-05), the framework behind the status table below. The previous pin
  was `06568893` (2026-06-20); see the history section.
- **Bumping:** edit `ACT_COMMIT`, then `make -C test/act distclean` (removes the
  clone) and re-`make` to repin. `make` warns if an existing clone's `HEAD` does
  not match `ACT_COMMIT`.
- The binary tools (`sail_riscv_sim` **0.16**, `riscv64-unknown-elf-gcc` 16,
  `uv` **0.13.6**, the version the framework's `.mise.toml` names) are pinned by
  sha256 in `toolchain/versions.env`; the framework's Python (3.15, installed
  by uv into `toolchain/.uv-python`) and Ruby deps are pinned by its own
  `uv.lock` / `Gemfile.lock`. The UDB gem downloads solver binaries into
  `toolchain/.cache` (the Makefile sets `XDG_CACHE_HOME`/`XDG_DATA_HOME`).

## heliodor DUT config (`config/heliodor/`)

Rebuilt at this pin from the framework's `sail-RVA23S64` config (UDB yaml and
Sail 0.16 `sail.json`) with heliodor's deviations.

| file | purpose |
|------|---------|
| `heliodor.yaml` | UDB config: what the core implements. RV64GCV (Zve64d, Zvl128b, VLEN 128, ELEN 64) + H with Sha (Shcounterenw/Shgatpa/Shtvala/Shvsatpa/Shvstvala/Shvstvecd, Ssstateen), S/Sm 1.13, B (Zba/Zbb/Zbs), Smstateen/Ssstateen (SE0-3 and ENVCFG writable, CONTEXT read-only zero), Zabha/Zacas/Zawrs, Za64rs (and Za128rs, which UDB requires with it), Zic64b/Ziccamoa/Ziccif/Zicclsm/Ziccrse, Zkt, Sscofpmf, Sstc, Ssnpm/Smnpm/Smmpm/Supm (PMLEN 7 and 16), Svadu (both stages under H), Sdtrig (2 triggers, mcontrol6 + icount, breakpoint reentrancy by the interrupt enables, no tcontrol), and the RVA23.1 options Svrsw60t59b, Ssqosid (RCID and MCID 12 bits), Smcsrind/Sscsrind (mstateen0/hstateen0 CSRIND writable), Smcdeleg/Ssccfg and Ssdbltrp. Parameters: GEILEN 0, tinst always zero, `MEI_INTR_IMPL` false (the PLIC sources are harness pins), vector misaligned accesses trap, mcountinhibit reads zero, LR/SC reservation on the exact address, cbo.inval acts as a flush, medeleg[3] writable. Not declared yet: Zvbb/Zvkb, Zvfhmin, Zvkt |
| `sail.json` | the matching Sail reference config: 4 MiB RAM region, vector misaligned → alignment exception, `EV_FENCE` mapped to HPM event 5, Sdtrig `Use_interrupt_enables` with 2 triggers, B, Sha and the stateen bits above, Svrsw60t59b, Ssqosid (12-bit RCID and MCID, mstateen0.SRMCFG writable) and Ssdbltrp (Smdbltrp off). Sail 0.16 has no Smcsrind/Sscsrind or Smcdeleg/Ssccfg option; they are declared to UDB only. The simple interrupt generator, which ACT requires to build signatures, sits at 0x0D00_0000 (a hole on heliodor, never touched) |
| `rvmodel_macros.h` | HALT writes tohost then `fence.i`; MSIP/MTIME/MTIMECMP at the CLINT; access-fault address 0x5000_0000 (a hole); HPM counter 3 with event 5 (memory port busy) and a load as the event code; supervisor interrupts through mip |
| `link.ld` | the framework's linker script with RAM = the 4 MiB harness DRAM and `.tohost` pinned at **0x80001000** (`TOHOST_IDX = 1024`) |
| `test_config.yaml` | compiler / objdump / `sail_riscv_sim` / udb / linker (all resolved from PATH) |

The harness is `arch_soc_harness` (the new-core arm of
`test_arch_common_harness`): the SoC with `MAP_ARCH`, 4 MiB DRAM.

## Status at pin 8b9ddedc (MI step 3, 2026-11-06)

MI step 3 declared Svrsw60t59b, Ssqosid, Smcsrind/Sscsrind, Smcdeleg/Ssccfg
and Ssdbltrp. The pin has no suite of its own for any of them (the
`SscfgH`, `SscrindH` and `SsdbltrpH` testplans have no generator), so the
selection stays 3,652 tests (3,650 run). Declaring them adds cases to
existing tests: Sm `mcsr_walk` (mstatus.SDT under menvcfg.DTE), Sm `mcause`
(cause 16), Smstateen (srmcfg from every mode under mstateen0.SRMCFG; the
CSRIND bit is masked out of the comparisons), H `vscsr_ro` (scountinhibit
with menvcfg.CDE = 0) and Sv `nleaf_pte_reserved` (non-leaf bits 60:59).
With Ssdbltrp the shared H trap handler also clears vsstatus.SDT, so every
image changed: the 720 GL-C finals were regenerated from the golden worktree
at `4db557ab` (the golden model accepted all 720). The extensions are
checked by the directed probes `mi_svrsw`, `mi_dbltrp` and `mi_csrind` in
`test/gates/mi_probe.list`.

GA: **W2 2,504/3,650, W4 2,503/3,650**; GL-C: **720/720** on both. The one
change against step 2 is H `vucsr_00` (W2 and W4), which now fails: (a)
Sail 0.16 does not model Sscsrind, so its signature expects an illegal
instruction for a VU-mode access to siselect, sireg, vsiselect and vsireg,
where Sscsrind requires a virtual-instruction exception (mstateen0.CSRIND
is set by the framework's setup). Every other failure is the step 2 list.

## Status at pin 8b9ddedc (MI step 2, 2026-11-06)

3,652 tests are selected (MI step 2 declared B, Sha, Smstateen and Ssstateen:
the 10 Smstateen/Ssstateen tests are new; B adds no suite) and 3,650 are run
(the two napot tests are excluded, above). GA: **W2 2,505/3,650, W4
2,504/3,650**; GL-C: **720/720** on both. Changes against step 1 (W2 / W4
pass): Exceptions 27/27, S and U 17/17, Sm 49/50, H 45/45, Shcounterenw 1/1,
SdtrigS 53/52 of 54, SdtrigU 41/42, Svadu 6/6, Zawrs 3/3, Smstateen 5/5,
Ssstateen 5/5 (the breakpoint delegation, hcounteren, vstvec, hedeleg[19:18],
WRS.NTO and VS-stage Svadu failures are gone). The V suites are unchanged
(1,160/2,292 on both). Remaining non-V failures: `vector_mask` in
SdtrigS/SdtrigU/SdtrigSm (c: G13, vmv.s.x), `trigger_vsti_sstc` ×4 and Sstc
`vstip` ×2, SdtrigSm `mcontrol6_napot_allones`, Sm `mcsr_cntr` (b, open, as
in step 1), Zkt `c.subw`/`c.not` on W2 and `tselect_trigs` ×2 on W4 (a), and
on W4 InterruptsS `wfi_VS` (a: with the regenerated ELF the timer interrupt,
due `RVMODEL_TIMER_INT_SOON_DELAY` = 100 ticks after it is set, arrives during
the T-SBI return, before the test samples its trap count; W2 passes).

## Status at pin 8b9ddedc (MI step 1, 2026-11-06)

3,642 tests are selected for the heliodor config; 3,640 build (the two
`SdtrigS`/`SdtrigU` `mcontrol6_match_napot` tests are 4.3 MiB and do not fit the
4 MiB harness DRAM). On the new core, GA pass/fail: **W2 2,421/3,640, W4
2,421/3,640.** Every test that corresponds to a suite of the previous pin
passes on both (I, M, F, D, Zca/Zcd/Zcb, Zba/Zbb/Zbs, Zicsr, Zifencei,
Zicntr, Zihpm, Zicond, Zimop, Zcmop, Zihintntl/Zihintpause, Zfa, Zfhmin,
Zicbo*, Zmmul, Zicclsm (was Misalign*), Zaamo/Zalrsc/Zabha/Zacas, PMP (was
PMP*), Sv/Svade/Svadu/Svbare/Svinval/Svnapot/Svpbmt, and the non-H
Exceptions cases of the old ExceptionsSv*). 58 suites (956 tests) pass in
full on both, among them the new Sscofpmf, Ssnpm/Smnpm/Smmpm, Za64rs,
Zic64b, Zicc*, Shgatpa/Shtvala/Shvsatpa/Shvstvala/Shvstvecd and Vf64.

Failures by suite (W2 / W4 pass) and category: (a) config or harness, (b) a
core bug in claimed functionality, (c) implemented later in MI, (d) needs a
decision.

| suite | tests | W2 | W4 | failures |
|---|---|---|---|---|
| Exceptions | 27 | 16 | 16 | 11 (d): breakpoint delegation, see below |
| S, U | 17, 17 | 15, 15 | 15, 15 | 2 + 2 (d): breakpoint delegation |
| SdtrigS / SdtrigU | 54 / 42 | 29 / 19 | 28 / 19 | (d) breakpoint delegation (25 / 23); W4: `tselect_trigs` (a: W4 has 4 triggers, the ELFs are built for 2) |
| SdtrigSm | 61 | 59 | 58 | `mcontrol6_napot_allones`, `vector_mask` (b, open); W4 `tselect_trigs` (a) |
| Sm | 50 | 44 | 44 | hcounteren upper half ×2, vstvec WARL (c); medeleg[3] ×2 (d); `mcsr_cntr` writes CLINT mtime, read-only on heliodor (b, platform, open) |
| H, Shcounterenw | 45, 1 | 42, 0 | 42, 0 | hcounteren upper half, vstvec WARL (c) |
| InterruptsS / InterruptsSm | 26 / 35 | 23 / 34 | 23 / 34 | `trigger_vsti_sstc_*`: fewer VS timer interrupts than Sail (b, open) |
| Sstc | 8 | 6 | 6 | `vstip` with STCE and hvip.VSTIP set (b, open) |
| Svadu | 6 | 4 | 4 | the H cases need henvcfg.ADUE (VS-stage Svadu); M5 chose Svade for the VS-stage (d) |
| Zawrs | 3 | 1 | 1 | WRS in S/U never returns (c: the Zawrs TW item) |
| Zkt | 66 | 64 | 66 | the test checks that two runs take the same cycles; W2 differs by 1 cycle for `c.subw`/`c.not` (a: front-end timing noise, the data does not matter) |
| Vx8/16/32/64 | 831 | 686 | 686 | all G13 (c): vmv.s.x, vmv<nr>r, vmacc family, vwmacc family, vadc/vsbc/vmadc/vmsbc, vzext/vsext |
| Vls8/16/32/64 | 1,240 | 306 | 306 | 850 segment (c: EMUL > 1, strided, indexed, ff); 84 strided and indexed non-segment accesses whose EEW differs from SEW (b, open: the tail and the element geometry follow SEW instead of EEW) |
| Vf16, Vf32 | 6, 101 | 0, 99 | 0, 99 | SEW 16 integer/FP conversions (c); vfncvt.f.f.w overflow and rod (c: G14) |
| ExceptionsVx/Vls/Vf32/Vf64 | 43/1/1/1 | 3/0/0/0 | same | arithmetic with vstart != 0 restarts at element 0 (the declared limit G7, §V.10); 3 are G13 instructions trapping as illegal (c) |
| MisalignV | 2 | 0 | 0 | indexed segment (c: G13) |

Breakpoint delegation (d): the config declares Sdtrig with tcontrol
(`Use_tcontrol`, what `trig_unit` implements), and UDB and Sail tie that
option to medeleg[3] hard-wired to 0. heliodor keeps medeleg[3] writable (the
riscv-tests `rv64si` sbreak test and Linux delegate breakpoints to S), so
every test whose breakpoint Sail takes in M and relays to S sees the trap
taken directly in S.

Fixed while bumping (directed probes in `test/gates/mi_probe.list`): mstatus,
sstatus and vsstatus keep only the implemented fields (XS and the fields of
unimplemented extensions read 0); mie writes only the implemented interrupts
and hie/hip are views of mie/mip (mip.VSSIP aliases hvip.VSSIP); medeleg and
mseccfg write only implemented bits; vsepc bit 0 reads 0; vstart is 7 bits;
henvcfg.STCE/PBMTE read 0 while menvcfg's are 0; vsie has no LCOFIE;
scountovf in M ignores mcounteren; vstimecmp below M needs mcounteren.TM and
menvcfg.STCE; pointer masking is off while MXR is in effect; the vector .vi
shifts take a uimm5 (SEW 64); vrgather/vslidedown bound the index by VLMAX
at a fractional LMUL.

## History: pin 06568893 (2026-06, old core)

The sections below record the previous pin and the old core; suite names
are those of that pin.

### Status (2026-06-21)

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

### CBO PMP — PMPZicbo 4/4, SvPMPZicbo pa_zicbom fixed (6/8)

**`PMPZicbo` 4/4** (was 3/4) and **`SvPMPZicbo` 6/8** (was 4/8). cbo.zero is
already a store-class op (W-checked → cause 7), but cbo.clean/flush/inval were
bare no-ops and so never took a PMP access fault. The Sail reference faults them
on the **R-or-W** rule (cause 7 when the block has NEITHER read nor write
permission — distinct from cbo.zero's W-only), verified with
`sail_riscv_sim --trace-exception`. heliodor now decodes cbo.clean/flush/inval as
`is_cbo_m`: routed through the store AGU/MMU (for address plumbing + the paged
walk) with a forced zero store-strobe (writes nothing), then a dedicated
commit-time R-AND-W `pmp_check` pair raises cause 7. The dmem_mmu's W-only leaf
store fault is suppressed for cbo_m, but a PMP-denied **PTE read** on the walk
(`o_pte_acc_fault`) still faults it. Regression-safe (default 250/0, N1 boot 4/4;
Linux issues cbo.* and they now retire as zero-strobe stores).

> Remaining `SvPMPZicbo` 2/8 = `pte_zicbom` (Smode/Umode): three back-to-back
> `cbo.clean/flush/inval` to the same VA after an `sfence.vma` whose page-table
> PTE is PMP-denied. heliodor faults only the FIRST of the three (the
> `pte_zicboz` variant has just one `cbo.zero` per region and passes); the 2nd/3rd
> repeated faulting walk to the same VA does not re-fault. This is an MMU
> repeated-walk corner (independent of the cbo_m PMP path, which is correct — the
> first walk of every region faults right), not yet root-caused.

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
