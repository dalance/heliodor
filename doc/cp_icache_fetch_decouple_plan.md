# CP / SRAM — icache sync-read + fetch decouple (the front-end functional flip)

The last un-flipped front-end SRAM step: make the **icache demand read synchronous**
(a realistic 1RW/1R1W macro) by decoupling the fetch address generation from the fetch
data consumption. Goal (b) SRAM-realism + the FINAL front-end pipeline structure
(status §5.1: "fetch is combinational on the icache read" is the one remaining front-end
architectural wall). Lower SMP risk than the dcache flip (per-hart, in-order front end, no
coherence/atomicity) but a WIDE surface (fetch / RVC / straddle / branch-predict / dual-issue).

## 1. State (2026-07-07)
- **`ICACHE_SYNC_READ` DEAD scaffold EXISTS** (`icache.veryl:556`, `const = 0`): registers the four
  CPU-side outputs `o_rdata` / `o_rdata_next` / `o_rdata_next_valid` / `o_stall` via
  rename-to-`*_raw` + reset-only `*_q` + `assign o_* = ICACHE_SYNC_READ ? *_q : *_raw`. Byte-identical
  at 0, synth-CP-neutral (regs DCE'd). Built Phase D (`cp_frontend_pipeline_plan.md §6`).
- **FF-insertion measured (Phase D §6):** at `=1` the whole front end (`pc_q → rs1_rdy`, 14.565)
  leaves the global CP (drops to 14.130, back-end-bound) — the icache read is masked; the flip's
  value is goal (b) + structure, not CP (CP won't move until the back-end wall < ~7 ns).
- **Flip is NON-functional (measured 2026-07-07):** `ICACHE_SYNC_READ=1` → default suite **21/231**
  (nearly all fail). The fetch loop is combinational on the read, so a +1 read latency breaks it
  wholesale. This plan is the functional-flip work.

## 2. The problem: the +1 icache read latency
Today the fetch is a single combinational sweep:
`pc_q → imem_mmu (translate) → icache read → icache_rdata → {RVC-expand, straddle, branch-predict,
dual-issue slot-1} → fetched_instr → FB push`, and `pc_q` advances the same cycle
(`pc_q = pred_next_pc_bp`, `core.veryl:1126`).

With `ICACHE_SYNC_READ=1`, `icache_rdata` at cycle N is the read of the address presented at **N−1**.
But every consumer reads the **current** `pc_q` (branch predict `pc_q[13:1]^spec_ghr`, straddle
`pc_q[1]`, `curr_hw = pc_q[1]?rdata[31:16]:rdata[15:0]`, `pc_advance` from `curr_is_rvc`). So the
instruction bytes (for N−1's pc) are combined with N's pc metadata = wholesale corruption.

## 3. Why it is intricate — the RVC coupling (the key design constraint)
A decoupled fetch normally advances the fetch PC speculatively while the read is in flight. But RV**C**
makes the instruction **length** (2 vs 4 bytes) unknown until the bytes are read — and `pc_advance`
(hence the next fetch PC) depends on `curr_is_rvc`. Plus:
- **straddle** — a 32-bit instr at a halfword boundary (`pc_q[1] && !curr_is_rvc`) spans two words /
  possibly two lines; today resolved in 1–2 cycles reading `{icache_rdata_next, icache_rdata}`.
- **dual-issue slot-1** — extracted from the same 64-bit `{next, cur}` window.
- **branch prediction** — BTB/BHT/TAGE/RAS/iBTB all look up on `pc_q` combinationally to steer the
  next fetch with no bubble.
So the fetch address, the length decode, the straddle window, and the predictor all currently share
the single combinational cycle. Splitting the read out means auditing **which of these needs the
address-being-read (the new speculative fetch PC) vs the address-whose-data-arrives (delayed)**.

## 4. Design: decoupled fetch (pc_present vs pc_data)
Two fetch stages around the registered read:
- **F0 (address) — cycle N:** present `pc_present` (today's `pc_q`) to imem_mmu + icache
  (`index = paddr`). The **predictor** runs here on `pc_present` (BTB/BHT/… are address-only lookups,
  independent of the icache bytes) → produce the *predicted* next fetch address. `pc_present` advances
  to it next cycle (streaming).
- **F1 (data) — cycle N+1:** `icache_rdata` is valid for the address that was `pc_present` at N; a
  register `pc_data_q` (+ the predictor outputs, straddle state, fault bits registered alongside)
  carries that address. The **RVC-expand / straddle-combine / dual-issue-extract / FB push** run here
  on `pc_data_q` + `icache_rdata`.
- The **RVC-length correction:** F0's speculative advance must guess the length before the bytes are
  known. Two shapes (the decision to make):
  - **(S) Streaming with length-correct bubble** — F0 advances by a *guess* (e.g. +4, or a
    length-predictor / BTB-fallthrough), F1 checks the real `curr_is_rvc`/straddle and, on a
    mismatch, re-steers `pc_present` (a 1-cycle bubble). Cost ≈ a bubble on each RVC/straddle
    boundary mis-guess; a per-line length-mark or a 2-wide predecode keeps it low. Lowest IPC, most
    logic.
  - **(N) Non-streaming, 1 group / 2 cycles** — F0 presents, F1 delivers, then F0 presents the next
    (address known post-decode). Simple, provably correct, but ~halves fetch bandwidth (bubble every
    group). The FB (fetch buffer) hides it only while the back-end is not fetch-starved.
  **Recommended: start with (N)** (simplest-correct, lands the SRAM realism + the pipeline stage with
  a known IPC hit), measure the IPC, then optimise toward (S) if the hit exceeds budget. This mirrors
  the campaign's "correct first, then tighten" (the dcache flip's cluster-by-cluster path).

  **✅ DECISION (2026-07-07, user-selected): shape (N), correct-first.** Note the sequential bandwidth
  cost is real (not just taken-branch): the next fetch address needs the just-read instruction's RVC
  length, which is only known at F1, so the next address cannot be *presented* during the F1 cycle —
  a `present → deliver` gap of one cycle per group (≈ ½ fetch bandwidth on a run of sequential ops),
  hidden by the FB only while the back end is not fetch-starved. That is exactly what shape (S)'s
  length-guess removes; measure the (N) IPC hit before investing in (S).

## 5. Corners (the functional flip — full ladder at each)
1. **Branch-redirect / early-redirect restart** (`redirect_fire`/`early_redir_fire_q`, `:1095-1104`):
   on a flush `pc_present = redirect_pc` and the in-flight F1 (wrong-path bytes) must be squashed —
   a +1 fetch-restart bubble (the "first real IPC cost", `cp_frontend_pipeline_plan.md §3`).
2. **Straddle** (`straddle_q`/`straddle_low_q`, `:581`,`:1119`): the 2-cycle straddle now layers on
   top of the +1 read latency — re-time the high-half capture to F1.
3. **FB push timing** (`fb_push0/1`, `:1154`): push in F1 with `pc_data_q`, not `pc_q`.
4. **Dual-issue slot-1** (`s1_*`, `if_*_q1`, `:851`): the 64-bit window is an F1 quantity.
5. **hit-under-fill / miss stall** (`icache_stall`/`o_stall`): the stall is now registered
   (`o_stall_q`) — the fetch-ready gate (`:769`) must use the F1-aligned stall.
6. **imem-MMU alignment**: `IMEM_MMU_STAGE` (§7 of the front-end plan, a separate DEAD scaffold) and
   this must stage consistently — the translate feeds the icache index.

## 6. SRAM port narrowing folded in (the goal-(b) payload)
Current `--dump-area` (post dcache-narrowing): icache **data `1024×32 2R2W ×4`**, **tags `64×52 4R1W ×4`**.
- **data 2W → 1W:** the 2 writes are the fill's adjacent lo/hi 32-bit words (`fill_widx_lo/hi`).
  Widen the array to 64-bit dwords (`logic<64> [SETS*8]`), fill writes one dword → 1W. Rewrite every
  32-bit read as a dword-extract. (Byte-identical array refactor, but folds naturally into the F1
  read restructure.)
- **tags 4R → 1R/2R:** the 4 reads are hit / next-line / non-leaf / **prefetch**; the prefetch reads
  (`nl_index`/`pf_index`) feed the OFF prefetch (`s11_pf_en=0`) = DEAD → DCE. Hit + next-line remain
  (the straddle window); with the F1 decouple the next-line read co-locates with the hit read.

## 7. Verification ladder + IPC (the front end touches everything)
default 252/0 + backend-validate + **ACT4 696/696** + litmus N2/N4 + N2/N4 SMP boot + **Verilator**
(NBA — the front-end restart timing). **IPC is the new axis** (this is the campaign's first real IPC
cost): boot-cy / CoreMark / Dhrystone vs the ~10–15 % budget. Measure at every flip increment.

## 8. Incremental strategy
This is a multi-session flip (the fetch loop is the core's most intricate region; the =1 flip fails
231/252). Proposed increments, each byte-identical at `ICACHE_SYNC_READ=0` where possible:
1. **Register the fetch address + predictor + fault bits** alongside the existing `o_*_q` (the
   `pc_data_q` carrier) — DEAD at 0.
2. **Move the F1 consumers** (RVC-expand / straddle-combine / FB push / dual-issue) onto
   `pc_data_q` + registered `icache_rdata`, gated by the param.
3. **Shape (N) fetch FSM** (present→deliver→advance) under the param; verify the ladder at `=1`.
4. **SRAM narrowing** (data dword-widen, tags prefetch DCE).
5. **Measure IPC**; if over budget, add shape (S) streaming (length-mark / 2-wide predecode).
6. Bundle-flip default-on when the ladder + IPC are green.

## 9. Anchors
- `icache.veryl:455-577` (o_rdata_raw / o_rdata_next / o_stall + the `ICACHE_SYNC_READ` scaffold),
  `:78-89` (arrays), fill `fill_widx_*`, prefetch `nl_index`/`pf_index`/`s11_pf_en`.
- `heliodor_core.veryl:596-603` (icache_rdata wiring), `:722-757` (RVC/straddle/fetched_instr),
  `:769` (fetch_ready), `:779-889` (branch predict + slot-1), `:1090-1133` (fetch FSM),
  `:1142-1180` (FB push).
- Templates: `DCACHE_SYNC_READ` (`dd9bf2a` flip + §11 cluster method), `FETCH_REG`/`IMEM_MMU_STAGE`
  (`cp_frontend_pipeline_plan.md §2.2/§7`).

## 10. ✅ Increment 1 (2026-07-07) — the shape-N fetch gate; flip 21/231 → 248/4

The shape-N insight that made this tractable: **holding `pc_q` until the read settles means
`o_rdata_q == read(pc_q)` at delivery, so every combinational consumer (branch-predict / RVC /
straddle / dual-issue) lines up automatically — no separate `pc_data_q` carrier is needed** (that is
a shape-S concern). Shape N is therefore just a **one-cycle fetch-delivery stall after each pc_q
change**.

Implemented (`heliodor_core.veryl`, core-local `const ICACHE_SYNC_READ` mirroring `icache.veryl`'s —
flipped together, like MEM_PIPE + DCACHE_SYNC_READ):
- `var ic_rd_settled_q` — set the cycle after `pc_q` was held **with a valid translation**
  (`imem_valid_w && !ic_pc_advances`), cleared the cycle `pc_q` advances
  (`ic_pc_advances = any_redirect || (!fb_full && fetch_ready)`). Const-gated D
  (`ICACHE_SYNC_READ ? … : 1'b0`) → CP-neutral (still +1 FF: veryl-synth keeps the const-0 flop, but
  it is off the path).
- `let ic_rd_ok = !ICACHE_SYNC_READ || ic_rd_settled_q` gates **`fetch_ready`** (covers fb_push0 /
  slot-1 / the FSM deliver branch / the FETCH_REG bypass) **and the straddle-prep branch** — the two
  consumers of the icache read.

This correctly handles: the deliver→advance cadence (1 group / 2 cy), the branch-redirect restart
(+1 bubble), the Sv39 PTW walk (settled waits for `imem_valid_w`), and the miss/fill (read + stall
both registered, `pc_q` held → they align).

**Verify:**
- ✅ **DEAD (=0): default 252/0**; synth **14.745 / 141 lv / pc_q→rs1_rdy IDENTICAL** (CP-neutral),
  FF 160645 (+1, the const-0 settled flop, off-path).
- 🔬 **FLIP (both consts =1): default suite 248/4** (was **21/231** without the gate). The gate is
  fundamentally correct. Remaining corners (next increment, cluster-by-cluster like the dcache flip):
  - **`test_icache`** — the icache UNIT testbench asserts the OLD same-cycle read contract; with the
    synchronous read it must expect the +1 latency (TB update, not an RTL bug — expected).
  - **`vfarith`** tohost=0x32 (subtest 50 fails) — a specific vector-FP subtest's fetch pattern.
  - **`higpf`** tohost=0 (**HANG** — highest priority: a stall/deadlock, likely a fetch corner where
    the settled/redirect/fill interaction wedges in the H-ext guest-page-fault path).
  - **`hvtiny`** tohost=0x501 (subtest fails).
  IPC not yet measured (do after the corners are green). The `higpf` hang is the first debug target
  (commit-PC trace: is fetch wedged, or a completion stall?).

**Committed at =0 (byte-id DEAD scaffold).** Next: debug the 4 corners at =1 (start with the higpf
hang), then IPC (boot-cy / CoreMark / Dhrystone), then the SRAM narrowing (§6), then the full ladder.

## 11. ✅ Increment 2 (2026-07-07) — the two arch corners; flip 248/4 → 251/1

Two byte-identical corner fixes (both `ic_rd_ok`-gated → no-op at =0), arch suite now GREEN at =1:

1. **`higpf` HANG = fault delivery.** A fetch FAULT (imem page/access/guest-page fault) has no icache
   read (`i_ren=0`), but `ic_rd_settled_q` only sets on `imem_valid_w` (=0 on a fault), so the fault
   never delivered → hang. Fix: `ic_rd_ok = … || imem_fault_w || imem_acc_fault_w` — a fault bypasses
   the read-latency wait (delivers same-cycle, as at =0). (`higpf` → tohost=1.)

2. **`vfarith` + `hvtiny` = the straddle read.** `fetch_vaddr = straddle_q ? pc_q+2 : pc_q`
   (`core.veryl:1328`) — a straddle-prep step **holds pc_q but shifts the icache address to pc_q+2**
   to read the high half's word. The settled logic tracked pc_q only, so it thought the read was
   settled while the pc_q+2 word was still in flight → the straddled instr got `read(pc_q)` (a cycle
   stale) instead of `read(pc_q+2)` = a wrong 32-bit instruction. Fix: `ic_pc_advances` now clears
   settled on straddle-prep too (`ic_straddle_prep`), giving the pc_q+2 read its own settle cycle
   (straddle becomes 3 cy under sync-read). (`vfarith`, `hvtiny` → tohost=1; both were the same bug.)

**Verify:** DEAD (=0) **default 252/0** (both fixes are `ic_rd_ok`-gated / DCE'd). FLIP (both =1)
**default suite 251/1** — the only fail is **`test_icache`** (the unit TB samples `rdata` at a fixed
`tc` assuming the combinational contract; needs a sync-read-aware update for default-on, deferred —
not an RTL bug). **The arch/boot/litmus suite is functionally green at =1.**

**Next: IPC measurement** (the shape-N `present→deliver` bubble cost — N1 boot-cy / CoreMark /
Dhrystone vs the ~10-15% budget; decides whether shape (S) streaming is needed), then the SRAM
narrowing (§6), the full SMP ladder + Verilator, and the `test_icache` TB update, before default-on.

## 12. 🔬 IPC measured (2026-07-07) — shape (N) is +20–38%, OVER budget → shape (S) is needed

N1 Linux boot cycles, `=1` (both consts) vs the `=0` baseline:

| workload | =0 | =1 | Δ |
|---|---|---|---|
| smoke | 0x00b7b740 | 0x00f61fd0 | **+34.0%** |
| linux 7.1 | 0x01217590 | 0x016d4ba0 | **+26.2%** |
| linux 7.1V | 0x013d8910 | 0x017f4d00 | **+20.7%** |
| linux 6.6 | 0x01402120 | 0x01bb1d80 | **+38.4%** |

All boot variants pass functionally, but the shape-N `present→deliver` bubble (≈ ½ fetch bandwidth
on sequential runs) costs **+20–38%** — well over the campaign's ~10–15 % IPC budget. Confirms §4's
prediction and the "measure before investing in (S)" call: **shape N is correct but not shippable;
shape (S) streaming is required to recover the sequential fetch bandwidth.**

**Shape (S) — the streaming recovery (design for the next increment).** The bubble is entirely the
sequential `present→deliver` gap: the next fetch address needs the just-read RVC length, so it can't
be presented during the read cycle. To stream, present the next address **speculatively** during the
read:
- **Word-granular fetch + extraction (the real-core shape):** advance the fetch address by the
  icache WORD (streamable, no length dependence), buffer the returned words, and extract/align the
  variable-length instructions from the buffer. Decouples the read (word-granular) from the decode
  (instruction-granular). Biggest change but the clean end state; the FB already buffers records.
- **Next-address guess + correct (the lighter shape):** F0 presents `pc_q + guess` (e.g. +4, or a
  1-bit-per-halfword length predecode of the just-read word) while reading `pc_q`; F1 checks the real
  length/straddle and re-steers on a mismatch (a bubble only on a mis-guess, not every group). Keeps
  the current instruction-granular fetch; a per-fetch-word predecode makes the guess exact for
  in-word sequential pairs. Lower effort, recovers most of the bubble.
Both keep the taken-branch/redirect +1 (unavoidable — the target's read is a cycle late). Decision
for the next increment (present to user): word-granular vs guess+correct.

## 13. Shape (S) design — decoupled fetch + F0 next-PC guess (user-selected 2026-07-07)

**⚠️ Scope correction: (b) is NOT a small tweak to shape N — it is a decoupled fetch.** Shape N
holds `pc_q` and lets the read catch up (`fetch_vaddr == pc_q`, one bubble/group). To STREAM, the
read address must run *ahead* of the delivery, presenting the next word's read while the current word
is delivered. The naive "present `pred_next` during a delivery" is a **combinational loop**
(`fetch_vaddr → imem_mmu → imem_valid_w → fetch_ready → delivering → fetch_vaddr`), so the fetch
address MUST be **registered** = the pc_present/pc_data decouple (plan §4).

**Structure:**
- **`pc_fetch_q`** (registered) — the address READ this cycle; drives `fetch_vaddr = pc_fetch_q`
  (no comb loop: it is a flop). `o_rdata_q(T+1) = read(pc_fetch_q(T))`.
- **`pc_data_q = pc_fetch_q` delayed one cycle** — the address DELIVERED this cycle (F1); the RVC
  expand / straddle-combine / dual-issue / FB push / commit-PC all move to `pc_data_q`.
- Each cycle `pc_fetch_q` advances to the **F0-predicted next fetch address**; `pc_data_q` follows.
  Streaming = one delivery/cycle; the read pipeline is 1 deep.

**The F0 prediction (the crux — runs on `pc_fetch_q`, WITHOUT the bytes):**
- **Taken target: exact.** The BTB/BHT/TAGE/RAS/iBTB are address-only lookups on `pc_fetch_q` — they
  give the taken target at F0 with no bytes. (Move the existing predictor from `pc_q` to `pc_fetch_q`.)
- **Fall-through length: needs a GUESS.** `pc_fetch_q + len` needs the RVC length, which is in the
  bytes (arrive at F1). Options:
  - **Simple `+4` guess** (no extra HW): most fall-throughs advance 4 (one 32-bit / two RVC). Wrong on
    a lone low-half RVC → F1 re-steers (bubble). Partial recovery; measure it first.
  - **F0 predecode length-mark** (full recovery, extra HW): store per fetch-word a "low-half is RVC"
    bit, computed at fill, in a **combinationally-read** side table indexed by `pc_fetch_q` (the
    sync-read cache gives it only at F1, too late — so a separate small array, BTB-like). Exact
    fall-through → no sequential bubble.
- **F1 verify + re-steer:** when the real length/branch differs from the F0 guess, squash the wrong
  F0 read and re-present (a bubble). Redirect/taken-branch keep the unavoidable +1.

**Corners:** straddle (the high word is now a *fetch-ahead* quantity — re-time onto the F0/F1 split),
dual-issue slot-1 (the 64-bit window is F1), the FB push (on `pc_data_q`), redirect restart (reset
both `pc_fetch_q` and `pc_data_q`), stall/back-pressure (hold both). This touches the same fetch
consumers shape N did, now on the F0/F1 boundary — **comparable to or bigger than the shape-N work.**

**Increment plan:** (1) the `pc_fetch_q`/`pc_data_q` decouple skeleton (DEAD at 0) with a **simple +4
guess**, move the predictor + consumers to the split; (2) verify the arch suite at =1, measure the
IPC recovery vs shape N's +20-38%; (3) if a lone-RVC bubble still exceeds budget, add the F0 predecode
length-mark; (4) SRAM narrowing (§6), full SMP ladder, TB update, default-on. **This is a fresh
multi-session piece best started in a clean context** — the shape-N gate (`d24e75d`/`7a561fd`) stays
the committed byte-id-at-0 scaffold; shape S replaces the settled-stall with the decoupled stream.
