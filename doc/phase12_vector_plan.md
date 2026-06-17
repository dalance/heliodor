# Phase 12 — Vector (RVV 1.0) Extension: Implementation Plan

Goal: add the RISC-V Vector extension so heliodor is **fully RVA23-compliant**
(the V family is the only RVA23 mandatory family still missing after Phase 11's
hypervisor work). Target: **RVV 1.0, VLEN = 128, ELEN = 64** — integer + FP
(single/double) vectors, all LMUL (1/8 … 8), masking, the standard vector
load/store and arithmetic/reduction/permutation instructions. Vector crypto
(Zvk*) and Zvbb are *not* RVA23-mandatory and are out of scope.

This plan is correctness-first. A simple, slow, in-order vector unit that passes
the vector arch tests and runs a V-enabled kernel/userspace is the milestone;
throughput optimization comes later.

## 1. Core architectural decision: a decoupled, in-order Vector Unit (VU)

The VU is a **separate module** that owns the vector register file (VRF) and the
vector config state, receives vector instructions from the scalar core **in
program order**, and executes them **in order** (one vector instruction at a
time, streaming elements over several cycles). It is *not* renamed into and not
tracked by the OoO scalar issue queues.

Rationale — and it is directly validated by **ReOVE** (Kimura & Shioya, U-Tokyo,
ISLPED '24, DOI 10.1145/3665314.3670805, copy in the repo root as
`3665314.3670805.pdf`):

- ReOVE's trace study finds **reordering *among* vector instructions barely helps
  performance** (vectors hide their own latency by time-division element
  processing; few scalars depend on a vector result), while **reordering between
  vector and scalar instructions *is* performance-critical**.
- So executing vectors in order — and thereby **eliminating vector register
  renaming and the vector LSQ** — costs only **~2.7% performance** but saves
  **~21% area and ~22% energy** vs. a full-OoO vector implementation. heliodor's
  huge architectural VRF (32 × up to LMUL 8) makes "don't rename it" the obvious
  call, and ReOVE quantifies that the performance left on the table is small.

The VU is the **third register-file + execution-unit class** in heliodor,
structurally analogous to the existing floating-point path (which already proves
the pattern: a second RF + FU bolted onto the OoO core). See §3.

## 2. Two design rules taken from ReOVE

### Rule A — avoid the "fenced model"; let younger scalars pass older vectors

The trap ReOVE warns against: if a vector instruction acts as a **fence** —
younger instructions wait for it to execute (its "Constraint 2") — the OoO
window collapses and performance drops badly (ReOVE measures −10.8% for the
FENCED model vs −2.7% for ReOVE). The fix is to **keep Constraint 1** (a vector
waits for older instructions to execute — it needs their scalar operands /
memory ordering) but **relax Constraint 2** (younger *scalar* instructions may
execute *past* an older vector).

heliodor's decoupled VU satisfies this *by construction*: vector ops live in a
**separate VU queue** and complete asynchronously (signalling the ROB
`result_written`), so younger scalar ops are woken by their own dependences in
the scalar IQ and never stall on a pending vector op. The hard design rule is
therefore: **never gate scalar dispatch/issue on an in-flight vector op.** Only
in-order *commit* (the ROB) orders a younger scalar behind an older vector —
which is standard and fine.

### Rule B — no vector LSQ; reuse heliodor's scalar store buffer + load-shadow replay

Vector memory ops are the hardest integration. ReOVE shows a dedicated vector
LSQ is unnecessary: vector/scalar memory ordering can ride the **scalar** LSQ
with a lightweight forwarding + order-violation-replay scheme. heliodor already
has the equivalent machinery, so we extend it rather than build a vector LSQ:

| ReOVE mechanism | heliodor structure to extend |
|---|---|
| vector load vs. older scalar store → search store queue, **re-execute** on overlap (rare → cheap; don't forward) | committed **store buffer** + overlap check (`sb_ld_ovl`) + S27 byte-lane forwarding; stores execute at commit, so older scalar stores are already in the buffer/cache when a (commit-driven) vector load runs |
| vector store vs. younger scalar load → on the store's execution, search the LSQ for a younger load that already read the same address → **order violation → flush + replay** | ROB **load shadow** (`sh_load_addr` / `sh_load_done`, `src/core/rob.veryl`) + `commit_load_replay` (the S9 memory-order-violation path) — extend the existing scalar-store check to vector stores |
| multi-address (scatter) store comparison **coarsened** to cache-line / page granularity — false positives OK, false negatives not | same: coarse address match is sound because the re-execution/replay restores correctness |

heliodor's commit-time store model + ROB load-shadow is, if anything, a *cleaner*
fit for ReOVE's scheme than a classic LSQ.

## 3. Integration with the OoO scalar core (mirror the FP path)

The FP path is the working template (`decode.veryl`, `rat_fp.veryl`,
`free_list.veryl` (fp instance), `prf_fp.veryl`, `iq_fp.veryl`,
`fpu_wrap.veryl`, the CDB mux + `cdb_dest_is_fp`). The VU mirrors it:

| Stage | FP path (template) | Vector path (new) |
|---|---|---|
| Decode | `is_fp` / `is_fpu_op` / `fpu_op` | `is_vec` / `vec_op` + addressing-mode + EEW/mop flags |
| Rename | `rat_fp` + fp free list + `prf_fp` | **none for the VRF** (VU is in-order); scalar operands use the existing int/fp rename |
| Dispatch | `iq_fp` alloc | **VU in-order queue** alloc (program order; front-end is in-order) |
| ROB | `is_fp_dest` | `is_vec` (ROB entry for in-order commit + precise exceptions) |
| Execute | `fpu_wrap` | `vector_unit` (owns VRF; streams elements; may reuse `fpu_wrap` arithmetic for FP elements) |
| Completion | `fpu_cdb` → ROB `result_written` | VU completion → ROB `result_written` |
| CSR coupling | `frm` → FPU, `fflags` ← FPU → `fcsr` | `vtype`/`vl`/`vstart`/`vxrm`/`vxsat`/`vcsr`/`vlenb`; `frm`/`fflags` for FP vectors |

Scalar ↔ vector data movement reuses the FP cross-file pattern (int↔fp ops):

- **scalar → vector** (`vadd.vx`, `vfadd.vf`, mem base/stride, `vsetvl` AVL):
  read the scalar operand through the existing scalar wakeup (as `fcvt.s.w` reads
  an int operand into the FPU), pass the *resolved* value to the VU.
- **vector → scalar** (`vmv.x.s`, `vcpop`, `vfirst`, `vfmv.f.s`, `vsetvl` rd =
  granted vl): the VU writes the int/fp PRF via the CDB, exactly like an
  `fcvt.w.s` (fp→int) writeback (`cdb_dest_is_fp = 0`).
- **`vsetvl{i}` / `vsetivli`**: compute the granted `vl` combinationally from the
  AVL (rs1 / imm / the `rs1=x0` and `rd=x0` special cases) and the new `vtype`
  (SEW, LMUL, vta, vma), write `vl` to the int rd, and update the VU's
  `vtype`/`vl`. No renaming of config state — the in-order VU holds it and
  vsetvl reaches it in order. (Scalar decode must *not* depend on `vtype`; the VU
  interprets each vector op against its current `vtype`.)

## 4. Subsystems

- **VRF**: 32 × VLEN(128) = 512 B, enough read/write ports to stream
  element groups. First cut: 64-bit-element-serial datapath (2 passes per
  128-bit register); widen to 128-bit (ReOVE's DLEN) later.
- **Vector CSRs**: `vstart`(0x008), `vxsat`(0x009), `vxrm`(0x00A),
  `vcsr`(0x00F), `vl`(0xC20), `vtype`(0xC21), `vlenb`(0xC22). `vl`/`vtype`/`vlenb`
  are read-only via CSR (written by `vsetvl`); `vstart`/`vxsat`/`vxrm`/`vcsr` are
  RW. Add to `csr.veryl` alongside the existing CSR file.
- **Precise traps + `vstart`**: a vector op (chiefly memory) that faults at
  element *i* sets `vstart = i` and traps; the handler resumes from `vstart`.
  Commit-driven vector memory (execute at/near the ROB head) makes "all older
  ops done" trivially true, simplifying this.
- **Memory ops**: VU generates element addresses (unit-stride: consecutive;
  strided: base + i·stride; indexed: base + vidx[i]) and drives the shared
  `dmem_mmu` → `dcache` port (add the VU as a requester in the existing dmem
  arbitration: PTW walk > committing store > issuing load > **vector**). Ordering
  via Rule B (no vector LSQ).

## 5. Phased sub-plan

| Sub | Scope | Validation hook |
|---|---|---|
| **V0** | Vector CSRs + `vsetvl{i}`/`vsetivli`; VRF; VU skeleton + in-order queue + ROB integration; first arithmetic op (`vadd.vv`/`.vx`) + `vmv.x.s` for observability | directed test: `vsetvli` → `vadd` → `vmv.x.s` |
| **V1** | **Unit-stride vector load/store** `vle`/`vse` (SEW 8/16/32/64) + masking + `vstart` precise faults (Rule B memory ordering) | load test data → compute → store result |
| **V2** | Vector integer arithmetic (OPIVV/VX/VI): add/sub/rsub, and/or/xor, sll/srl/sra, min/max, mul/mulh/div/rem, compares, merge/move, widening/narrowing; LMUL/SEW/vta/vma/mask | integer vector arch tests |
| **V3** | Vector FP (OPFVV/VF): vfadd/sub/mul/div/sqrt, FMA family, min/max/sgnj, compares, conversions, vfmv; reuse `fpu_wrap` arithmetic per element; frm/fflags | FP vector arch tests |
| **V4** | Reductions (vredsum/…, vfredusum/…), mask ops (vmand/…, vcpop/vfirst/vmsbf/vmsif/vmsof/viota/vid), permutations (slides, vrgather, vcompress) | ordering/mask tests |
| **V5** | Fixed-point (vsadd/vssub/vaadd/vssrl/vssra/vnclip) + remaining mem modes (strided, indexed gather/scatter, segment, fault-only-first `vleff`, whole-register `vl1r`/`vs1r`/`vmv1r`) | full-coverage tests |
| **V6** | **Validation + RVA23 compliance**: riscv-tests rv64uv; a **V-enabled Linux boot / userspace vector program**; advertise `misa.V`; add V to the device tree | gold standard |

Each sub keeps the regression byte-identical: vector ops are gated by `misa.V` /
`is_vec` so V=0 and the existing scalar boots are unaffected; **keep `misa.V`
un-advertised until V6** so the whole feature stays inert for stock kernels until
it is complete.

## 6. Risks & validation

Risks, highest first: ① vector memory × the single dmem port × `vstart` precise
faults (Rule B mitigates by reusing proven scalar machinery); ② the sheer
instruction count of RVV (the V0–V5 phasing manages it); ③ an in-order
serial-element VU is slow (acceptable for RVA23 *correctness*; optimize later
per ReOVE — execute-driven instead of commit-driven, scalar pass-through);
④ VRF port count (fine at VLEN 128).

Validation: per-class directed tests (as in the Phase-11 H work) → riscv-tests
rv64uv → a V-enabled kernel/userspace program (final gold standard). Cross-check
suspicious results on a second sim backend (cc / cranelift) and Verilator.

## References

- **ReOVE**: M. Kimura, R. Shioya, "ReOVE: Restricted Out-of-Order Execution for
  Superscalar Processors with Vector Extension," ISLPED '24.
  https://doi.org/10.1145/3665314.3670805 (repo root: `3665314.3670805.pdf`).
- RISC-V "V" Vector Extension, version 1.0 (Asanović et al.).
- The FP path is the working in-tree template for a second RF + FU class:
  `rat_fp.veryl`, `iq_fp.veryl`, `fpu_wrap.veryl`, `prf_fp.veryl`, and the CDB
  `cdb_dest_is_fp` mux in `heliodor_core.veryl`.
