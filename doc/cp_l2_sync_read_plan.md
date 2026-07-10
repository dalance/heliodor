# CP/SRAM — L2 sync-read (goal-(b) SRAM realism: the shared L2 data array → a synchronous macro)

## 1. State / motivation (2026-07-09, user-chosen)

Deep-pipeline **goal (b)** = migrate to realistic ASIC SRAM (1RW/1R1W synchronous).
After the scalar-core CP levers were shown exhausted — front-end (shape-W / I$ decouple),
commit-store pre-translate, and the execute keystone are all **built-and-masked**, capped at
~13.7–14.1 ns; below 13.71 ns lies only R3 (the atomic-inclusive slow-store retire redesign,
SMP-critical) — the user chose to **continue goal (b)** over committing to R3
(`deep_pipeline_status_and_replan.md` §6/§6.2, `cp_retire_decouple_plan.md` §6.2).

**L2 is the target.** The shared L2 data array `data_0..3: logic<512>[512]` (l2cache.veryl:174)
= **4 × 512 × 512 b ≈ 1 Mbit of flip-flops** — the single largest fake-flop array in the design;
no real chip has L2 data as flops. It is:
- **independent** of the commit wall / R3 **and** of the gated front-end fronts (shape-W): the
  L2 read is a multi-cycle miss path (behind `mem_ctrl`), so its +1 lookup latency is absorbed
  by `mem_ctrl`'s accept FSM regardless of any core-side gating — a **standalone shippable flip**,
  unlike the predictor sync-read (btb/bht/ibtb), whose flip is only meaningful inside the gated
  decoupled-fetch bundle ("the synchronous SRAM read is the fetch-decouple bundle", btb.veryl:65).
- the **highest realism win** (biggest fake-flop array → real sync SRAM macro).

The arrays are already **SRAM-shaped**: "each way reads/writes a whole line through a single port
— the shape a line-wide SRAM macro infers as RAM" (l2cache.veryl:171). The only non-SRAM-ish
part is that the **lookup/copy c-port read is combinational** on `i_caddr`.

## 2. The read to make synchronous — the c-port lookup

`l2cache.veryl:216-260` — the lookup/copy port is fully combinational on `i_caddr` (→ `c_index`,
`c_tag`): `o_chit = any_ctm`, `o_cdata[l] = data_way[c_index][l*64+:64]`, plus the directory
verdict `o_c_sharers` / `o_c_owned`. `mem_ctrl` drives `o_l2_caddr`/`o_l2_cren` from the selected
slot and reads the verdict **the same cycle** — `lk_hit_ok = lk_v && !lk_cf && i_l2_chit &&
!i_l2_c_owned` (mem_ctrl:537), `lk_recall_req = … && i_l2_c_owned` (:554), and captures the line
`buf_q[l] = i_l2_cdata[l]` on accept (:382). A real sync SRAM returns the line **one cycle after**
the address → this migration **registers the c-port read** (chit/cdata/c_sharers/c_owned).

Write-side / directory-add stay same-cycle on the presented index: PLRU-on-`i_cren` and the
lookup-grant sharer add `i_cadd_v` (l2cache directory) act on the address presented **this** cycle;
only the READ-OUT is delayed. The =1 flip re-times the **consumer** (mem_ctrl), not the write-side.

## 3. Design — DEAD scaffold (P1), then FSM-absorb flip (P2)

Same proven pattern as `ICACHE_SYNC_READ` (icache.veryl:546-583) / `DCACHE_SYNC_READ`:
```
const L2_SYNC_READ: bit = 0;
let  o_chit_raw / o_cdata_raw[8] / o_c_sharers_raw / o_c_owned_raw = <the current combinational reads>;
var  o_chit_q / o_cdata_q[8] / o_c_sharers_q / o_c_owned_q;
always_ff { if_reset {…=0} else if L2_SYNC_READ { *_q = *_raw; } }   // reset-only at 0 → DCE
assign o_chit = if L2_SYNC_READ ? o_chit_q : o_chit_raw;  // == o_chit_raw at 0 → byte-identical
… (cdata/c_sharers/c_owned likewise)
```
At `=0`: port == `*_raw` (byte-identical); every `*_q` is written only under `else if L2_SYNC_READ`
→ reset-only → DCE (synth-neutral). At `=1`: the c-port read is a cycle late (a real sync SRAM).

## 4. The =1 flip (P2, functional) — mem_ctrl accept FSM +1

`mem_ctrl` presents `o_l2_caddr`(T) and must read `i_l2_chit`/`i_l2_cdata`/`i_l2_c_owned`(T+1):
split the accept into a LOOKUP-present cycle + a HIT/CAPTURE cycle (register the presented slot one
cycle), and shift the lookup-grant sharer-add (`i_cadd_v`) to T+1 (it is granted the cycle the hit
is decided). `HIT_WAIT` (the L2-latency model, ≥1, mem_ctrl:72) may **absorb** the +1 with no net
cycle cost. This is a shared-L2 timing change → the full SMP coherence ladder gates it.

## 4.1 ⚠️ REDESIGN (2026-07-09) — register ONLY the DATA, keep the directory combinational

The §4 "register the whole c-port read + settle-gate the consume" flip (P2 first attempt) **LIVELOCKED
litmus N2** (`cy=01c9c380 tohost=0 pass=0` timeout; both harts spinning at `pc=0x800007b8`, ret-count
advancing = no forbidden outcome, a coherence livelock). Root cause: registering the **directory**
(chit / sharers / owned) delayed the coherence verdict a cycle, skewing the **RFO sharer-invalidate**
and **recall** timing — a spin-release store's invalidate missed the spinner, so the release never
became visible. Splitting the directory read across cycles corrupts the MESI decisions.

**Correct design — the DATA array is the only SRAM; the directory stays flops.** Per
`sram_inventory.md`, the fake-flop target is the **data array** (`data_0..3`, 1 Mbit); the directory
(tags→chit, sharers, owned) is small associatively-read flop state a real chip keeps as flops.
So register **ONLY `o_cdata`** (sync SRAM), leave `o_chit`/`o_c_sharers`/`o_c_owned` **combinational** →
every coherence decision (hit / miss / recall / RFO-invalidate / sharer-add) is **timing-unchanged**.
The one consumer change: a hitting slot decides the hit combinationally in ST_LOOKUP (presenting
`line_q`), and the registered data line arrives the **next** cycle — so the `buf_q` capture moves from
ST_LOOKUP to the **first ST_HWAIT cycle** (`wcnt==0`). `HIT_WAIT` (≥1, the L2-access latency model)
already provides that cycle, and the captured value is the same LOOKUP-cycle combinational read → the
flip is **CYCLE-IDENTICAL and DATA-IDENTICAL to =0** (pure realism: the data read is now synchronous,
at zero IPC/coherence cost). l2cache registers `c_line_q`; mem_ctrl gates the capture-timing on its
mirror const (flip together).

## 5. Verification ladder

- **DEAD (=0) — byte-identical proof (P1, THIS step):** default `veryl test` **252/0** + N1 boot
  cy-exact + **N2 litmus + N2 SMP boot** cy-exact (a shared-L2 change touches SMP) + synth (SoC top
  `heliodor_soc_smp`: +regs area, CP unchanged; `heliodor_core` top unaffected — L2 is not in the
  single-core synth, `sram_inventory.md` scope note).
- **FLIP (=1) — full ladder (P2):** arch 252, litmus N2/N4, SMP boot N2/N4, Verilator N2/N4, IPC
  (L2-hit latency +1 may cost boot cy — measure vs the HIT_WAIT absorb).

## 6. Staging

- **P1 — DEAD scaffold:** register the c-port read (chit/cdata/c_sharers/c_owned), const-gated,
  byte-identical. ✅ **DONE (2026-07-09).** `l2cache.veryl:216` — the combinational reads renamed
  to `o_chit_raw`/`o_c_sharers_raw`/`o_c_owned_raw`/`c_line_raw` (data packed to one `logic<512>`),
  registered to `*_q`/`c_line_q` under `else if L2_SYNC_READ`, ports `? *_q : *_raw`.
  **Verify:** `veryl build` clean; **default `veryl test` 252/0** (incl. `test_litmus_2hart` N=2
  shared-L2 SMP litmus `cy=0022f150 pass=1`). Byte-identical by construction (=0 → port==`*_raw`,
  `*_q` reset-only → DCE, the established ICACHE/DCACHE_SYNC_READ idiom).
  **SoC synth baseline** (`--top heliodor_soc --dump-area`, =0): **26.340 ns** (`prio[5]→vrf[64]` —
  an arbitration/vector path, not L2), area 24.25 M um² (seq 3.833 M, mem 10.39 M). The L2 data array
  shows as **`512×512 2R2W ×4 = 1 Mbit, 4.25 M um²`** — the migration target; the scaffold regs DCE
  at =0 (synth-neutral). Remaining DEAD gates (expected byte-identical, cheap, run at/near the flip):
  N1 boot cy-exact, N2 SMP boot cy-exact.
- **P2 — flip (data-only, §4.1 redesign):** ✅ **DONE (2026-07-09).** l2cache registers ONLY the DATA
  (`c_line_q` → `o_cdata`), directory combinational; mem_ctrl moves the `buf_q` capture from ST_LOOKUP
  to the first ST_HWAIT cycle (const-gated, flip together). The first settle-gate attempt (register the
  whole c-port) livelocked litmus N2 → reverted; the data-only design is CYCLE-IDENTICAL.
  **Verify (=1):** `veryl build` clean; **default `veryl test` 252/0** (litmus N2 `cy=0022f150 pass=1`
  — **byte-for-byte the =0 cy**). **N1 boots** 5.15 `cy=00b7b740` / 7.1 `01217590` / 7.1V `013d8910` /
  6.6 `01402120` all pass=1 (5.15+6.6 **match the §19-icache-doc =0 refs exactly**). **N2 SMP boot**
  `cy=00fd24b0 pass=1` — **re-run at =0 gives the IDENTICAL `cy=00fd24b0` + identical mid-boot probe**
  (`cy=0098bd90 h0=…800d2ae6 h1=…8001ab30 ret0=005626ab`) → bit-for-bit **CYCLE-IDENTICAL** proof.
  **N4 SMP boot** `cy=015d6d20 pass=1` (r3=0xaa, 4-hart shared-L2). The +1 data-read latency is hidden
  by HIT_WAIT → **no IPC cost, no coherence change** (directory timing untouched).
  > Note: CLAUDE.md's SMP-boot cycle refs (N2 ~12.3M, N4 ~16.6M) are **stale** — current-master =0 is
  > N2 `0x00fd24b0` (16.6M) / N4 `0x015d6d20` (22.9M); the =0 re-run above confirms it's baseline drift,
  > not this change.
  **SoC synth (=1, `--top heliodor_soc`):** CP **26.340 ns UNCHANGED** (`prio→vrf`; L2 is not on the
  SoC critical path, so the read register is CP-neutral), area +0.1 % (24.277 M vs 24.252 M — the one
  512-b `c_line_q` output register in `seq`). The data array still lists `512×512 2R2W ×4` — veryl
  synth counts the array + output register separately; the RTL is now the canonical sync-SRAM read
  pattern (`c_line_q <= data[c_index]`) that a real SRAM compiler folds into a macro with an output
  register. The **synchronous read** (the "synchronous" of goal (b)) is done, cycle-identical + CP-neutral.
- **P3 — L2 data port reduction 2R2W → 1R1W** (the true single-port SRAM macro). Split into
  **P3.a** (write ports 2W→1W, ✅ DONE) + **P3.b** (read ports 2R→1R via R2-fold, ▶️ NEXT). See §8.

## 7. Anchors
- L2 lookup c-port (combinational read): `l2cache.veryl:216-260`.
- mem_ctrl same-cycle consume: `:484-554` (`lk_hit_ok`/`lk_recall_req`), `:382` (`buf_q` capture).
- Scaffold pattern: `icache.veryl:546-583` (`ICACHE_SYNC_READ`), `cp_dcache_sync_read_plan.md`.
- Inventory + order: `sram_inventory.md` (L2 = SoC-level Phase-C extension), `deep_pipeline_status_and_replan.md` §5 goal (b).

## 8. P3 spec — L2 data array 2R2W → 1R1W (the single-port SRAM macro)

**Entry state (post-P2, committed `555a3ef`, L2_SYNC_READ=1 default-on):** the data lookup read is
synchronous; the array still infers `512×512 2R2W ×4` because it has **4 accesses** (`l2cache.veryl`):
| port | access | index | line |
|---|---|---|---|
| **R1** lookup | `data_*[c_index]` → `c_line_raw`/`c_line_q` (sync) | `c_index` | 262–268 |
| **R2** write-hit merge read-old | `data_*[w_index][l*64+:64]` (o_w_line for the byte-merge) | `w_index` | 495–501 |
| **W1** write-hit merge | `data_*[w_index] = w_merged_line` | `w_index` | 692–698 |
| **W2** install (gathered DRAM line) | `data_*[in_index] = inst_line` | `in_index` | 721–739 |

**Target 1R1W = 1 read port + 1 write port.** The two writes (W1 merge, W2 install) are at
different indices; the two reads (R1 lookup, R2 merge-read-old) are genuinely concurrent at
different indices (`c_index` vs `w_index`). Split into P3.a (writes 2→1) + P3.b (reads 2→1).

### P3.a — write ports 2W→1W ✅ DONE (`c36cc2c` scaffold + flip)

Each bank `data_0..3` is a SEPARATE array → its OWN 1RW write port. Bank k's write MUXES
{install→`in_index`/`inst_line` if `install_way==k`, else merge→`w_index`/`w_merged_line`} into ONE
per-bank write statement (const-gated `L2_PORTS_1R1W`, `l2cache.veryl`). A different-bank
merge+install co-fire needs no arbitration (each bank writes its own port); the ONLY real contention
is the **SAME bank** (`w_tm_way == install_way`), where the **install YIELDS to the merge** via a new
`l2→mem_ctrl` signal `o_inst_port_busy` (folded into `inst_blocked` = hold+retry the install; the
merge writes, the install retries next cycle). `o_inst_port_busy` is computed WITHOUT `i_inst_v`
(from `install_way`, comb on the registered slot addr) so it does NOT close a comb loop through
`o_l2_inst_v`.

> ⚠️ First flip attempt vetoed the **bus write** via the SoC `wgrant_ok` gate on `l2_inst_v` — that
> DID form a combinational loop (`o_l2_inst_v` depends on the bus write through mem_ctrl, so gating
> the write grant on it loops). The install-yields design (write→install dependency) does not loop.

**DEAD at =0 (byte-identical):** the muxed block DCEs, the original two writes stand,
`o_inst_port_busy=0`. **Flip =1:** array infers `512×512 2R1W ×4` (was 2R2W). **Full ladder (=1):**
default 252/0 (litmus N2 `cy=0022f150` exact); SoC synth CP **26.340 ns unchanged** (L2 off the
critical path); N1 boots 4/4 **cy-EXACT** (`00b7b740`/`01217590`/`013d8910`/`01402120` — zero IPC);
litmus N4 `cy=00535020` pass=1 (RVWMO exact); N2 SMP boot `cy=00fd24b0` pass=1 (net cy-exact — the
mid-boot probe interleaving shifts, the install-yield IS a real functional change, but the
barrier-synchronized boot converges to the same total cycle); N4 SMP boot `cy=01450320` pass=1
(clean shutdown `r3=0xaa`; was `cy=015d6d20`=22.9M at =0 → 21.3M, **−1.6M/−7%**: the install-yield
reorders same-bank L2 install-vs-store, shifting the non-barrier-deterministic N4-boot interleaving —
here FAVORABLY. A lost install would never reach clean SBI shutdown, so this is valid rescheduling,
not dropped work). **Effectively FREE** (write ports halved, +0 CP, ≤0 IPC) → flipped **default-on**.

### P3.b — read ports 2R→1R (R2-fold) — ⚠️ SCAFFOLD DONE, FLIP BLOCKED (2 findings)

**Scaffold ✅ (`ea0e823`, DEAD byte-identical, const `L2_READ_1R1W`).** Design = **atomic accept,
no stale-read window**: a requested partial write-hit whose old line is not yet in `c_line_q` HOLDS
the grant (SoC `wgrant_ok && !l2_w_spec_hold`, `l2_w_spec_hold = wv_req_on && o_w_hit &&
!o_w_spec_ready`). l2cache speculatively reads the store's `w_index` on a **free** read-port cycle
(`!i_cren` = mem_ctrl not looking up → the lookup's `c_line_q` timeline is undisturbed, **no
mem_ctrl change**); the next cycle the old line is in `c_line_q` and the store is granted → directory
+ merged data write the SAME cycle (atomic). `write_merged` sources `w_lold` from `c_line_q` at =1.
Two comb loops fixed: (a) the SoC hold uses RAW l2 pieces (`o_w_hit`/`o_w_spec_ready`) not a bundled
output; (b) `o_w_hit` must NOT use `i_wstrb_hi` (grant-gated at the SoC via `bus_wgrant[h]`).
Byte-identical at =0: default 252/0, synth 2R1W CP-neutral, N1 boots + N2 SMP boot cy-exact.

**🚨 FLIP (=1) BLOCKED — two problems (2026-07-10):**
1. **litmus N2 LIVELOCK** (`cy=01c9c380 tohost=0 pass=0` timeout — same signature as the P2 first
   attempt). A coherence bug in the 2-cycle store. Prime suspect: an **install to the store's
   `w_index` during the hold** (before the atomic accept). The spec-read at cycle M reads the OLD
   line; if an install writes `w_index` at M's edge, the merge at M+1 (old + store dword) clobbers
   the install. mem_ctrl's install-suppress is by the *granted* write, but during the hold the store
   is NOT yet granted → the install is not suppressed. Need to suppress installs (or re-spec-read)
   against the SELECTED (pre-grant) write line, or make the busy/held line block installs. Other
   suspects: recall/WB interaction with the held store; the spec-read stealing a cycle a spinner needs.
2. **synth shows `512×512 3R1W ×4`, NOT 1R1W** — the fold *added* read ports. The muxed read
   (`c_line_raw = if L2_READ_1R1W ? way-mux(data_*[rd_index]) : ctm-chain(data_*[c_index])`) does NOT
   collapse to 1 read port in veryl synth: at =1 the `rd_index` runtime mux reads at BOTH `w_index`
   and `c_index`, AND the untaken ternary branches' reads (ctm `c_index`, `write_merged`'s
   combinational `w_index`) are **not DCE'd for port inference**. Contrast P3.a's WRITE fold, which
   DID collapse 2W→1W — because it used a **separate `if L2_PORTS_1R1W { muxed write } / if
   !… { original writes }` block** (untaken block fully DCEs), not a `? :` ternary over two read
   expressions. **Fix direction:** restructure the read like P3.a's write — a single `if
   L2_READ_1R1W { c_line_q <= data_k[rd_index] } else { … original ctm read }`-style split so the
   =1 path has exactly ONE read index net per bank and the =0 reads DCE at =1; verify with
   `--dump-area` that it reports `1R1W` before chasing the livelock.

**Order for the next session:** (i) fix the port structure first (get `--dump-area` to `1R1W` at =1,
still byte-id at =0), THEN (ii) debug the livelock (install-vs-held-store race) with the litmus N2
$display trace. The scaffold is committed at =0 (byte-id, safe); the flip const is the only change.
The hard part is the same class as dcache §12.3's read-port arbitration (SMP-critical). IPC (the
store 2-cycle RMW throttle) is measured after the flip is coherence-clean.

**Note (tags):** L2 tags (`512×49 5R1W`) + the directory (sharers/owned) stay flops — a real chip
keeps the coherence directory associatively-read (registering it livelocks, §4.1). P3 is DATA-only.
