# P9.6 — Coherent instruction side (I-cache + I-PTW through the L2)

Design note. **Not yet implemented** — this captures the analysis and the plan
so the implementation can start with a clear target. (Session 2026-06-15.)

## Goal

Make the instruction side coherent with the data side through the shared L2,
so a store to code (or to a page-table entry the instruction walker reads) is
seen by a later fetch without a brute-force cache sweep. The concrete payoff is
**retiring the D$ flush sweep** that runs today on every `FENCE.I` /
`SFENCE.VMA` / `satp` write.

## Current architecture (the starting point)

- **D-cache**: write-back + MESI, fills through `mem_ctrl` → shared `l2cache`
  (8 × 64-bit dwords per 64 B line), tracked in the L2 inclusive directory
  (per-hart sharer bitmask + OWNED bit). Remote writes invalidate sharers
  precisely; an M line is recalled (written back) on RFO / eviction.
- **I-cache** (`src/cache/icache.veryl`, inside `heliodor_core`): 4-way,
  read-only, 64 B line as **16 × 32-bit words**, fills from the core's
  `o_imem_*` port. That port is **tb-served** — it does NOT go through
  `mem_ctrl`/L2. It has `i_flush` (FENCE.I → invalidate all) but **no
  coherence-invalidate input**. So the I-cache is non-coherent.
- **I-PTW** (instruction page-table walk, `imem_mmu`): reads PTEs over the
  core's `o_iptw_*` port — also **tb-served**, non-coherent.
- **The D$ flush sweep** (`heliodor_core` `dc_flush_req`/`dc_flush_done`,
  `dcache` `i_flush_req`/`o_flush_done`): on commit of `FENCE.I` / `SFENCE.VMA`
  / `satp` write, the D-cache writes back its dirty lines (P9.x `flush_opt`
  skips clean sets) so that subsequent **I-fetch AND I-PTW reads of DRAM see
  current data**. The op's retire ack waits for `dc_flush_done`. This is the
  band-aid that exists *because* the I side is non-coherent — see
  `flush_opt`'s "coherent I-side eliminates the flush" note.

Key consequence: the sweep covers **two** non-coherent readers — the I-cache
(code bytes) and the I-PTW (PTEs). Eliminating it requires **both** to become
coherent (or to read through the coherent D-side).

## Target design

### 1. I-cache fills through `mem_ctrl`/L2

Route the I-cache's fill port to a **second `mem_ctrl` requester per hart**
(today `mem_ctrl` has one slot per hart for the D-cache). Options:

- **(a) Second slot per hart** in `mem_ctrl` (D + I), arbitrated like the
  existing accept logic. Cleanest separation; doubles the slot array.
- **(b) Shared slot with a requester tag** (D vs I) — fewer slots, but the
  D-cache and I-cache miss can't overlap per hart. Simpler, lower perf.

Recommend (a): an explicit I-slot, so a D-miss and an I-miss on the same hart
proceed independently (fetch under load-miss is common).

**Impedance mismatch**: the I-cache fills **16 × 32-bit words**, but
`mem_ctrl`/L2 stream **8 × 64-bit dwords**. Resolve by rewriting the I-cache
fill FSM to consume **8 dword beats**, writing two 32-bit words per beat (the
data array stays 32-bit-word indexed; just fill two adjacent words per granted
dword). `o_mem_addr`/`i_mem_rdata` widen 32→64 on the fill path; the CPU read
side (`o_rdata`/`o_rdata_next`, 32-bit) is unchanged. This is the single
biggest change inside `icache.veryl`.

### 2. L2 directory tracks I-cache copies + precise invalidate

When the I-cache fills a line it becomes a **read-only sharer** in the L2
directory. A remote (or local) D-cache **write** to that line must invalidate
the I-cache copy (a new `i_inv` input on the I-cache, driven from `mem_ctrl`'s
precise-invalidate ports — the same path that invalidates D-cache sharers).

The directory currently carries one per-hart sharer bitmask. The I-cache is a
distinct cache, so add either:
- a parallel **I-sharer bitmask** per line (`ishr_*`), invalidated on writes,
  never granted ownership (read-only), OR
- treat the I-cache as an extra sharer index (e.g. hart `h`'s I-cache = bit
  `N_HARTS+h`) so the existing mask logic carries it — needs the mask width and
  the inv ports widened.

Recommend the parallel `ishr_*` mask: the I-cache is read-only (never OWNED,
never RFO), so its bookkeeping is strictly simpler than the D sharer mask
(add-on-fill, clear-on-write-invalidate, clear-on-fence.i is global).

### 3. Recall on I-fill of a modified line

When the I-cache fills a line that is **M (modified) in some hart's D-cache**
(self-modifying code that hasn't been written back), the L2 must **recall** the
dirty copy before serving the I-fill, exactly like a D-cache RFO of an owned
line. The existing recall engine in `mem_ctrl` already does this for the
D-side; the I-slot lookup needs to drive `lk_recall_req` on an owned line the
same way (the I-fill is a READ — grant S, never E/M).

### 4. I-PTW coherence (the harder half)

The I-PTW reads PTEs. If it stays on the tb-served `o_iptw` port, the sweep is
still needed for PTE coherence even after the I-cache is coherent. Two routes:

- **(a) Route the I-PTW through the D-cache** (like the D-PTW already does via
  `dmem_mmu`/dcache) — a PTE read is a coherent cacheable load. This shares the
  D-cache port (arbitration) but gives PTE coherence for free.
- **(b) Route the I-PTW through `mem_ctrl`/L2** as a third requester — more
  ports, but symmetric with the I-cache.

Recommend (a): PTEs are data; reading them through the coherent D-cache is the
natural model and avoids a third `mem_ctrl` requester. Needs `imem_mmu`'s PTW
read multiplexed onto the dcache CPU port (arbitrated against loads / the
D-PTW / store drain — the dcache port already has several readers enumerated in
`heliodor_core`).

### 5. FENCE.I / SFENCE.VMA / satp: retire the sweep

Once both readers are coherent:
- **FENCE.I**: invalidate the I-cache (`i_flush`, unchanged). The next fetch
  misses and refills from L2, which recalls any modified D$ line. **No D$
  writeback sweep needed** — drop `dc_flush_req` for FENCE.I and the
  `dc_flush_done` retire wait.
- **SFENCE.VMA / satp**: the I-PTW now reads coherent PTEs, so the sweep is
  also unneeded for the PTW. The TLB flush (already selective, P9.5) stands on
  its own. Drop the sweep for these too.

The whole `dc_flush_req`/`o_flush_done` sweep machinery can then be removed
(the D-cache keeps write-back; coherence handles visibility on demand).

## Concrete change points

| File | Change |
|---|---|
| `src/cache/icache.veryl` | fill FSM 16×32b → 8×64b dword beats; add `i_inv_valid`/`i_inv_addr` (coherence invalidate); widen `o_mem_*` to 64-bit dword fill |
| `src/cache/mem_ctrl.veryl` | second per-hart requester (I-slot): accept / lookup / DWAIT / gather / install / stream for the I-cache; recall on owned line (read grant) |
| `src/cache/l2cache.veryl` | parallel `ishr_*` I-sharer mask: add on I-fill grant, clear on write-invalidate + on (global) fence.i |
| `src/core/heliodor_core.veryl` | wire the I-cache fill to the new `mem_ctrl` I-slot (was `o_imem`); route I-PTW through the dcache port; drop `dc_flush_req` for fence.i/sfence/satp |
| `src/core/heliodor_soc*.veryl` | `o_imem`/`o_iptw` no longer tb-served for DRAM (still used for any boot-ROM region?) — re-evaluate the imem path; add the I-slot wiring to `mem_ctrl` |
| `src/cache/dcache.veryl` | accept the I-PTW read as another CPU-port reader (arbitration) if route 4(a) |
| `tb/*` | the boot/arch harnesses serve `o_imem`/`o_iptw` from the same DRAM as the data port — once I-fetch/I-PTW go through L2/dcache, those harness ports change or retire |

## Risks

- **Correctness-critical**: instruction fetch + page-table coherence. A missed
  invalidate or a stale I-fill = wrong code executed (silent, hard to debug).
- **The boot-ROM / firmware region**: instruction fetch of the firmware (low PA,
  outside the cacheable DRAM window PA[63:25]==0x40) must still work — the I
  side needs an uncached / passthrough path for non-DRAM fetch, mirroring the
  D-side `c_store_mmio` boundary. (The P9.5 uncached-load work is the model.)
- **`mem_ctrl` port pressure**: a second requester per hart (I-slot) + the
  I-PTW through the dcache adds arbitration; watch the N=8 serialization the
  L2-banking profile already flagged.
- **Impedance / alignment**: 32b-word I-cache vs 64b-dword L2 fill — off-by-one
  in the word/dword split corrupts fetch.

## Verification plan

- **Directed**: a self-modifying-code test — store new instructions to a code
  page via the D-cache, `FENCE.I`, fetch and execute them; must run the NEW
  code (proves the I-fill recalled the modified D$ line). A second test stores
  a new PTE, `SFENCE.VMA`, and fetches through the new mapping (I-PTW
  coherence). Build on the `smode_*`/`test_mmu_asid` patterns.
- **Regression**: the full multi-step suite (default 155/0, N=1/2/4 boot,
  litmus). The boots exercise fence.i (module load) + sfence heavily.
- **Perf**: the boot cycle delta is the headline — the D$ flush sweep cost (the
  residual after `flush_opt`) should disappear. Expect a measurable N=1/2/4
  boot reduction (the sweep is on the fence.i/sfence/satp commit path).

## Suggested phasing

1. **I-cache fill through L2 + I-side invalidate** (coherent code; keep the
   sweep for the I-PTW). Verify self-modifying-code directed test + boots.
2. **I-PTW through the dcache** (coherent PTEs). Verify the PTE-coherence test.
3. **Retire the D$ flush sweep** for fence.i/sfence/satp. Measure the boot win.

Each phase is independently testable and commit-able; phase 3 is where the
flush sweep (and its boot cost) goes away.
