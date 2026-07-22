# D$ tag realistic-SRAM via REPLICATION — Phase 13 tag close-out

User decision (2026-07-22): finish the realistic-SRAM migration's last front — the D$ **tag**
array — by **replication** (the predictor method: one SRAM copy per concurrent read port, every
write applied identically to all copies → **byte-identical**), NOT the §15.5-S2 arbitration grind.
Rationale: §15.5-S2 is the SMP-critical finale (register the live hit + stall) that moves no
area/CP and lands only at a non-strict 2–4R1W; replication reaches "real 1R1W macros" byte-
identically (no coherence risk, IPC-neutral), at an area cost the small tag array can absorb.
See `cp_dcache_sync_read_plan.md §15` (the arbitration path) and `sram_inventory.md`.

## Goal

Turn the tag/valid/dirty/excl array (`64×52 ×4 ways`, currently **13R1W** after §15.5-S1) into a
set of **true 1R1W macros** — one per genuinely-concurrent read port — each with a single read and
a single (replicated) write. The 4 ways stay 4 banks (capacity split, not a port).

## Concurrent-read analysis (what forces a copy)

A copy is needed for every read that can fire **the same cycle at a different index** as demand.
From `cp_dcache_sync_read_plan.md §15.1` (the 15 read-index nets), re-checked against the RTL:

- **demand** (`index`, live) — every IDLE access; gates o_hit/o_stall + miss/AMO/store.
- **misaligned hi-line** (`next_index = index+8`) — same cycle as demand on a cross-line access.
- **store-drain** (`sindex`) — `i_swen` is a distinct port from `i_ren`; can co-fire with demand.
- **presence-watch** (`chk_index`/`chk2_index`/`chk3_index`, `:2729–2755`) — the core queries the
  LR/SC/AMO reservation set every cycle at **three** independent addresses → **three** copies.
  This is the dominant area cost (§15.4's "hardest").
- **snoop / maintenance** (probe `p_index`, inv `inv_index`/`inv2_index`, flush `fl_set`, victim
  `f_index`) — the FSM processes coherence events serially; a mid-fill probe is **pinned/deferred**
  (`:1122`), flush is a dedicated walk state, victim reads only during a fill (demand stalled).
  These **time-share ONE copy** (a snoop/maint duplicate-tag), the exclusivity verified per-fold.

slot-1 (`index2`/`next_index2`) is best-effort **denied** (`S3_SLOT1=1`, `o_hit2=0`) so its tag
reads are already DCE'd (§15.3) → no copy today; a copy re-appears if dual-issue btb-load is restored.

## Copy assignment (tag = 7 × 1R1W macros/way)

| copy | read index | consumers |
|---|---|---|
| **C0 demand** | `index` (live) | o_hit/o_stall, hit_way/excl/dirty, miss/AMO/store, plain-load |
| **C1 load-hi** | `next_index` | misaligned cross-line hit + hi-line dirty |
| **C2 store** | `sindex` | store-drain merge / evict |
| **C3 presence** | `chk_index` | o_chk_present |
| **C4 presence** | `chk2_index` | o_chk2_present |
| **C5 presence** | `chk3_index` | o_chk3_present |
| **C6 snoop/maint** | probe / inv / flush / victim (time-shared) | probe_depart, invalidate, flush-WB, fill-victim WB |

Area ≈ 13.3 Kbit/copy × 7 ≈ **93 Kbit** (cf. data 1R1W ≈ 131 Kbit — same order, acceptable).

## Writes — replicated to ALL copies (this is what makes it byte-identical)

Every tag/valid/dirty/excl mutation is applied identically to C0…C6. Write sites (to enumerate in
RTL and mirror): **fill** (victim way ← new tag/valid), **invalidate** (remote-inv way clear),
**store-dirty** (hit way dirty set), **drain-merge** (dirty/excl bookkeeping), **flush-clear**
(fl_set way clear), **excl** update (AMO/store E/M). Because all copies see the same writes, every
copy holds identical contents → each copy's read equals the original single-array read. Byte-identical.

## Two confirmed design decisions (user, 2026-07-22)

1. **Revert S1** (`DCACHE_TAG_READ_1R=0`): drop the registered-demand tag stage; demand reads live
   `index` as ONE copy (C0). The deep-pipeline registered-demand *stage* is a separate axis, not part
   of the replication realism goal. (`§15.5-S1` documents `=0` is byte-identical, 252/0.)
2. **presence-watch = 3 copies for now** (C3/C4/C5, byte-identical, certain). A future area
   optimization holds the reservation address in a dcache flop and updates a present-bit on
   fill/inv/evict events (real-chip style → tag read removed, 7→4 copies) — correctness-critical
   (LR/SC/AMO atomicity), deferred to a separate stage.

## Staged implementation (campaign methodology: DEAD scaffold → flip → full gate)

1. **S1 revert** — set `DCACHE_TAG_READ_1R=0`; fast gate (252/0) confirms byte-identical live-demand.
2. **Replication scaffold** — `const DCACHE_TAG_REPLICATE` (DEAD at 0). Declare per-copy arrays,
   mirror every tag write into all copies, route each read group to its copy. At 0 the copies are
   reset-only → DCE (byte-identical). Per-copy bisect consts (`TREP_C1..C6`) like the data folds
   (`§14` `S1_DEMAND`/…) so a coherence miss pins to one copy.
3. **Flip =1 + `--dump-area`** — confirm each copy infers as a `64×52 1R1W` macro (7 macros/way).
4. **Full slow gate** — tag is coherence-critical: `veryl test` 252/0 · litmus N2/N4 (no forbidden) ·
   ACT4 696/0 · N1/N2/N4 SMP Linux boot · **Verilator** N1/N2 (byte-identical cy expected, since
   replication is cycle-identical). A silent stale-tag/stale-presence bug is the risk the gate covers.
5. **Bookkeeping** — update `sram_inventory.md` (tag → 7×1R1W) and `pipeline_knob_registry.md`;
   then the D$ tag realism is DONE → re-close Phase 13 (tag no longer 13R1W multi-port).

## Method verification result + submodule design (2026-07-22)

**2D array is OUT**: `veryl synth` rejects a dynamic multi-dim index
(`unsupported construct: dynamic multi-dim index on variable`). Replication must
use separate 1D arrays. User chose **submodule + generate-for** over hand-written
copies (write logic once, instance-per-copy, cleanest realism).

### `dcache_tagbank` submodule — TAG storage for ONE copy (4 ways)
**TAG ONLY.** `valid/dirty/excl` stay flops in the parent — they are read associatively
every cycle AND a misaligned store clears two sets of the same way in one cycle
(`valid_k[index]`+`valid_k[next_index]`), which no 1W SRAM serves (sram_inventory.md
§Refinement). Only the tag maps to 1R1W (written on FILL only: one way/index per cycle).
Ports:
- **write (per-way FILL, parent-resolved, broadcast identically to every instance)**:
  per way k∈0..3 — `i_t_we_k/i_t_idx_k/i_t_val_k`. Tags unreset (valid flop gates them).
- **read (per-instance)**: `i_ridx` → `o_tag_0..3`.

Each instance infers one `64×TAG_W 1R1W` macro/way (the realistic SRAM). generate-for
instantiates the copies, each with its own `i_ridx`; all share the broadcast fill write.
hit = `valid_flop_k[ridx] && o_tag_k == tag` (valid from the shared flop, tag from the copy).

### Parent (dcache) role
- Feed each copy's read index: C0=`index`, C1=`next_index`, C2=`sindex`,
  C3/4/5=`chk/chk2/chk3_index`, C6=snoop-mux(`p_index`/`inv_index`/`fl_set`/`f_index`).
- Compute hit/way/dirty/excl from the **C0 instance's** read outputs — the existing
  consumers (`hit_0..3`, `cache_hit`, `hit_way`, `hit_dirty`, `vic_tag`…) just source
  from `o_*` instead of the inline arrays.
- Resolve the **per-way write** we/idx/val from the current always_ff and broadcast
  to all instances. This is the byte-id-critical transcription.

### Tag write source (per-way) — FILL ONLY
The tag is written on fill only (`:1647` `tags_k[fill_index]=fill_tag`, way=`fill_way`).
The parent drives each instance's `i_t_we_k/i_t_idx_k/i_t_val_k` from that fill:
`we_k = <fill tag-write condition> && fill_way==k`, `idx=fill_index`, `val=fill_tag`. ALL
the valid/dirty/excl writes (misalign / drain / probe / flush / inv / inv2 / store-dirty)
stay in the parent's existing always_ff on the FLOP arrays — UNCHANGED. This makes the
write-mirror trivial (one fill write), and the byte-id risk drops to just the tag-read
rerouting (hit compares now source `o_tag_k` from the copy, valid still from the flop).

### Staged
1. Define `dcache_tagbank`; instantiate ONE (C0) in-place, route existing reads
   (via `o_*`) + writes (per-way we/idx/val) through it. Fast gate + `--dump-area`
   (1 macro/way, byte-id, `cy=00236680` litmus N2 baseline).
2. Add C1..C6 via generate-for (per-instance ridx); route each rare read
   (next/store/chk/probe/inv/flush) to its copy's `o_*`. Fast gate per copy.
3. `--dump-area` (7 macros/way). Full slow gate (litmus N4 + SMP + Verilator).

## ✅ IMPLEMENTED (2026-07-22) — all D$ tags are 1R1W SRAM macros, byte-identical

The demand tag stays in-module (`tags_0..3`, now demand `index` read + fill write = **1R1W**);
every OTHER tag read moved to its own `dcache_tagbank` instance (fill write broadcast via
`ftwe_*`, defined once near the fill vars). Copies:
- **C0** (in-module `tags_0..3`) `index` — demand Stage-B hit
- **C0b** `index_r` — demand Stage-A hit (S1 reverted → live)
- **C1** `next_index` — misaligned hi-line ; **C2** `sindex` — store-drain
- **C3/C4/C5** `chk/chk2/chk3` — presence-watch
- **C6a** `f_index_raw` (victim select) ; **C6b** `f_index` (victim capture)
- **C6c** `p_index` (probe) ; **C6d** `fl_set` (flush) ; **C6e** `inv_index` ; **C6f** `inv2_index`

`--dump-area`: tag **`64×52 1R1W ×52`** (13 copies × 4 way) + data `64×512 1R1W ×4`. The
`13R1W` multi-port tag is GONE — every tag read is a real 1R1W macro. **Byte-identical** at each
incremental step: `veryl test` **252/0**, litmus N2 `cy=00236680` (baseline exact) after C3, after
+C0b/C1/C2/C4/C5, and after +C6a-f. valid/dirty/excl untouched (flops).

**Full slow gate ✅ PASSED (2026-07-22):** litmus N2 `00236680` / N4 `00537730` (pass=1, no forbidden),
SMP N2 boot `010f4d20` / N4 boot `01647200` (pass=1, r3=0xAA), **Verilator N1 + N2 PASSED** (SBI
shutdown, x3==0xAA — independent SV-NBA ground truth, single- and multi-hart). tag replication is
byte-identical AND coherence-correct on both the Veryl sim and Verilator.

### Area note / future optimization
13 tag copies (52 macros, 173 Kbit) is area-heavy vs a real dual-tag scheme (2–3 banks). The
copies are byte-identical replicas; a follow-on can merge EXCLUSIVE readers — victim (`f_index*`)
and flush (`fl_set`) fire during a demand stall, probe/inv are the coherence port — into a
real-chip **dual-tag** (CPU port + snoop port) via a small arbiter. Per-fold exclusivity proof +
full gate, area-only (no CP/byte-id change). Not this stage.

## Future (not this stage)
- presence-watch reservation-flop (decision 2) → 7→4 copies.
- way-packing (`64×208 ×1` vs `64×52 ×4`) is a macro-shape choice, orthogonal to port count.
- L2 tag replication (same method, at the SoC level) + `L2_READ_1R1W` flip + icache sync — the
  remaining realism fronts after D$ tag.
