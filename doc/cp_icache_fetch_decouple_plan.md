# CP / SRAM — icache sync-read + fetch decouple (the front-end functional flip)

The last un-flipped front-end SRAM step: make the **icache demand read synchronous**
(a realistic 1RW/1R1W macro) by decoupling the fetch address generation from the fetch
data consumption. Goal (b) SRAM-realism + the FINAL front-end pipeline structure
(status §5.1: "fetch is combinational on the icache read" is the one remaining front-end
architectural wall). Lower SMP risk than the dcache flip (per-hart, in-order front end, no
coherence/atomicity) but a WIDE surface (fetch / RVC / straddle / branch-predict / dual-issue).

## 1. State (2026-07-08)
- **▶️ LATEST (§19, 2026-07-08): shape-W W3 is BOOT-CLEAN + within the IPC budget.** §18 non-cacheable
  2-beat F0 fixed the boot hang + `test_smode_plic` (same root: firmware PA0 non-cacheable high-word=0 loop);
  §19 FIFO read-around bypass recovered the taken-branch refill BUBBLE2. arch **251/252** (only `test_icache`
  = W4), N1 boot 5.15/7.1/7.1v/6.6 PASS at =1, byte-id at 0 (252/0 + synth 14.745/FF160645 identical, +0 FF).
  **IPC now within budget: Dhrystone +29.7 %→+15.3 %, CoreMark +17.1 %→+14.2 %, boot 5.15 +18.3 %→+12.8 %,
  6.6 +13.3 %→+9.3 %** (Dhrystone frontidl 65432→15394). Residual = BUBBLE1 (inherent sync-read latency), only
  (b) fetch-directed prefetch removes it → (b) deferred. **Next = W4** (SRAM narrow §6, SMP ladder + Verilator,
  `test_icache` TB, default-on).
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

## 14. Shape (W) — word-granular decoupled fetch (user-selected 2026-07-07, SUPERSEDES §13's shape)

**⚠️ §13's instruction-granular "+4 guess" is fundamentally SINGLE-ISSUE.** If `pc_fetch_q` advances
one *instruction* per cycle (`+4` guess or a length-mark), it presents ONE fetch address per cycle,
which can't feed the existing 2-wide dual-issue (slot-1) that delivers two instrs from one 64-bit
`{rdata_next, rdata}` window. A "group-length guess" (2/4/6/8 B) keeps dual-issue but the guess mis-
fires often (predecode-length-mark almost mandatory). Rather than patch §13, go straight to the
**FINAL front-end structure** (per the campaign's "advance the FINAL pipeline structure, not the CP
number"): **word-granular fetch, instruction-granular decode — the real-core front end.**

**The key decoupling: the FETCH advance has NO length/branch dependence.** Fetch reads *words*, not
instructions. `pc_fetch_q += WORD` every cycle (the sync-read latency vanishes into a buffer), so
sequential code NEVER bubbles — the +20-38% is gone by construction. RVC length + straddle + dual-
issue are all resolved DOWNSTREAM at extract, where the bytes are already buffered.

**Structure — two decoupled stages around a raw WORD FIFO:**
- **F0 (read stream):** `pc_fetch_q` = word-aligned fetch address (registered → no comb loop; drives
  `fetch_vaddr`). Present to imem_mmu + icache; the sync-read word arrives next cycle and is PUSHED
  into the **word FIFO** (`wf_data[32]` + `wf_pc` + fault bits per entry). `pc_fetch_q += 4` each
  fetch cycle. HOLD on: word-FIFO full, icache miss/`o_stall`, Sv39 PTW walk (`!imem_valid_w`),
  redirect-cycle. JUMP on: branch-redirect / early-redirect (→ redirect target, flush the FIFO) and
  the extract stage's **predicted-taken** (→ pred target, flush the younger-than-branch words).
- **Extract (decode-granular):** an **`ext_pc_q`** (the slot-0 instruction PC) indexes the word-FIFO
  head; the ENTIRE existing extraction datapath — `curr_hw`/RVC-expand/straddle-combine/slot-1
  dual-issue/BTB·BHT·TAGE·RAS·iBTB predictor — moves from reading `icache_rdata`+`pc_q` to reading
  **the word-FIFO head words + `ext_pc_q`** (byte-identical map: `pc_q`→`ext_pc_q`,
  `icache_rdata`→`wf_head`, `icache_rdata_next`→`wf_head_next`). It pushes decoded records into the
  existing `fb_*` decode FIFO exactly as today. The predictor STAYS instruction-granular here (no BTB
  re-index); a predicted-taken redirects F0 (the taken +1 is unavoidable — target word is a cycle
  late — same as today), and the word FIFO buffers the read-ahead so the redirect costs only the +1.

**Why this preserves the predictor + extraction wholesale:** every consumer keeps running on an
instruction PC (`ext_pc_q`) and a 64-bit window (`{wf_head_next, wf_head}`), so RVC/straddle/slot-1/
BTB/BHT/TAGE/RAS/iBTB logic is UNCHANGED in substance — only its *source* moves from the combinational
icache read to the registered word FIFO. That is what removes the icache read from the fetch
combinational cone (goal-(b) + the pipeline stage) without a predictor redesign.

**Corners:** (a) **straddle across a word-FIFO boundary** — the high half is `wf_head_next`'s low half
(the FIFO already buffers it → straddle may need NO extra cycle, unlike today's 2-cycle re-fetch); (b)
**dual-issue** reads `{wf_head_next, wf_head}` (needs ≥2 words buffered); (c) **word-FIFO
pop timing** — pop a word when `ext_pc_q` crosses its boundary (may pop 0/1/2 words per extract
cycle for a straddle/dual bundle); (d) **flush** on redirect / predicted-taken drains both the word
FIFO and re-seeds `pc_fetch_q`/`ext_pc_q`; (e) **fault words** — a faulting fetch pushes a fault-
marked word (no data) so the extract delivers the fault in program order; (f) **MMU-walk / miss** hold
F0 but the extract keeps draining the buffered words (that IS the streaming win).

**Increment plan (byte-id at `ICACHE_SYNC_READ=0` throughout — the const gates every =1 arm):**
- **W1 — word FIFO + F0 read stream skeleton (DEAD at 0).** Add `pc_fetch_q` + the word FIFO
  (arrays, push from the sync-read word, F0 advance/hold/flush FSM). `fetch_vaddr` = const-mux to the
  word-aligned `pc_fetch_q` at =1. Verify default 252/0 + synth CP-neutral. (The read-decouple half.)
- **W2 — extract stage on the word FIFO (DEAD at 0).** Introduce `ext_pc_q`; const-mux every
  extraction/predictor source (`pc_q`→`ext_pc_q`, `icache_rdata`→`wf_head`, `_next`→`wf_head_next`);
  the extract's predicted-taken/redirect feeds F0's flush+reseed. Verify byte-id at 0.
- **W3 — bring up `=1`:** flip both consts, run the arch suite, debug corners cluster-by-cluster
  (straddle/dual-issue/flush/miss/PTW), then measure N1 boot-cy / CoreMark / Dhrystone vs shape N's
  +20-38% and the ~10-15 % budget.
- **W4 — SRAM narrowing (§6), full SMP ladder + Verilator, `test_icache` TB update, default-on.**

`pc_data_q` (§13) is subsumed by the word FIFO (the buffer IS the F0→extract decouple). The shape-N
gate (`d24e75d`/`7a561fd`) stays the committed byte-id-at-0 baseline until W3 replaces the =1 path.

## 15. ✅ W1 (2026-07-07) — F0 read stream + word FIFO skeleton (DEAD at 0), `ca6f736`

The read-decouple half. Added (all const-gated, DEAD at 0):
- **`pc_fetch_q`** — the F0 dword-aligned fetch address, presented to imem_mmu + icache via the
  `fetch_vaddr` const-mux. Streams `+= 8` (one 64-bit dword) each fetch — NO length/branch dependence.
  redirect / early-redirect reseed it (dword-aligned); F0 holds on FIFO-full / miss / `!imem_valid_w`.
- **WORD FIFO** (`wf_data`/`wf_pc`/`wf_ifault`/`wf_iacc`/`wf_gstage`/`wf_gpa` + head/tail/count, `WF_N=8`):
  each entry is the natural 64-bit icache window `{rdata_next, rdata}` at a dword-aligned PC.
- **F0→push pipeline** (`wf_push_*_q`): the sync-read dword for `pc_fetch_q(T)` arrives at T+1, so the
  presented PC + fault bits register one cycle to push alongside the arriving data.

**DCE idiom (measured):** both `always_ff` write ONLY under `else if ICACHE_SYNC_READ` (no =0 write) →
reset-only at =0 → the whole scaffold DCEs. An earlier `else if !ICACHE_SYNC_READ { =const }` form left
the `mux(control,const,hold)` flops KEPT — **measured +75 off-path FF** (CP still 14.745). The reset-only
form (the icache `o_rdata_q` idiom) DCEs to **+0 FF**.

**Verify:** byte-id at 0 = default **252/0**, litmus N=2 `cy=0x0022f150` (**cycle-EXACT** vs baseline);
synth **14.745 ns / 141 lv / `pc_q[34]→rs1_rdy[0]` IDENTICAL**, **FF 160645 IDENTICAL (+0)** — a true
dead scaffold. Next: **W2** introduces `ext_pc_q` + const-muxes every extraction/predictor source onto
the FIFO head (still DEAD at 0).

## 16. ✅ W2 (2026-07-08) — extract stage on the word FIFO (DEAD at 0), `ea09b72`

The decode-decouple half. Introduced **`ext_pc_q`** (the slot-0 INSTRUCTION PC) and rerouted the
ENTIRE extraction/predictor datapath to read the WORD FIFO head via const-muxes (old value at =0):
- **`ext_word`/`ext_word_next`** — the 32-bit words at `ext_pc_q` from the head dword `wf_data[wf_head]`
  (`ext_pc_q[2]` selects low/high; the next word is the head dword's high word or `wf_data[wf_head+1]`'s
  low word). **`ext_next_valid`** — next word present (within-dword always; across needs `wf_count>=2`).
- **`ic_pc`/`ic_rdata`/`ic_rdata_next`/`ic_rdata_nv`** `= SYNC ? ext_* : {pc_q, icache_rdata,
  icache_rdata_next, icache_rdata_next_valid}`. Every consumer (`curr_hw`, RVC/straddle, `fetched_instr`,
  slot-1 window + `s1_b1`/`s1_pc`, BTB/iBTB/TAGE `i_pc`, `bht_lk_index`, `pred_next_pc_bp`,
  `ras_push_addr`, `fb_pc` push, the `if_pc_q`/`if_pc_q1`/`i_trap_pc` bypass fallbacks) reads the muxes.
  `pc_q` keeps only its fetch-FSM writes (vestigial / DCE'd at =1); predictor stays instruction-granular.
- **Extract pointer FSM** — `ext_pc_q` advances past the delivered bundle (`ext_next_pc`), reseeds on
  redirect; the FIFO pops the head dword when the advance crosses it (`ext_pop`). Reset-only at 0 → DCE.
- Moved `const ICACHE_SYNC_READ` up into the shape-W scaffold block (it now gates the extract-source
  muxes near the RVC decode, which precede its old definition — Veryl requires define-before-use).

**Verify:** byte-id at 0 = default **252/0**, litmus N=2 `cy=0x0022f150` (**cycle-EXACT**); synth
**14.745 / 141 lv IDENTICAL, FF 160645 (+0)** — the const-muxes fold to the old sources at 0, so
`ext_pc_q` + the FIFO reads DCE.

**W3 (=1 bring-up, the functional core):** (1) replace `fetch_ready`'s F0-side `imem_valid_w`/`icache_stall`
with a FIFO-availability deliver gate (head dword present, +next when the instr straddles / slot-1 needs
it); (2) re-time straddle onto the FIFO's fetch-ahead high word (may drop the 2-cycle path — the next
dword is already buffered); (3) pop 0/1/2 for a bundle spanning two dwords; (4) the **predicted-taken →
F0 redirect + FIFO flush** (ext detects taken on `ext_pc_q`, steers `pc_fetch_q` to the target, drains the
now-wrong-path words); (5) fault-word delivery + miss/PTW hold. Then flip both consts, run the arch suite
cluster-by-cluster (like shape N's 21/231→248/4→251/1), measure IPC vs shape N's +20-38%.

## 17. 🔬 W3 (2026-07-08) — =1 functional bring-up: arch **250/252** (DEAD at 0), `78355eb`

Implemented all five =1 pieces (deliver gate / straddle re-time / pop / predicted-taken→F0 redirect /
fault-word), const-gated → **byte-id at 0 (default 252/0, cy=0x0022f150 cycle-EXACT)**. Flipped both
consts and drove the arch suite from **21/231 (shape-N first flip) → 250/252**.

**Two RTL bugs found + fixed at =1:**
1. **F0 miss hold** — `f0_present` must gate on the **combinational** demand-miss (new icache
   `o_stall_comb = o_stall_raw`), NOT the registered `o_stall` (a cycle late → F0 streamed past the
   miss → the first-flip whole-suite hang). The push keeps the registered stall (it aligns with the
   registered `o_rdata` arrival). *This got basic fetch working (rv64ui add/etc PASS).*
2. **WORD FIFO overflow** — `wf_full` must count the in-flight push: `wf_count + wf_push_valid_q >= 8`.
   Presenting at count==7 else overflows (in-flight push → 8, this present's push → 9 → FIFO
   corruption), ONLY under sustained back-pressure (a long div / FP / atomic fills the FIFO). *This
   was the div/rem/FP/atomic hang cluster: **39 fails → 2** after the fix.*

**Remaining 2 at =1 (NOT on the =0 baseline; the W3 tail):**
- **`test_smode_plic`** — NON-cacheable fetch (boot ROM at PA 0, `ic_dram=0`): `o_rdata_next_raw=0`
  there, so the dword FIFO's HIGH word is 0 → any instr in the high word decodes as 0 → hang
  (`rd_cnt=0`, no progress). Fix: a **2-beat word-granular F0 for non-cacheable** (present dword-addr,
  then +4, assemble the dword over 2 cycles). Boot-ROM only; arch/Linux fetch from DRAM (cacheable).
- **N1 Linux boot** — hangs EARLY (no UART banner, cy≈44.8M vs ~12M baseline) at =1 while the arch
  suite passes. A **SoC-only** corner (the arch harness passes) — likely the deeper shape-W prefetch
  (word FIFO 8 dwords ahead) through the coherent L2 fill arbiter, or a stale-fetch sync event the
  arch tests don't hit. **Next step: a commit-PC trace** (last committed PC before the hang) to
  pinpoint — best in a fresh context. This BLOCKS the IPC measurement (the W3 payoff).
- **`test_icache`** — unit TB asserts the old same-cycle contract (known; W4 TB update).

**Status: shape-W is functionally proven on the OoO core (arch 250/252) but NOT yet Linux-boot-clean.**
Consts stay 0 (baseline unchanged). Next: debug the Linux boot early hang (trace) → non-cacheable
2-beat → IPC measurement → W4 (SRAM narrow, ladder, `test_icache` TB, default-on). **[SUPERSEDED by §18.]**

## 18. ✅ W3 boot-clean (2026-07-08) — non-cacheable 2-beat fixes BOTH the boot hang AND `test_smode_plic`; IPC measured

**Root cause of the boot hang = the SAME non-cacheable dword bug as `test_smode_plic`, not a "deeper prefetch"
corner.** A commit-PC trace (heartbeat on `rob_commit_ack`) showed the N1 boot stuck committing **PC `0x4`**
forever at `icdram=0` (the firmware boot ROM at PA 0 — reset vector, M-mode, non-cacheable). Decode:
PA `0x0` = `csrw mie,x0`, PA `0x4` = `auipc t0,0`, PA `0xC` = `csrw mtvec,t0`. Shape-W's F0 pushes the
64-bit window `{o_rdata_next, o_rdata}`, but a non-cacheable icache read returns **`o_rdata_next = 0`**
(the passthrough serves only the single presented word). So the dword at PA 0 = `{high=0, low=csrw}`;
the extract runs PA 0 fine, then reads the **high word (PA 4) = 0** → decodes as an illegal RVC → trap to
`mtvec` (still 0, `csrw mtvec` at PA 0xC never reached) → PA 0 → **infinite PA0→PA4(illegal)→trap loop**.
The firmware runs from PA 0 non-cacheable, so the boot hangs at its 2nd instruction — the same failure
`test_smode_plic` hit (boot-ROM fetch), which is why the arch suite (DRAM/cacheable fetch) passed 250/252.

**Fix — non-cacheable 2-beat word-granular F0 (`heliodor_core.veryl`, const-gated, DEAD at 0).** A
non-cacheable fetch has no next word, so F0 fetches WORD-granular over two beats and assembles the dword
before the push: beat 0 presents the dword-low word (`pc_fetch_q`), latches it into `f0_nc_lo_q` when it
arrives; beat 1 presents the high word (`pc_fetch_q+4`) and pushes `{icache_rdata(high), f0_nc_lo_q(low)}`.
`f0_beat_done = ic_dram || f0_fault || f0_nc_beat_q` gates the pc-advance + push (cacheable = 1 dword/present;
non-cacheable = 2 beats/dword; a fault = single fault-marked entry). New regs `f0_nc_beat_q` /
`f0_nc_lo_inflight_q` / `f0_nc_lo_q` / `wf_push_nc_q` are written only under `else if ICACHE_SYNC_READ` →
reset-only at 0 → DCE. Boot ROM / MMIO only (arch + Linux both fetch DRAM = cacheable), so the half-rate
non-cacheable fetch is free. `ic_dram` moved up ahead of the F0 stream (referring-before-definition).

**Verify — functional flip (=1):**
- **N1 Linux boot 5.15 PASS** `cy=0x00d94900` (14.24M); **6.6 PASS** `cy=0x016adaa0` (23.78M) — was 44.8M hang.
- **arch 250/252 → 251/252**: `test_smode_plic` now PASSES; the only remaining fail is `test_icache`
  (unit TB asserts the old same-cycle contract — the known W4 TB update).

**Verify — byte-id (=0, the committed baseline):** default `veryl test` **252/0**; synth **14.745 ns / 141 lv /
`pc_q[34]→rs1_rdy[0]` IDENTICAL / FF 160645 (+0)** — the 2-beat regs DCE, a true dead scaffold.

**🔬 IPC measured (=1 vs =0) — shape-W roughly HALVES shape-N's boot regression but is STILL over the
~10–15 % budget on branch-dense code:**

| workload | =0 | =1 shape-W | Δ shape-W | (§12 shape-N) |
|---|---|---|---|---|
| Dhrystone | 230937 | 299624 | **+29.7 %** | — |
| CoreMark | 327980 | 383912 | **+17.1 %** | — |
| boot 5.15 (smoke) | 0x00b7b740 | 0x00d94900 | **+18.3 %** | +34.0 % |
| boot 6.6 | 0x01402120 | 0x016adaa0 | **+13.3 %** | +38.4 % |

**The residual is almost entirely front-end idle**, NOT the back-end. Dhrystone counters (`=0 → =1`):
`frontidl 146 → 65432` (**+65286**, ≈ the whole +68687-cycle delta), `commit0 52260 → 103600` (secondary
starvation), `membusy 74869 → 75337` (flat). So §14's "sequential code never bubbles" **held** (a pure-
sequential run has ~0 idle), but its "the taken +1 is unavoidable — same as today" was **optimistic**: at =1
every **taken branch (predicted OR mispredicted) flushes the word FIFO** (`ext_taken_redir`, since F0 streamed
sequentially past it) and refills the target through the **synchronous** icache — a ~2-cycle bubble
(BUBBLE1 = the sync-read latency [unavoidable]; BUBBLE2 = the FIFO register round-trip
[present→arrive→push→visible, removable]) vs =0's ~0–1-cycle combinational refill. Branch-dense Dhrystone
(tiny functions = a taken branch every few instrs) pays +29.7 %; loop-dense CoreMark +17.1 %; boots +13–18 %.
**The deep 8-dword prefetch is wasted on every taken branch** — the streaming win is real for straight-line
code but the taken-branch refill is now WORSE than =0.

**Recovery options (the W3 → shippable crossroads):**
- **(a) FIFO read-around / bypass** — deliver the arriving dword the cycle it lands (`icache_rdata` is
  REGISTERED under sync-read → a register→extract bypass, NOT the combinational read cone → CP-safe),
  recovering BUBBLE2 (~1 cycle/taken-branch → Dhrystone ~+10 %, within budget). Smallest, lowest-risk win.
- **(b) Fetch-directed prefetch** — F0 consults the BTB on `pc_fetch_q` and FOLLOWS predicted-taken
  branches instead of streaming sequentially + flushing (the real-core decoupled front end: a BTB-driven
  fetch-target stream). Eliminates the flush entirely; biggest redesign, the clean end state.
- **(c) Accept shape-W as structural progress** — the icache combinational read is off the fetch cone (the
  CP goal), at a +13–18 % real-workload IPC cost. Per the "structure over CP" campaign ethos, still progress.

**Consts stay 0 (baseline unchanged).** Next (user decision): pursue (a) the FIFO bypass to reach the IPC
budget, then W4 (SRAM narrow §6, full SMP ladder + Verilator, `test_icache` TB, default-on).

## 19. ✅ FIFO read-around bypass (2026-07-08, user-selected recovery (a)) — shape-W now within the IPC budget

**Recovered BUBBLE2 (the FIFO register round-trip on refill).** The taken-branch refill (§18) was ~2 bubbles:
BUBBLE1 = the sync-read latency (the target dword is one cycle late — inherent), BUBBLE2 = the word-FIFO
register round-trip (the arriving dword is pushed, then read back a cycle later). The bypass delivers the
arriving dword the cycle it lands: when F0's just-fetched dword (the REGISTERED `icache_rdata` for last
cycle's `pc_fetch_q`, about to be pushed) is EXACTLY the dword the extract wants but the FIFO does not hold
it yet (post-redirect / miss refill), the extract reads it directly instead of waiting for the FIFO write→read.

**Implementation (`heliodor_core.veryl`, const-gated, byte-id at 0):** `ext_bypass = ICACHE_SYNC_READ &&
wf_push_valid_q && !icache_stall && (wf_push_pc_q[63:3] == ext_pc_q[63:3])` (the arriving push is the wanted
dword). `ext_eff_head = ext_bypass ? wf_push_dword : wf_head_data` feeds `ext_word`/`ext_word_next`;
`ext_head_avail = ext_head_match || ext_bypass` gates `fetch_ready`; the fault bits read the arriving push
when bypassing. **No new FF** — the bypass is combinational over already-registered signals (`icache_rdata`
is REGISTERED under sync-read, so this is register→extract, NOT the combinational read cone → CP-safe).
Key invariants: `ext_bypass ⟹ wf_do_push` (the FIFO push/pop arithmetic is unchanged — the pushed dword is
consumed via the bypass AND still lands in the FIFO for continued extraction); `ext_bypass ⟹ !ext_head_match`
in practice (a bypass fires only when the FIFO has drained to the fetch point, so during normal streaming
`wf_push_pc_q` = the far-ahead prefetch ≠ `ext_pc_q` → no spurious bypass); across-dword slot-1/straddle
correctly waits (`wf_count ~0` during a bypass → `ext_next_valid` across = 0).

**Verify — byte-id (=0):** default `veryl test` **252/0**; synth **14.745 ns / 141 lv / pc_q[34]→rs1_rdy[0] /
FF 160645 IDENTICAL** (the whole ext_* block feeds only the `=1` arm of `ic_rdata` → DCE at 0).

**Verify — functional (=1):** arch **251/252** (only `test_icache` = W4 TB); N1 boot 5.15/7.1/7.1v/6.6 all PASS.

**🔬 IPC (=1 vs =0) — the bypass roughly halves the shape-W residual → within the ~10–15 % budget on real workloads:**

| workload | =0 | shape-W no-bypass | **+ bypass** | frontidl (=0 / no-byp / byp) |
|---|---|---|---|---|
| Dhrystone | 230937 | +29.7 % | **+15.3 %** | 146 / 65432 / **15394** |
| CoreMark | 327980 | +17.1 % | **+14.2 %** | — |
| boot 5.15 | 0x00b7b740 | +18.3 % | **+12.8 %** (0x00cf36e0) | — |
| boot 6.6 | 0x01402120 | +13.3 % | **+9.3 %** (0x015de250) | — |

The Dhrystone front-end idle fell **65432 → 15394** (−76 %), confirming BUBBLE2 recovery. Real workloads
(boots +9–13 %, CoreMark +14 %) are now within budget; branch-pathological Dhrystone sits at +15.3 % (its
residual is BUBBLE1 = the inherent sync-read latency, which only (b) fetch-directed prefetch removes — so
(b) is deferred, not needed for shippability). **Consts stay 0.** Next: W4 — SRAM narrowing (§6, the goal-(b)
port payload), full SMP ladder + Verilator, `test_icache` TB update, then `ICACHE_SYNC_READ=1` default-on.

## 20. 🚨 W4 SMP ladder (2026-07-08) — SMP boot **N=4 HANGS** at =1: a 2-beat non-cacheable straddle race (default-on BLOCKER)

Ran the §7 SMP ladder at =1 (the gate for default-on). **litmus N2 ✓ / SMP boot N2 ✓ / litmus N4 ✓, but
SMP boot N4 HANGS** (`cy=0x05f5e100`=100M timeout, hart0 x3 = a kernel VA not 0xAA). This is a real
shape-W regression (byte-id at 0 guarantees =0 is the known-good baseline).

**Diagnosis (per-hart commit-PC heartbeat + a dense hart-1 window trace):** hart 0 boots the kernel
(kernel VAs, commits advancing); harts 1/2/3 are stuck **spinning in the M-mode firmware secondary-park
loop** (`0x500`–`0x558`, NON-cacheable = the 2-beat path). Disassembling the actual **hex** (the `.elf` is
stale — hex ≠ elf) shows the park loop is **RVC-mixed with many 32-bit instructions at 2-byte-but-not-
4-byte offsets** (`ld`@0x516, `beq`@0x51a, `ld`@0x51e, `sd`@0x522 — all straddling). The dense trace shows
hart-1 committing a stable loop that **mixes valid instruction starts with MID-INSTRUCTION PCs**
(`0x51c`/`0x520`/`0x524`/`0x55e`/`0x562` = the straddle PCs + 2) → the fetch drifted +2 on a straddling
32-bit instr (delivered as if RVC / wrong length), cascading into a corrupt loop that traps into
`s_debug_trap` (`0x55c`, sets `gp=0xDD`) and wedges.

**Isolation:** disabling the §19 bypass (`ICACHE_BYPASS_EN=0`) **still hangs** with the same corrupt loop →
the bug is in the **2-beat non-cacheable path, NOT the bypass**. It is **timing-dependent** (N2 runs the
identical park loop and PASSES; only N4 fails), so it is a RACE — N4's shared-L2/bus data contention
(the park loop's mailbox `ld`/MSIP `sw`) shifts the branch/redirect timing and exposes a corner in the
2-beat straddle assembly (within-dword straddle uses the beat-1 high word; across-dword uses the next FIFO
dword — one path mis-delivers a straddling 32-bit instr under a specific arrival timing).

**Status: default-on is BLOCKED on this N4 hang.** The committed baseline is unaffected (consts stay 0,
byte-id). **Next debug step:** an ONSET trace (hart-1 fetch state — `ext_pc_q`/`pc_fetch_q`/`wf_count`/
`f0_nc_beat_q`/`straddle_q` — every cycle around the FIRST mid-instruction commit, bisect the cy where the
+2 drift first appears) → identify the 2-beat straddle race → fix (byte-id at 0) → re-run the full ladder →
resume W4 (`test_icache` TB, SRAM narrow §6, default-on).
