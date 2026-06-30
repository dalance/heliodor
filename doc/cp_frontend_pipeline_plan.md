# CP — front-end pipeline (the real 14.565 floor after the wall cut)

After the AMO-wstrb wall fell (`66c0f14`, 15.300 → 14.565) and the **keystone was shown to
be mis-aimed** (`a78dee7`: registering the CDB does NOT cut `rs1_rdy`), the measured floor is
the **single-cycle front end**. This plan is grounded in `--dump-timing` traces at 14.565.

## 1. The measured cone (MEASURED, not the keystone doc's model)

The 14.565 floor is a BROAD cone rooted at the fetch PC `pc_q`, feeding *every* top endpoint —
`rs1_rdy`, `commit_cnt`, `head`, `sh_valid`, `entries` (the IQ/ROB allocate fan-out) — all at
14.3–14.6. Traced (both issue slots):

```
pc_q[FF]
  → u_imem_mmu V=1 (hypervisor two-stage) TLB  v1_vpn→v1_level→v1_valid→v1_match→v1_hit   ~5.0 ns
  → o_imem_paddr
  → u_icache  tag → valid_* → hit_* → stream_rdata → icache_rdata   (COMBINATIONAL read)  ~2.6 ns  (→7.6)
  → u_cexp/u_cexp1 (compressed-instr expand) → s1_instr → u_dec/u_dec2 (DECODE)           ~3.4 ns  (→11.0)
  → free-list pop (pdst alloc) → IQ rename/allocate → {rs1_rdy, entries, head, commit_cnt}[FF.D]  ~3.4 ns (→14.565)
```

Segment budget (of the 14.565): **imem MMU ~5.0 · icache read ~2.6 · cexp/decode ~3.4 ·
rename/allocate ~3.4.**

### 1.1 Why the fetch-buffer bypass is NOT the cut
heliodor already has a fetch buffer (`fb_instr`, depth-8) with a bypass: when the FB is empty,
decode reads the live combinational fetch (`if_*_q = fb_count!=0 ? fb[head] : <live>`,
`core.veryl:1218`). It is tempting to think "remove the bypass → decode reads a register → cut."
**MEASURED: removing ALL the `if_*_q` bypasses moves CP only 14.565 → 14.365 (−0.2 ns).** The
critical route is **not** the FB-register *read* — it is the **icache combinational *read*** that
feeds `cexp → decode` directly (via `s1_instr` on slot-1, `icache_rdata` on slot-0), regardless of
the FB bypass. The FB stores the *post-cexp* aligned instruction; the icache read upstream of it is
the long pole. So the cut must **register the icache read output**, not the FB read.

## 2. The cut order (recommended: icache sync-read FIRST, then imem-MMU staging)

Both register boundaries are ultimately needed (the campaign wants a multi-stage front end). The
question is which yields the better floor first.

| cut | register boundary | new floor | campaign role |
|---|---|---|---|
| **(A) icache synchronous read** | after `icache_rdata` (~7.6 ns) | **~7.6 ns** (imem+icache fetch half; decode/rename half ~7.0 drops below) | **Phase C/D icache SRAM migration** (a real compiler SRAM IS sync-read) — does double duty |
| (B) imem-MMU translate stage | after `o_imem_paddr` (~5.36 ns) | ~9.2 ns (icache+decode+rename half) | pure pipeline reg (the TLB is flops, not SRAM) — worse floor, not SRAM-aligned |

**→ Recommendation: (A) icache sync-read first.** It gives the better floor (~7.6 vs ~9.2), and it
**is** the front-end SRAM migration the campaign needs anyway (SRAM ⊂ pipelining) — the same
sync-read pattern as the planned dcache-sync-read warm-up, applied to the icache where the floor
actually is. After (A), the **imem MMU V=1 TLB (~5.0 ns) becomes the fetch-half bottleneck** → do
(B) next to split the fetch half (imem translate | icache access), driving toward the
decode/rename floor (~7.0 ns).

Trajectory: `14.565 → ~7.6` (A, icache sync-read) `→ ~7.0` (B, imem staging) → then the
decode/rename/allocate cone (and the execute/wakeup keystone, finally unmasked) is the floor.

## 3. The icache sync-read scaffold (A) — methodology

Mirror the proven dcache-sync-read / MEM_PIPE pattern (`DCACHE_SYNC_READ`-style):
- `param ICACHE_SYNC_READ: bit = 0` (DEAD = today's combinational read).
- When 1: register the icache `tag`/`data`/`hit`/`rdata` outputs; the index is presented at cycle N,
  the read result is valid at N+1. Decode (`cexp`/`u_dec`) reads the **registered** `icache_rdata`,
  so `pc → imem → icache-read` ends at the icache output register; `reg → cexp → decode → rename →
  allocate` is the next stage.
- DEAD (=0): outputs fall through combinationally = byte-identical (N1 boot-cy match).
- **The flip is NOT byte-identical** — the icache becomes 1-cycle latency, adding a front-end
  stage. This is the campaign's **first real IPC cost** (+1 branch-mispredict penalty, the FB
  refill timing). Measure boot-cy / CoreMark / Dhrystone vs the ~10–15 % budget.

Corners (the flip): straddle/cross-line fetch (`straddle_q`, two-halfword instructions spanning a
cache line — `icache_rdata_next` window), the FB push/pop timing (the FB now buffers a 1-cycle-later
fetch), branch-redirect → fetch restart (+1 bubble), and the dual-issue slot-1 (`s1_instr`,
`if_*_q1`). Full gate ladder (default · backend-validate · **ACT4** · litmus N2/N4 · N2/N4 SMP boot ·
Verilator) at the flip — the front end touches everything.

## 4. Anchors
- `core.veryl:1218-1223` if_*_q FB bypass (slot-0), `:1244` if_*_q1 (slot-1, `s1_instr`).
- `core.veryl:600` icache_rdata, `:723/739/743` straddle window, `u_icache` instance.
- `mmu.veryl:318-360` imem MMU V=1 two-stage TLB (already clz-tree-ized — not a linear-scan win).
- `speculative_wakeup_design.md §1.1` (the keystone-premise correction: rs1_rdy = the allocate path).
- `deep_pipeline_sram_plan.md` (Phase C/D: caches sync-read; SRAM ⊂ pipelining).
