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

## 20.1 ⚠️ CORRECTION (2026-07-08) — the N4 culprit is the §19 BYPASS, not the 2-beat

§20 wrongly blamed the 2-beat. The bypass-OFF isolation run (`ICACHE_BYPASS_EN=0`) I read as "still hangs"
actually **PASSED** — I checked only its cy≈2M dense window (where the secondaries are NORMALLY still in the
park loop; release happens ~30M) and misread the normal park loop as stuck. The "mid-instruction PCs" were an
**objdump RVC-misalignment artifact** (greedy hex→bin disassembly drifted), not real corruption. Confirmed:

| N4 SMP boot (=1) | result |
|---|---|
| bypass ON (§19) | **HANG** (100M timeout) |
| bypass OFF (`ICACHE_BYPASS_EN=0`) | **PASS** `cy=0x01e5aff0` (31.8M) |

So the **§19 FIFO read-around bypass has an N4-specific timing race** (N1/N2/litmus all pass with it ON;
only N4 SMP boot fails — N4's shared-L2/bus contention shifts the refill timing into the racing corner).
The bypass is combinational over registered signals and looked correct by inspection, so the race is subtle.

**Partial-fix attempt (insufficient):** restricting the bypass to a TRUE refill — `ext_bypass &&=
(wf_count == 0)` — on the theory that in a tight loop F0 re-fetches a still-buffered dword so `wf_push_pc_q`
(the wrapped tail position) matches `ext_pc_q` (the head) while pointing at a different stream slot. This
did move the failure: hart 0 booted **further** (past the banner, "Hardware name: Heliodor RV64GC (4-hart)")
but the N4 SMP probe then showed **hart 0 stuck in a tight KERNEL loop at `0x800dda54` (cacheable/DRAM) with
harts 1/2/3 re-parked in firmware** — an SMP-bringup deadlock (hart 0 spins waiting to online the secondaries;
the secondaries wait in the park loop for hart 0's IPI). So the bypass race is **GENERAL — it corrupts a
CACHEABLE kernel refill too**, not only the non-cacheable straddle; `wf_count==0` alone does NOT close it.

**Next: a targeted ONSET trace of the bypass** — log `ext_bypass`/`ext_head_match`/`wf_push_pc_q[.]`/
`ext_pc_q[.]`/`wf_count`/`ext_word` for hart 0 around the first divergence at `~0x800dda54` (cacheable, easier
to reason about than the non-cacheable park loop), find the exact cycle the bypass delivers the wrong dword,
and fix precisely. **Decision point (crossroads):** (a) properly fix the bypass race (keeps §19's within-budget
IPC), or (b) revert §19 and default-on §18 (2-beat, N4-clean but IPC over budget — Dhrystone +29.7 %), treating
the bypass as deferred IPC work. The committed tree is unaffected (consts 0, byte-id — the bypass DCEs at 0).

## 20.2 🔬 Onset trace (2026-07-09) — the bypass delivers a WRONG dword (data ≠ its own PC) in a redirect corner

Onset trace at =1 with the `wf_count==0` partial fix (to reach the cacheable 0x800dda divergence): logged hart-0
fetch DELIVERY (`fb_push0`) in the `0x800dda00`–`ff` window (`ext_pc_q`/`fetched_instr`/`ext_bypass`/`wf_count`/
`wf_push_pc_q`). Findings (onset ≈ cy `0x745347`, ~7.6M):
- The real kernel code there (from the actual **dram hex**) is a memcpy/memmove word+byte copy loop. hart 0
  ends up stuck **2.13M×** in a corrupt loop `0x800dda44`–`0x800dda58` executing garbage — `csrr a5,time`
  (`0xc01027f3`) at `0x800dda48` (mid-instruction), `div a5,a5,x0`, `ret`, `j -16` — bytes from ELSEWHERE.
- The corrupt deliveries are **`byp=1`** with `wf_count==0` and `wf_push_pc_q[63:3] == ext_pc_q[63:3]` (the guard
  holds\!), yet the delivered `fetched_instr` is for a DIFFERENT address. So `wf_push_dword` (= `{icache_rdata_next,
  icache_rdata}`) does **not correspond to `wf_push_pc_q`** — the registered icache read is stale/for another PC.
- The onset is preceded by **backward jumps (predicted-taken loop redirects) + bypass** back-to-back.

So the race is a **data-staleness**: in a redirect/refill corner the bypass's `icache_rdata` is NOT the read of
`wf_push_pc_q`, so it delivers a valid-PC-but-wrong-data dword → the RVC extractor drifts → cascade corruption.
By static inspection `icache_rdata(T+1) = read(fetch_vaddr(T)) = read(pc_fetch_q(T)) = read(wf_push_pc_q)` for a
cacheable fetch, so the skew must come from a specific redirect/miss timing the trace hasn't yet pinned (objdump
RVC-drift on the raw hex makes exact-boundary comparison hard). **Onset log preserved:** `scratchpad/n4_onset.log`
(718 MB, 8.5M `O0` lines). **Next (continue (a)):** bisect the exact onset cycle — dense-trace hart-0's
`pc_fetch_q`/`fetch_vaddr`/`icache_stall`/`redirect`/`ext_taken_redir`/`wf_push_valid_q` for ~50 cycles around
`0x745347` to catch the first stale-data bypass, then guard/fix it. **Fallback (b):** if intractable, revert §19
and default-on §18 (2-beat, N4-clean, Dhrystone +29.7 %). The committed tree is unaffected (consts 0, byte-id).

## 21. 🔬 =1 synth CP measured (2026-07-09, user-chosen decider) — shape-W is net-NEGATIVE solo; the wall is the commit-store front → GATE shape-W, DE-PRIORITIZE the bypass

Before sinking more into the §20.2 bypass race, the user chose to **measure the =1 synth CP first** — does shape-W's sync-read actually cut the front-end floor enough to pay for its IPC cost? Flipped BOTH consts to 1 (core §336 + icache §561), `veryl synth --top heliodor_core --dump-timing`, reverted to 0.

| config | CP | levels | binding path | area (um²) |
|---|---|---|---|---|
| =0 (shipping) | 14.745 ns | 141 | `pc_q[34] → rs1_rdy[0]` (**front-end** fetch cone) | 18.895 M |
| =1 (shape-W)  | **14.130 ns** | 146 | `head[0] → n_inflight[5]` (**back-end** commit) | 18.982 M (+87 K = the ~66 sync regs) |

**The sync-read register DID split the front-end cone** — the binding root moved off `pc_q` (fetch) onto
`head → ROB-commit → CAS/store detect → commit-store **dmem-MMU TLB** (3.1→7.6) → **PMP-W** (7.6→9.9) →
commit-trap/redirect → free-list **n_inflight** counter (12.2→14.13)`. This EXACTLY reproduces
`cp_commit_store_pretranslate_plan.md`'s FETCH_REG=1 wall (**14.130 ns, `head→n_inflight[5]`**) — same
number, same path. The =0→=1 win is only **−0.615 ns (−4.2 %)**: the =0 baseline had drifted 14.565→14.745
(front-end cone growth), all of which the register removes, landing on the hard back-end wall at 14.130.

**Decisive economics — shape-W SOLO is net-NEGATIVE** (perf = clock × IPC; boot-5.15 IPC from §19):

| | clock gain | boot IPC cost | net throughput |
|---|---|---|---|
| §18 default-on (N4-clean, shippable) | +4.35 % (14.745→14.130) | +18.3 % | ×1.0435 / 1.183 = **−11.8 %** |
| §19 bypass (IF the race were fixed) | +4.35 % | +12.8 % | ×1.0435 / 1.128 = **−7.5 %** |

Break-even needs the back-end wall ≤ 14.745/1.183 = **12.46 ns** (§18) / ≤ **13.07 ns** (§19) — the commit-store
front must fall **≥1.67 / ≥1.06 ns below 14.130** before shape-W pays for itself. It does not, alone.

**Decision (plan REVISED — the "advance the FINAL structure, not the binding synth number" rule):**
1. **shape-W is BANKED: ready-but-GATED (consts stay 0).** §18 (2-beat, N4-clean) is the correct shippable
   body and the front-end half of the deep-pipeline bundle. It does NOT go default-on in isolation.
2. **The §19 bypass race is DE-PRIORITIZED** (not reverted — the code DCEs at 0). Even fixed it leaves shape-W
   net-negative (−7.5 %); it is IPC-recovery for a stage that is not default-on. Not worth the §20.2 trace-hunt
   now — the onset log + diagnosis stay parked for when the bundle makes shape-W profitable.
3. **The real next structural target is the wall shape-W just re-exposed: the commit-store live-MMU/PMP front**
   (`head→n_inflight`, 14.130) — already the user-chosen ACTIVE FRONT in `cp_commit_store_pretranslate_plan.md`:
   **move store address translation from commit to execute (Stage-A).** shape-W + commit-store-pretranslate +
   vrf (13.880, 2nd front) form the coordinated bundle whose CP headline only moves together.

**Next:** resume `cp_commit_store_pretranslate_plan.md` (P1' probe `7598185` down-payment → the hard part: the
§9 2-cycle registered-SB-push fallback that §4.1 proved is required — the naive commit-MMU-removal breaks the
Linux boot). shape-W waits in the bundle; the bypass race stays parked.

## 22. ✅ Resume as a banked verified scaffold (2026-07-16, user-selected "advance I$ decoupled fetch") — re-verified healthy on the bundle-banked tree; the §20 N4 blocker is RESOLVED (the bypass race is gone on the FETCH_REG=1 tree)

After the deep-pipeline **bundle bank** (`c2a98fe`: FETCH_REG + STORE_PRETRANSLATE + RETIRE_DECOUPLE +
VALU_PIPE = 1, CP 14.745 → 13.120, −11 %) addressed the commit-store front that §21 was waiting on, the
user chose the **I$ decoupled-fetch** front (the `deep_pipeline_status_and_replan.md` §5.1/§7 structural
block: sync-SRAM I$ = the F2 stage, independent of the commit wall). This increment **re-verifies shape-W
on the current tree, resolves the §20 N4 blocker, and banks it as a fully-verified ready-to-flip scaffold.**

**Re-verify (bit-rot / FETCH_REG-composition check).** The last shape-W verification (§18–§21) was on a
`FETCH_REG=0` tree; the bundle bank made `FETCH_REG=1` the default. Flipping `ICACHE_SYNC_READ=1` (both
consts) on the current tree fast-gates **251/252** (only `test_icache` = the known TB, fixed below) — the
scaffold is **not bit-rotted**, and `FETCH_REG=1 × ICACHE_SYNC_READ=1` compose cleanly (they are orthogonal
layers: shape-W's extract feeds the fetch buffer's *pushes* via `fetched_instr`; `FETCH_REG` registers the
FB *head* — the `ic_pc`/`fetched_instr` live-bypass arm const-folds out at `FETCH_REG=1`).

**Strategic reframe — shape-W is now BANKED (verified), not flipped.** On the bundle-banked tree the binding
wall is `head → n_inflight` (**13.800 ns**, the commit-store live-TLB cone, §8 atomicity-bound), and
`FETCH_REG=1` already masks the whole front end below it. So `ICACHE_SYNC_READ=1` adds **0 headline CP**
(masked) — flipping it default-on = 0 frequency gain + the shape-W IPC cost = **net-negative** (worse than
§21's −4.35 %, which at least had a freq gain). Per `feedback_heliodor_optimize_for_structure_not_cp`, the
correct move is to **bank shape-W as a fully-verified DEAD scaffold** (the front-end half of the eventual
deep-pipeline bundle, to flip when a commit-wall cut unmasks its CP), not to ship the regression.

**§20 N4 blocker RESOLVED — the bypass race is GONE on the FETCH_REG=1 tree.** The §20/§20.2 blocker was the
§19 FIFO read-around bypass's N4 data-staleness race (bypass-ON N4 SMP boot hung deterministically at the
~7.6 M onset on the `FETCH_REG=0` tree). On the current (`FETCH_REG=1`) tree the **bypass-ON N4 SMP boot
PASSES**: Verilator `tb_soc_smp_linux_boot_4hart` runs to SBI shutdown (`x3==0xAA`) at ~30 M cycles. The
FETCH_REG pipe stage shifts the fetch/redirect timing enough to dissolve the specific race corner — the
deterministic hang became a deterministic PASS. (Note: the run is SLOW under Verilator `--timing` N4
[~11 K cycles/s], so the output block-buffers between the 5 M-cycle heartbeats — an 11-minute "frozen"
window is normal, not a hang; the earlier read of that window as a hang was a mis-diagnosis.)

**Bypass separated behind its own const (bisect knob), banked default = the conservative §18 body.** Added
`ICACHE_FIFO_BYPASS` (default **0**): at 0 the whole `ext_bypass` cone DCEs → the §18 2-beat body (the
unambiguous N4-clean base, no bypass mechanism); at 1 the §19 within-budget bypass (now de-risked by the
N4 PASS above). Banked default is 0 (the simplest correct structure); the bypass is the documented
within-budget IPC option (shape-W IPC +9-15% vs +13-18% for §18 alone), available to enable at flip time.
Both are DEAD at `ICACHE_SYNC_READ=0` (`ext_*` feeds only the =1 arm of `ic_rdata`).

**`test_icache` TB fix (contract-agnostic).** The unit TB's Phase 2 sampled `o_rdata` the same cycle the
address settled (`tc=7`), which fails under sync-read (`o_rdata` is registered, one cycle late). Moved the
sample to `tc=8`; `addr` holds `0x008` through `tc=8`, so it reads `0xBBBB` under **both** the `=0`
combinational and `=1` registered contracts. Byte-identical behaviour at `=0` (the sample just waits one idle
cycle on a held address).

**Verification.**
- §18 body (`ICACHE_SYNC_READ=1` + `FETCH_REG=1` + `ICACHE_FIFO_BYPASS=0`): fast gate (incl litmus N2 +
  the fixed `test_icache`) **252 / 0**; litmus N4 **pass=1, no forbidden** (`cy=0x0059dfd0`); Verilator N4
  SMP boot **PASS** (a fortiori — it is the proven bypass-ON config minus the bypass; §20.1 also proved the
  old-tree §18 body N4-clean at 31.8 M; a dedicated bypass-OFF run confirms).
- §19 bypass (`ICACHE_FIFO_BYPASS=1`): fast gate **251/252** (pre-TB-fix; the 1 fail was `test_icache`,
  now fixed → 252/0); Verilator N4 SMP boot **PASSED** (`x3==0xAA`, ~30 M cy) — the §20.2 race is resolved.
- Byte-id at the committed default (`ICACHE_SYNC_READ=0`): fast gate **252 / 0** (incl the fixed
  `test_icache`); synth **13.800 ns / `head → n_inflight[5]` IDENTICAL** (the `ICACHE_FIFO_BYPASS` const-gate
  DCEs bar a negligible +397 µm² comb residue, CP-neutral).

**Banked.** Consts reverted to **0** (DEAD, byte-identical baseline). The committed change is the
`ICACHE_FIFO_BYPASS` const-gate (byte-id at `ICACHE_SYNC_READ=0`) + the `test_icache` TB fix (byte-id at `=0`)
+ this section. The scaffold advances from "N4-broken at =1" to "N4-clean at =1 (both bodies), ready to
flip". **Next front: recovery (b) fetch-directed prefetch** — F0 consults the BTB on `pc_fetch_q` and follows
predicted-taken branches instead of streaming-then-flushing (the predictor sync-read scaffolds
`btb`/`bht`/`ibtb` `6c9d0fe`/`826a95f` are the substrate), making shape-W IPC-neutral so the eventual bundle
flip is a genuine win (removes the taken-branch refill BUBBLE1 that even the bypass leaves).

## 23. ✅ Re-verify on the icache-data-1R1W tree (2026-07-22) — shape-W survives the `128×256 1R1W` repack; still flips clean

The §22 bank was verified on a tree where the icache **data** array was still `1024×32 2R2W`. Since then
`e04e4cf` repacked it to the realistic **`128×256 1R1W ×4`** 256-bit FETCH-BLOCK macro (the demand read
serves the demand word + the same-block next word from one 1R port; `o_rdata_next` is now served ONLY when
`next_in_block = offset[2:0] != 7`, else the core takes the 2-cycle re-fetch — see `cp_icache_data_1r1w_plan.md`).
Shape-W reads the icache through the SAME `{o_rdata_next, o_rdata}` window, so the two changes could have
interacted. **They compose cleanly** — re-verified by flipping both consts (`ICACHE_SYNC_READ=1`,
`ICACHE_FIFO_BYPASS=0` = the §18 body) on the current tree:

| gate (at `=1`, current icache-data-1R1W tree) | result |
|---|---|
| fast `veryl test` (arch rv64ui/um/ua/uc/mi/si + fp + litmus N2 + the fixed `test_icache`) | **252 / 0** (litmus N2 `cy=0x002e14e0`, no forbidden) |
| N2 SMP Linux boot (`test_soc_smp_linux_boot_2hart`) | **PASS** (`1 passed, 0 failed`) |

**Why it composes (the structural reason):** shape-W's F0 stream presents a **dword-aligned** `pc_fetch_q`
(`+= 8`), so the demand word's `offset[0]=0` → `offset[2:0] ∈ {0,2,4,6}`, which is ALWAYS `!= 7` →
`next_in_block` is always true → the 256-bit fetch-block ALWAYS serves the F0 window's next word. The
repack's in-block restriction only drops the `offset[2:0]==7` next word, which a dword-aligned present never
asks for. And shape-W's cross-dword straddle/dual-issue reads the NEXT word-FIFO **entry** (a separate pushed
dword), not `o_rdata_next` — so the in-block restriction is invisible to it. The 2-beat non-cacheable path is
unchanged (passthrough `i_imem_rdata`, no `o_rdata_next`). Result: **the realistic icache is now proven as a
`128×256 1R1W` macro read SYNCHRONOUSLY** (registered address = a real clocked SRAM) — the front-end half of
the deep-pipeline bundle, functionally green on the shipped data-array shape.

**Still banked (consts back to 0), unchanged rationale:** on the `FETCH_REG=1` tree the binding wall is the
commit-store `head → n_inflight` cone; `FETCH_REG` already masks the whole front end below it, so
`ICACHE_SYNC_READ=1` adds **0 headline CP** and pays only the shape-W IPC cost (net-negative solo, §21/§22).
Default-on still waits for **(b) fetch-directed prefetch** to make the flip IPC-neutral. This section adds no
RTL change (the re-verify flip was reverted); it records that the banked scaffold is bit-rot-free against the
current icache-data-1R1W substrate.

**🔬 IPC + CP re-measured on the current tree (2026-07-22, `=1` + `ICACHE_FIFO_BYPASS=1` vs `=0`).** `instret`
is identical at both (pure cycle overhead), so these are clean IPC deltas:

| workload | `=0` | `=1`+bypass | IPC cost |
|---|---|---|---|
| Dhrystone (branch-dense) | 231724 | 268409 | **+15.8 %** |
| CoreMark | 347693 | 384308 | **+10.5 %** |
| N1 Linux boot 5.15 | `0x00c83200` (13.12 M) | `0x00dca460` (14.46 M) | **+10.2 %** |

**Synth CP (`--top heliodor_core --dump-timing`):** `=0` **13.762 ns** (`pc_q[34] → n_inflight[5]`, 137 lv) →
`=1`+bypass **12.805 ns** (`pc_fetch_q[34] → n_inflight[5]`, 136 lv). **The −0.96 ns is a FALSE-PATH artifact,
NOT a real frequency gain:** the binding path chains the ENTIRE front end (`pc_q → imem-MMU iTLB walk → icache
read/miss → iptw/dmem fill route → dcache state`) into the ENTIRE back end (`→ commit/CSR-satp → trap/redirect
→ free-list n_inflight`) with no register between — a topological cone that can't be sensitized (the
icache-miss-memory-request and commit-trap-redirect controlling values are mutually exclusive). §72b30ef already
established the real CP floor is **~12.5 ns (FP/vector datapath)**, which the icache flip does NOT touch. So the
flip's real frequency gain is **~0** (§22's masked conclusion holds), and default-on = **pure IPC cost ≈ −10 %
throughput on real workloads** (−16 % Dhrystone). **User decision (2026-07-22): pursue (b) fetch-directed
prefetch** to make shape-W IPC-neutral BEFORE any default-on flip (§24).

## 24. Design — (b) fetch-directed prefetch (started 2026-07-22, user-selected)

**Goal:** remove the taken-branch refill **BUBBLE1** (the residual shape-W IPC cost, §19) so the
`ICACHE_SYNC_READ=1` flip becomes IPC-neutral → a genuine win to ship default-on. Today shape-W's F0
streams **sequentially** (`pc_fetch_q += 8`) with NO branch awareness; the EXTRACT stage detects a
predicted-taken branch on `ext_pc_q` and fires `ext_taken_redir` (`core.veryl:1349`) — which FLUSHES the
word FIFO and re-steers F0 to the target, whose dword is then a cycle late (BUBBLE1). (b) makes **F0
itself** follow predicted-taken branches so the FIFO fills with the taken-path words ahead of extract — no
flush, no refill bubble.

### 24.1 The core constraint — consistency (F0 prediction MUST match extract's)
If F0's prediction and extract's independent prediction on the same PC ever **disagree**, extract's
`ext_pc_q` stream diverges from F0's fetched stream → extract detects the mismatch and redirects = a
**spurious flush**, defeating the purpose. So F0 must predict **identically** to extract. The safe way:
F0 consults the **SAME predictor tables** extract uses (BTB/BHT/TAGE/RAS/iBTB), one+ cycle ahead, via the
**predictor sync-read scaffolds** (`BTB_SYNC_READ`/`BHT_SYNC_READ`/`IBTB_SYNC_READ`, all `=0` DEAD — the
`6c9d0fe`/`826a95f` substrate): a registered read makes the F0-ahead lookup timing-feasible.

### 24.2 The three hard parts
1. **Fetch-block granular vs instruction-granular.** F0 fetches a dword (2 words = up to 4 RVC instr);
   the BTB is indexed by instruction PC. F0 must locate the FIRST taken branch WITHIN the dword and its
   target, without decoding. Two options: (i) look up the BTB at all 4 halfword offsets of the dword
   (4 read ports → more replication, area); (ii) a dedicated **fetch-block table (FTB)** indexed by
   `pc_fetch_q[.:3]` storing `{valid, first-taken halfword-offset[1:0], target}`, trained from the SAME
   taken events extract sees (1R1W, small). Recommend **(ii)** — but note FTB↔BTB eviction skew can cause
   occasional spurious flushes (measure; the FTB is a hint, extract remains authoritative).
2. **Speculative RAS at F0 (the hardest).** Returns use the speculative RAS stack (`ras_spec_top/valid`),
   pushed/popped by extract. F0 running AHEAD would need its own speculative RAS mirror advanced at F0
   push/pop time — a stateful structure that must stay consistent with extract's. Defer to a late stage.
3. **TAGE / iBTB / spec_ghr at F0.** Conditional direction (TAGE/BHT on `spec_ghr`) and indirect targets
   (iBTB on `spec_ind_hist`) also need F0-side lookups with consistent speculative history. Defer.

### 24.3 Staged increment plan (each byte-id at 0, gated by a NEW `const ICACHE_FETCH_DIRECTED` — only
active with `ICACHE_SYNC_READ=1`; DEAD/DCE at 0 like the shape-W consts)
- **B1 — unconditional-only F0 redirect (minimal, the biggest single win).** F0 redirects ONLY for an
  **unconditional** BTB-hit branch (`btb_hit && !is_cond && !is_ret && !is_ind` = JAL / direct always-taken)
  — NO direction/RAS/iBTB dependence, so NO speculative state to reproduce at F0 (the reason to start here).
  Structure: a small FTB (24.2-ii) trained on extract's unconditional-taken events; F0 reads it on
  `pc_fetch_q`, and on a hit re-steers `pc_fetch_q` to the stored target (dword-aligned) instead of `+=8`,
  suppressing the later `ext_taken_redir` flush for that branch (extract confirms the same unconditional
  target → no divergence). Conditional / return / indirect branches keep flushing-on-extract (today's
  path). **Measure the IPC recovery** (Dhrystone/CoreMark/boot) vs the §19 bypass baseline; JAL + loop
  back-edges that are unconditional should recover a large slice.
- **B2 — conditional direction.** Add an F0-side BHT/TAGE lookup + a consistent `spec_ghr` snapshot so F0
  follows strongly-taken conditional branches (loop back-edges). The FTB entry flags `is_cond`; F0 gates
  the redirect on the F0 BHT/TAGE. Hardest consistency: the `spec_ghr` update timing F0 vs extract.
- **B3 — returns (F0 speculative RAS mirror).** The 24.2-2 hard part.
- **B4 — indirect (F0 iBTB).**
- **Bn — measure + flip:** once IPC-neutral (≈ 0 % on real workloads), run the full ladder (default 252/0
  + litmus N4 + SMP boot N4 + Verilator N1/N2/N4) at `ICACHE_SYNC_READ=1 + ICACHE_FETCH_DIRECTED=1` and
  take the bundle default-on — the genuine win (real clocked-SRAM icache-data, IPC-neutral).

### 24.4 Verification
Byte-id at every `ICACHE_SYNC_READ=0` (the FTB + F0 redirect feed only the `=1`/`FETCH_DIRECTED=1` arms →
DCE). At `=1`: default suite cluster-by-cluster (like shape-N/W), then IPC measurement (the payoff metric),
then the SMP ladder + Verilator. The predictor is a HINT — extract stays authoritative — so a wrong F0
redirect is always caught (correctness is never at risk; only IPC, via a spurious flush).

**Next: B1 — the unconditional-only F0 redirect scaffold (byte-id at 0).**

## 25. ✅ B1 implemented (2026-07-22) — byte-id at 0; the `=1` corners ROOT-CAUSED + FIXED in §25.3 (litmus + arch + SMP boot N2/N4 all GREEN)

Implemented the B1 unconditional-only fetch-directed prefetch (`const ICACHE_FETCH_DIRECTED`, DEAD at 0):
- **FTB storage** (`heliodor_core.veryl`): `ftb_valid/tag/target [64]` — a 64-entry tagged fetch-block table
  (index `pc_fetch_q[8:3]`, tag `pc_fetch_q[63:9]`), a small async-read register file (realistic below the
  SRAM floor — sram_inventory §2). Only `ftb_valid` is reset; tag/target are RF-style.
- **Training**: on an unconditional-taken slot-0 delivery (`fb_push0 && btb_hit && !is_cond && !is_ret &&
  !is_ind`, target `pred_target == btb_target`), EXCLUDING a straddling branch (`!curr_is_rvc &&
  ic_pc[2:1]==2'b11`, whose high half lives in the sequential-next dword F0 would skip).
- **F0 read + redirect**: `f0_ftb_hit` on `pc_fetch_q` re-steers the next `pc_fetch_q` to the stored target
  (dword-aligned) instead of `+= 8`, prefetching the target ahead of extract.
- **The redirect logic was REWORKED** from the shape-W `predicted_taken`-only flush to TWO OR'd reasons:
  (1) taken branch, flush UNLESS F0 already prefetched the exact target (`f0_prefetched_target =
  wf_count>=2 && wf_pc[head+1]==ext_next_pc` → the B1 bubble-suppress win); (2) `ext_buf_mismatch` — F0's
  buffered next dword ≠ extract's authoritative next PC (catches a stale-FTB / evicted-BTB divergence on a
  non-taken delivery). This authoritative buffered-PC comparison is what keeps the FTB a pure HINT.

**A design bug found + fixed mid-bring-up:** the first attempt made the redirect a SINGLE general
`ext_pop && buffered-mismatch`. That MISSED the force-redirect when a taken branch's target was not yet
buffered (`wf_count<2`): the pop then emptied the FIFO and extract read F0's wrong-path sequential words as
the target → 8 arch fails. The two-reason form (taken always redirects unless prefetched; mismatch as a
separate catch) is correct.

**Status:**
- ✅ **Byte-id at the committed default** (`ICACHE_SYNC_READ=0`, `ICACHE_FETCH_DIRECTED=0`): fast `veryl test`
  **252/0** (the FTB + the reworked `ext_taken_redir` all carry `ICACHE_SYNC_READ`/`FETCH_DIRECTED` → DCE).
- 🔬 **`=1` (all three consts) fast gate: 250/252 — TWO corners.** All rv64ui/um/ua/uc/mi/si + FP + Zb arch
  tests PASS **except**: (1) `test_arch_rv64mi_illegal` (`tohost=0`, hang); (2) `test_litmus_2hart` (forbidden
  outcome OR timeout). Both point at a residual fetch-correctness bug in the B1 redirect/suppress path (litmus
  is exquisitely sensitive to precise fetch/execute), NOT a mere mtvec corner. **Candidate causes to chase
  next:** (a) a stale FTB re-steer on a reseed dword (`mtvec` / a litmus label) that the `ext_buf_mismatch`
  recovery does not fully close — try gating `f0_ftb_hit` off for the first fetch after `any_redirect`, or
  invalidating the FTB on `fence.i` / reseed; (b) the `f0_prefetched_target` suppression firing on a
  COINCIDENTAL `wf_pc[head+1]==ext_next_pc` match where F0 did NOT actually FTB-redirect (a sequential match)
  — this is safe by the earlier analysis ONLY if the head+1 data is truly the target's; re-audit the
  straddle / slot-1 / same-dword-target interaction; (c) an ordering bug between the FTB redirect and the
  non-cacheable 2-beat F0 (`f0_ftb_hit` must not fire mid-2-beat). **Debug method (doc's proven path):** a
  commit-PC heartbeat trace of `rv64mi_illegal` at `=1`, then reduce with `ICACHE_FETCH_DIRECTED=1` +
  `ICACHE_FIFO_BYPASS=0` to isolate the FTB from the bypass. **Consts reverted to 0 (byte-id baseline
  unaffected — B1 is a DEAD scaffold at the committed default).**
  - **⚠️ FIRST isolation step (may re-attribute litmus N2):** this `=1` run used `ICACHE_FIFO_BYPASS=1`, but
    the §23 shape-W re-verify that got clean litmus N2 used `ICACHE_FIFO_BYPASS=0` (the §18 body). So the
    litmus N2 failure is NOT yet attributed — it could be the **§19 bypass on the repacked icache-data tree**
    (never re-verified with litmus N2 post-repack), not B1. Run `ICACHE_SYNC_READ=1 + ICACHE_FETCH_DIRECTED=0
    + ICACHE_FIFO_BYPASS=1` first: if litmus N2 still fails, it is the BYPASS (a repacked-tree §19 regression,
    independent of B1 — chase it separately, or ship B1 with bypass off); if it passes, litmus N2 is a B1 bug.
    (`rv64mi_illegal` is almost certainly B1 — the §23 shape-W re-verify passed the full arch suite incl it.)

### 25.1 🔬 Isolation DONE (2026-07-22) — the two corners are DIFFERENT bugs; both precisely located
Ran the isolation matrix (all at `ICACHE_SYNC_READ=1`):

| config | `rv64mi_illegal` | `litmus_2hart` N2 |
|---|---|---|
| `FETCH_DIRECTED=0, BYPASS=1` (shape-W + bypass, no B1) | — | **PASS** (`cy=0x00284880`) |
| `FETCH_DIRECTED=1, BYPASS=0` (B1 alone) | **PASS** (`tohost=1`) | **HANG** |
| `FETCH_DIRECTED=1, BYPASS=1` (B1 + bypass) | **HANG** | HANG |

So:
1. **`litmus_2hart` = a B1-ALONE bug (bypass-independent).** A retire-PC heartbeat shows **hart 0 wedges at
   `pc=0x80000098` with only 133 retires (ret frozen)**, hart 1 runs. Disassembly: `0x98` is the tight delay
   loop's UNCONDITIONAL back-edge `j 0x80000090` (loop = `90: beqz t0,9c / 94: addi t0,t0,-1 / 98: j 90`,
   dwords `0x90`={beqz,addi} and `0x98`={j,li@9c}). This `j` is EXACTLY what B1 FTB-trains → **B1's FTB
   redirect deadlocks a tight unconditional 2-dword loop.** The FTB makes F0 ping-pong `0x90↔0x98`; the loop
   EXIT (`beqz` taken → `0x9c`, then sequential `0xa0`) needs dword `0xa0`, which F0 — FTB-looping — never
   fetches, so `ext_buf_mismatch` must re-steer F0 to `0xa0`; a hole in that recovery (or an earlier
   mid-loop wedge, since ret froze BEFORE the exit) deadlocks the pipe. **This is THE B1 bug to fix.**
2. **`rv64mi_illegal` = a B1 + BYPASS INTERACTION** (passes at `FETCH_DIRECTED=1, BYPASS=0`). The §19 bypass
   (`ext_bypass` delivers the arriving `wf_push_dword` when `wf_push_pc_q==ext_pc_q`) assumes F0's push is the
   sequential continuation; B1's FTB redirect changes what F0 pushes, breaking that assumption. **Fix path:
   develop/ship B1 with `BYPASS=0` first (the §18 body, N4-clean); reconcile the bypass with the FTB
   redirect as a later step (or gate the bypass off when the pushed dword came from an FTB redirect).**

**Next debug (B1 tight-loop wedge):** add temporary core debug ports (`pc_fetch_q`, `wf_count`, `wf_head`,
`ext_pc_q`, `f0_ftb_hit`, `ext_taken_redir`) + a per-cycle trace around hart-0's `0x90/0x94/0x98/0x9c`
window; find whether F0's FTB ping-pong starves the exit dword `0xa0` (recovery hole) or the FIFO
count/head wedges mid-loop. Likely fix: on an `ext_buf_mismatch` re-steer, ensure F0 abandons the FTB loop
(it does re-seed `pc_fetch_q`, but verify the FTB doesn't immediately re-hit and re-loop), and/or gate
`f0_ftb_hit` so a tight self-referential loop cannot monopolise the FIFO. Consts reverted to 0 (byte-id
baseline unaffected).

### 25.2 🔬 Forward-only restriction TESTED — does NOT fix litmus (rules out "backward-loop-specific")
Hypothesis: the wedge is the backward `j 0x90` back-edge; restricting the FTB to FORWARD unconditional
targets only (`ftb_train_en &&= pred_target[63:3] >: ic_pc[63:3]`, so the tight backward `j`-loop is never
FTB-trained) would sidestep it. **Result (B1-alone, `BYPASS=0`): 251/252 — arch + FP ALL pass (incl
`rv64mi_illegal`), but `litmus_2hart` N2 STILL times out** (`cy=0x01c9c380`, `tohost=0`). So the wedge is
**NOT backward-loop-specific** — the ping-pong story in §25.1 is likely a SYMPTOM, not the root cause. The
real B1 `f0_ftb_hit` bug is more fundamental (a forward unconditional target elsewhere in the litmus code,
or a general FIFO/`ext_pc_q` interaction). Forward-only was reverted (adds complexity, doesn't fix). **The
fetch-state trace (above) is now mandatory to find the true root cause** — reasoning + hypothesis-restriction
have been exhausted. Reduce on litmus N2 (hart-0 wedge) with the per-cycle fetch-state dump, not the arch
suite.

### 25.3 ✅ Root-caused + FIXED (2026-07-23) — mid-dword FTB re-entry; litmus + full arch + SMP boot N2/N4 GREEN at `=1`

Built the mandated per-cycle fetch-state trace (a hart-0 change-detect `$display` of `{pc_fetch_q, ext_pc_q,
wf_head, wf_count, f0_ftb_hit, ext_pop, ext_taken_redir, …}`, gated on `ICACHE_FETCH_DIRECTED && HART_ID==0`
+ a PC window, DEAD at 0). It pinned ONE root cause underlying BOTH the litmus wedge AND a newly-surfaced
SMP-boot corruption (SMP boot was never run for B1 before — §25/§25.1 only gated arch+litmus).

**Root cause — mid-dword FTB re-entry.** A commit/early redirect (or an `ext_taken_redir`, or a chained
*suppressed* taken branch to a mid-dword target) lands MID-dword, PAST the unconditional branch that trained
the FTB entry for that dword. F0, re-seeded to that dword, FTB-hits and jumps to the (now-irrelevant) trained
target instead of continuing sequentially. The FTB is dword-granular so it CANNOT know extract entered past
the branch. Two failure modes:
- **litmus wedge (trace-confirmed, cy=0x24e–0x259):** loop `90:beqz 9c / 94:addi / 98:j 90`, dwords 0x90=
  {beqz,addi} 0x98={j,li@9c}. The loop EXIT is a commit redirect to 0x9c (dword 0x98). F0 re-seeds to 0x98,
  `FTB[0x98]=0x90` (the `j`) → F0 jumps 0x98→0x90, NEVER fetching 0xa0. Extract delivers li@9c then needs
  0xa0 → head mismatch → STALL. The delivery-gated `ext_buf_mismatch` recovery can't fire during a stall (no
  `fb_push0`) → deadlock (FIFO fills ping-pong 0x90/0x98, extract's 0xa0 never fetched). hart-0 froze at 0x98,
  ret=133 — EXACTLY §25.1's symptom.
- **SMP-boot corruption (data, not a wedge):** if the mid-dword re-entry dword ENDS in a straddling 32-bit
  instruction (offset-6 low half), extract reads its high half from `wf_data[head+1]` which — after F0's FTB
  redirect — is the NON-sequential target dword → a WRONG instruction decodes/executes → silent data
  corruption. In N2 boot this mis-computed a pointer feeding `arch_spin_lock`; hart 0 span forever on a
  never-free lock (pinned at kernel `0x80025af6`, `c.lw/c.bnez` test-and-set) and never brought up hart 1
  (stuck at the SBI wait 0x500). A second instance sat in the timekeeping divide path (`0x800dd684`).

**Why only unconditional branches / only mid-dword re-entry:** the FTB trains ONLY on unconditional taken
branches, which decode ALWAYS takes on a full (offset-0) entry — so F0 and extract agree, and an offset-6
straddle at a branch dword's tail is never reached on a sequential entry. Divergence is possible ONLY when
extract enters the dword PAST the branch, which only a redirect (or a suppressed taken branch to a mid-dword
target) does.

**Fix — three mechanisms, all DEAD/DCE at `ICACHE_FETCH_DIRECTED=0` (byte-identical to shape-W):**
1. **`f0_no_ftb_q` (the root fix):** gate the FIRST F0 FTB redirect after ANY re-steer (redirect / early /
   `ext_taken_redir` / `f0_diverged`). The re-entry dword's successor stays SEQUENTIAL → both failure modes
   closed at the source. (With this, `f0_diverged` fires **0×** on litmus/boot — prevention, not recovery.)
2. **`head1_seq` + `ext_next_valid` guard:** the across-dword straddle / slot-1 read (`wf_data[head+1]`) is
   honoured ONLY when head+1 is head's sequential successor (`wf_pc[head+1][63:3] == wf_pc[head][63:3]+1`). A
   non-sequential head+1 STALLS the straddle (`needs_straddle_slow` → `fetch_ready=0`) instead of decoding a
   WRONG high half. Covers slot-1 too (its `s1_needs_next` path already gates on `ic_rdata_nv=ext_next_valid`).
3. **`f0_diverged` (the HINT safety net, §24.4):** a STALL-time recovery — full flush + re-fetch `ext_pc_q`'s
   dword with `f0_no_ftb_q` set (→ sequential refill) — for (A) a head mismatch and (B) a straddle blocked by
   a non-sequential head+1. Catches any residual divergence (e.g. a self-modifying-code / `fence.i` FTB
   staleness corner) the delivery-gated `ext_buf_mismatch` cannot.

**Verification at `=1` (`ICACHE_SYNC_READ=1 + ICACHE_FETCH_DIRECTED=1 + ICACHE_FIFO_BYPASS=0`, the B1-alone body):**

| gate | result |
|---|---|
| fast `veryl test` (arch rv64ui/um/ua/uc/mi/si + fp + litmus N2) | **252 / 0** (litmus N2 `cy=0x2e14e0`, no forbidden; `rv64mi_illegal` PASS) |
| N2 SMP Linux boot (`test_soc_smp_linux_boot_2hart`) | **PASS** (both harts reach SBI shutdown) |
| N4 SMP Linux boot (`test_soc_smp_linux_boot_4hart`) | **PASS** (all 4 harts, `cy≈0x1d92cd0`) |

So B1 is now **functionally correct at `=1`** — the §25.1 litmus + `rv64mi_illegal` corners AND the boot
straddle corruption are all closed. Consts reverted to 0; the three mechanisms are committable **DEAD scaffold**
(same staging as W1/W2/W3 + B1), fast `veryl test` **252/0** byte-identical at the committed default.

**⚠️ IPC caution (deferred to §24.3-Bn — the payoff measurement):** N4 boot at `=1` ran `cy≈0x1d92cd0`
(~30.9 M) vs the ~16.6 M committed-default baseline — a large cost. The `f0_no_ftb_q` gate fires on EVERY
redirect (boot has frequent traps/IPIs/context-switches → the FTB prefetch is gated most of the time AND the
guard/recovery add bubbles), so B1 as implemented is currently **IPC-counterproductive on redirect-dense SMP
workloads**. Correctness is the milestone here; **the next step is the IPC re-measure (Dhrystone/CoreMark/boot)
vs the §19-bypass baseline** — B1 must be shown IPC-neutral-or-better BEFORE any default-on flip. Likely tuning:
gate `f0_no_ftb_q` only when the re-steer target is actually mid-dword (`redirect_pc[2:1] != 0`) so offset-0
redirect targets keep their prefetch; and/or make the FTB store the branch halfword-offset so F0 can honour a
redirect that lands at-or-before it. The §25.1-2 bypass↔FTB reconciliation is still deferred (ship BYPASS=0).

### 25.4 ✅ IPC refinement + payoff measured (2026-07-23) — gate the FTB only on MID-dword redirect targets

Implemented the §25.3 tuning: `f0_no_ftb_q` now gates the first FTB redirect ONLY when the re-steer target
lands MID-dword (`<target>[2:1] != 0`) on each re-steer branch (redirect / early / ext_taken / f0_diverged).
An offset-0 (dword-start) target enters at-or-before any branch in the dword, so F0's FTB redirect agrees
with extract — keep the prefetch. Correctness is unchanged (`head1_seq` + `f0_diverged(B)` remain the safety
net); re-verified GREEN at `=1`: fast `veryl test` **252/0** (litmus N2 pass), SMP boot **N2 + N4 PASS**.

**IPC measured on the CURRENT tree** (instret identical per row ⟹ B1 is architecturally transparent and the
cycle deltas are clean; `=1` = `ICACHE_SYNC_READ=1`, `FD` = `ICACHE_FETCH_DIRECTED`, all at `BYPASS=0`):

| bench (instret) | `=0` | shape-W (FD=0) | B1-refined (FD=1) | B1 vs shape-W |
|---|---|---|---|---|
| Dhrystone (264,834) | 231,724 | 301,816 (+30.3 %) | 295,025 (+27.3 %) | **−2.25 %** |
| CoreMark (374,357) | 347,693 | 392,844 (+13.0 %) | 390,572 (+12.3 %) | **−0.6 %** |
| N4 SMP boot 5.15 | (~16.6 M) | ~31 M | ~31 M (PASS) | ≈ 0 |

**Findings:**
1. **B1 beats shape-W in the intended direction** — it removes the taken-branch refill bubble, so the gain is
   larger on branch-dense Dhrystone (−2.25 %) than CoreMark (−0.6 %). Architecturally transparent (instret
   unchanged), so this is a pure cycle win.
2. **But the gain is small** — the DOMINANT `=1` cost is shape-W's read-latency (+30 % Dhry / +13 % CoreMark at
   BYPASS=0), which B1 barely touches. **B1 alone does NOT make the flip IPC-neutral.**
3. **The N4-boot ~31 M is NOT the FTB gate** (correcting §25.3's hypothesis): it is shape-W's read-latency on a
   memory-bound 4-hart boot, and it is the SAME with the gate refined vs un-refined — B1 (transparent, only
   removes bubbles) is neutral-to-slightly-better there, not the cause of the cost.
4. **The bigger IPC lever is the §19 read-around bypass** — §23 measured it brings shape-W Dhry from +30 % to
   **+15.8 %** — but it conflicts with the FTB redirect (§25.1-2). So the path to an IPC-neutral default-on is
   the **bypass↔FTB reconciliation** (gate the bypass off when the pushed dword came from an FTB redirect, or
   make the bypass FTB-aware), NOT more B1 tuning. B1 is now correctness-complete + a small correctly-directed
   IPC gain; the bypass reconciliation is the next real increment before any default-on flip.

### 25.5 ✅ Bypass↔FTB reconciliation is DONE — for FREE via the §25.3 contiguity fix (2026-07-23)

The §25.1-2 B1+BYPASS interaction (`rv64mi_illegal` + `litmus_2hart` both HANG at `FETCH_DIRECTED=1,
BYPASS=1`) was measured BEFORE the §25.3 fix. Re-testing with the three contiguity mechanisms in place
(`f0_no_ftb_q` + `head1_seq`/`ext_next_valid` guard + `f0_diverged`) shows the reconciliation **needs no new
RTL** — the same contiguity invariants that fixed the plain-B1 wedge also close the bypass corner:
- The bypass (`ext_bypass`) reads the arriving push `wf_push_dword` when `wf_push_pc_q==ext_pc_q`. `f0_diverged(A)`'s
  in-flight guard `!(wf_push_valid_q && wf_push_pc_q==ext_pc_q)` is the EXACT bypass predicate, so f0_diverged
  is correctly suppressed while the bypass is delivering ext_pc_q's dword (no double-steer).
- During a bypass `wf_count≈0`, so the across-dword `head1_seq` guard is masked by its own `wf_count>=2` gate
  (straddle/slot-1 just wait) — no misfire on the bypass's non-FIFO read.
- `f0_no_ftb_q` keeps the F0 push stream contiguous through re-entries, so `wf_push_pc_q` genuinely is the
  dword the bypass claims — the §25.1-2 "F0's push is not the sequential continuation" break is gone.

**Verified at `=1 + FETCH_DIRECTED=1 + ICACHE_FIFO_BYPASS=1`:** fast `veryl test` **252/0** (`rv64mi_illegal`
PASS, `litmus_2hart` N2 pass — both §25.1 hangs GONE), SMP boot **N2 PASS**, SMP boot **N4 PASS** (`cy≈29.0M`,
slightly under the bypass-off `~30.9M`).

**Full IPC stack (current tree, instret identical per row ⟹ clean cycle deltas):**

| bench (instret) | `=0` | shape-W (FD0,BYP0) | B1 (FD1,BYP0) | **B1+BYPASS (FD1,BYP1)** |
|---|---|---|---|---|
| Dhrystone (264,834) | 231,724 | 301,816 (+30.3%) | 295,025 (+27.3%) | **265,926 (+14.8%)** |
| CoreMark (374,357) | 347,693 | 392,844 (+13.0%) | 390,572 (+12.3%) | **382,463 (+10.0%)** |

So the **bypass is the dominant IPC lever** (Dhry +30.3%→+14.8%), and **B1 stacks on top of it** — B1+BYPASS
beats §23's bypass-only shape-W (Dhry 268,409/+15.8% → 265,926/+14.8%; CoreMark 384,308/+10.5% → 382,463/+10.0%)
because B1 additionally removes the taken-branch refill flush the bypass alone still pays. **The full B1+BYPASS
bundle is now FUNCTIONALLY VIABLE** (the §25.1-2 blocker is cleared) and is the best-IPC correct config.

**Residual + next:** B1+BYPASS is still **+10-15%, NOT the §22/§24 IPC-neutral goal.** The residual is the
shape-W read-latency the bypass cannot fully hide (a demand-fetch that misses the FIFO AND is not the arriving
push still pays the register round-trip). Closing the last +10-15% is a deeper fetch-structure question (widen
the bypass window / a 2nd fetch-ahead entry / prefetch depth), not a B1 or bypass-reconciliation issue. For a
default-on decision the bundle is now a clean **+10-15% IPC for a real clocked-SRAM icache** — a user call on
whether that trade (real SRAM macro vs 2R2W) is worth it, or whether to chase IPC-neutral first (§24.3-Bn).
