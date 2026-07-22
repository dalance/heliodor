# icache DATA → realistic 1R1W SRAM — 256-bit fetch-block (Phase-D front-end)

User decision (2026-07-22): finish the icache realistic-SRAM migration by taking the **data**
array to a **true 1R1W macro** — NOT the earlier "extract as a 2R2W submodule" (reverted: a 2R2W
4-port array is not a buildable SRAM macro — foundry compilers offer 1RW / 1R1W only, so packaging
2R2W as a submodule improves realism 0mm). The realistic target is the **same shape as the D$ data
array: `64×512 1R1W ×4`** — read the WHOLE 64-byte line in one access, write via a 64-bit(of 512)
word-write-enable on fill.

## Why a whole-line (512-bit) read reaches 1R1W with near-zero IPC cost

The icache data array today is **`1024×32 2R2W ×4`**:
- **2 reads**: demand word (`data_idx = {index, offset}`) + next/straddle word (`next_data_idx =
  {next_index, next_offset}`).
- **2 writes**: the fill's two adjacent 32-bit words (`fill_widx_lo/hi`) per 64-bit dword beat.

Reducing to 1R1W:
- **2W → 1W**: store the line as `logic<512>` (one 64-byte line per entry, `64×512`); each fill beat
  writes ONE 64-bit dword via a masked write (`wr_dword` idiom, mirrors D$ `DCACHE_DATA_1RW` +
  L2 `w_wmask`). One write port with a 64-bit-of-512 write-enable. **Byte-identical** (same bits,
  regrouped 16×32 → 8×64-in-512).
- **2R → 1R (same-line)**: the demand read now returns the **whole 512-bit line**, so the demand word
  (`offset`) AND *any same-line* next word (`next_offset`, when `offset != 15`) come from the SAME
  read — no 2nd port. This covers **every** live next-word consumer except the cross-line case:
  - **slot-1 (2-wide dual-issue fetch)**: `slot1_valid` needs the next word only when `s1_same_line`
    (`imem_paddr_w[5:2] != 4'hf`, i.e. offset != 15) — always same-line → fully preserved.
  - **S7 single-cycle straddle** (`straddle_oneshot`): a 32-bit instr at a halfword boundary needs
    word+1; for a *same-line* straddle (offset != 15) it comes from the demand line → preserved.
  - **streaming / hit-under-fill**: reads the fill way's line words as they arrive → preserved
    (the demand read already targets the fill line during a fill).
- **The one residual 2nd read = the CROSS-LINE next word** (offset == 15: word 0 of `index+1`,
  a different set). It is served by a 2nd read `data_k[next_index]`, dropped at the flip.

## Cross-line straddle at 1R1W — correctness (the delicate part)

Dropping the cross-line 2nd read removes ONLY the **cross-line single-cycle straddle**
(`straddle_oneshot` when offset==15 and the next line is cached). The core has an always-correct
fallback: the **2-cycle re-fetch** (`straddle_q`, heliodor_core.veryl:1254). It does NOT use
`o_rdata_next` — cycle T saves the low half (`straddle_low_q = curr_hw`) and sets `straddle_q`;
cycle T+1 **demand-fetches pc+2** (the next line's word 0) and assembles `{ic_rdata[15:0],
straddle_low_q}`. So cross-line straddles simply always take the 2-cycle path — correct, IPC-only.

The interlock that must hold (heliodor_core.veryl:911-917): BOTH `fetch_ready` and `ic_straddle_prep`
require `!icache_stall`. So at the flip, for a cross-line straddle we must:
1. force **`o_rdata_next_valid` cross-line → 0** ⟹ `ic_rdata_nv=0` ⟹ `straddle_oneshot=0` ⟹
   `needs_straddle_slow=1` (routes to the 2-cycle path), AND
2. force **`demand1_missing → 0`** (do NOT assert `o_stall` for the cross-line next word) so
   `ic_straddle_prep` fires and the 2-cycle re-fetch proceeds. Asserting the stall instead would
   HANG when the next line is tag-cached (no `straddle_miss` fill to clear it).

`straddle_miss` (the next-line prefetch fill, driven by the `u_itag_next` TAG read — independent of
the data array) stays live: it pre-fills the next line so the 2-cycle T+1 demand hits. `demand0`
(the demand word) is untouched — a demand miss still stalls/streams normally.

## Staging (campaign methodology: byte-identical repack → const flip → full gate)

- **Stage 1 — 512-bit line repack (byte-identical, 2W→1W + same-line 2R→1R).** Rewrite `data_0..3`
  as `logic<512>[SETS]`; fill via masked `wr_dword` write; demand + same-line-next from one 512-bit
  read; **keep** the cross-line 2nd read (`data_k[next_index]`) live behind the const at 0. Array =
  `64×512 2R1W`. `next_rdata_k = if next_same_line ? word(dl_k,next_offset) : word(xl_k,next_offset)`
  reproduces the old `data_k[next_data_idx]` exactly. Gate: `veryl test` 252/0 · litmus N2
  `00236680` (cycle-exact) · SMP N2 boot `010f4d20` (cycle-exact).
- **Stage 2 — drop the cross-line 2nd read (2R→1R).** Remove `xl_k = data_k[next_index]`;
  `o_rdata_next_valid` cross-line → 0, `demand1_missing` → 0. Array = `64×512 1R1W`. Functional
  (cross-line single-cycle straddle → 2-cycle). Gate: full ladder — litmus N2/N4 (no forbidden) ·
  SMP N2/N4 boot · Verilator N1/N2 — + IPC (Dhrystone / CoreMark / boot cycles; expect a tiny
  regression bounded to cross-line-straddle-heavy code) + `--dump-area` (`64×512 1R1W ×4`).

  **Note — the scaffold const could NOT gate the read port.** A `let xl = if CONST ? 0 :
  data_k[next_index]` keeps `data_k[next_index]` in the emitted SV (veryl emits `if const` as a
  live ternary; only reset-only *flops* DCE, not array *reads*), so `--dump-area` still counted it
  as `64×512 2R1W`. The read port only disappears when the `data_k[next_index]` expression is
  physically absent. So Stage 1's byte-identical whole-line repack (validated cycle-exact: boots
  smoke `00c747a0` / 7.1 `013301c0` / 7.1V `015026b0` all EXACT vs baseline, litmus N2 `00236680`,
  252/0) was the checkpoint; then the cross-line read was **physically removed** (no const), giving
  the unconditional `64×512 1R1W ×4` confirmed by `--dump-area` (merges with D$ data → `64×512
  1R1W ×8`). FFs 160075 unchanged (data was RAM before and after).

## Sim-cost note (verification-time only)

A whole-line read models 4 ways × 512-bit combinationally every fetch cycle (vs the baseline
`8×32`-bit demand+next reads) — real HW cost is one wide SRAM read (fine). The veryl `cc`-backend
*simulator* copies more per cycle, but the measured wall-clock hit is modest: the fast gate (252
tests + litmus N2) runs in **2:21** at 1R1W (~1.3-1.5× baseline), well within budget. (Earlier
boot-run timeouts were **box contention** from many concurrent jobs, NOT the change — a clean run
is fine.) If the sim/read-power cost ever matters, a narrower fetch-block (`256×128` / `128×256`)
cuts it at a small dual-issue IPC cost (loses same-line next-word for `offset[1:0]==3`) — a width
tuning orthogonal to the 1R1W result.

## Final shape — 256-bit fetch-block (user decision 2026-07-22)

Shipped as a **256-bit fetch-block** `128×256 1R1W ×4` (a 64 B line = 2 blocks × 256 bit / 8 words):
ONE 256-bit read (block `{index, offset[3]}`) serves the demand word + the same-BLOCK next word
(`offset[2:0] != 7`), fill is a masked 64-bit-of-256 slot-write. The width was chosen by measuring
three points on the IPC ↔ sim-speed/read-power curve:

| block | shape | same-line next lost at | boot IPC Δ (N1, measured) | boot sim (N1, measured) |
|---|---|---|---|---|
| 512-bit (whole line) | `64×512 1R1W ×4` | never (only cross-line 15) | **+0.05–0.33%** | **~6×** baseline |
| 128-bit | `256×128 1R1W ×4` | offset 3/7/11 (3/16) | **+1.7–3.0%** | **~1.0×** baseline (3:59) |
| **256-bit (shipped)** | `128×256 1R1W ×4` | offset 7 only (1/16) | **+0.46–1.09%** | **~1.0×** baseline (3:59) |

256-bit is the clear winner: near-full slot-1 dual-issue / S7 same-line straddle (loses only offset 7
same-line + the cross-line 15 fallback) — **1/3 the IPC cost of 128-bit** — at **baseline sim speed**.
Surprising measured finding: the veryl `cc`-backend sim is ~baseline for BOTH 128- and 256-bit blocks;
only the 512-bit whole line hits a slow path (~6×), so 256-bit gets the wider block's better IPC for
free. Cross-block/cross-line next word (`offset[2:0]==7`) has no read port → the core resolves via its
always-correct 2-cycle re-fetch.

The whole-line 512-bit form was implemented + validated first (byte-identical repack cycle-exact on
boots + litmus N2; `--dump-area 64×512 1R1W ×4`; functional 1R1W 252/0 + N1 boots pass + N2 SMP boot)
to de-risk the 1R1W restructure, then narrowed (128 → measured too costly at +2.2% → 256).

## Gate results (256-bit, shipped)

- `--dump-area`: **`128×256 1R1W ×4`** (merges nothing — distinct from D$ `64×512`). FFs 160075 unchanged.
- `veryl test` (fast + arch): **252/0**. litmus N2 **`00236680`** (cycle-exact — no cross-block/line
  straddle in that workload).
- litmus N4: **`00539e40` pass=1** (no forbidden outcome, +0.18% vs baseline `00537730`).
- N1 boots ×4 (5.15 smoke / 7.1 / 6.6 / 7.1+V): all pass, **+0.46–1.09%**.
- N2 SMP boot: **`01101070` pass=1** (+0.28% vs baseline `010f4d20`).
- **Verilator N1: PASSED** (independent SV-NBA ground truth — SBI shutdown, `r3=0xAA`, `cy=13116757`).

## Result

All icache storage arrays are realistic SRAM macros: tags `64×52 1R1W ×16` (replication,
`dcache_tagbank`), **data `128×256 1R1W ×4`** (256-bit fetch-block, this plan). No 2R2W/2R1W array
remains in the icache; the 4R1W tag and the 2R2W data multi-port arrays are both gone.
