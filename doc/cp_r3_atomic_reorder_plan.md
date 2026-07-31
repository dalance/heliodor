# R3 — reorder atomics through the store-queue + coherence (the SMP finale)

Block R of Phase-14 (`phase14_frontend_deep_ooo_plan.md`). The **last fused piece** of
the canonical-LSQ redesign: replace the single-cycle in-cache atomic RMW commit with a
**multi-cycle store-queue-based atomic** that acquires ownership and performs its RMW under
the coherence protocol, tolerant of pipeline slip. **Highest SMP risk in the whole campaign
— the litmus / M3b minefield.** The study (`retire_memory_ordering_redesign_study.md §4`)
scopes this as "large — bigger than the whole campaign so far … multi-turn, SMP-gated" and
says explicitly *do not start it autonomously.* User chose it 2026-07-27 (over L3 / declare-
complete) as the next block; F+S+L1+L2 are done.

Status: 🏁 **SHIPPED LIVE — `ATOMIC_SQ = 1`** (2026-07-28, user's ship decision at §7.16).
R3.0 + R3.1 + R3.2a/b + the §7.11/§7.13 fixes are on the default path: without-return atomics
(`rd == x0`) now retire into the atomic store-queue and their RMW drains at the memory system
under coherence, instead of being a single-cycle in-cache commit fused at the ROB head. Design
RESOLVED (§6); validation gap CLOSED (§7.1); **both `=1` bugs found and fixed** (§7.11 M-stage
double-write, §7.13 the stale `asq_divert_q` latch killing unrelated atomics' writes). **Every
gate passes at `=1`**: `veryl test` 252/0 · litmus N2 **and N4** · dhrystone bit-exact · N=1
boot · N=2 SMP boot (cycle-identical) · **N=4 SMP boot 29.28 M vs 30.55 M = −4.2 %** ·
**Verilator NBA 4/4** (§7.14) · **ACT4 696/0** (§7.15).
🏁 **R3.2c (§6.5) is ALSO SHIPPED — `ASQ_NOREAD = 1`** (2026-07-31, §7.20): the class does only
translate + fault-check at execute. Four real bugs fixed on the way, the last (§7.18) a
**pre-existing** one — an atomic held at the ROB head could become `sb_elig` and retire through
the committed-store buffer as a plain store. Ladder at `=1`: 252/0 · litmus N2/N4 · dhrystone
bit-exact · boot N1/N2/N4 · **ACT4 696/0** · **Verilator NBA 4/4** (§7.19). Cost-neutral.

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

> **⚠️ SUPERSEDED at design time (2026-07-27) — see §6.** (A) was analysed and **rejected**: its
> "hold ownership across retire" needs an unbounded pin, which re-opens the very deadlock cycle
> the 64-cy watchdog exists to break, and the pin does not stop *local* eviction either. The
> resolved design splits on `rd`: **(B) for atomics whose result is architecturally dead
> (`rd == x0`)**, today's proven head-serialised path for everything else. §6 is authoritative.

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

- **R3.0 — atomic-SQ substrate (this block's first increment). ✅ BUILT, DEAD at 0.** Declares
  `const ATOMIC_SQ = 0` / `ASQ_N = 1` + the entry array with reset-only, const-gated writes, and
  the dual-path write-enable, all at `heliodor_core.veryl` immediately after `amo_cwr_en`.
  Shipped shape (scheme A, so the entry carries the write verbatim rather than `op/src`):
  `asq_valid_q / asq_pa_q (=ac_pa_q) / asq_data_q (the pre-computed new) / asq_strb_q /
  asq_excl_q (=ac_wexcl_q) / asq_wpa_q (watch, for R3.2's cross-retire pin) / asq_pin_q`.
  `asq_alloc = ATOMIC_SQ && amo_commit_live && ac_wok_q && !asq_full` mirrors R3.1's intent
  (book the entry the cycle the in-cache write would have fired); `asq_drain = ATOMIC_SQ &&
  asq_valid_q[0] && sb_empty` mirrors R3.2's (release-order gate preserved). The mux is
  `amo_cwr_eff = ATOMIC_SQ ? asq_drain : amo_cwr_en` — **`amo_cwr_en` itself is untouched**, so
  the =0 arm is the proven expression (the `alu_cdb_eff` / `c_store_eff_pa` idiom); the two
  consumers (`dmem_wen_m`, `dmem_wexcl_m`) read `_eff`.
  **Verified:** SV diff = the existing `amo_cwr_en` expression verbatim + const-gated additions
  (`ATOMIC_SQ` is a `localparam bit = 0`, so both arms are constant 0 and the mux selector is
  constant) · `veryl test` **252/0** · litmus N2 **cycle-exact** (`cy=0x282170`, = baseline) ·
  no `veryl check` warning names the new signals · synth-neutral by the §10.10 const-gated-D
  rule. *Structure grounded; not flipped — R3.0 at =1 is non-functional by construction (no
  drain machinery yet), which is why the flip is R3.3.*
  > **Metric note (learned at R3.1):** a raw `veryl check` warning COUNT is not a valid
  > baseline comparison — it is build-cache dependent (only re-processed files re-emit), and
  > the same tree reported 4856 / 4666 / 735 on consecutive runs. Compare by *name* instead
  > (grep the new signals), which is what the R3.0 and R3.1 checks actually establish.
- **R3.1 — classify + retire-into-SQ (alloc + head-release). ✅ BUILT, DEAD at 0.** Entry
  re-shaped to the §6 operand set (`asq_pa/src/op/sz/aq/rl_q`, replacing R3.0's scheme-A
  `data/strb/wpa/pin`), and — like `sb_elig`/`sb_full`/`sb_empty` — the const, the array and
  `asq_full`/`asq_empty`/`asq_ld_ovl` moved up to the store-buffer forward declarations,
  because retire/fence/issue all read the queue state above the entry's D-cone. Shipped:
  - **class predicate** `asq_class` (just above `rob_commit_ack`): `ATOMIC_SQ && c_is_amo &&
    !c_is_cas_q && c_rd_arch == 0 && funct5 ∉ {LR 00010, SC 00011, amocas 00101} &&
    ac_wexcl_q && ac_wok_q`. `asq_takeover = asq_class && !asq_full` (retire relaxation) and
    **`asq_stall = asq_class && asq_full`** (the matching hold — see the corner below).
  - **alloc** `ATOMIC_SQ && amo_commit_live && asq_class && !asq_full`; `src` is read from
    `arch_regs[c_instr[24:20]]` at commit (the amocas.q commit-operand idiom — the atomic is
    at the head and retires in order, so the architectural rs2 is authoritative), op/size/aq/rl
    off `c_instr`.
  - **retire** (`rob_commit_ack`): the `dcache_stall || sb_empty` in-cache-write wait is
    bypassed for `asq_takeover`; **`&& !asq_stall`** added.
  - **§6.4 ordering:** `asq_ld_ovl` (page-offset dword compare mirroring `sb_ld_ovl`) added to
    `load_blocks_on_store` for loads *and* AMO reads — the entry cannot forward, so overlapping
    younger accesses wait, which also discharges `.aq`; the FENCE gate becomes
    `!(c_serial && !(sb_empty && asq_empty))`.
  - **`amo_cwr_eff`** now keeps the live in-cache write for non-class atomics at =1
    (`asq_drain || (amo_cwr_en && !asq_class)`).

  **Corner found and fixed during the build (would be a silently lost atomic at =1):** a class
  atomic never performs the in-cache write (`!asq_class` masks it), so when the queue is full
  it can neither allocate nor write — the un-relaxed retire gate would still let it retire with
  its write nowhere. `asq_stall` holds it at the head until the entry drains (bounded).

  **Verified (=0):** `veryl test` **252/0** · litmus N2 **cycle-exact** `cy=0x282170` ·
  dhrystone **instret 264834 bit-exact** (252939 cy = post-S1 baseline) · **N=1 boot
  `cy=0x0d99720` cycle-identical to R3.0** · **N=2 SMP boot `cy=0x125bb50` = 19.25M**, the S1
  ship figure · no `veryl check` warning names the new signals.

  **Not yet functional at =1** — `asq_drain` is still R3.0's placeholder (it frees the entry
  without performing the RMW), so the queue would swallow the write. R3.2 builds the engine.
- **R3.2 — compute-at-drain engine (scheme B, `rd == x0` only).** The entry drains as one
  owned-line transaction: RFO → read → `new = old OP src` → write through the dcache
  `i_wen_excl` port, when it is the oldest memory op. **The fallback question dissolves**: no
  architectural state depends on any intermediate, so a stolen line means *retry the drain*,
  never a replay (§6.2). Once the drain owns the line the existing pin covers the single write
  cycle exactly as today — no pin extension, no watch, no poison for this class. Split three
  ways because the port arbitration is the risky part and deserves its own verified step:
  - **R3.2a — engine (datapath + FSM). ✅ BUILT, DEAD at 0.** `asq_dr_st_q`
    IDLE→RD(ownership read)→WR(exclusive merge)→IDLE, started on `asq_valid_q[0] && sb_empty`;
    `asq_dr_old_q` captures the read dword; `asq_dr_poison` (the execute-side watch's own
    sources — `i_dcache_inv/inv2`, `dc_evict1/2` — compared against the entry's line) sends the
    engine **back to RD**, so a stale `old` can never reach the write. That retry *is* the
    fallback. The RMW replicates alu_wrap's M5.A compute on the queued operands (right-align by
    byte offset → width-extend → the nine RMW ops → re-shift with a funct3 strobe); LR/SC/
    amocas cannot appear. `asq_drain` becomes `asq_dr_wdone`, replacing R3.0's placeholder.
    **Comb-loop corner found and fixed:** the `amo_cwr_eff` drain arm must be the REQUEST
    (`asq_dr_wen`, a pure function of the FSM register), never the completion (`asq_dr_wdone`,
    which reads `dcache_stall`) — routing the completion there closes
    write-enable → `dcache_stall` → `wdone` → write-enable, and Veryl's detector is structural
    (it does not fold the `ATOMIC_SQ=0` constant away, so the loop is a hard build error even
    DEAD). Whether the write landed only ever advances the FSM.
    **Verified (=0):** 252/0 · litmus N2 `cy=0x282170` · dhrystone 252939 cy / instret 264834
    (identical to R3.1) · N=1 boot `cy=0x0d99720` cycle-identical. Two expected `unused`
    warnings (`asq_dr_wstrb`, `asq_dr_wdata`) — the engine's outputs have no consumer until
    R3.2b.
  - **R3.2b — port arbitration. ✅ BUILT, DEAD at 0.** The engine is an **opportunistic**
    requester: `asq_dr_port_ok = !ptw_dc_active && !amo_commit_live && !m_ren_q && !m_wen_q &&
    !lsr_drive && !replay_drive` qualifies both `asq_dr_go_r`/`asq_dr_go_w`, so it drives the
    shared port only on cycles nobody else owns it. That is a correctness requirement, not
    politeness — the M-stage request is registered, so stealing its cycle would *drop* it, and
    stealing an LSR/replay/PTW cycle would make the engine capture someone else's data.
    Because `go_*` already excludes every other user, the seven new mux arms (`dmem_pa_m`,
    `ren`, `wen`, `wstrb`, `wdata`, `amord`, `wexcl`) are mutually exclusive with the existing
    ones by construction and fold away at =0. The read asserts `dmem_amord_m` (RFO — the
    engine needs ownership, exactly like the execute-side AMO read); the write is the
    exclusive merge, and since `asq_class` requires `ac_wexcl_q` the merge arm is always the
    right one (no MMIO write-through can reach the queue).
    **Anti-starvation, from the other side:** while `asq_dr_busy`, new load/AMO *issue* is
    held (`load_blocks_on_store`), so the port quiesces as in-flight accesses retire and the
    engine gets its cycles — instead of the engine preempting anyone.
    **WR watchdog:** the exclusive merge only lands while the line is owned; departures
    normally announce themselves via `asq_dr_poison`, but a 128-cycle bound (twice the dcache
    pin's own) re-enters **RD** if the merge is held that long. It never "writes anyway" — the
    `old` behind the value is always freshly read.
    **Correction it also carried:** R3.2a had put `asq_dr_wen` into `amo_cwr_eff`, which is
    only selected under `amo_commit_live` — i.e. during a *commit*, never during a drain. That
    term was dead; the drain's real write is the new `dmem_wen_m` arm. `amo_cwr_eff` is now
    just `amo_cwr_en && !asq_class` (suppress the class's in-cache write at =1).
    **Verified (=0):** 252/0 · litmus N2 `cy=0x282170` · dhrystone 252939 cy / instret 264834 ·
    N=1 boot `cy=0x0d99720` · N=2 SMP boot `cy=0x125bb50` — all cycle-identical to R3.2a · the
    two R3.2a `unused` warnings are gone (the outputs now have consumers).
  - **R3.2c — §6.5. ✅ BUILT + root-caused — see §7.17/§7.18.** Drops the class's execute-time
    read (`issue_amo_read`, the RFO, the fetch handshake, the watch, the poison, the replay, and
    the ROB load record). Four real bugs found and fixed building it; the last (§7.18) is a
    **pre-existing** hole — `sb_2cyc_ok` was missing `!c_is_amo`, so a held atomic could retire
    through the store buffer as a plain store. Found by budget bisection to the exact
    instruction. With the guard, the full ladder passes at `=1`.

---

## 7. First flip probe (2026-07-27) — two findings, one of them a validation-plan problem

`ATOMIC_SQ=1` was run early, *before* R3.2c, deliberately: with the execute-time read still in
place, any failure is attributable to the queue/drain machinery alone rather than confounded
with the read removal. Reverted to `=0` afterwards; the tree ships DEAD.

### 7.1 🚨 The litmus battery cannot exercise this class at all

At `=1` the whole default suite was **252/0 with litmus N2 `cy=0x282170` — cycle-identical to
`=0`**. That is not a pass; it means the class never fired. A probe on every AMO commit showed
`wexcl=0` universally: `ac_wexcl_q`'s cacheability test excludes
`dmu_dmem_addr[31:14] == 18'h20000`, i.e. **PA 0x80000000-0x80003FFF** (a 16 KB window around
the riscv-tests tohost page). And `litmus.ld` puts the barrier at **0x80002000** and the test
variables at **0x80003000** — both inside it. Every litmus and arch-test atomic is therefore
non-cacheable, so `asq_class` (which requires `ac_wexcl_q`) can never match.

**Consequence: the guards §3 names — Test 7 (`amoadd.w x0`, the exact M3b case), Test 6, Test 8
— could not validate the R3 path as the tests stood.**

**✅ RESOLVED (option (a), user's call, 2026-07-27):** `.barrier` → **0x80006000** and `.vars` →
**0x80007000** (`litmus.ld` + the hardcoded `li s3/s4` bases in `litmus.S` + the harness's
barrier watch words `dram[6144]`/`dram[6160]` in `tb/test_litmus.veryl`). `.result`
(0x80004000) and `.scratch` (0x80005000) were already outside the window and did not move.
Option (b) — narrowing the RTL's `[31:14]` window — was declined: it touches live behaviour and
would need its own validation, while (a) touches only the test.

This is a **test-strengthening** change, not merely an R3 enabler: the litmus battery had never
exercised the in-cache MESI atomic write path *at all*, on any prior campaign step. It passes
at `ATOMIC_SQ=0`, so that path is sound — but the baselines move, because the atomics now pay
real ownership/line-bounce cost:

| | before (write-through atomics) | after (cacheable atomics) |
|---|---|---|
| litmus N2 | `cy=0x282170` (2.63 M) | **`cy=0x2e3bf0` (3.03 M), +15 %** |

| litmus N4 | `cy=0x55ce90`-ish (5.63 M, S1 figure) | **`cy=0x398690` (3.77 M), −33 %** |

N4 gets *faster* because a non-cacheable atomic went out over the bus on every operation,
while an owned-line merge is cheap even when the line bounces; N2 gets slower because two harts
now RFO-ping-pong a line that used to be write-through. Both pass. `veryl test` stays 252/0.
**Use the new figures as the litmus baseline from here on** — the `0x282170` quoted in
R3.0/R3.1/R3.2's evidence refers to the old, weaker image.

**And it immediately paid for itself.** With the relocation in place, `ATOMIC_SQ=1` fails
litmus N2 in ~3 M cycles with **`tohost=0x7012`** → `0x701` = **test 7, slot 1 = the AMO
atomicity forbidden outcome**, i.e. the lost update §3 named as *the exact M3b case*. So the
battery now guards the R3 path for real, and §7.2's ordering work has a **fast, precise
reproducer** instead of a 45 M-cycle boot wedge. Debug §7.2 against `test_litmus_2hart`, not
the boot.

### 7.2 Two real design gaps the boot found

- **Port-ownership deadlock (understood, fixed).** `asq_dr_port_ok` treated `amo_commit_live`
  as "someone else owns the port". But a *class* atomic's commit drives no write
  (`amo_cwr_eff` masks it) and no read (the M-stage read arm is already gated off by
  `amo_commit_live`) — and when the queue is full the class atomic waits at the head on
  `asq_stall`, holding `amo_commit_live=1` the whole time, which would keep the drain from ever
  getting the port that frees the entry. Qualified with `!asq_class`; **kept** (a `=1`-only
  refinement, inert at 0).
- **Younger-store ordering hole (open — needs a design decision).** §6.4 blocks younger *loads*
  and AMO reads from passing the queued atomic, but says nothing about younger **stores**. The
  drain waits for `sb_empty`, so a younger store that reached the store buffer drains **first**,
  and the drain then reads a value that already includes it — program order inverted.
  The naive fix (hold store *retire* while the queue is occupied) **deadlocks**: a store held at
  the head keeps driving `store_drive` → `dc_i_wen` → `m_wen_q=1` every cycle, so
  `asq_dr_port_ok` never opens and the queue never drains. Evidence: allocations collapsed
  1798 → 39 and the boot wedged earlier. Reverted.
  The real fix has to gate the younger store's **write drive** (`store_drive` / `fast_store` /
  the `sb_push`), not its retire — i.e. it lands in the store commit path, which is the memory-
  ordering heart of the machine.

### 7.3 §7.2 hardening landed; the flip still fails — hand off to a trace session

Four fixes were designed and built against the §7.1 reproducer. All are individually justified
and all are DEAD at 0 (the tree ships `=0`, re-verified: 252/0 · dhrystone 252939 / 264834 ·
N=1 boot `cy=0x0d99720`):

1. **Younger-store ordering (§7.2's real fix).** `asq_st_block = !asq_empty` now gates
   `store_drive` **and** `fast_store` **and** the store's retire. Gating the drive is the part
   the first attempt missed, and it is what breaks that attempt's deadlock.
2. **Alloc-time ordering anchor.** `asq_alloc` now also requires `sb_empty`, so an entry only
   enters the queue once every OLDER store is visible. Together with (1) — younger stores held
   out until it drains — the queued RMW is pinned to its program-order position without the
   drain having to reason about the buffer.
3. **Presence-based drain poison.** `asq_dr_poison` gains `asq_dr_st_q == WR && !dc_amo_present`,
   and the dcache's `chk3` port is borrowed for the drain's line while `asq_dr_busy`. inv/evict
   pulses alone are *not* a sufficient departure signal — a remote RFO recall can take the line
   without one, which is exactly why the execute-side `amo_remote_hit` carries `!dc_amo_present`.
   Safe to borrow: while the drain is busy no load/AMO may issue and no store may retire.
4. **🚨 The write-mask/alloc unification — a silently lost atomic.** `amo_cwr_eff` masked the
   in-cache write on **`asq_class`** (mere class membership), while `asq_alloc` carries extra
   conditions (`!asq_full`, `sb_empty`). A class-eligible atomic that could **not** allocate
   therefore had its write suppressed *and* retired through the normal path — **its write
   went nowhere.** Diverting the write and booking the entry are one decision and must be one
   predicate: the mask is now `!asq_alloc`, `asq_takeover` mirrors the same conditions, and
   `asq_stall` is deleted (an atomic that cannot be booked simply takes today's proven path,
   so there is no longer anything to stall for).

**The flip still fails**, identically: litmus N2 `cy=0x2d9fb0`, `tohost=0x7012` (test 7 slot 1).

### 7.4 Trace session — what the drain actually does (and what it is NOT)

Instrumented every commit and every drain write landing on test 7's `x` line (0x80007000) at
`=1`. **The drain path is not the problem:**

| measurement | value |
|---|---|
| AMO commits at `x` | 4000 |
| of which booked an entry (`alloc=1`) | 3000 |
| of which wrote in-cache (`cwr=1`) | 1000 |
| queue full at commit (`full=1`) | **0** |
| drain writes at `x` | 3000 — **exactly the alloc count** |
| drain writes that are `new == old + 1` | 2000, **1000 per hart** |
| duplicate `(old, new)` pairs among those | **0** |

So every atomic took exactly one path, every booked entry drained, and **no two drains ever
read the same `old`** — the compute-at-drain RMW is genuinely atomic under contention, which is
the core thing R3 had to prove. The §7.2 fixes are doing their job.

**The failure is elsewhere: `x` ends at ~4000, not 2000** (max `new` observed = 3999). Test 7
does 2000 `amoadd`s and asserts `x == 2*AMO_ITER`; it fails on *inequality*, so "too large"
lands in the same slot as "lost update" — the slot name ("lost AMO update(s)") misled the whole
first round of analysis. **Test 7 does not zero `x` on entry** (`t7_ok` clears it on the way
*out*), so it inherits whatever the preceding tests left.

**Leading hypothesis for the next session:** at `=1`, `x` is already ~2000 when test 7 starts —
i.e. an earlier test's cleanup store (`sw x0, 0(s4)`) is being **overtaken by a queued atomic's
drain**, which lands after the reset and resurrects a stale value. That is still the §7.2
ordering family, but on the path `asq_st_block` does not cover, so the next probe is narrow and
cheap: **print `x` at test-7 entry** (and at each test boundary), and if it is non-zero, trace
which drain wrote it after the reset store.

### 7.5 Write-order trace + a build sanity check — where the next session should start

Traced **every write landing on `x`, on both dcache write paths** (the main port = atomic
commit write + queue drain; the store-buffer drain port = plain stores, including the tests'
`sw x0, 0(s4)` resets), qualified to the cycle each write actually lands.

**Accounting, and it closes exactly:** the 4000 commits at `x` are `2000 amoadd (test 7) +
1000 unlock amoswap (test 8) + 1000 sc.w (test 8)`. `alloc=3000` = the amoadds + the unlock
swaps (both class); `cwr=1000` = the SC writes (SC is not in the class). **Every commit takes
exactly one path — there is no double-apply per commit.** A `drw=0` write immediately followed
by a `drw=1` write, which looked like one atomic applying twice, is two *different* atomics
(one that could not book an entry because the queue was still full, then the next one's drain).

**A diversion latch was added anyway** (`asq_divert_q`, set on alloc, cleared on the atomic's
`rob_commit_ack`) because the live-state suppression it replaces really is unsound in
principle: the drain can finish while the atomic is still at the head, and then nothing holds
`amo_cwr_en` down. It is kept, but it **changed nothing** — like every other fix in this round.

**🚨 Build sanity check — the toolchain is NOT the problem.** Eight substantive RTL edits in a
row producing bit-identical output justified checking the obvious: forcing `asq_class = 1'b0`
at `ATOMIC_SQ=1` makes litmus **pass at `cy=0x2e3bf0`, exactly the `=0` baseline**. So the
build/sim pipeline responds correctly, the DEAD-at-0 folding is real, and the class path is
genuinely the only thing at fault. *(Worth repeating whenever a run stops responding to edits —
it is one cheap run and it separates "wrong fix" from "wrong binary".)*

**So the remaining fact to explain is arithmetic, not mechanism:** 2000 atomic, non-duplicated
`+1` drains land on `x`, yet `x` reaches 3999. Those two statements are only compatible if
**`x` was already ~2000 when test 7's loop started** — i.e. the residue hypothesis of §7.4
stands and is now the *only* survivor. Start there: dump `x` at each test boundary (the WSB
trace already shows plain stores of 0/1 to `x` from tests 0-1, so the instrumentation exists),
find the last test that leaves `x` non-zero at `=1` but zero at `=0`, and diff that test's
write order between the two builds.

### 7.6 The residue hypothesis is DEAD — it is a clean factor of two

Captured the same x-write-order trace at **both** `ATOMIC_SQ=0` and `=1` and compared:

| | `=0` (passes) | `=1` (fails) |
|---|---|---|
| writes landing on `x` | 20665 | 24170 |
| **max value written to `x`** | **2000 — exactly right** | **3999** |
| shape | — | one *continuous* run: …1999, 2000, 2001, 2002… |

`x` climbs straight past 2000 in a single unbroken sequence, so nothing was inherited from an
earlier test. **§7.4's residue hypothesis is dead.** The real fact is simpler and sharper:
**~4000 increments are applied where 2000 are expected — a clean 2×.**

That is hard to reconcile with §7.5's accounting (2000 amoadd commits, each taking exactly one
path, 2000 drain completions with non-duplicated `old`). The two are only compatible if **one
drain completion produces two increment writes on the dcache port.**

**Fix tried, correct in principle, did not move it:** the FSM gave `asq_dr_poison` priority over
`asq_dr_wdone`, so a departure signal arriving in the same cycle the exclusive merge landed sent
the engine back to RD — while `asq_drain` (which has no such priority) freed the entry — and it
re-read the already-updated value and applied the op again. `asq_dr_wdone` now outranks poison
(a completed write is done; a same-cycle departure refers to the line *after* it). **Kept — it
is a real ordering bug — but the result stayed bit-identical.**

**Next probe, and it is a narrow one:** count main-port *landing* writes per drain completion.
If it is 2, find why `asq_dr_go_w` presents the merge on two cycles that both see
`dcache_stall == 0` (the level-held request is the obvious suspect: the write enable is a state
decode, not a one-shot, so anything that delays the FSM's departure from WR by a cycle while the
port stays ready applies the merge twice). A one-shot / "write already issued" latch on the WR
state is the likely shape of the fix.

### 7.7 The 2× is two *landing writes*, split evenly between the two paths

Classified every landing write in test 7's increment region (from the §7.5 log, no new run):

- **3999 landing writes, values 1…3999, every value distinct, none written twice**
- split **`drw=1` (queue drain) 2000 / `drw=0` (in-cache) 1999**
- the head of the run is **hart 0 alone**, alternating `drw=0, drw=1, drw=0, …`

So it is *not* one drain landing twice (§7.6's guess). It is **both paths each applying once**
for what should be 2000 operations. **§7.5's "every commit takes exactly one path" was wrong** —
that counted *commit events*; counting *landing writes* shows otherwise.

Mechanism that fits: the atomic performs its in-cache write, but its **retire is held** (most
often by `asq_st_block`, because the queue still holds the *previous* atomic), so it stays at
the head; when the queue frees, it satisfies `asq_alloc`, books an entry, and the drain applies
the operation a second time.

**Fix built for exactly that (kept, correct in principle, still inert):** the `asq_divert_q`
latch now closes **both** directions — set on `asq_alloc` **or** on the in-cache write
(`amo_commit_live && amo_cwr_eff`), cleared on the atomic's `rob_commit_ack`, and it now gates
`asq_alloc` as well as `amo_cwr_eff`. Whichever way the atomic performed its RMW, it performs
it once.

**🚨 Honest status: ten consecutive fixes have left the result bit-identical** (`cy=0x2d9fb0`,
`tohost=0x7012`), while forcing `asq_class = 0` still flips it to a clean pass. Every guard
added so far is evidently never true in this workload — which means the *mechanism* inferred
from aggregate counts is still not the real one. **Stop inferring from counts.**

**The one instrumentation that has been missing all along: attribute each landing write to the
INSTRUCTION that caused it.** Print the committing atomic's PC (and ROB index) with every
in-cache write, and carry the allocating atomic's PC in the queue entry so the drain write can
print it too. If the two writes of a pair carry the *same* PC/ROB index, it is one instruction
applying twice and the latch must be repaired (start by checking it is not cleared in the same
cycle it is set); if they carry *different* PCs, the counting premise ("test 7 issues only 2000
amoadds") is wrong and the loop is executing ~4000 times — which would point at the retire/
redirect path, not the queue. That single measurement splits the remaining space in half; do it
before writing any more candidate fixes.

### 7.8 ✅ Attribution: every writer of `x` is correct — the queue is exonerated

Carried the allocating atomic's **PC and ROB index** in the queue entry and printed them with
every landing write on `x`, alongside the committing PC for in-cache writes. Cross-referenced
with `objdump`:

| PC | instruction | landing writes | verdict |
|---|---|---|---|
| `0x800005cc` | `t7_amo`: `amoadd.w zero,t2,(t3)` | **2000 drains** (1000/hart, all ROB indices distinct) | ✅ exactly one per instruction |
| `0x80000624` | `t8_acq`: `sc.w t2,t1,(t3)` | 1000 in-cache (SC is not in the class) | ✅ |
| `0x80000638` | test 8 unlock: `amoswap.w.rl zero,zero,(t3)` | 1000 drains | ✅ |

**All three writers are accounted for with exactly the right counts, and test 7's amoadd applies
once per instruction through the queue.** There is no double apply.

**⇒ §7.6/§7.7's "clean 2×" was an artifact of my own segmentation heuristic** (slicing the
value stream on "values > 2500" and extending backwards stitched unrelated runs together), not
a real doubling. Retracted. **The R3 queue is exonerated for the whole of test 7.**

**So the failure is not in *applying* the atomics — it is in what test 7's check observes.**
Test 7 does `barrier; lw t0, 0(s4); beq t0, 2*AMO_ITER`. With 2000 correct increments the value
must be 2000 at the check, so the next measurement is **the loaded value itself**: print `t0` at
the `lw` (PC `0x800005e0`-ish, right after `t7_sync`'s barrier) at both `=0` and `=1`. Two
outcomes, both actionable:
- **loaded value ≠ 2000 but the line's final value is 2000** → the *load* is stale: a queued
  atomic had not drained when the barrier released, i.e. the barrier/fence ordering does not
  cover the ASQ from the *observer's* side. Check that `barrier_fn`'s `amoadd.w.aqrl` (rd = t1,
  so **not** in the class → in-cache path) and its trailing `fence rw,rw` really do wait for
  `asq_empty` on **both** harts, and that a remote hart's un-drained queue cannot be passed by
  our acquire.
- **loaded value = 2000** → the failure is in the compare/record path, not the memory system at
  all, and the whole R3 line of investigation is clear.

### 7.9 The check really does load 3999 — and that un-does §7.8's exoneration

Printed the value committed by test 7's check load (`lw t0, 0(s4)`, PC `0x800005e0`) on both
builds:

| | loaded value |
|---|---|
| `ATOMIC_SQ=0` | **`0x7d0` = 2000 — correct** |
| `ATOMIC_SQ=1` | **`0xf9f` = 3999** |

So `x` genuinely holds 3999 at the check; the doubling in §7.6/§7.7 was real after all, and it
is **§7.8's exoneration that was premature** — not the other way round. The reason §7.8 looked
clean: its in-cache filter was `amo_commit_live && amo_cwr_eff`, which only catches writes
attributable to an *atomic commit*. §7.7's `drw=0` writes (1999 of them, carrying the rising
values) are **not** atomic-commit writes, so §7.8 never counted them and the PC attribution
covered only three of the four write populations.

**So the open question is precise and small: what drives the ~2000 non-atomic, rising-value
writes onto `x` via the main dcache port at `=1`?** They land, they carry `old+1`, and they
interleave one-for-one with the drains.

**Next probe (one run, decisive):** on every landing write to the `x` line
(`dmem_wen_m && !dcache_stall`), print the **mux arm that drove it** — `asq_dr_go_w`,
`amo_commit_live`, `amo_cwr_eff`, `m_wen_q`, `ptw_dc_active` — plus `dmem_wdata_m`. Exactly one
of those is high for each phantom write and it names the culprit arm. The leading suspect is the
drain's own write being presented a second time through a *different* arm after `asq_dr_go_w`
has dropped (e.g. `m_wen_q` still set, with `dmem_pa_m`/`dmem_wdata_m` still muxed to the drain's
address/data) — i.e. a mux-arm overlap introduced by R3.2b's seven new outermost arms, not a
queue-logic bug at all. Check the R3.2b arms for exactly this: they were added assuming
`asq_dr_go_*` is the *only* way the drain's address/data reach the port.

### 7.10 ✅ The culprit arm is named: `m_wen_q` + `m_wen_excl_q`

Printed, for every landing write on the `x` line, which port-mux arm drove it. **7521 landing
writes at `=1`, and they partition cleanly into three populations:**

| driving arm | count | what it is |
|---|---|---|
| **`m_wen_q = 1`, `dmem_wexcl_m = 1`, everything else 0** | **3521** | ← **the unexplained population** |
| `asq_dr_go_w = 1` | 3000 | the queue drains — legitimate |
| `amo_commit_live = 1, amo_cwr_eff = 1` | 1000 | in-cache atomic commits (the SCs) — legitimate |

So the doubling comes from **3521 writes issued off the registered M-stage
(`m_wen_q`) with the exclusive-merge flag set (`m_wen_excl_q`)** — neither a drain nor an
atomic commit. With `asq_dr_go_w = 0` the port muxes fall through to `dmem_pa_m = m_pa_q`,
`dmem_wdata_m = m_wdata_q`, `dmem_wexcl_m = m_wen_excl_q`, so this population is the M-stage
replaying an exclusive write onto `x`.

**Why this is very likely R3.2b's fault rather than a pre-existing bug:** `asq_dr_port_ok`
includes `!m_wen_q` exactly so the drain never steals a cycle from a pending M-stage write —
but the drain's *outermost* mux arms (R3.2b) override `dmem_pa_m`/`wdata`/`wstrb`/`wexcl`
whenever `asq_dr_go_r || asq_dr_go_w`, and the **read** arm (`asq_dr_go_r`) is *not* covered by
the write-side reasoning. A drain RD cycle repoints `dmem_pa_m` at the queue's line while an
M-stage store is mid-flight; that store then lands later against a different address/data
pairing than it was issued with. That is exactly the "the drain's address/data reach the port
only via `asq_dr_go_*`" assumption R3.2b was built on, and it does not hold in the other
direction: **the M-stage's address/data must not be perturbed by the drain's arms either.**

**Next step (small, and now well-aimed):** attribute those 3521 writes to instructions with the
same PC technique that worked in §7.8 (print `c_pc`/ROB index alongside `m_wen_q` writes, or
carry the issuing PC into the M-stage registers temporarily). Then fix by making the drain's
port arms *mutually exclusive with a pending M-stage write in both directions* — either extend
`asq_dr_port_ok` to gate `asq_dr_go_r` on `!m_wen_q` as well (it already does — verify it is
actually holding), or stop overriding `dmem_pa_m` on RD cycles and give the drain a dedicated
read address port.

### 7.11 ✅ ROOT CAUSE FOUND AND FIXED — the diverted write still latched into the M-stage

The measurement that cracked it was the one I had skipped all along: **run the same arm
breakdown as a control at `ATOMIC_SQ=0`.**

| driving arm | `=0` (passes) | `=1` (failed) |
|---|---|---|
| atomic commit (`amo_commit_live && amo_cwr_eff`) | **4000** — every atomic | 1000 |
| queue drain (`asq_dr_go_w`) | — | 3000 |
| **M-stage (`m_wen_q`, `m_wen_excl_q`)** | **15** — just the reset stores | **3521** |
| total | 4015 | 7521 |

15 versus 3521. The ~3500 extra M-stage writes at `=1` are exactly the 3000 atomics that went
to the queue — **each one also left a write pending in the M-stage.**

**Root cause:** suppressing `amo_cwr_eff` stops the *live* in-cache write, but `dc_i_wen` is
derived from the same `store_drive` and is latched into `m_wen_q` regardless. The diverted
write therefore lands one cycle later through the M-stage arm, and the atomic is applied
**twice** — once by the queue drain and once from the M-stage. This is what every earlier
theory was circling: it really was "both paths apply once", and §7.8's PC attribution missed it
because the second write is not attributable to an atomic *commit*.

**Fix (one line, at the M-stage capture):**
```veryl
m_wen_q = dc_i_wen && !(ATOMIC_SQ && amo_commit_live && !amo_cwr_eff);
```
An atomic whose live in-cache write was suppressed because it was diverted into the queue must
not leave an M-stage write behind either. Folds away at `ATOMIC_SQ=0`.

**Result — the flip PASSES:** `litmus(N=2) cy=0x2e6300 tohost=1 pass=1`, `veryl test` **252/0**,
dhrystone **252939 cy / instret 264834 — bit-exact with `=0`**, **N=1 Linux boot
`cy=0x0d9e540` `x3=0xAA` pass=1** (vs `0x0d99720` at `=0`: +0.03 %, IPC-neutral).

**Method note worth keeping:** ten candidate fixes failed because I kept inferring mechanism
from aggregate counts on the *failing* build alone. The decisive step was a **control run of the
same instrumentation on the passing build** — 15 vs 3521 named the population instantly. Take
the control measurement early, not after exhausting hypotheses.

### 7.12 🚨 But litmus N=4 LIVELOCKS at `=1` — the next (and now sole) blocker

With the §7.11 fix in, the N=2 ladder is green but **litmus N=4 times out**: `cy=0x1c9c380`
(30 M, the cap), `tohost=0` (timeout, *not* a forbidden outcome), ~1 h wall-clock versus ~10 min
at `=0`. So the correctness bug is fixed and what remains is a **forward-progress** problem that
only bites at four-way contention.

**Most likely cause — the drain has no ownership protection across its RD→WR window.** The
in-cache path establishes ownership and writes *in the same cycle*; the drain takes two (RD then
WR), and the dcache pin deliberately does **not** re-arm on an E/M hit to a line it is already
pinning (`dcache.veryl:1531`, `{tag,index} != pin_line_q` — the anti-starvation rule that stops
a spin loop from holding a line forever). So under N=4 every hart's drain can acquire, lose the
line to the next hart before its WR cycle, poison, re-read, and repeat — a textbook livelock,
and exactly why N=2 (where the 64-cy pin defer is enough for one hart to win) passes while N=4
does not.

**Candidate fixes, in increasing order of intrusiveness:**
1. **Single-cycle drain when the line is already owned** — if the RD hits E/M, compute and write
   the same cycle, so the drain has the same atomicity profile as today's commit write. Removes
   the window entirely for the common case; the two-cycle path stays only for the fill case.
2. **Arm the pin for the drain explicitly** — give the drain a "pin this line until my write
   lands" request, bounded by the existing watchdog. Needs a dcache port and must not reintroduce
   the starvation the `!= pin_line_q` rule prevents.
3. **Backoff on repeated poison** — count consecutive poisons for one entry and, past a
   threshold, fall back to performing the RMW at the ROB head the old way (the entry is still
   architecturally un-retired at that point only if we keep the atomic at the head, so this
   interacts with R3.1's head-release and needs care).

(1) is the natural first attempt and is a small change to the FSM.

### 7.13 ✅ N=4 fixed too — a single latch was killing unrelated atomics' writes

The N=4 probe showed **all four harts spinning at `barrier_fn+0x18`** (the sense-flag wait) with
retire counters still climbing — a livelock, not a deadlock. The barrier's
`amoadd.w.aqrl t1, t0, (s3)` has **rd = t1, so it is NOT in the class** and takes the in-cache
path; the fact that it was affected at all named the culprit:

**🚨 `asq_divert_q` is a single latch, not per-instruction.** Left set by one class atomic, it
gates `amo_cwr_eff` for whatever atomic reaches the head next — silently killing that atomic's
write. A lost barrier increment means no hart ever observes `t1 == 3`, so all four wait on the
sense flag forever. Exactly the observed state.

**Fix:** drop `asq_divert_q` from both `amo_cwr_eff` and `asq_alloc`; the per-commit
`!asq_alloc` is sufficient, because §7.11 fixes the real double-write **at its source** in the
M-stage capture. (The latch was introduced in §7.7 against a mechanism that turned out not to
be the real one — it was never load-bearing, only harmful.)

**Also added (forward progress, not correctness): a staggered retry backoff.** On poison the
engine now enters a BACKOFF state for a hart-dependent, doubling, capped interval before
re-acquiring, which desynchronises harts that would otherwise ping-pong the line in lockstep.
Correctness never depends on it — the re-read still happens, only its timing changes.

**Ladder status at `=1`:**

| check | `=0` | `=1` | delta |
|---|---|---|---|
| `veryl test` | 252/0 | **252/0** ✅ | — |
| litmus N2 | `0x2e3bf0` | **`0x2e6300` pass** ✅ | +0.09 % |
| litmus N4 | `0x398690` | **`0x39ada0` pass** ✅ | +0.24 % |
| dhrystone | 252939 cy / 264834 instret | **bit-exact** ✅ | 0 |
| N=1 boot | `0x0d99720` | **`0x0d9e540` pass** ✅ | +0.03 % |
| N=2 SMP boot | `0x125bb50` (19.25 M) | **`0x125bb50` pass** ✅ | **identical** |
| N=4 SMP boot | 30.55 M | **`0x1bec700` (29.28 M) pass** ✅ | **−4.2 %** |
| Verilator NBA (§7.14) | — | **4/4 pass** ✅ | — |
| ACT4 RVA23 (§7.15) | — | **696/0** ✅ | — |

**The entire functional ladder passes with the queue live**, at essentially neutral cost — and
the N=4 SMP boot is actually **4.2 % faster**, which is §0(b)'s contended-atomic win showing up
where four harts fight over kernel locks. (The N=4 runs took ~1 h wall-clock on this shared box;
that is host load, not a livelock — both completed and passed.)

**Remaining before a ship decision:** Verilator NBA (the SV-semantics cross-check that has
caught bugs the Veryl sim masked — including an SMP LR/SC livelock) and ACT4. Per the campaign
convention the flip itself is the user's call; the tree ships `=0` until then.

### 7.14 ✅ Verilator NBA cross-check — 4/4 pass at `=1`

The check that mattered most: standard SV non-blocking-assignment semantics, on the very
machinery (`m_wen_q` capture, the drain FSM's RD→WR window, the `asq_*` gates) whose bugs the
Veryl sim's multi-instance evaluation could in principle have masked — this is the flow that
caught the SMP LR/SC `read_lock` livelock. Built from `veryl build` output with `ATOMIC_SQ = 1`
(`heliodor_core.sv:928` `localparam bit ATOMIC_SQ = 1`), Verilator 5.050, `-O3`:

| Verilator run | result | cycles | Veryl sim `=1` | wall |
|---|---|---|---|---|
| `tb_litmus_4hart` (P9.0 RVWMO battery, N=4) | **PASS** `tohost=1`, `fail=0` | 3,778,796 | 3,779,488 (`0x39ada0`) | 7.4 min |
| `tb_soc_linux_boot` (N=1) | **PASS** `x3=0xAA` | 14,267,393 | 14,279,488 (`0x0d9e540`) | 2.4 min |
| `tb_soc_smp_linux_boot_2hart` | **PASS** `x3=0xAA` | 19,245,878 | 19,250,000 (`0x125bb50`) | 7.0 min |
| `tb_soc_smp_linux_boot_4hart` | **PASS** `x3=0xAA` | 29,277,542 | 29,279,488 (`0x1bec700`) | 59 min |

Every count agrees with the Veryl sim to **< 0.1 %** (the residual is the wrappers' reset-cycle
offset, not behaviour), so the two simulators do not merely both pass — they execute the same
schedule. The litmus histogram shows only allowed outcomes; no forbidden slot, no trap, no
timeout. In particular the N=4 litmus battery — the contended-atomic case where §7.13's
livelock lived — completes in the same ~3.78 M cycles under NBA semantics, which is the direct
evidence that the backoff/`asq_divert_q` fix is not a Veryl-sim artefact.

Build/run recipe (from the project root, per CLAUDE.md; `--Mdir sim/verilator/build_r3_*`):
`verilator --binary -j 6 --top-module <top> -f heliodor.f sim/verilator/<wrapper>.sv --timing
-Wno-fatal -O3`.

### 7.15 ✅ ACT4 RVA23 compliance — 696/0 at `=1`

`veryl test --ignored --test test_act_` over the already-generated suites (framework pinned at
`ACT_COMMIT` `0656889`): **696 passed, 0 failed** (252 ignored are the non-ACT `#[ignore]`
tests). That covers the atomic-relevant suites the class actually touches — `Zaamo`/`Zalrsc`
including the `ExceptionsSvZaamo`/`ExceptionsSvZalrsc` fault-precision groups, which is the
external check on §6.4's "translation + PMP stay at execute, so a faulting atomic never
allocates". Zero failures means there is nothing to compare against a `=0` baseline: the
suite cannot do better.

**Validation is now complete — every gate in the plan has been run at `=1` and passes.** What is
left is not a test but the **ship decision**, which is the user's per the campaign convention.

### 7.16 🏁 R3.3 SHIPPED — `ATOMIC_SQ = 1` is the default path

User's decision, 2026-07-28, on the §7.13-§7.15 evidence. `heliodor_core.veryl:922` flips to 1
and the queue is live; the `=0` arm stays in the source as the fold-away fallback (every gate is
still written `if ATOMIC_SQ ? … : …`, so reverting is the same one-line change).

Re-verified on the flipped tree before the commit: `veryl test` **252/0** with
`litmus(N=2) cy=0x2e6300 tohost=1 pass=1`, and **N=1 boot `cy=0x0d9be30` `x3=0xAA` pass=1**.
That N=1 figure is one 10 000-cycle probe interval below §7.13's `0x0d9e540` — the harness
samples `tohost` on that granularity, so the two differ by a boundary crossing (0.07 %), and
Verilator's exact 14,267,393 sits just under both, as it should.

**What is now structurally true:** a without-return atomic is no longer a ROB-head special case.
It allocates like a store, retires without waiting for its write, and the drain acquires
ownership and performs the RMW at the memory system — the canonical-LSQ shape for this class.
§0(b)'s contended-atomic win is real and measured (N=4 SMP boot −4.2 %); §0(a)'s
canonicalisation is what unblocks R3.2c.

**Next: R3.2c (§6.5)** — with the drain computing the value, the class no longer needs its
execute-time read, so it can drop out of `issue_amo_read` / RFO-at-head / `amo_watch_*` /
`amo_poison_q` / `commit_amo_replay` entirely and become *a store with an ALU op*. That is where
the remaining IPC is: removing the at-head read is what lifts issue-side serialisation.

### 7.17 R3.2c built + probed — three real bugs fixed, one blocker left (the RFO itself)

**Status: BUILT, DEAD at `ASQ_NOREAD = 0`, NOT flipped.** New const `ASQ_NOREAD`
(`heliodor_core.veryl`, next to `ATOMIC_SQ`) gates the whole increment; at 0 the SV diff is the
existing expressions verbatim + const-gated additions (plus Veryl's column realignment), and the
DEAD ladder passes: `veryl test` **252/0**, litmus N2 **`cy=0x2e6300` cycle-exact**, N=1 boot
**`cy=0x0d9be30`**.

**What R3.2c does at `=1`.** `asq_nr_iss` is the ISSUE-side class predicate — the decode half of
`asq_class` (`rd_arch == 0`, a real RMW funct5, not amocas.q), deliberately **PA-independent**
because the read/no-read decision must be made in the cycle the MMU produces the PA.
`issue_amo_read` splits into `issue_amo_xlat` ("an atomic translates + fault-checks", every
atomic, unchanged) and the narrower `issue_amo_read` ("…and needs the data read"). The class then
drops out of `dc_amo_read`/`dmem_amord_m`, `amo_fetch_hold`, `amo_watch_*`/`amo_poison_q`/
`commit_amo_replay`, and the M-stage dcache access (`m_ren_q`).

**Three bugs found and fixed on the way (all real, all keepers):**

1. **The cacheability half of `asq_class` cannot be decided at issue.** Resolved with existing
   machinery instead of new fallback logic: a no-read atomic that translates to an uncacheable PA
   **arms the AMO watch already poisoned**, so the existing `commit_amo_replay` re-fetches it, and
   a sticky `amo_fread_q` makes the re-executed one take today's read path. Exactly one replay, no
   new commit-side state, no new redirect arm. (Never fires in any current test — `freadcnt=0`
   over the whole N=1 boot — so every atomic in DRAM stays on the fast path.)
2. **🚨 The class atomic must not present itself to the ROB as a LOAD.** `alu_wrap` gained
   `i_amo_noread`, which clears `o_cdb.is_load`. Without it the P9.0 remote-invalidate scan
   (`rob.veryl:1031`) poisons the atomic's ROB **load record** the moment the other hart's RFO
   invalidates the line → `commit_load_replay` blocks retire, but `commit_store_fire` (hence
   `asq_alloc`) is *not* gated by it, so the same atomic **re-allocates forever**: litmus N=2
   deadlocked with both harts at `t7_amo`, `asq_alloc` firing while `rob_commit_ack` never did.
   Until R3.2c the AMO watch masked this — it poisons on the same events and *does* suppress
   `commit_store_fire`. There is nothing to re-read for this class, so the record is simply wrong.
3. **The drain's read had no fetch/access handshake.** The dcache data array is a synchronous read
   (`DCACHE_SYNC_READ=1`: the PA must be presented one cycle before its data, and `miss` is itself
   registered) — which is exactly why the execute-side AMO read has `amo_fetched_q`/
   `amo_fetch_hold`. The drain captured on its first driving cycle; until R3.2c the execute read
   had already walked the line through that pipeline, so it never showed. `asq_dr_rfetch_q` adds
   the missing cycle. Also added: the same 2-cycle handshake for the class's translate-only access
   (`asq_nr_acc` / `asq_nr_fetched_q`), and the positive invariant `amo_cwr_eff && !ac_noread_q`
   so an atomic that performed no read can *never* reach the in-cache write path.

**Ladder at `=1`: everything passes except the N=1 Linux boot.**

| check | `ASQ_NOREAD=0` | `=1` | note |
|---|---|---|---|
| `veryl test` (incl. arch + litmus N2) | 252/0 | **252/0** ✅ | litmus N2 `0x2e3bf0` vs `0x2e6300` = **−0.09 %** |
| litmus N=4 | `0x39ada0` | **`0x398690` pass** ✅ | **−0.24 %** |
| dhrystone | 252939 cy / 264834 instret | **bit-exact** ✅ | — |
| **N=1 Linux boot** | `0x0d9be30` pass | **wedges at the 45 M cap** ❌ | kernel panic — see below |

**The failure is a kernel panic, not a hang.** Console: `Unable to handle kernel NULL pointer
dereference at virtual address 0x100`, `cause 0xd` (load page fault), PID 1, then
`Attempted to kill init! exitcode=0xb` → `panic()`'s blink loop (`state ^= 1`,
`i_next = i + 200`, `mdelay(100)`), which is what the 45 M cycles of `__delay` spinning at
`0x800b9be2..bf2` actually were. The faulting code loads `page->flags`, takes its **top two bits**
as a zone/node index and indexes a table — and those bits read **2 instead of 0**, so the table
entry is NULL. `page->flags` is exactly what `set_bit`/`clear_bit` (`amoor.d`/`amoand.d` with
`rd == x0`) touch: the R3.2c class.

**Bisected to the execute-time READ itself.** With the class's dcache access restored and
everything else of R3.2c live (no watch, no ROB load record), the boot passes **cycle-identical to
baseline** (`0x0d9be30`) — so fixes 1-3 are inert on this path and the culprit is inside the read
removal. Bisecting further *inside* that: restoring the M-stage plain read (RFO still gone) still
fails; restoring the 2-cycle translate handshake still fails; restoring the
`load_blocks_on_store` terms (`sb_ld_ovl`, `commit_store_fire`, `.rl && !sb_empty`) still fails.
**What is left is the ownership (RFO) read itself.**

**🚨 Measured and RULED OUT — do not re-litigate (every one of these was a direct measurement at
`=1`, not an argument):**
- **Wrong captured PA.** `ac_pa_q` compared against a commit-time re-translation on every alloc:
  **0 mismatches** out of ~1000 checked.
- **Port ownership at capture.** Counter on "class atomic acks while the dmem port is not carrying
  its own address" (vu/store-drive/walk/redirect/replay/LSR): **0** over the whole boot.
- **Drain arithmetic.** All 1163 drains re-computed offline from their own logged
  `(old, src, op, size, byte-offset)`: **1163/1163 correct**.
- **Stale `old` / lost writes.** Per-PA drain chaining: `old_n != new_{n-1}` in **0.9 %** of
  repeat-PA drains at `=1` — *identical* to the `=0` rate — and **zero** cases of re-reading the
  same `old` (the lost-update signature).
- **Ordering vs younger accesses.** Probe for an overlapping younger load/AMO issuing while a
  class atomic is executed-but-not-drained: **1 hit in the whole boot, and it is a page-offset
  alias** (VA offset 0x700 vs a different page's PA offset 0x700). The window is in fact closed by
  construction: `rob.veryl:724` blocks a younger load behind *any* in-ROB AMO ("atomic — never
  reorder"), and from alloc onward `asq_ld_ovl` + `asq_dr_busy` take over.
- **Lost / duplicated queue entries.** `asq_alloc` count == `asq_drain` count at every sample.
- **The uncacheable fallback.** `freadcnt = 0` — it never fires in the boot.
- **MMU busy timing.** `mmu.veryl:1300` `o_busy` includes `tlb_miss_start` combinationally, so
  there is no "TLB miss not yet busy" window to latch a garbage PA through.

### 7.18 ✅ ROOT CAUSE — an atomic could retire through the STORE BUFFER (`sb_2cyc_ok`)

**Found by budget bisection, not by hypothesis.** §7.17's eight refuted theories showed the
atomic datapath was clean, so the next step was to localise the *first* atomic that breaks the
boot rather than guess a mechanism. A temporary `NR_BUDGET` const capped how many class atomics
were allowed the no-read path; with the boot testbench's cycle cap lowered to 16 M (pass and fail
both ~2.5 min) a binary search over 0…1200 converged in 10 runs:

> **budget 239 → boot passes, budget 240 → boot fails.** The culprit is no-read class atomic
> **#239**: `amoadd.w x0, a4, (a5)` at PC `0xffffffff80066232`, PA `0x80a0d798`, cacheable.

A cycle trace of exactly that instruction showed it **retiring with its RMW nowhere**:

```
t=0  cv=1 cpc=…232 camo=1 acl=1 ack=0 | ELIG=0 sfet=0 p2c=0 sbempty=0 sbpush=0 | cls=1 alloc=0 cwr=0
t=1  cv=1 cpc=…232 camo=1 acl=1 ack=1 | ELIG=1 sfet=1 p2c=1 sbempty=0 sbpush=1 | cls=1 alloc=0 cwr=0 sdata=0x1
t=2  cv=1 cpc=…236   ← head has moved on
```

- **t=0** — the atomic is at the ROB head with `sb_empty = 0`, so it can neither retire, nor
  allocate (`asq_alloc` requires `sb_empty`), nor perform the in-cache write. That very cycle
  satisfies `store_fetched_q`'s set condition (`store_drive && !sb_elig && !dmem_mmu_busy`).
- **t=1** — `store_fetched_q = 1` makes **`sb_2cyc_ok = 1` ⇒ `sb_elig = 1`**, and `sb_elig`
  *removes the whole `c_is_store && !sb_elig && (… c_is_amo ? !sb_empty …)` term from the retire
  gate*. So the atomic retires (`ack=1`) and is **pushed into the committed-store buffer**
  (`sbpush=1`) as a plain store of `c_store_data`, with `alloc = 0`.

**The bug is in `sb_2cyc_ok` (`heliodor_core.veryl`), and it predates R3.2c.** Both of its
siblings exclude atomics explicitly — `c_pretx_fast` carries `&& !c_is_amo` and so does
`sb_vm_live_ok`, and the comment above them states the rule ("AMO/SC … are excluded"). This arm
instead leaned on `store_fetched_q` to imply "plain store", which is false: **any** atomic held at
the head for one cycle sets that latch. Fix = the missing guard:

```veryl
let sb_2cyc_ok: logic = STORE_PRETRANSLATE && store_fetched_q && !c_is_amo && m_pa_cacheable && …
```

**Why it was invisible until R3.2c.** At `ASQ_NOREAD = 0` the buffered `c_store_data` is the
*correct* pre-computed RMW result, so the atomic still lands the right value — only its
*atomicity* is lost (no ownership, no in-cache merge, and at `ATOMIC_SQ=1` it silently bypasses
the atomic-SQ). Latent on one hart; a genuine atomicity hole under SMP. With R3.2c's execute read
gone there is no pre-computed result, so the buffer wrote garbage — the trace shows `sdata = 0x1`
for an `amoadd.w` whose true `old` was non-zero, i.e. a **lost update**. That is also why the
bisect in §7.17 pointed at "the RFO itself": the read was not the cause, it was the thing whose
value made the pre-existing bug harmless.

**Ladder at `ASQ_NOREAD = 1` with the fix — everything passes:**

| check | baseline (`=0`, pre-fix) | `=1` + fix | delta |
|---|---|---|---|
| `veryl test` (arch + litmus N2) | 252/0, `0x2e6300` | **252/0, `0x2e6300`** ✅ | identical |
| litmus N=4 | `0x39ada0` | **`0x3b0d30` pass** ✅ | +2.4 % (the fix makes held atomics wait) |
| dhrystone | 252939 cy / 264834 instret | **bit-exact** ✅ | 0 |
| N=1 Linux boot | `0x0d9be30` | **`0x0d9be30` pass** ✅ | **cycle-identical** |
| N=2 SMP Linux boot | `0x125bb50` | **`0x125bb50` pass** ✅ | **cycle-identical** |

The `sb_2cyc_ok` guard is a correctness fix for **both** arms, so it is deliberately *not*
const-gated and is verified at `=0` in its own right (252/0 · litmus N2 `0x2e8a10` · N=1 boot
`0x0d9e540` · litmus N4 `0x3ae620` · N=2 SMP boot `0x125bb50`). Against **that** `=0` arm —
the honest comparison, since both carry the fix — R3.2c is essentially **cost-neutral**:
litmus N2 −0.33 %, litmus N4 +0.26 %, N=1 boot −0.07 %, N=2 SMP boot cycle-identical,
N=4 SMP boot `0x1c4e180` pass. **ACT4 RVA23: 696 passed / 0 failed at `=1`.**

**Honest note on §0(b)'s IPC promise.** R3.2c removes the class's RFO, its 2-cycle fetch
handshake, its watch/poison/replay and its ROB load record — the machinery §6.5 predicted would
"lift issue-side serialisation" — and the measured result is **neutral, not a win**. The
without-return class is simply not frequent enough in these workloads (≈1160 such atomics in a
14 M-cycle N=1 boot) for its per-instruction saving to show up at the top level. What R3.2c does
deliver is §0(a): the class is now structurally *a store with an ALU op*, which is the
canonical-LSQ end state, plus the two real bugs it exposed (§7.18's store-buffer hole is an SMP
atomicity hole that exists at `ASQ_NOREAD=0` today, and §7.17's ROB-load-record hole).

### 7.19 ✅ Validation complete at `ASQ_NOREAD = 1` — Verilator NBA 4/4 + ACT4 696/0

Every gate R3.3 itself had to clear (§7.14/§7.15) has now been re-run for R3.2c, on the same
flow that once caught the SMP LR/SC `read_lock` livelock — standard SV non-blocking-assignment
semantics, Verilator 5.050, `-O3`, built from `veryl build` output with `ASQ_NOREAD = 1`:

| Verilator run | result | cycles | Veryl sim `=1` | agreement |
|---|---|---|---|---|
| `tb_litmus_4hart` (P9.0 RVWMO battery, N=4) | **PASS** `tohost=1`, `fail=0` | 3,861,342 | 3,870,000 (`0x3b0d30`) | −0.22 % |
| `tb_soc_linux_boot` (N=1) | **PASS** `x3=0xAA` | 14,260,462 | 14,269,488 (`0x0d9be30`) | −0.06 % |
| `tb_soc_smp_linux_boot_2hart` | **PASS** `x3=0xAA` | 19,244,683 | 19,250,000 (`0x125bb50`) | −0.03 % |
| `tb_soc_smp_linux_boot_4hart` | **PASS** `x3=0xAA` | 29,670,919 | 29,679,488 (`0x1c4e180`) | −0.03 % |

Plus **ACT4 RVA23 696 passed / 0 failed** — including the `Zaamo`/`Zalrsc` and
`ExceptionsSvZaamo`/`ExceptionsSvZalrsc` groups, which is the external check on §6.4's
"translation + PMP stay at execute, so a faulting atomic never allocates" now that the class
does *only* translate + fault-check at execute.

**Nothing is left to test.** As at §7.15, what remains is the **ship decision**, which is the
user's per the campaign convention; the tree stays at `ASQ_NOREAD = 0` until then. Reverting or
flipping is the same one-line change, and the `sb_2cyc_ok` fix (§7.18) is already live in both
arms because it is a correctness fix, not part of the increment.

### 7.20 🏁 R3.2c SHIPPED — `ASQ_NOREAD = 1` is the default path

User's decision, 2026-07-31, on the §7.18/§7.19 evidence. `heliodor_core.veryl` flips to 1: a
without-return atomic now does **only translate + fault-check** at execute. It is out of
`issue_amo_read` / the RFO / the 2-cycle fetch handshake / `amo_watch_*` / `amo_poison_q` /
`commit_amo_replay` / the M-stage dcache access / the ROB load record — *a store with an ALU op*,
which is §6.5's canonical-LSQ end state for this class. The `=0` arm stays in the source as the
fold-away fallback (every gate is written `if ASQ_NOREAD ? … : …` or `&& ASQ_NOREAD`, so
reverting is the same one-line change).

Re-verified on the flipped tree before the commit: `veryl test` **252/0** with
`litmus(N=2) cy=0x2e6300 tohost=1 pass=1`, and **N=1 boot `cy=0x0d9be30` `x3=0xAA` pass=1** —
both exactly the §7.18 figures.

**What Block R now is, end to end.** A `rd == x0` atomic is no longer a ROB-head special case in
*any* respect: it translates and fault-checks like a store, retires into the atomic store-queue
without waiting for its write, and its RMW is performed at the memory system under coherence by
the drain, which acquires ownership itself. The cost is neutral and the payoff is structural —
plus the two genuine bugs the work exposed (§7.17's ROB-load-record hole, §7.18's store-buffer
atomicity hole, the latter live at `ASQ_NOREAD=0` as well and fixed for both arms).

**Next candidate:** R3.2c was the last item in Block R's decomposition (§4), so the next choice is
a Phase-14 block-level one, not an R3 one.
