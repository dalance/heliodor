# Heliodor

**Heliodor** is a from-scratch, out-of-order RV64 RISC-V application-processor core
written in [Veryl](https://veryl-lang.org/). It implements the complete **RVA23**
profile — RV64GC, the scalar extensions, the **vector (V)** extension, and the
**hypervisor (H)** extension — across all privilege modes (M / HS / VS / VU), and
boots unmodified mainline Linux: the **5.15**, **6.6 LTS**, and **7.1** SMP kernels
(1–8 harts) through OpenSBI to SBI shutdown, plus a full **guest Linux** under a
self-written bare-metal **type-1 hypervisor**.

## Status

A 2-wide superscalar, PRF-based out-of-order core (Tomasulo + physical register
file, 32-entry ROB, branch prediction) with non-blocking write-back L1 caches kept
coherent through a MESI-directory L2, Sv39 virtual memory, and 1/2/4/8-hart SMP. A
decoupled in-order **vector unit** (RVV 1.0, VLEN = 128) and the hypervisor's
**two-stage MMU** sit alongside the scalar OoO datapath; the **Architecture**
section below describes the design in full.

It is machine-checked against the official RISC-V Architectural Compliance Tests
(`riscv-arch-test` / ACT4, Sail golden reference) and validated by booting mainline
Linux SMP — including a 7.1 kernel that discovers and exercises the RVA23 vector,
FP, and privileged extensions from the device tree — and a guest Linux under its
own type-1 hypervisor. See **Verification**.

## Architecture

- **Out-of-order core** (`src/core/`)
  - Pipeline: fetch → decode + rename → issue → execute → commit, 2-wide at
    every stage (fetch bundle, dual rename, dual issue, dual retire of simple
    ops)
  - Register renaming: RAT (speculative + architectural) + free list
  - Physical register files: 64-entry integer (`prf_int`) + 64-entry FP (`prf_fp`)
  - 32-entry Reorder Buffer driving in-order retire; precise exceptions;
    execute-time early redirect with single-cycle checkpoint restore + partial
    ROB/IQ squash for branch mispredicts (commit-time redirect as backstop)
  - Branch prediction: 4096-entry BTB, 8192-entry gshare BHT (13-bit GHR),
    TAGE-lite direction predictor, 512-entry indirect-target BTB
    (path-history-indexed), return-address stack
  - Issue queues: 8-entry integer (oldest-ready, 2-issue: pipe-0 full / pipe-1
    ALU-class + bare-mode hit-only loads) + FP queue
  - Memory pipeline: single AGU/LSU on pipe-0 with memory-dependence
    speculation (load-violation detection + commit-time replay), speculative
    loads under Sv39, store-to-load forwarding from BOTH in-flight (ROB) and
    committed (store-buffer) stores
  - Committed-store buffer: stores retire without waiting for the bus; 4 x 64B
    line entries with byte-granular write-combining, drained as one line-wide
    bus transaction each
  - Function units: 2 ALU/branch lanes (`alu_wrap`) and FPU (`fpu_wrap`:
    FP add / multiply / divide / sqrt, single + double). Integer divide and FP
    divide/sqrt are multi-cycle and non-blocking.
- **Vector unit (V)** (`src/core/vector_unit.veryl`, `vrf.veryl`): the RVV 1.0
  extension in a **decoupled, in-order** vector unit (ReOVE-style — see
  [References](#references)) that owns the
  32 × 128-bit architectural vector register file and the vector config
  (`vtype`/`vl`/`vstart`/`vcsr`). Vector ops enter from rename in program order
  and execute in order — the VRF is not renamed and not tracked by the OoO scalar
  issue queues; only the scalar operand of `vadd.vx` / `vset*vl` wakes from the
  integer CDB, and completion rides the lane-0 CDB at lowest priority. VLEN = 128,
  ELEN = 64; integer + single/double FP, all LMUL; `vset{i}vl{i}`, unit-stride /
  strided / indexed / segment / fault-only-first loads and stores, masking, and
  widening / narrowing
- **ISA**: **RV64GC** base (RV64IMAFDC_Zicsr_Zifencei) — M (mul/div), A (LR/SC +
  AMO), F/D (single + double FP), C (compressed, incl. compressed FP load/store,
  expanded in fetch by `c_expander`) — extended to the full **RVA23 application /
  supervisor profile**:
  - The **vector (V)** extension (RVV 1.0) — see *Vector unit* below
  - Bit-manipulation **Zba/Zbb/Zbs**; data-independent-latency **Zkt**
  - Atomics: **Zacas** (compare-and-swap, incl. the 128-bit even-odd
    `amocas.q`) and **Zabha** (byte / halfword AMO)
  - **Zfa** (additional FP) and **Zfhmin** (minimal half-precision: binary16
    conversions + load/store/move)
  - **Zicond** (conditional zero), **Zawrs** (wait-on-reservation-set)
  - Cache-block ops **Zicbom**/**Zicboz**/**Zicbop**; compressed **Zcb**
  - May-be-ops **Zimop**/**Zcmop**; hints **Zihintpause**/**Zihintntl**
  - Counters **Zicntr**/**Zihpm**; pointer masking **Supm/Ssnpm** (`PMM` in
    mseccfg/menvcfg/senvcfg)
- **Privilege & virtual memory**: Machine / Supervisor / User; Sv39 with a
  16-entry fully-associative TLB (ASID-tagged) and a hardware 3-level page-table
  walk (separate instruction / data MMUs, `SFENCE.VMA` + fine-grained **Svinval**).
  **PMP** (Smpmp) physical-memory protection — region checks enforced on every
  load / store / fetch / AMO and on page-table-walk reads, plus PMA-hole faults.
  Sv39 honors **Svnapot** (64 KB NAPOT), **Svpbmt** (page-based memory types),
  and both **Svade** (A/D page-fault) and **Svadu** (hardware A/D update via
  `menvcfg.ADUE`). Supervisor extensions: **Sstc** (`stimecmp`) and **Sscofpmf**
  (HPM count-overflow interrupt + mode-based filtering)
- **Hypervisor (H) extension** (`src/mmu/`, `src/core/csr.veryl`): the
  virtualized **HS / VS / VU** modes and the `V` state bit on top of M/S/U. Full
  HS/VS CSR set; **two-stage translation** — a guest VS-stage Sv39 walk nested
  through a host G-stage Sv39x4, cached in a combined VMID + VS-ASID-tagged TLB;
  `HLV`/`HLVX`/`HSV` hypervisor virtual-memory accesses with their mode-traps;
  the guest-page-fault trio (instruction 20 / load 21 / store 23) with
  `htval`/`htinst` (HS) and `mtval2`/`mtinst` (M); virtual-interrupt delivery
  (`hvip` into VS, plus non-delegated VS interrupts taken by HS); `htimedelta`
  and **Sstc-in-VS** (`vstimecmp`) guest timers; `hstatus.VTVM`/`VTSR` guest-op
  interception and VS-mode CSR isolation; `HFENCE.VVMA`/`GVMA`
- **Caches** (`src/cache/`)
  - L1 I-cache: 16 KB, 4-way, 64 B line, tree-PLRU, non-blocking
    (hit-under-fill, streaming), single-cycle assembly of instructions
    straddling a line boundary; fills coherently through the L2 (recall-on-owned)
    so self-modified code is seen after a FENCE.I with no flush sweep
  - L1 D-cache: 16 KB, 4-way, 64 B line, write-back with a MESI-style inclusive
    L2 directory (per-line ownership, read-for-ownership store fills, dirty
    writeback / recall on eviction; full-line stores stay posted write-through),
    non-blocking (2 MSHRs, hit-under-miss, critical-word-first fill with early
    restart), a second hit-only read port for dual loads, and separate
    read / write bus channels
  - Shared L2: 128 KB, 4-way, 64 B line, line-granular, write-through to DRAM,
    tree-PLRU, with the inclusive coherence directory (per-hart sharer mask +
    owner bit); looked up / installed by the split-transaction read controller
  - Split-transaction DRAM reads (`mem_ctrl`): a line fill is a tagged
    per-hart transaction with modeled latency — L2 hit ≈ 4 cycles to first
    beat, L2 miss ≈ 30 (DRAM wait + 8-beat gather), one outstanding line read
    per hart progressing independently; writes stay 1-cycle posted
    write-through and contend with gathers for the DRAM port
- **SMP** (`heliodor_soc_smp #(N_HARTS = 1 / 2 / 4 / 8)`)
  - N private cores share one `memory_bus` DRAM arbiter (independent read /
    write channels), the L2, and the CLINT / PLIC / UART
  - Coherence via the L2 inclusive directory: write-back L1 D-caches with
    precise invalidate, owner recall (cache-to-cache transfer), and in-cache
    AMO / LR-SC (no bus lock). The instruction side is coherent too — I-cache
    fills and the instruction page-table walker read through the L2 with recall,
    so FENCE.I / SFENCE.VMA / satp need no D$ flush sweep. RVWMO is checked by a
    litmus harness
- **Peripherals** (`src/peripheral/`): CLINT, PLIC, UART
- **Boot**: mainline Linux (5.15 / 6.6 LTS / 7.1) SMP via the bundled OpenSBI
  M-mode firmware

## Verification

| Suite                                                                       | Result |
|-----------------------------------------------------------------------------|--------|
| Default `veryl test` (unit + inline arch suites + Phase-10/11/12 directed tests + N=2 litmus, on the OoO core) | 250 passed, 0 failed |
| **RVA23 scalar compliance** — ACT4 (`riscv-arch-test`, Sail-signed golden reference), run via `make -C test/act` | pass: integer / atomic (+Zacas/Zabha) / FP / Zb*/Zc* / Zfa / Zfhmin / Zicbo* / PMP (Smpmp/SvPMP) / Sv* / Exceptions — see `test/act/README.md` |
| Linux **5.15** SMP boot, 1 / 2 / 4 / 8-hart                                 | pass (~10.2 / 13.9 / 20.0 / 26.9M cycles) |
| Linux **6.6 LTS** SMP boot (RVA23 device tree), 1 / 2 / 4-hart              | pass (~18.6 / 25.5 / 33.6M cycles) |
| Linux **7.1** SMP boot (RVA23 + userspace FP), 1 / 2 / 4-hart               | pass (~16.8 / 19.2 / 23.6M cycles) |
| Linux **7.1 + Vector** boot (`test_soc_linux_boot_71v`, V-aware kernel)      | pass (~17.8M cycles, 1-hart) |
| **Guest Linux** boot under a type-1 hypervisor (H extension, two-stage MMU)  | pass (~21.4M cycles) |

The inline arch suites are the official `riscv-tests` rv64ui / um / ua / mi / si
(integer + privileged), rv64uf / ud (FP), and the **vector (RVV)** suites,
hand-maintained in `tb/test_arch_common.veryl` (integer / privileged / vector) and
`tb/test_arch_fp.veryl` (FP); they are not `#[ignore]`, so they run as part of the
default `veryl test`. The default run also includes the
Phase-11 hypervisor directed tests (two-stage walk, guest-page-faults, HLV/HSV
and their mode-traps, Sstc-in-VS, VS-mode CSR isolation, `VTVM`/`VTSR`,
non-delegated VS interrupts, `mtval2`, and an end-to-end mini-hypervisor). The
Linux boots are `#[ignore]`d (run them by name, e.g.
`--test test_soc_smp_linux_boot_71_2hart`, or `--test test_soc_hvlinux` for the
guest boot); the 7.1 kernel is built with `CONFIG_FPU=y`, so its boot drives the
FP unit through real kernel context switches. The boot is additionally
cross-checked on Verilator and a second codegen backend (cc / cranelift) — see
`CLAUDE.md`.

## Microbenchmarks

Bare-metal programs run from the test harness to completion; the cycle count and
retired-instruction count are frozen at completion (IPC = instret / cycles, no
interrupts). CoreMark is the upstream EEMBC source (vendored under
`test/c/coremark/`) at ITERATIONS=1.

| Benchmark  | Cycles  | Instret | IPC   |
|------------|---------|---------|-------|
| CoreMark   | 276,893 | 374,357 | 1.352 |
| Dhrystone  | 210,037 | 273,241 | 1.301 |
| memcpy     |  80,099 | 102,051 | 1.274 |
| multiply   |  20,612 |  27,397 | 1.329 |
| median     |   6,790 |   6,875 | 1.013 |

CoreMark score: at ITERATIONS=1 the frequency-independent figure
CoreMark/MHz = iterations × 10⁶ / cycles ≈ **3.61**. Because the harness times the
whole program and runs a single iteration, the one-time setup is not amortized, so
this is a conservative lower bound on the steady-state (multi-iteration)
CoreMark/MHz rather than an official score.

Run individually (all `#[ignore]`):

```bash
veryl test --ignored --test test_coremark
veryl test --ignored --test test_dhrystone
veryl test --ignored --test test_bench_memcpy
veryl test --ignored --test test_bench_multiply
veryl test --ignored --test test_bench_median
```

The benchmark hex files are committed under `test/hex/`; rebuild them (requires
`riscv64-unknown-elf-gcc`) with `make -C test/c/dhrystone`, `make -C test/c/bench`
and `make -C test/c/coremark`.

## Directory Layout

```
src/
├── core/         OoO core: fetch/decode/rename, PRF/RAT/ROB/IQ, ALU, FPU, vector unit, CSR, SoC
├── cache/        I-cache / D-cache / shared L2 / memory_bus arbiter
├── mmu/          Sv39 MMU (instruction / data) + TLB
├── peripheral/   CLINT, PLIC, UART
└── pkg/          Shared packages and type definitions
tb/               Veryl native testbenches
test/             RISC-V ISA tests and hex programs
veryl/            Veryl compiler (local clone, gitignored)
```

## Build & Test

Install [Veryl](https://veryl-lang.org/) (e.g. via `verylup`) — heliodor builds on
upstream Veryl. Then from the project root:

```bash
veryl test                                                  # unit + arch suites + directed tests
veryl test --ignored --test test_soc_linux_boot             # 1-hart Linux 5.15 boot
veryl test --ignored --test test_soc_smp_linux_boot_4hart   # 4-hart SMP Linux 5.15 boot
veryl test --ignored --test test_soc_smp_linux_boot_66_2hart # 2-hart SMP Linux 6.6 boot
veryl test --ignored --test test_soc_smp_linux_boot_71_2hart # 2-hart SMP Linux 7.1 boot (RVA23 + FP)
veryl test --ignored --test test_soc_hvlinux                 # guest Linux under a type-1 hypervisor (H ext, two-stage MMU)
```

The `riscv-tests` arch hex files are committed under `test/riscv-arch-test/build/`;
rebuild them with `make -C test/riscv-arch-test` (requires `riscv64-unknown-elf-gcc`).

See `CLAUDE.md` for the development workflow (the Veryl compiler is also kept as a
gitignored local clone there for compiler hacking; toolchain modes, regression
steps, Verilator cross-check).

## Development Phases

Development history — the **Architecture** section above describes the design
as of Phase 12:

| Phase | Scope                                    | Status       |
|-------|------------------------------------------|--------------|
| 1     | RV64I scalar pipeline + caches + privilege + MMU + Linux boot | complete |
| 2     | ALU-side OoO: Tomasulo + ROB + RAT, dual-issue, FP RS, multi-cycle FU non-blocking | complete |
| 3     | Memory OoO: Store RS, Load Queue OoO issue, store-to-load forwarding, speculative load | complete |
| 4     | Multi-hart infrastructure: heliodor_core / heliodor_soc split, dcache invalidate broadcast, LR-SC remote flush, AMO bus lock, CLINT / PLIC array, multi-hart DTS / firmware (SBI HSM) | complete |
| 5     | Multi-hart Linux SMP boot: single-port DRAM bus arbitration, AMO data-valid gating, 2-hart Linux 5.15 boot to SBI SRST shutdown | complete |
| 6     | 4-hart SMP (`gen_n4` round-robin, SBI HSM HART_START tuned for `wait_for_completion` timing) + shared 128KB 4-way L2 with tree-PLRU | complete |
| 7     | Clean-slate OoO redesign: a from-scratch 1-wide pure-Tomasulo + PRF core that replaces the earlier OoO datapath, re-validated to RV64GC + 1/2/4-hart SMP Linux boot | complete |
| 8     | Microarchitecture build-out on the Phase 7 core: 2-wide superscalar (fetch / rename / issue / commit), branch prediction (BTB + gshare + TAGE-lite + indirect BTB + RAS, execute-time early redirect), non-blocking L1s (MSHRs, hit-under-miss, critical-word-first), memory-dependence speculation + replay, committed-store buffer with line write-combining and store-to-load forwarding, split read/write bus channels — 1-hart boot 26M → 8.6M cycles, 4-hart 52M → 16M | complete |
| 9     | Multi-core memory-system build-out: RVWMO litmus harness (P9.0), split-transaction DRAM read controller + line-granular L2 (P9.1), write-back D$ + MESI inclusive directory (P9.2), cache-to-cache transfer + in-cache AMO/LR-SC (P9.3), N=8 SMP boot (P9.4), PLIC wiring + uncached MMIO + TLB ASID + selective SFENCE.VMA (P9.5), coherent instruction side — I-cache + I-PTW through L2, FENCE.I/SFENCE flush sweep retired (P9.6) | complete |
| 10    | RVA23-profile ISA extensions (vector V / hypervisor H excluded): Zba/Zbb/Zbs, Sstc, Zicntr/Zihpm, Zicond, Zicbom/Zicboz, Zfa, hint bundle (Zihintpause/Zihintntl/Zicbop/Zimop/Zcmop), Zcb, system bundle (Zawrs/Svinval/Zkt), MMU bundle (Svnapot/Svpbmt/Svadu), Zfhmin, Sscofpmf, Supm/Ssnpm. Validated on real mainline kernels: upgraded the boot from 5.15 to the 6.6 LTS and 7.1, which discover the extensions from the device tree and exercise them (Sstc timer, Svpbmt ioremap, Zicboz clear_page, Zbb, hardware unaligned). Enabling userspace FP on 7.1 exposed and fixed two SMP-only RTL bugs — an FP-context-switch wedge (MSHR int-load completion misclassified FP-dest on the CDB mux) and missing compressed FP load/store (C.FLD/C.FSD/C.FLDSP/C.FSDSP) | complete |
| 11    | **Hypervisor (H) extension** (`misa.H`): HS/VS/VU modes + `V` bit, the full HS/VS CSR set, two-stage Sv39 × Sv39x4 nested translation with a VMID/VS-ASID-tagged TLB, HLV/HLVX/HSV (+ mode-traps), the guest-page-fault trio (20/21/23) with htval/mtval2, virtual-interrupt delivery (hvip into VS + non-delegated VS interrupts taken by HS), htimedelta + Sstc-in-VS guest timers, hstatus.VTVM/VTSR guest-op interception, VS-mode CSR isolation, and the mideleg/hedeleg read-only conformance bits. Brought up incrementally against per-feature directed tests, then validated end-to-end by a self-written bare-metal type-1 hypervisor that boots an unmodified guest Linux to its own userspace and SBI shutdown (cross-checked on the Veryl sim and Verilator). The vector V family lands in Phase 12 | complete |
| 12    | **Vector (V) extension (RVV 1.0)** — completing the RVA23 profile — plus full **architectural-compliance verification**. Added a decoupled, in-order vector unit (32 × 128-bit VRF, VLEN=128 / ELEN=64, integer + single/double FP, all LMUL): `vset{i}vl{i}`, integer / FP arithmetic (incl. multiply/divide, compares/merge, widening/narrowing, reductions), masking, and unit-stride / strided / indexed / segment / fault-only-first loads & stores; a V-enabled 7.1 kernel discovers and exercises it. The vector unit is verified by heliodor's inline **RVV arch suites** (`tb/test_arch_common.veryl`); the **scalar** RVA23 profile is machine-checked against the official RISC-V Architectural Compliance Tests (ACT4 / `riscv-arch-test`, Sail golden reference — which has no vector suite) across integer / atomic / FP / compressed / CSR / Zb\* / Zc\* / Zfa / Zfhmin / Zicbo\* / PMP / Sv\* / Exceptions. The compliance pass closed the scalar atomic gaps it surfaced (**Zabha** byte/half AMO, full **Zacas** incl. the 128-bit `amocas.q`), added **PMP** (Smpmp / SvPMP) region enforcement (load/store/fetch/AMO + PTE walks, PMA-hole faults), and fixed numerous real **FPU** bugs and several **Veryl simulator/analyzer bugs — fixed and upstreamed** to veryl-lang/veryl, so heliodor now builds on pristine upstream Veryl. See `test/act/README.md` | complete |

## References

- **[ReOVE]** Masayuki Kimura and Ryota Shioya, "ReOVE: Restricted Out-of-Order
  Execution for Superscalar Processors with Vector Extension," in *Proc. ACM/IEEE
  International Symposium on Low Power Electronics and Design (ISLPED '24)*,
  Newport Beach, CA, USA, 2024.
  DOI: [10.1145/3665314.3670805](https://doi.org/10.1145/3665314.3670805). The
  decoupled, in-order vector unit follows this scheme.
