# P9.2 — Write-back L1 D$ + MESI with an inclusive L2 directory

Phase 9 step 2 (see Phase 9 plan): convert the L1 data cache from
write-through/no-write-allocate to write-back/write-allocate, and replace the
broadcast-invalidate coherence scheme with an inclusive L2 **directory** (home
node) issuing **precise invalidates**. Cache-to-cache transfer and in-cache
AMO/LR-SC stay out of scope (P9.3): a remote hit on a Modified line is served
*through the home* (recall = owner writes back, requester re-reads the L2).

## Starting point (post-P9.1)

- L1 D$: 16KB 4-way write-through, no-write-allocate. Plain aligned stores
  (bare + Sv39-TLB-hit) retire into a line-granular store buffer and drain as
  full-line writes (S25); AMO/LR-SC/misaligned/MMIO/slow stores use the
  blocking `i_wen` path. Every DRAM write is broadcast as an invalidate to all
  other harts' L1s.
- L2: 128KB 4-way, line-granular (P9.1), write-through below; the read side is
  owned by `mem_ctrl` (split transactions: ACCEPT → LOOKUP → hit-stream /
  DRAM-gather-install-stream).
- AMO/LR-SC: bus-wide sticky lock pins both channels to the holder; AMO/LR
  reads force-miss so the value is fetched under the lock.

## Protocol summary

### States

- **L1 line**: `I / S / E / M` (2 bits per line, replacing `valid`).
  E and M differ only in dirtiness; both mean "sole copy" at the directory.
- **L2 directory** (per L2 line, alongside tag/lv): `sharers[N_HARTS]` mask +
  `owned` bit. `owned=1` ⇒ mask is one-hot = the owner (its L1 state is E or
  M — the home does not distinguish; a recall finds out). `owned=0, mask≠0` ⇒
  S copies only (all clean). The L2 line's *data* is current unless `owned`.

### Inclusion

Every valid L1 line is covered by a valid L2 line whose directory entry lists
the holder. Enforced by:

- L1 fills only happen through mem_ctrl transactions, which add the requester
  to the directory (at LOOKUP for hits, at INSTALL for DRAM fetches).
- An L2 eviction (install victim) back-invalidates the victim's sharers; an
  *owned* victim is recalled first.
- A suppressed install (write conflict during gather, `iok=0`) sends an
  explicit invalidate to the requester so its in-flight fill aborts — without
  it the L1 would complete a fill the L2 never recorded.
- L1 *clean* drops (S/E victim, plain invalidate) are silent: the directory
  over-approximates, which only costs spurious invalidates / clean-ack
  recalls, never correctness. M drops always write back (the WB clears
  `owned`).

### Transactions (mem_ctrl slots, one per hart)

Each slot carries a `rfo` flag (read-for-ownership, from the dcache's store
fill). New rules on top of P9.1:

- **Per-line serialization**: an accept is blocked while any other slot (or
  the recall engine) is active on the same line. This is what makes
  directory updates race-free and (with the lock gating below) preserves AMO
  atomicity.
- **LOOKUP, hit, not owned**: READ → grant `E` if mask was empty else `S`;
  add requester. RFO → invalidate the other sharers (precise), directory
  becomes owned-by-requester, grant `M`.
- **LOOKUP, hit, owned (by anyone, incl. the requester itself — stale after a
  silent E drop, or an eviction WB still in flight)**: request the **recall
  engine**, wait, then re-LOOKUP. The recall leaves the line unowned with
  current L2 data.
- **LOOKUP same-cycle write collision** (granted write to the same line, lo or
  misaligned-hi): retry LOOKUP next cycle (the comb data copy would pre-date
  the merge).
- **MISS** → DWAIT → GATHER → INSTALL (grant `E`/`M` by rfo): the install
  victim must have no active slot/engine on it (else hold); an owned victim is
  recalled (engine) before the install; a shared victim's sharers are
  back-invalidated at the install edge.

### Recall engine (one, in mem_ctrl)

Requesters: slot LOOKUP (owned line), install (owned victim), and the
write-channel veto (below). Probe wire per hart (`probe_v/addr`); the L1
answers:

- line in `M`: capture to the writeback buffer, invalidate, drain via the
  write channel as a **WB** (full-strobe line write, `wb` flag). The engine
  completes when the WB for that line is seen on the write channel.
- line in `S`/`E`/`I`: invalidate, pulse `probe_ack` (clean).
- line sitting in the L1's writeback buffer (evicted, WB not yet drained): no
  ack — the in-flight WB completes the recall.
- writeback buffer busy with a *different* line: hold the probe (engine
  waits); the buffer drains via normal write-channel grants.

### Write channel (post-P9.2 users)

Plain aligned stores no longer appear here — they merge into owned L1 lines.
Remaining users: **WB** (eviction / recall / flush, full-line, `wb` flag),
**AMO/LR-SC stores** (write-through under the bus lock, unchanged), **misaligned
stores** (write-through lo + hi-bypass, unchanged), **MMIO**, **slow stores**
(Sv39 TLB-miss path). At the home:

- WB: merge line (always hits — inclusion), clear `owned` and the writer's
  sharer bit.
- non-WB write, L2 hit: merge, precisely invalidate `sharers & ~writer` (and
  for a misaligned store, also the +8 line: L2-invalidate it and invalidate
  *its* sharers — closing the P9.1 "hi line not invalidated" hole).
- non-WB write to a line **owned by another hart**: the write grant is vetoed
  (per-hart) until the engine recalls the line. (Reachable via misaligned /
  slow stores; AMO/SC writes target self-owned or unowned lines by
  construction.)
- non-WB write, L2 miss: passthrough (inclusion ⇒ no L1 copies; an in-flight
  gather is handled by `iok`).

### Precise invalidate distribution

Two per-hart invalidate ports (`inv`, `inv2`) replace the broadcast: a granted
misaligned write needs lo+hi in the same cycle (atomic with the data write).
Port arbitration per cycle: **write > install > lookup** — writes are posted
and cannot wait; install/lookup hold their state and retry. The L1 applies
both ports identically (including the mid-fill `fill_aborted` latch and the
completion-cycle `inv_hits_done` fold from P9.1).

### AMO / LR-SC

AMOs keep the P9.0/9.1 shape: bus lock + force-miss read + write-through
commit. Two new rules keep the RMW atomic now that stores can become visible
*without* the write channel:

1. **RFO accepts (and so all ownership grants) are gated on the AMO lock**:
   while a hart holds the lock, no *other* hart's RFO is accepted. Combined
   with per-line accept blocking (an in-flight RFO finishes before the lock
   holder's force-miss read is accepted), no remote store can land between the
   locked hart's value capture and its commit write.
2. The L1's AMO force-miss invalidate detours dirty lines through the
   writeback buffer (capture + WB) instead of dropping them.

LR/SC reservations: with precise invalidates, a remote write is only visible
to this hart while the line is *cached here*. The core therefore clears
`rsv_valid` (and poisons `sc_watch`) whenever the reserved line is no longer
present in the L1 — implemented as combinational **presence-check ports** on
the dcache (line cached, or being filled un-aborted; a line in the writeback
buffer counts as absent). Own misaligned stores overlapping the reservation
clear it core-side.

### Instruction-side coherence (imem / iptw stay tb-direct)

The I-fetch and I-PTW ports read DRAM directly, so dirty L1 data must reach
DRAM at the architectural sync points:

- **FENCE.I** (stores → fetch visibility) and **SFENCE.VMA / satp writes**
  (PTE stores → I-PTW visibility) trigger a full **D$ flush**: scan all
  sets/ways, write back + invalidate every M line through the writeback
  buffer. All three are already `c_serial` (retire ack waits for sb drain);
  the ack gate extends to flush completion. The D-side PTW reads through the
  dcache and is coherent without flushing; a remote walker that misses goes
  through the home and recalls dirty PTE lines.
- Between a PTE store and the SFENCE.VMA, a remote I-PTW may read the *old*
  PTE from DRAM — architecturally allowed (visibility is only guaranteed
  after the fence, which Linux performs before relying on the mapping).
- L2 stays write-through *below* (every write-channel transaction, including
  WBs, propagates to DRAM), so DRAM is current at every sync point.

### tohost (harness visibility)

Test harnesses watch the DRAM array for `tohost`. With write-back, plain
stores never reach DRAM, so the core's fast-store classifier excludes the two
tohost pages (PA `0x8000_1xxx` arch/litmus, `0x8000_8xxx` benchmarks): those
stores take the `i_wen` write-through path and stay harness-visible.
Misclassification risk is performance-only (write-through is always coherent).

## Why a store needs no bus transaction on an owned hit

`M`/`E` at the directory means no other L1 holds the line and every future
remote access goes through the home, which recalls before serving. Merging
into the owned line and marking `M` is therefore globally ordered — this is
the point of the whole exercise: the write-channel traffic that dominated
S19/S25 profiling collapses to evictions + the uncached paths.

## Staging

- **Phase A** (committed separately): directory + precise invalidates with the
  L1 still write-through (sharers only, no owner/recall/RFO). Lands the
  inv-port arbitration, install back-invalidate, victim/slot exclusion,
  iok-abort invalidate, and the reservation presence checks under the full
  litmus + boot battery before any dirty data exists.
- **Phase B**: M/E states, RFO + recall + writeback buffer + flush + veto.
