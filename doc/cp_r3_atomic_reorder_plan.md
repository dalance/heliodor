# R3 — reorder atomics through the store-queue + coherence (the SMP finale)

Block R of Phase-14 (`phase14_frontend_deep_ooo_plan.md`). The **last fused piece** of
the canonical-LSQ redesign: replace the single-cycle in-cache atomic RMW commit with a
**multi-cycle store-queue-based atomic** that acquires ownership and performs its RMW under
the coherence protocol, tolerant of pipeline slip. **Highest SMP risk in the whole campaign
— the litmus / M3b minefield.** The study (`retire_memory_ordering_redesign_study.md §4`)
scopes this as "large — bigger than the whole campaign so far … multi-turn, SMP-gated" and
says explicitly *do not start it autonomously.* User chose it 2026-07-27 (over L3 / declare-
complete) as the next block; F+S+L1+L2 are done.

Status: **R3.0 + R3.1 + R3.2a/b + the §7.11 fix built, DEAD at `ATOMIC_SQ=0` (tree ships
DEAD)** (2026-07-28). Design RESOLVED (§6); validation gap CLOSED (§7.1); **the `=1` correctness
bug is FOUND AND FIXED** (§7.11 — a diverted atomic still latched its write into the M-stage and
was applied twice; one-line fix at the M-stage capture). At `=1`: `veryl test` **252/0**, litmus
N2 **pass**, dhrystone **bit-exact**, N=1 boot **pass** (+0.03 %). **Sole remaining blocker:
litmus N=4 livelocks** (§7.12) — a forward-progress problem, not correctness: the drain's RD→WR
window has no pin protection and the dcache deliberately will not re-arm the pin on a line it
already pins, so four-way contention can ping-pong forever. First candidate fix: make the drain
single-cycle when the RD hits E/M. R3.2c and R3.3 stay behind it.

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
  - **R3.2c — §6.5.** Drop the class's execute-time read (`issue_amo_read`, the watch, the
    poison, the replay). This is what actually lifts issue-side head serialisation and is where
    §0(b)'s IPC lives. **Deferred behind §7** — see the first-flip findings.

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

**Ladder status at `=1`:** `veryl test` 252/0 ✅ · litmus N2 ✅ · dhrystone bit-exact ✅ · N=1
boot ✅ · **litmus N4 ❌ (timeout)** · N2/N4 SMP boot, Verilator, ACT4 not yet run.

**Ruled out by these traces (do not re-litigate):** lost/dropped queue entries; non-atomic drains;
**double application by the queue itself** (the drain fires once per instruction, §7.8's PC
attribution is still valid *for the writes it counted*);
`asq_full` starvation; and the "class atomic double-applies via in-cache write on the cycle
after alloc" theory — a guard for it was added (`!(asq_class && !asq_empty)` in `amo_cwr_eff`,
kept, it is correct in its own right) and changed **nothing**: the counts stayed 4000/3000/1000
bit-identical. Six substantive RTL edits in a row have produced bit-identical results, which is
itself the strongest evidence that the fault is off these paths.
The cycle count was **bit-identical across all four RTL variants**, which is the useful signal:
whatever is wrong is not on the paths being edited. Hypothesis-driven patching has stopped
paying, and the next step is the campaign's proven method instead — a **trace session** on
`test_litmus_2hart` (per-atomic PA/old/new/state trace out of the drain FSM, plus a
divergence trap on "x advanced by exactly 1 per amoadd"), not another candidate fix. Note also
that a counter probe reading `ALLOC` at the 4000th AMO commit showed 0 and was **misread as
"the class never fires"** — test 7 runs later than that sample point; do not repeat that
inference without sampling at the end of the run.

**Boot status at `=1`:** wedges at the 45 M cycle cap (`pass=0`) with drains completing
normally (1797/1798, watchdog never trips), i.e. the queue machinery runs — the failure is the
§7.2 ordering hole, not a stuck engine.
- **R3.3 — flip + litmus closure.** Flip `ATOMIC_SQ=1`; run the FULL ladder (litmus N2/N4 +
  SMP boot N2/N4 + Verilator + ACT4) + contended-atomic IPC. Debug the minefield corners
  (expect several — this is Test-7/Test-8 territory). Ship decision (=0 validated DEAD vs =1),
  per the campaign's structural-mandate framing.

**Anchors to touch** (line numbers post-R3.0): `amo_cwr_en` (:8182) + the R3.0 substrate and
`amo_cwr_eff` mux right below it (:8183-8249) + the commit port muxes (`dmem_pa_m` :8250,
`dmem_wen_m` :8265, `dmem_wdata_m`/`dmem_wexcl_m` :8279-8281) → R3.2 must route the drain's
address/data/strobe from the asq entry, not the live commit drive; `ac_pa_q`/`ac_wok_q` alloc
(:6561-6565) → asq alloc + the class check; `commit_amo_replay` (:4646) / retire gate
(`rob_commit_ack` :4702, whose `c_serial && !sb_empty` fence term is :4711) → SQ-decoupled
retire + the §6.4 fence extension; `load_blocks_on_store` (:7003, `sb_ld_ovl` :911/:7415) →
the §6.4 younger-access block; `sb_empty` (:911) → atomic-SQ drain ordering; `issue_amo_read`
(:5950) / `amo_exec_capture` (:6455) → §6.5 removal of the class's at-head read.
*Not needed under §6* (they were scheme-A anchors): `amo_watch_*_q` (:3437-3440), the
`dc_amo_present` chk3 port (:8381) and the `dcache.veryl` pin (`pin_cnt_q` :587, reset :1534)
all stay exactly as they are — the without-return class carries no watch and needs no
cross-retire pin hold.

## 5. Sequencing note
Per the study's "do not start R3 autonomously" + the campaign's "clean-context start for a
fresh block" pattern (used for S1): build **R3.0 from a clean context**, verify byte-identical,
then R3.1→R3.3 across sessions with the full ladder at each functional step. R3.2's ownership-
locked-drain fallback (what happens when a retired atomic cannot drain) is the single hardest
design question — resolve it before R3.1's head-release lands. **✅ Resolved 2026-07-27 — §6.**

---

## 6. R3.2 design resolution — the fallback question, answered by splitting on `rd`

**Status: RESOLVED (2026-07-27), supersedes §2's scheme-A recommendation. Authoritative for
R3.1-R3.3.** The blocking question was *"what does a retired atomic do when it cannot drain?"*
The answer is to make the question unreachable, by only letting an atomic retire early when its
drain depends on **nothing captured at execute**.

### 6.1 Why scheme A was rejected

(A) keeps `rd ← old` at execute, so the execute-time `old` must stay valid until the drain —
i.e. the line must hold E/M continuously across retire. Three findings kill it:

1. **The pin cannot be extended.** `pin_cnt_q` (`dcache.veryl:587`) defers a remote probe only
   while `!pin_cnt_q[6]` (< 64 cy), and its own comment states why: *"The bound keeps the defer
   from closing a deadlock cycle through the single engine."* Holding the pin until an SQ drain
   re-opens exactly that cycle — hart A defers B's probe on line X while A's drain waits behind
   an older store whose RFO needs a line B is pinning.
2. **The pin does not stop LOCAL eviction.** `pin_line_q` is read only by `probe_pinned` and the
   arm condition (`:589`, `:1531`) — nothing in victim selection consults it. A younger access's
   conflict/capacity miss can evict the pinned line. Today that is caught by `amo_poison_q` via
   `dc_evict1/2` → **replay**, which is precisely what a retired atomic cannot do.
3. **What is left is worth ~1 cycle.** Bound the window instead (retire only when the write is
   already guaranteed) and the alloc condition collapses back into today's `store_drive &&
   sb_empty && ac_wok_q` — the atomic retires one cycle before its write lands. Not worth the
   highest SMP risk in the campaign.

### 6.2 The split: the result register decides

In an **in-order-retire** machine, an atomic that writes `rd` cannot retire before its RMW is
globally performed — retire *is* the architectural commit of `rd`, and after retire there is no
replay. That is not a limitation of this design; it is what retirement means.

But when **`rd == x0` the execute-time `old` is architecturally dead.** Then the SQ entry need
carry no pre-computed value at all: it carries `{pa, amo_op, src, size, aqrl}` and the drain
performs RFO → read → compute → write as one owned-line transaction (scheme B). **No
architectural state depends on any intermediate**, so:

> **"Cannot drain" is answered by "retry the drain."** A line stolen mid-drain costs cycles,
> never correctness. No pin extension, no cross-retire watch, no poison, no replay, no fallback
> machinery — the hard design question does not exist for this class.

Forward progress is no weaker than today: once the drain owns the line, the existing pin covers
its single write cycle exactly as the commit write does now; acquiring the line is the same RFO
fairness problem the current AMO (and its replay loop) already has. No new livelock class.

This is the same split real ISAs make — ARM64 `ST<op>` (no return, store-shaped) vs `LD<op>`
(returns, load-shaped); "far atomics" are exactly the without-return class.

### 6.3 Why this is the valuable subset, not a consolation prize

The guards in §3 answer this themselves — the highest-value contended cases are all `rd == x0`:

| litmus | instruction | class |
|---|---|---|
| **Test 7** AMO atomicity (forbidden `0x701`, *the exact M3b case*) | `amoadd.w x0, t2, (t3)` (`litmus.S:381`) | **without-return → SQ** |
| **Test 6** release | `amoswap.w.rl x0, t0, (t1)` (`:348`) | **without-return → SQ** |
| **Test 8** lock release | `amoswap.w.rl x0, x0, (t3)` (`:415`) | **without-return → SQ** |
| barrier arrive | `amoadd.w.aqrl t1, t0, (s3)` (`:570`) | returns → old path |
| Test 8 acquire | `lr.w.aq` / `sc.w` (`:407-410`) | returns → old path |

Linux's `atomic_add`/`atomic_or`/unlock-store paths have the same shape. So §0(b)'s entire IPC
motivation — contended counters and release stores — is covered, while LR/SC, `amocas`, MMIO
atomics and every result-returning AMO stay on the proven single-cycle path **untouched**. That
also shrinks the flip's blast radius: R3.3 changes behaviour only for without-return AMOs.

### 6.4 Rules the SQ path must obey

- **Younger overlapping accesses BLOCK — they cannot forward.** The entry's value does not exist
  until the drain, so no S27-style forward layer is possible. Reuse the existing shape: today
  `issue_amo_read && sb_ld_ovl` (`:7003`) blocks an AMO/LR read on a buffered overlapping store.
  Extend the same predicate to the pending ASQ line, and — unlike the S27 store-buffer case —
  **plain loads that overlap must block too.** (ASQ_N=1 keeps this a single compare.)
- **Release / fence.** The ASQ drains in order behind the store buffer, so `.rl` is preserved by
  construction. Extend the fence retire gate `!(c_serial && !sb_empty)` (`:4711`) to also
  require the ASQ empty, or a FENCE could complete ahead of a pending atomic write.
- **Acquire.** `.aq` on a without-return atomic: its read happens at drain, so block younger
  loads until the entry drains (the same predicate as above — conservative and sufficient).
- **Fault precision.** Translation + PMP stay at execute (`ac_pa_q` / `ac_wok_q` already do
  exactly this), so a faulting atomic never allocates and no fault can surface at drain.
- **Class exclusions:** `rd != x0`, all SC (rd = success code) and LR, `amocas`, and MMIO /
  uncacheable (`ac_wexcl_q == 0`, a write-through cannot be an owned-line RMW) keep today's path.
- **No new comb loop:** the drain's presence check reads registered tag state, as `dc_amo_present`
  does today (§3.6). The ASQ needs no `chk3`-style watch at all — there is nothing to poison.

### 6.5 The structural prize

A without-return atomic **does not need its execute-time read**. Once R3.2's drain computes the
value, the execute side reduces to translate + fault-check, and the class drops out of
`issue_amo_read` / RFO-at-head / `amo_watch_*` / `amo_poison_q` / `commit_amo_replay` entirely:
it becomes *a store with an ALU op*, allocated and drained like any other store. That is the
canonical-LSQ end state for this class, and removing the at-head read is what actually lifts
issue-side serialisation — the IPC in §0(b) comes from there, not from the retire bump alone.
Sequence it as the tail of R3.2 (the read is still live and harmless during R3.1).
