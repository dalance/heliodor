# LSU Pipelining Plan (single-cycle load → 2-stage load)

Status: **design / not yet implemented.** Target session: a fresh context picks
this up and implements incrementally.

## 0. Goal & context

After the 2026-06-26 critical-path session the global CP is **26.24 ns**, and the
26 ns wall is dominated by the **single-cycle load datapath**:

| endpoint (top-60) | count | ns | meaning |
|---|---|---|---|
| `sh_load_poison` | 32 | 26.195 | single-cycle LSU (load replay/poison) |
| `load_viol_cnt`  | 15 | 25.675 | load-violation counter (LSU/mem-order) |
| `reg_r_exp`      | 13 | 26.240 | fp div/sqrt **seed** (secondary wall) |

LSU is 47/60 of the wall. All easy linear-scan wins are exhausted (LZC / mip-OR /
TLB-priority all tree-ized). To go below ~26 ns the load datapath must be split
into pipeline stages. This is **not** a bit-exact change: it raises load-use
latency (IPC↔Fmax trade-off) and re-times the memory-ordering machinery.

The synth load path (single combinational cone, head→…→sh_load_poison):
```
head → rob_head_idx → rob store-blocker scan (~7ns, tree-ized)
     → iq issue-select (tree-ized) → PRF read → AGU (rs1+imm, ~2.5ns)
     → dmem_mmu translate (bare=passthrough; TLB tree-ized) → PMP (~2.7ns)
     → dcache hit/SRAM read (~4ns incl. RAM) → store→load forward (~1.5ns)
     → alu_wrap format/sign-extend → alu_cdb (lane 0)   ← all ONE cycle
     → (mem-order) sh_load_poison / load_viol_cnt
```

## 1. Current single-cycle LSU architecture (grounded; file:line)

**Datapath (all combinational in the issue cycle).**
- Issue: memory ops live in the integer IQ `iq_int` (`heliodor_core.veryl:2697`),
  oldest-ready select, lane 0; loads gated by `blocked` (store-ordering /
  xlate-barrier / AMO-at-head) `iq_int.veryl:272-332`.
- PRF read combinational (`prf_int`), AGU = `prf_rs1_data + imm` at
  `heliodor_core.veryl:4251-4264` (`agu_addr_iss`). alu_wrap re-derives a parallel
  AGU for `o_cdb.store_addr` (`alu_wrap.veryl:189-204`).
- Translate: `u_dmem_mmu` (`heliodor_core.veryl:5966`). **Bare mode = wire
  passthrough** (`dmem_mmu.veryl:183,201`, `o_busy=0`); Sv39 = PTW FSM that
  **stalls issue** (multi-cycle via `o_busy`, not pipelined).
- dcache `u_dcache` (`heliodor_core.veryl:6206`): line-wide SRAM
  (`dcache.veryl:256-259`), **combinational hit read** `rd_dword`
  (`dcache.veryl:289-304,374-377`), `o_rdata` way-mux (`dcache.veryl:1417`);
  `o_stall` on miss (`dcache.veryl:1692`).
- Format/forward: `alu_wrap` has **zero `always_ff`** — `ld_shifted`→`ld_merged`
  (store-forward overlay)→`load_data_sel`→`o_cdb.data`, `o_cdb.valid =
  i_issue_valid` (`alu_wrap.veryl:214-256,416,421`). Load uses **CDB lane 0**
  (`alu_cdb`, merged at `heliodor_core.veryl:2160`).

**Wakeup is broadcast, NOT latency-scheduled (the key enabler).** iq_int snoops
the live CDB and sets `rs*_rdy` combinationally (`iq_int.veryl:457-468`, wired
`heliodor_core.veryl:2715-2717`). **There is no `LOAD_LATENCY` constant** — a
consumer issues the cycle after the actual broadcast. So delaying a load's CDB by
1 cycle "just works" for wakeup: the load broadcasts later, dependents wake later.
Mixed latencies (ALU=1, load=N) are already handled (the MSHR proves it).

**Existing multi-cycle load template = MSHR + `mshr_cdb` deferred fill.** On a
miss the load captures `{pdst, rob_idx, funct3, addr, has_rd}` into a 2-entry MSHR
(`heliodor_core.veryl:1473-1490`), **acks out of the IQ immediately**
(`iq_issue_ack || mshr_capture`, `heliodor_core.veryl:2380`), and re-injects the
result later onto the shared CDB via `mshr_cdb` (lane 0, priority FPU>MSHR>ALU,
`heliodor_core.veryl:6479-6644`). That CDB drives IQ-wakeup, PRF-write, and ROB
completion identically to a synchronous FU. **This is exactly the "issue now,
write back N cycles later" pattern the pipeline needs** — the LSR (below) is a
guaranteed-1-deep version of it. Hit-under-miss (`ld0_hum_ok`/`dc_hit_safe`,
`heliodor_core.veryl:6446-6457`) already lets younger loads complete during a
fill.

**Memory ordering (the hard part — all assume issue-cycle address+data).**
- Store→load forward: 2-layer per-byte combinational scan — ROB-resident stores
  (8 `always_comb`, 32 entries, `heliodor_core.veryl:4347-4543`) + committed
  store-buffer (4 entries, `:5654-5817`), using `agu_addr_iss`/`dmu_dmem_addr`,
  consumed in alu_wrap the same cycle (`:2189-2190`).
- Violation/poison: store-resolve scan (younger load aliasing older store,
  `rob.veryl:819-858`), VM record-time self-scan (`:871-924`), CoRR/invalidate
  scan (`:938-952`), MSHR abort poison (`:1409-1413`). All set `sh_load_poison`
  (`rob.veryl:442`); replay = **flush + re-fetch at commit**
  (`commit_load_replay`, `heliodor_core.veryl:4093-4099`).
- The load-bearing single-cycle assumption: the **"fold the same-cycle live
  record"** pattern (`rob.veryl:826-834,941-945`) — "its `sh_load_done` lands next
  edge, so a store resolving in the SAME cycle would miss it; fold it in here."
  This assumes the load's address is on the wire in its execute cycle.
- Store-ordering issue gate `load_blocks_on_store` (`heliodor_core.veryl:5167`)
  and the ROB block-store argmin (`rob.veryl:713-760`) gate load **issue**.

## 2. Why it's hard

The whole load (address + data + forward + ordering decision) lives in one
combinational cone. Splitting it means: (a) load-use latency 1→2 (IPC cost);
(b) two loads in flight (structural hazards on the dmem/dcache port and the CDB
writeback lane); (c) re-timing every memory-ordering mechanism that currently
reads the issue-cycle address and produces the issue-cycle data. (c) is the risk
— RVWMO correctness (litmus) and SMP coherence depend on it.

## 2.5 Phase 0 — extract the LSU into a module first (bit-exact prerequisite)

Today the LSU is **scattered across `heliodor_core.veryl` (7025 lines)** + the load
path inside `alu_wrap.veryl`. Pipelining it in place would be an error-prone,
hard-to-review edit across a huge file. **Do a behavior-preserving extraction into
a new `lsu` module first.** This separates "move code" (safe, byte-identical,
verifiable) from "change behavior" (the risky pipelining), localizes all future
LSU work, makes the Stage-A→B register an *internal* module boundary, and yields a
concrete architectural payoff (below).

**Proposed `lsu` module contents (move out of core / alu_wrap):**
- AGU (`agu_addr_iss`/`_iss2`, pm-mask) `heliodor_core.veryl:4251-4292`.
- dmem/dcache port arbitration (`core_dmem_vaddr`/`ren`/`wen` mux) `:5076` + deps.
- Store buffer (`sb_*`) `:687-710,5481-5817` (push/merge/pop/drain).
- Store→load forward **generation** (16 per-byte `always_comb`)
  `:4347-4543,5654-5817`.
- Store→load forward **consumption + load data format** — currently in
  `alu_wrap.veryl:209-256` (`ld_concat`→`ld_merged`→`load_data_sel`). Pull it out.
- MSHR (2 entries) + deferred-fill writeback (`mshr_cdb`) `:1473-1490,6384-6644`,
  replay/hit-under-miss `:6446-6513`.

**Stays put:** ROB-resident violation/poison scans (`rob.veryl` — they scan ROB
internals); IQ issue-select/wakeup (`iq_int`); commit logic; `dcache`/`dmem_mmu`
(already modules). The LSU↔ROB interface (`i_lq_rec_*` record, `mshr_*_poison`,
the store-shadow bus `ls_*`) is already defined — it becomes the module port list.

**Architectural payoff (not just organization):** today loads and ALU/AMO share
CDB **lane 0** because both live in `alu_wrap`. Pulling the load-format into `lsu`
gives loads their **own CDB lane** (`lsu_cdb`), arbitrated alongside
`fpu`/`mshr`/`alu`/`vu`. That directly resolves design point §7's lane-0 hazard:
the pipelined Stage-B load writeback is then a distinct lane from the Stage-A
ALU writeback — no contention to engineer later.

**Scope caveat:** the interface is wide (ROB store-shadow ≈ 32×~132 b, SB, dcache
handshake) — many ports, but well-defined wires (Veryl flattens them; same gates,
same synth). **AMO / LR-SC / Zacas** are serialized at head and entangled with
`alu_wrap`'s read-modify path — keep them on the **blocking (non-pipelined) path**
initially; only plain loads need the new lane / 2-stage fast path. Decide
up front whether AMO read-data moves into `lsu` or stays in `alu_wrap`.

**Verification (bit-exact):** this must be byte-identical. Gate it like the
heavier refactors — `default veryl test` 251/0 + `--backend-validate` + N1 boot 4/4
**cy-exact** + **litmus N2 (default) & N4** + **N2/N4 SMP boot** + Verilator SMP
cross-check (the dmem port + ordering are touched, so SMP/litmus are mandatory even
though no behavior should change). Commit Phase 0 on its own once green.

## 3. Proposed design — 2-stage load, cut after translate+PMP

(Implemented **inside** the `lsu` module from Phase 0.)

Balance analysis (≈26 ns cone): the front (issue-select ~7 + PRF/AGU ~2.5 +
translate + PMP ~3 ≈ **~12.5 ns**) and the back (dcache ~4 + forward ~1.5 +
format + poison ~2.7 ≈ **~13 ns**) split cleanly **after the physical address +
permission are known, before the cache access**. This is the classic
`AGU/TLB | cache/data` load pipeline.

```
Stage A (issue cycle):  iq select → PRF → AGU → translate → PMP
                        → produce paddr + fault + metadata
                        → LATCH into LSR (Load Stage Register); ACK out of IQ
Stage B (next cycle):   LSR.paddr → dcache access → store→load forward (LSR.paddr
                        + live ROB/SB) → format/sign-extend → re-inject on CDB
                        → IQ wakeup / PRF write / ROB complete  (load-use lat = 2)
```

**LSR (new, ~1-deep, mirrors an MSHR entry):** `{valid, paddr, pdst, rob_idx,
funct3, has_rd, fault, is_amo?, fwd-needed bits}`. Reuse the `mshr_cdb`
re-injection machinery (priority-arbitrated lane 0) for Stage-B writeback. On a
Stage-B miss, hand off to the existing MSHR (now captured from Stage B instead of
issue). Flush clears LSR.valid (like `s2_valid` in fpu_wrap).

**Why this is tractable despite the coupling:** broadcast wakeup needs no latency
table; the MSHR/`mshr_cdb` path already implements late writeback + IQ-ack-at-
capture + ROB completion; hit-under-miss already allows overlap. The new work is
the **memory-ordering re-timing**, detailed next.

## 4. Per-mechanism re-timing (the core of the work)

1. **Store→load forward** → moves to **Stage B**. Scan uses `LSR.paddr` +
   `LSR.age` against the **live** ROB store-shadow + SB (which advanced one cycle
   — still correct: stores older than the load stay older). Re-point the 16
   per-byte `always_comb` (`heliodor_core.veryl:4347-4543,5654-5817`) from
   `agu_addr_iss` to `LSR.paddr`; gate by `lsr_valid` instead of
   `iq_issue_valid`.
2. **LQ record** (load PA into ROB for violation detection) → record at **Stage B
   completion** (load has actually read), using `LSR.paddr`/`LSR.rob_idx`. Today
   it records at issue (`i_lq_rec_*`, `heliodor_core.veryl:3205-3208`). The ROB's
   `sh_load_done` already lands "next edge"; with a 2-stage load the record edge
   simply shifts by one — re-check the `rob.veryl:826-834,941-945` fold windows so
   a store resolving in the SAME cycle a load completes in Stage B is still folded.
3. **Store-resolve violation scan** (`rob.veryl:819-858`) → unchanged in logic,
   but the "same-cycle live load" inputs (`i_cdb2_is_load`, `i_lq_rec_*`) must now
   reflect the **Stage-B** completing load (registered paddr), not the issue-cycle
   load. Wire the scan's live-load ports from the Stage-B writeback, not Stage-A.
4. **Issue gate `load_blocks_on_store`** + ROB block argmin → stays at **Stage A
   (issue)**; a load still must not *issue* past an unresolved older store.
   Unchanged timing. (This keeps the conservative-ordering guarantee at issue.)
5. **dcache / dmem port arbitration** → Stage B owns the dcache **read** port;
   Stage A's translate owns the MMU (and, under Sv39, the PTW reads dcache — a
   real conflict with a Stage-B load wanting the same port). Extend the existing
   `core_dmem_vaddr` mux (`heliodor_core.veryl:5076`) priority:
   store-drive > PTW > Stage-B-load > (Stage-A is MMU-only). Under Sv39 PTW the
   load stalls in Stage A as today; the fast path is bare / TLB-hit.
6. **MSHR capture** → moves to **Stage B** (the miss is detected there now).
   `mshr_capture_own`/`que` (`heliodor_core.veryl:6384-6393`) re-source from the
   Stage-B load. The deferred-fill writeback (`mshr_cdb`) is unchanged.
7. **CDB writeback port** → Stage-B load competes with a Stage-A ALU op for lane
   0. Add the Stage-B load to the CDB arbitration (like `mshr_cdb`); on conflict
   either route ALU to slot-1 (`u_alu2`) or back-pressure the ALU issue. Resolve
   explicitly — this is a new structural hazard (today the load *is* the lane-0 op
   in its own cycle).
8. **Flush** → squash both Stage-A (in IQ, existing) and Stage-B (clear
   `lsr_valid`, like fpu_wrap `s2_valid` on `i_flush`).

## 5. IPC impact

- Load-use latency **1→2** for the common (hit) path: a dependent of a load
  issues 2 cycles after the load (was 1). Misses are already ≥ many cycles, so the
  MSHR path is unaffected. Expect a few-percent IPC drop on load-dependent code
  (Dhrystone/CoreMark load chains; boot is integer-heavy with moderate load-use).
- **No latency-table change** (broadcast wakeup) → no scheduler rework, and the
  pipeline naturally tolerates the +1.
- Measure with the microbenchmarks (`test_dhrystone`, `test_coremark`,
  `test_bench_*`) — IPC = instret/cycles, and with boot cycle counts (N1/N2/N4).
  Record the IPC delta against the Fmax gain to judge the trade-off.

## 6. Incremental steps + verification (memory ordering is NOT separable)

Memory ordering can't be half-pipelined, so the pipelining itself is one coherent
change verified in layers. But **Phase 0 (module extraction) is a separate,
bit-exact commit done first** (§2.5).

0. **Extract the `lsu` module (bit-exact, separate commit).** Move AGU / port-arb
   / SB / forward / load-format / MSHR into `lsu`; give loads their own `lsu_cdb`
   lane. Gate: `default` 251/0 + `--backend-validate` + N1 boot cy-exact + litmus
   N2/N4 + N2/N4 SMP + Verilator SMP. **Must be byte-identical** before any
   pipelining starts.

1. **Datapath split (single-hart hit path).** Add LSR + Stage-B writeback (reuse
   `mshr_cdb` template), move forward to Stage B, re-time LQ record. Gate: N1 boot
   (`test_soc_linux_boot` 4/4) + `default veryl test` 251/0 + ACT4 load/AMO
   (`rv64ua`, misalign) + `--backend-validate`.
2. **Miss / MSHR from Stage B.** Re-source MSHR capture; verify hit-under-miss
   and deferred fill still work. Gate: `test_dcache*`, N1 boot, microbenchmarks
   (record IPC).
3. **Memory ordering (the gate that matters).** Re-time violation/poison fold
   windows. Gate: **`test_litmus_2hart` (in default) + `test_litmus_4hart`
   (`--ignored`, ~10 min) — any forbidden outcome = ordering bug** + N2/N4 SMP
   boot (`test_soc_smp_linux_boot_2hart/4hart`) + Verilator SMP cross-check
   (NBA semantics catch what the Veryl sim masks; see CLAUDE.md).
4. **Fmax + IPC report.** `veryl synth --top heliodor_core --dump-timing`:
   confirm the LSU cluster drops to ~13 ns; the **fp div/sqrt seed (`reg_r_exp`,
   ~14 ns)** then becomes the limiter (see §8). Record boot cy deltas (IPC).

Each layer: `default` + `backend-validate` + N1 first, escalate to N2/N4/litmus
only when the lighter gates are green ([[feedback_regression_cadence]]).

## 7. Risks & open questions

- **RVWMO correctness** is the top risk — the fold-window re-timing
  (`rob.veryl:826-834,941-945`) is subtle. Litmus N=4 + Verilator SMP are the
  decisive gates. Budget time for $display-trace debugging of any forbidden hit.
- **CDB lane-0 structural hazard** (Stage-B load vs Stage-A ALU): **resolved by
  Phase 0** — giving loads their own `lsu_cdb` lane means Stage-B load writeback
  and Stage-A ALU writeback are already distinct lanes (just add `lsu_cdb` to the
  arbitration). No ALU back-pressure / slot-1 reroute needed.
- **Sv39 PTW vs Stage-B dcache port** conflict: confirm the arbitration never
  deadlocks (PTW stalls Stage A; Stage B drains first). The Sv39 path is already
  multi-cycle so correctness > speed here.
- **AMO / LR-SC / Zacas**: these are serialized at head today; keep them on the
  blocking (non-pipelined) path initially — only plain loads need the 2-stage
  fast path. Re-check `iss_dc_ok`/`load_blocks_on_store` gating.
- **2 loads in flight** vs the single committed-store-buffer overlap checks
  (`sb_ld_ovl`, `replay_sb_ovl`): verify both in-flight loads see consistent SB
  state.

## 8. After the load split: the fp div/sqrt seed (secondary wall)

Once the LSU cluster drops to ~13 ns, **`reg_r_exp` (~14 ns)** is the new #1: the
**fp_sqrt/divider seed setup** (`u_fp_sqrt`, the IDLE-state seed: unpack /
normalize / result-exp; the LZC there is already tree-ized — no hidden scan). It
is a multi-cycle FSM (29/30 cy), so a clean fix is to **add one seed pipeline
stage** (register the unpacked/normalized operand in IDLE, compute the result-exp
in the first RUN cycle): div/sqrt latency 29→30 (negligible IPC; div/sqrt are
rare and already multi-cycle), seed path halved. Apply symmetrically to
`fp_sqrt`, `fp_sqrt_s`, `fp_divider`, `fp_divider_s`. Do this **after** the LSU
(doing it first yields zero global-CP gain — LSU caps at 26.2). Gate: ACT4 F/D +
`test_fp_div_sqrt` + `--backend-validate` + N1 V-boot (drives vector div/sqrt).

Target after both: global CP ≈ **13–14 ns** (≈ another −47% from 26.24 ns).

## 9. Tooling recap (from the CP sessions)

- synth: `./veryl/target/release-verylup/veryl synth --top heliodor_core
  --dump-timing --timing-paths N` (~30 s; `--top <module>` to isolate). Diagnostics
  localize as `instance.signal`.
- Equivalence-test pattern for ordering changes without RVV toolchain:
  parallel-vs-serial testbench (see `tb/test_vmspre.veryl`) — but ordering needs
  litmus, not just unit equivalence.
- ⚠️ RVCP `$display` is space-separated → use `grep -a`. ⚠️ avoid `veryl fmt`
  whole-repo reformat (hand-format). ⚠️ commit to master, co-author +
  Claude-Session trailer.

## 10. Implementation log + grounded Phase-1 plan (2026-06-26)

### Phase 0 — DONE (commit `9fc2927`, byte-identical)

Extracted the plain-load datapath into `src/core/lsu.veryl` on its own CDB lane
(`lsu_cdb`). A slot-0 plain load (`is_load && !is_amo`) now drives `lsu_cdb`
instead of `alu_cdb` under the IDENTICAL issue gate: `u_alu` is gated off via
`!iss_is_plain_load`, `u_lsu` gated on by `iss_is_plain_load`. `lsu` reproduces
the old alu_wrap load `CdbBus` bit-for-bit. `lsu_cdb` sits at the same lane-0
priority (below `alu_cdb`, above `vu_cdb`) in three places that MUST stay in
sync: the `cdb` mux (`:2171`), `cdb_dest_is_fp` (`:2108`), `vu_cdb_free`
(`:2109`). `agu_addr_iss` was forward-declared (`:~1470`) so `u_lsu` reads it.
AMO/LR/SC/STORE stay on the `alu_wrap` blocking path. Gates all green: default
251/0, N1 boot cy-exact 4/4, backend-validate dcache+rv64u 152/0, litmus N4,
N2+N4 SMP boot.

### Phase 1 — grounded plan (the LSR is a guaranteed-1-deep MSHR)

**Key discovery: the existing MSHR+replay machinery IS a deferred-load-completion
pipeline, and the LSR mirrors it.** Today a missing load is captured into the
MSHR (`mshr_rec_addr = dmu_dmem_addr`, acked OUT of the IQ), the fill happens,
then `replay_drive` re-reads the dcache at a *registered* address (`replay_addr`,
dcache `i_addr` mux at `:6252`: `if replay_drive ? replay_addr : dmu_dmem_addr`)
and the load completes via the deferred `mshr_cdb` (lane-0, FPU>MSHR priority,
`:6655`). **The LSR is the same pattern but fires for EVERY plain load at a fixed
1-cycle latency** — so reuse the `replay_drive`/`mshr_cdb` templates directly.

Flow becomes `issue → LSR(Stage A) → dcache read(Stage B) → {hit: lsu_cdb,
miss: existing fill}`. The "dcache read → hit/miss" half is UNCHANGED; it just
reads the LSR's registered address instead of the issuing load's combinational
one.

**LSR registers** (declare near the MSHR regs `:1484`, mirror their field set):
`lsr_v_q`, `lsr_vaddr_q` (= `agu_addr_iss`, the VA — feeds lsu byte_off +
store_addr/LQ-record + the forward-gen compare vs store VAs), `lsr_paddr_q` (=
`dmu_dmem_addr`, the translated PA — feeds ONLY the dcache read), `lsr_pdst_q`,
`lsr_rob_idx_q`, `lsr_funct3_q`, `lsr_has_rd_q`, `lsr_fp_ld_q`, `lsr_pc_q` (CDB
redirect_pc=pc+4 parity), `lsr_rs2_q` (= `alu_rs2_data`, store_data parity),
`lsr_fault_page_q` (`dmem_mmu_fault`), `lsr_fault_acc_q` (`dmem_mmu_acc_fault`).
Keep VA and PA separate: dcache reads PA, everything else (byte_off[2:0] is
page-offset-preserved so VA==PA there, forward, LQ-record) uses VA — matching
today (forward gen `:4347` uses `agu_addr_iss` while the dcache reads
`dmu_dmem_addr`).

**Stage A (issue):** a plain load that passes the issue gates latches the above
into the LSR and ACKs OUT of the IQ (like `mshr_capture` folds into
`iq_issue_ack` at `:2421`). The MMU still translates (`dmu_dmem_addr`); the
dcache is NOT read this cycle — remove the issuing-load term from `core_dmem_ren`
(`:5273`) and drive the read from the LSR instead. Issue is additionally gated by
"LSR can accept" = `!lsr_v_q || lsr_drains_this_cycle`.

**Stage B:** `lsr_drive` (model on `replay_drive` `:6194`) drives dcache
`i_addr = lsr_paddr_q`, `i_ren=1` when the port is free (`!store_drive &&
dmem_mmu_idle`, same guard as replay). Re-point the 16 forward-gen `always_comb`
(`:4347-4543`) and `stld_fwd_en` from `agu_addr_iss`/`iq_iss_*` to
`lsr_vaddr_q`/`lsr_v_q`. `u_lsu` inputs switch from Stage-A combinational signals
to: `i_valid=lsr_v_q`, registered metadata, `i_agu_addr=lsr_vaddr_q`,
`i_load_data=dcache_rdata` (Stage-B read), `i_fwd_*`=Stage-B forward,
`i_dmem_fault*`=registered. Completion = `lsu_cdb` (already its own lane). On a
Stage-B miss the existing dcache fill machinery runs; **step-1 simplification:
the LSR BLOCKS on a miss** (holds, re-reads each cycle via `lsr_drive` driving
the fill, completes when `dc_hit_safe` after fill) — disable `mshr_plain_load`
(`:6426`) for now. Non-blocking (MSHR-from-Stage-B) is step 2.

**Step ordering (each layer must boot before the next):**
1. Datapath split + block-on-miss (above). Gate: default 251/0 (bare-mode loads),
   then N1 boot (Sv39). The forward/LR-SC/AMO/violation interactions all assume
   issue-cycle address — re-check each. AMO/LR/SC stay single-cycle in `alu_wrap`
   (NOT through the LSR); only plain loads pipeline. Their reservation
   (`rsv_pa_q=dmu_dmem_addr` `:4714`) and watch (`amo_watch_pa_q` `:4881`) stay
   Stage-A — fine, they don't use the LSR.
2. MSHR capture from Stage B (re-source `mshr_capture`/`mshr_rec_addr` from the
   LSR; re-enable non-blocking). Gate: `test_dcache*`, N1 boot, microbenchmarks.
3. Memory-ordering re-time (LQ record at Stage-B completion not issue
   `:3246`/`rob.veryl:1330`; the `rob.veryl:826-834,941-945` same-cycle fold
   windows shift by one — re-derive). Gate: litmus N2(default)+N4, N2/N4 SMP,
   Verilator SMP.
4. synth `--dump-timing`: confirm the LSU cluster drops to ~13 ns; record IPC
   (boot cy deltas — load-use latency 1→2 raises them a few %).

**Risks:** `dcache_stall`/`replay_q`/`fill_busy_q` (`:6527`) interaction with the
LSR-block; the store-buffer overlap checks (`sb_ld_ovl`, `replay_sb_ovl` `:6506`)
now see a Stage-B-old load; two-in-flight (LSR Stage-B + Stage-A translate) on the
dcache vs MMU/PTW port (plan §4.5 priority). Litmus N4 + Verilator SMP are the
decisive gates — budget `$display`-trace debugging.

### Phase 1 step-1 — refined implementation plan (2026-06-26, the concrete wiring)

The scaffold commit `e46ac07` declared the 12 LSR registers (above). This
subsection records the precise wiring decisions worked out before the datapath
rewire — points NOT in the conceptual plan above. **Read this before coding.**

**(1) The lane-0 structural hazard is solved by BLOCK-ON-ISSUE, not a separate
lane.** A Stage-B load (driving `lsu_cdb`) and a Stage-A slot-0 op (ALU/store/the
*next* plain load) would both want slot-0 resources in the same cycle. Step-1
resolves this the same way the MSHR does: **`!lsr_v_q` gates ALL slot-0 issue** —
`u_alu i_issue_valid`, the non-div/non-load branch of `iq_issue_ack`, and the
plain-load capture itself all stop while the LSR is occupied. This costs one
issue bubble per load (IPC hit) but is correct and simple. A dedicated
non-blocking lane (two loads truly overlapped) is **step-1.5**, deferred.

**(2) 🔑 Byproduct of block-on-issue: step-1 does NOT touch `rob.veryl` at all.**
Because block-on-issue serializes the Stage-B load against any slot-0 store, the
violation/fold windows (`rob.veryl:826-834,941-945`) keep seeing the Stage-B load
through CDB lane-0 exactly as they see today's single-cycle load — the live-load
record still arrives via the same `i_cdb*_is_load`/`i_lq_rec_*` ports, just one
cycle later, with the slot-0 store provably not co-issued. **The §4.2/§4.3/§10
"re-time the LQ record / fold windows" work belongs to step-3 (non-blocking),
not step-1.** This collapses the ordering risk of step-1 dramatically: the gates
that matter for step-1 are bare-load `default` + Sv39 N1 boot, not litmus.

**(3) Synth-wall reality (measured, recorded so we don't over-promise §8).**
Killing the LSU cone does NOT get global CP to the §8 "13–14 ns": with the LSU
path cut, the global critical path only relaxes to **~25.125 ns at
`redirect_pc_q`** (≈ −4% from 26.195). The §8 target is unreachable by the LSU
split alone — `redirect_pc_q` and the fp div/sqrt seed (`reg_r_exp` ~14 ns, now
secondary) are the next walls. Treat step-1's payoff as **architectural
groundwork + a few-percent CP**, not the headline −47%. Re-measure after the
rewire to confirm `redirect_pc_q` is the real new #1.

**(4) The concrete edit list (~11 sites).** All in `heliodor_core.veryl` unless
noted; line numbers are pre-rewire (`e46ac07`):
  1. **LSR regs:** add `lsr_unc_q` (uncached flag, `dmem_mmu`'s `o_uncached`
     latched) to the 12 scaffold fields — Stage B needs it for the dcache
     `i_uncached` arm.
  2. **Comb signals (new):** `lsr_accept = !lsr_v_q` (issue may capture);
     `lsr_fault = lsr_fault_pg_q || lsr_fault_acc_q`; `lsr_drive` (Stage-B dcache
     arm — model on `replay_drive` `:6194`); `lane0_hi_free` / `lsr_complete`
     (Stage-B writeback fires); `lsr_dc_load_next`; `lsr_capture` (Stage-A latch
     enable); `lsr_squashed` (flush, reuse MSHR squash logic).
  3. **LSR `always_ff`:** capture on `lsr_capture`, drain on `lsr_complete`,
     squash on flush (`lsr_squashed`).
  4. **`u_alu`:** gate `i_issue_valid` (and slot-0 issue arms) with `!lsr_v_q`
     (block-on-issue, point 1).
  5. **`u_lsu` inputs:** switch from Stage-A combinational signals to Stage-B —
     `i_valid=lsr_complete`, registered metadata (`lsr_*_q`),
     `i_agu_addr=lsr_vaddr_q`, `i_load_data=dcache_rdata`, Stage-B forward,
     `i_dmem_fault*=lsr_fault_*_q`.
  6. **`iq_issue_ack`:** branch a plain load into `lsr_capture` (acks OUT of the
     IQ at Stage A, like `mshr_capture` folds in at `:2421`).
  7. **Forward-gen retiming:** the 16 per-byte `always_comb` sf0..7
     (`:4347-4543`): `agu_addr_iss`→`lsr_vaddr_q`, `stld_fwd_en`→`lsr_v_q`,
     `age`→`lsr_rob_idx_q`. (The slot-1 `sg*` generators stay as-is.)
  8. **SB forward layer** (`:5654-5817`): same retime to `lsr_vaddr_q`.
  9. **`core_dmem_ren`** (`:5273`): the issuing-load read term → AMO-read only
     (`issue_is_load`→`issue_amo_read`); plain-load read now driven by `lsr_drive`.
 10. **`dcache` arm:** `i_addr`/`i_ren`/`i_load_next`/`i_uncached` muxed from the
     `lsr_drive` Stage-B drive (model on the `replay_drive` muxes at `:6252`).
 11. **`mshr_plain_load`** (`:6426`): disable for step-1 (LSR blocks on miss;
     non-blocking MSHR-from-Stage-B is step-2).

**(5) Gate order (escalate only on green, [[feedback_regression_cadence]]):**
build → `default` 251/0 (bare-mode loads, the first real signal) → N1 boot
(`test_soc_linux_boot`, exercises Sv39 translate + the port arbitration) → litmus
N2/N4 → N2/N4 SMP boot → Verilator SMP cross-check. Per point (2), step-1's
ordering surface is small, but the dmem port + SB overlap are touched, so the SMP
gates stay mandatory before declaring step-1 done.
