# R3 — reorder atomics through the store-queue + coherence (the SMP finale)

Block R of Phase-14 (`phase14_frontend_deep_ooo_plan.md`). The **last fused piece** of
the canonical-LSQ redesign: replace the single-cycle in-cache atomic RMW commit with a
**multi-cycle store-queue-based atomic** that acquires ownership and performs its RMW under
the coherence protocol, tolerant of pipeline slip. **Highest SMP risk in the whole campaign
— the litmus / M3b minefield.** The study (`retire_memory_ordering_redesign_study.md §4`)
scopes this as "large — bigger than the whole campaign so far … multi-turn, SMP-gated" and
says explicitly *do not start it autonomously.* User chose it 2026-07-27 (over L3 / declare-
complete) as the next block; F+S+L1+L2 are done.

Status: **design, grounded in the atomic-machinery audit.** No R3 RTL yet.

---

## 0. 🚨 Honest framing — R3's CP/enable motivation is currently LATENT (EX_PIPE banked)

R3's headline motivation in the study is: *remove the M3b single-cycle-atomic constraint so
EX_PIPE (execute staging) can be enabled + translate-at-execute works for atomics.* But **S1
banked EX_PIPE at 0** (its boot corner + −15 % IPC, 2026-07-27). At `EX_PIPE=0` the M3b gate
`amo_cwr_en = … && (dc_amo_present || !EX_PIPE)` (`heliodor_core.veryl:8182`) takes the
`!EX_PIPE`=1 arm — the presence check is bypassed, the single-cycle commit is unconstrained,
and there is **no active M3b hazard today.** So R3 is **not** unblocking a live problem.

What R3 IS worth, with EX_PIPE banked:
- **(a) structural canonicalisation** — atomics stop being a single-cycle-commit special case
  fused at the ROB head; they retire into the SQ like stores (the canonical-LSQ end state).
- **(b) IPC on contended atomics** — a contended atomic no longer holds the ROB head for its
  single-cycle in-cache write; it retires and the write drains (post-P9.3.B contended atomics
  already pay line-bounce/RFO cost, and today block the head while paying it).
- **(c) future EX_PIPE re-enablement** — once R3 removes the single-cycle constraint, the
  EX_PIPE boot corner's *atomic* facet is gone (though EX_PIPE also has the separate early-
  paging corner from S1, so R3 alone does not re-enable EX_PIPE).

This is a real structural advance (per the Phase-14 "advance FINAL structure, CP-neutral is
still progress" mandate), but it is the **highest-risk** one and its CP payoff is deferred.
Weigh (b)'s IPC-on-contended-atomics against the SMP-validation cost before the flip.

---

## 1. The current single-cycle in-cache atomic RMW (what R3 replaces)

Audited machinery (anchors in `heliodor_core.veryl` unless noted):

**Execute (the AMO is at the ROB head, P9.3 issues at head):**
- `issue_amo_read` (:5950) → `dc_amo_read` (:7085) drives the dcache **RFO**: E/M hit serves
  locally; S hit upgrades in place; miss fills E/M (`dcache.veryl:454 amo_upg`, `p93_c2c_amo_
  design.md §2`). The line is acquired **exclusive**.
- `amo_exec_capture` (:6455) registers, at the access cycle:
  - `ac_pa_q` (:6562) = translated PA (held issue→commit, avoids re-driving the TLB at commit).
  - `ac_wok_q` (:6563) = R+W fault-free at issue.
  - `amo_watch_valid_q`/`_pa_q`/`_rob_q` (:3437-3440) = the RMW-window watch.
  - `amo_poison_q` = immediate check for a concurrent inv/evict to the captured line (:6538).
- The ALU computes `new = old OP src`; `rd ← old` broadcasts on the CDB at execute.

**Commit (single-cycle, the load-bearing piece):**
- `amo_cwr_en` (:8182) = `store_drive && sb_empty && ac_wok_q && (dc_amo_present || !EX_PIPE)`.
  When it fires, the pre-computed `new` value is written **into the E/M-owned line in one
  cycle** (`i_wen_excl` merge, `dcache.veryl:37`). No bus, no multi-cycle.
- `sb_empty` (release order: all older stores drained first); `ac_wok_q` (fault-OK);
  `dc_amo_present` (the M3b gate, EX_PIPE-only).

**Atomicity guarantee (watch/poison/replay):**
- Between capture and commit, a remote RFO recall / local evict / precise-inv to the watched
  line sets `amo_poison_q` (`amo_remote_hit` :6456, sources `i_dcache_inv*` :129-136,
  `dc_evict*` :6316-6319, `!dc_amo_present`).
- `commit_amo_replay` (:4646) suppresses the commit and **redirects to the AMO's PC** →
  re-execute → re-RFO → re-read → re-compute. The watch clears on `rob_commit_ack` (:6469),
  not `rob_commit_valid` (P9.3: the read arms while already at head).
- **Ownership pin** (`dcache.veryl:587 pin_cnt_q`, bounded 64 cy): defers remote probes to the
  pinned line so a spin-loop's RFO cannot be stolen mid-RMW → forward progress; releases on
  the commit write or at the 64-cy watchdog.

**LR/SC** (parallel, `rsv_valid_q`/`rsv_pa_q` :3401-3409, `sc_watch` :3427, `sc_may_clear`
:6301): PA-line-granular reservation, killed by remote inv / evict / program-order SC. R3
must keep SC's reservation-check semantics; only the SC *store* write shares the commit path.

**The M3b constraint:** the single-cycle commit write is atomic *because* it happens in one
cycle into a line the pin holds E/M. A +1-cy slip (EX_PIPE) opens a window where the recall
and the write coincide → the write leaks into a recalled line → lost update (litmus N2 Test 7
`0x701`). The `dc_amo_present` gate closes it *by re-checking presence the write cycle.* R3
removes the single-cycle assumption entirely.

---

## 2. The R3 target + the fundamental atomicity challenge

**Target:** the atomic **retires into the SQ** (pointer bump, frees its ROB entry) like a
store; the write drains multi-cycle from the SQ under coherence. This takes the atomic off the
single-cycle-commit critical path and off the ROB-head serialisation.

**🚨 The crux (why this is the minefield):** once an atomic **retires**, it **cannot be
replayed** — replay today is a PC redirect, only possible while it still owns a ROB entry. So
an atomic that has retired into the SQ *must complete its RMW atomically no matter what
coherence does.* Two sound ways to guarantee that; R3 must pick and prove one:

- **(A) Ownership-locked drain (LL-style).** The atomic holds E/M ownership continuously from
  the execute-time read through the SQ drain write (extend the `pin` across retire). Because
  the line never leaves, the execute-time `old` value stays valid and the pre-computed `new`
  is written unmodified. A remote request to the line is **deferred** (not NAK'd) until the SQ
  entry drains. Risk: a deferred remote request bounded by the pin watchdog must not deadlock
  under contention; the SQ-held atomic must be the *oldest* memory op (ordering).
- **(B) Re-read-at-drain (compute-at-drain).** The SQ entry carries `{pa, amo_op, src}` (not a
  pre-computed `new`); at drain it RFOs, reads the *current* value, computes, writes — all as
  one coherence transaction the home serialises. Then `rd ← old` cannot be written at execute
  (the value isn't final until drain) → breaks the current execute-time `rd` writeback →
  atomic result writeback must also move to drain (a deferred-CDB, like the MSHR path). Bigger,
  but this is what real cores do (atomics are performed at the memory system, not speculatively).

**Recommendation (to be confirmed at design time):** start from **(A)** — it reuses the pin +
watch machinery, keeps `rd ← old` at execute, and is the smaller delta from today's proven
scheme (today's commit write already assumes continuous ownership; R3-A just lets the atomic
*retire* before that write drains, holding the pin across retire). (B) is the fully-canonical
end state; treat it as R3-far if (A)'s ordering proves insufficient.

**SQ vs the committed-store buffer:** the atomic drain can reuse the existing committed-store-
buffer drain port (`sb_pop`, `dcache i_wen_excl`) — a dedicated **atomic-SQ entry** carries
the extra atomic state (op, watch, pin-hold) and drains through the same dcache write port,
serialised after older stores (`sb_empty`-equivalent ordering preserved).

---

## 3. SMP invariants R3 must preserve (non-negotiable)

1. **Atomicity under coherence.** No remote write may interleave between the atomic's read and
   its write becoming globally visible. (A) holds ownership; (B) serialises at the home.
2. **Release order.** The atomic write drains only after all older stores (today `sb_empty`);
   a `.rl` atomic is a release. FENCE/`c_serial` retire only after the SQ (incl. the atomic)
   drains (`!(c_serial && !sb_empty)` :168 — extend to the atomic-SQ).
3. **Acquire order.** A `.aq` atomic's *read* orders younger loads (today via the head
   serialisation + watch); retiring the atomic early must not let a younger load pass its read.
4. **LR/SC unchanged.** SC still checks the reservation (`sc_may_clear`) and only its store
   write moves to the SQ; the reservation kill-set is untouched.
5. **Forward progress.** The pin watchdog (64 cy) must still break a contended ping-pong; an
   SQ-held atomic that cannot drain (line perpetually stolen) must fall back (bounded).
6. **No new comb loop.** The atomic-SQ presence/poison must read *registered* dcache tag state
   (like `dc_amo_present` :8315 does today), never the live MMU/dcache comb cone.

**Litmus guards (must not regress — commit before ANY flip):**
- **Test 7 AMO atomicity** (`test/litmus/litmus.S:373-397`, forbidden `0x701`): N harts'
  `amoadd.w` on a shared counter; lost update = fail. *The exact M3b case.*
- **Test 8 LR/SC lock** (`:399-431`, forbidden `0x801`): mutual exclusion.
- **Test 6 aq/rl release** (`:335-371`): `.rl` write / `.aq` read ordering.
- **Tests 2/3 fence** (`:180-283`): atomic must drain before a fence completes.
- Full ladder EVERY step: default 252/0 · litmus N2/N4 · **SMP boot N2/N4** · **Verilator NBA**
  (caught MEM_PIPE M-stage bugs the Veryl sim masked) · ACT4. Dual metric CP + IPC (contended-
  atomic microbench + boot-cy).

---

## 4. Decomposition — DEAD-scaffold increments (byte-identical at 0, flip last)

Const `ATOMIC_SQ: bit = 0` gates every increment; each new register's D is const-gated (the
§10.10 rule: a DEAD reg whose D-cone doesn't mirror a live signal is NOT synth-neutral unless
its D is const-gated). Byte-identical proof = existing SV verbatim + additions const-inert.

- **R3.0 — atomic-SQ substrate (this block's first increment).** Declare the `ATOMIC_SQ` const
  + a small atomic-SQ entry array (`asq_valid/pa/op/src/watch/pin_hold`, `ASQ_N=1..2`) with
  reset-only + const-gated writes, and a **dual-path `amo_cwr_en` mux** whose `ATOMIC_SQ` arm
  const-folds to the live single-cycle path at =0. No functional change. Verify: 252/0, litmus
  N2 cycle-exact, synth FF/CP unchanged (const-gated D). *Ground the structure; do not flip.*
- **R3.1 — retire-into-SQ (alloc + head-release).** At the atomic's commit, instead of the
  single-cycle write, allocate the atomic-SQ entry (carrying the execute-captured `ac_pa_q` +
  pre-computed `new` for scheme A) and **retire** (free the ROB entry, pointer bump). The write
  is now pending in the SQ. `rob_commit_ack` for the atomic no longer waits the in-cache write.
  Gated `ATOMIC_SQ`. This is where head-serialisation is lifted.
- **R3.2 — ownership-locked drain + coherence poison (scheme A).** Extend the pin to hold E/M
  across the atomic's retire→drain; the SQ entry drains the write through the dcache `i_wen_
  excl` port when it is the oldest memory op + owns the line. A remote request to the held line
  is deferred (pin) until drain; if the pin watchdog trips (contention), fall back (bounded —
  design TBD: re-acquire + re-drain, since replay is no longer available). Wire the fence/`.rl`
  drain-ordering and `.aq` read-ordering.
- **R3.3 — flip + litmus closure.** Flip `ATOMIC_SQ=1`; run the FULL ladder (litmus N2/N4 +
  SMP boot N2/N4 + Verilator + ACT4) + contended-atomic IPC. Debug the minefield corners
  (expect several — this is Test-7/Test-8 territory). Ship decision (=0 validated DEAD vs =1),
  per the campaign's structural-mandate framing.

**Anchors to touch:** `amo_cwr_en` (:8182) + commit mux (:8183); `ac_pa_q`/`ac_wok_q` alloc
(:6561-6565) → asq alloc; `amo_watch_*_q` (:3437-3440) → asq watch fields; `commit_amo_replay`
(:4646) / retire gate (`rob_commit_ack` :4702) → SQ-decoupled retire; `dcache.veryl` pin
(:587, :1529) → cross-retire hold; `sb_empty` (:911) / `c_serial` drain (:168) → atomic-SQ
ordering; presence `dc_amo_present` (:8315) → asq-driven.

## 5. Sequencing note
Per the study's "do not start R3 autonomously" + the campaign's "clean-context start for a
fresh block" pattern (used for S1): build **R3.0 from a clean context**, verify byte-identical,
then R3.1→R3.3 across sessions with the full ladder at each functional step. R3.2's ownership-
locked-drain fallback (what happens when a retired atomic cannot drain) is the single hardest
design question — resolve it before R3.1's head-release lands.
