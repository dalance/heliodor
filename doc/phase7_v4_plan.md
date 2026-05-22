# Phase 7 v4: Cosim-First OoO Core Redesign

## Status

- **Date**: 2026-05-22
- **Predecessor**: Phase 7 v3 (archived as `phase7-v3-experimental` branch)
- **Base commit**: 5f834d2 (Phase 6 master — same starting point as v3)

## Why v4? (Lessons from v3 failure)

### v3 root cause (one-sentence)

> Cosim was the *load-bearing verification mechanism* on which the entire v3 design depended, yet it was classified as "infrastructure work, later" and ended up skipped — putting v3 back into the same "30M-cycle panic, hand-trace" debug syndrome as v2.

### Structural failures

| # | Failure | Evidence |
|---|---------|----------|
| 1 | M0 declared complete with **skeleton only** | `cosim_checker` + `test_cosim_skeleton` exists; no `test_cosim_rv64ui_add` ever built. Memory note "JIT 互換 refactor は M1 残課題" never resolved. |
| 2 | M1 exit criterion **slid** from "rv64ui cosim pass" to "v3 alone passes rv64ui-add" | task #443 marked completed for v3-solo run, no v1↔v3 comparison |
| 3 | "Cosim 本格実装" task #470 marked done while only **instrumenting** Linux boot | added ring buffers, not actual lockstep comparison |
| 4 | Boot gate **not enforced** as halt condition | regression found 2026-05-22: rv64ui-add fails on master, broke sometime after #443 |
| 5 | Debug instrumentation **leaked into production code** | `heliodor_core_v3.veryl` grew to 1400+ lines with STUCK detectors, per-idx counters, ring buffers — all workarounds for not having cosim |
| 6 | `veryl test --test <filter>` substring match **silently fails** | `--test test_v3_arch_rv64ui_add` reports "No tests matched" — developers running targeted tests would see 0/0 and move on |
| 7 | v1 retire-PC dbg ports **never added** | "treat v1 as black-box" principle prevented the 30-line port addition that cosim required |

### Symptom recap

- v3 Linux real boot: 64 inst issue + 64 CDB writeback, **0 commits**, stuck at firmware PC=0x104
- v3 arch test rv64ui-add/addi/addw/addiw all **FAIL** (tohost=0)
- v3 unit tests (220) pass — so basic ALU/PRF/RAT functional, but commit chain broken in some integration scenarios
- Regression cycle unknown; would require `git bisect` to localize

## v4 Iron Rules (non-negotiable)

These are the rules that v3 failed to enforce. v4 must enforce them mechanically.

### Rule 1: M0 exit gate = real cosim, not skeleton

M0 is complete only when `tb/test_cosim_rv64ui_add.veryl` exists and:
- Instantiates **both** `heliodor_core` (v1) and `heliodor_core_v3` (v3, even if stub) with the same hex
- Wires both retire-PC streams to `cosim_checker`
- Runs for ≥100 cycles and reports `diverged=0 && compared > 0`

If v3 is just a stub (no real retires), the test must explicitly mark expected-divergence for that stub state and assert on that. Once v3 has real retires, the test must pass with no divergence.

**Acceptance trigger**: `veryl test --include-ignored --test test_cosim_rv64ui_add` returns exit 0 with explicit "PASS" log line.

### Rule 2: commit gate = full regression must pass

Every commit to v4 work must, **before commit**:

```bash
rm -f .build/lock
./veryl/target/release-verylup/veryl test            # fast suite, MUST be all-green
./veryl/target/release-verylup/veryl test --include-ignored --test test_cosim   # MUST be all-green
./veryl/target/release-verylup/veryl test --include-ignored --test test_v4_arch # MUST be all-green (once M1 done)
```

A `script/v4_precommit_check.sh` will be added in M0 to encapsulate this. **Failing this check = no commit.** Even debug/instrumentation commits.

### Rule 3: production code stays clean

No STUCK detector, ring buffer, counter, $display, or `dbg_*` accumulation in `src/core_v4/`. All such instrumentation lives in `tb/` wrappers or behind a `#[ifdef DEBUG_*]`-style gate that the precommit script verifies is off in CI mode.

If you find yourself adding `dbg_alloc24`-style counters to production, **stop and add it to the cosim assertion library instead**.

### Rule 4: v1 modifications are allowed for verification

The "treat v1 as black-box" principle was wrong — it prevented cosim from being built. v4 explicitly allows the following v1 modifications, **only** in M0:

- Add `o_dbg_retire_v_a / o_dbg_retire_pc_a / o_dbg_retire_rd_v_a / o_dbg_retire_rd_a / o_dbg_retire_data_a` to `heliodor_top` and `heliodor_core` (5 output ports)
- Wire these to the existing `rob_commit_*` signals inside `heliodor_core`
- No other functional changes

Once these ports exist, v1 remains read-only.

### Rule 5: task completion = exit gate passes

Tasks like "M0 cosim infra" must list their exit gate explicitly in the task description. Marking a task complete without the gate having passed is forbidden. Skeleton-completion tasks must be split into separate sub-tasks.

### Rule 6: --test filter audit

The `veryl test --test <filter>` issue must be characterized and worked around in M0:

- Determine why `--test test_v3_arch` reported "No tests matched" despite the substring being present
- Document the actual matching behavior in a comment in `script/v4_precommit_check.sh`
- Ensure the precommit script invokes tests in a way that reliably runs the intended targets

### Rule 7: cosim divergence = halt + dump

`cosim_checker` must, on first divergence:
- Set `o_diverged=1` (sticky)
- Dump last 256 retires from each side (already implemented in v3 skeleton — port as-is)
- Cause the enclosing tb's $assert to FAIL with a clear error message
- Veryl test exit code must reflect this failure

## Architecture (carryover from v3, refined)

v4 keeps the v3 architecture decisions that were correct, drops what failed:

### Kept from v3

- **Pure Tomasulo + PRF + ROB + LSQ** — design choice was sound, implementation broke
- **FU/service modules black-box from v1** — alu, branch_comp, int_divider, fp_*, decoder, c_expander, dcache, icache, mmu, peripheral, pkg
- **Phased milestone (M1 RV64I → M9 Linux SMP)** — sequencing is fine
- **commit-time-only redirect** — design principle remains
- **All op goes through IQ (no direct path)** — design principle remains

### Changed from v3

- **Naming**: directory `src/core_v4/`, package `pipeline_v4_pkg`, top `heliodor_core_v4`, soc `heliodor_soc_v4`, tb prefix `test_v4_*`. This keeps v3 archive distinguishable in cross-references.
- **No accumulated debug code**: starting clean, will not import v3 STUCK detector / counters / ring buffer code
- **Cosim driven**: M1 will be very small (single integer ALU + ROB + commit), built specifically to make cosim pass on rv64ui-add subset (NOT all of rv64ui)
- **Boot gate from M4 enforced via precommit script**: see Rule 2

### Cosim implementation sketch (M0)

```veryl
module test_cosim_rv64ui_add_harness (
    clk: input clock,
    rst: input reset,
    o_pass: output logic,
    o_done: output logic,
    o_diverged: output logic,
    o_compared_cnt: output logic<32>,
) {
    // Cycle counter
    var cycle: logic<32>;

    // === Shared hex memory (read-only for v1 and v4) ===
    var dram: logic<32> [65536];
    initial { $readmemh("test/riscv-arch-test/build/rv64ui/add.hex", dram); }

    // === v1 instance with retire dbg ports (new in v4 M0) ===
    inst v1: heliodor_top #( RESET_PC: 64'h80000000 ) (
        clk, rst, ...,
        o_dbg_retire_v_a   : v1_ret_v,
        o_dbg_retire_pc_a  : v1_ret_pc,
        o_dbg_retire_rd_v_a: v1_ret_rdv,
        o_dbg_retire_rd_a  : v1_ret_rd,
        o_dbg_retire_data_a: v1_ret_data,
    );

    // === v4 instance with same hex ===
    inst v4: heliodor_core_v4 #( RESET_PC: 64'h80000000 ) (
        clk, rst, ...,
        o_dbg_retire_v_a   : v4_ret_v,
        o_dbg_retire_pc_a  : v4_ret_pc,
        ...
    );

    // === Cosim checker (carried over from v3 cosim_checker.veryl) ===
    inst u_check: cosim_checker (
        clk, rst,
        i_cycle: cycle,
        i_v1_push: v1_ret_v,  i_v1_pc: v1_ret_pc,  ...,
        i_v4_push: v4_ret_v,  i_v4_pc: v4_ret_pc,  ...,
        o_diverged    : o_diverged,
        o_compared_cnt: o_compared_cnt,
    );

    assign o_done = cycle >= 32'd200_000 || tohost_signaled;
    assign o_pass = !o_diverged && o_compared_cnt > 32'd50;
}

#[test(test_cosim_rv64ui_add)]
module test_cosim_rv64ui_add {
    // standard scaffolding
    $assert(pass, "cosim divergence detected at cy=...");
}
```

Memory sharing: in M0, v1 and v4 each have their own DRAM copy (initialized from same hex). They never share writable state. They each run independently. Cosim only compares retire streams, NOT memory contents (which differ in OoO timing anyway). For arch tests, tohost is checked on each side separately.

## Milestone Restructure

The v3 milestone names (M0-M9) overloaded with v3 task history. v4 uses clean naming:

| v4 Mx | Target | Exit gate |
|-------|--------|-----------|
| **M0** | Cosim infra + v1 dbg ports + precommit script | `test_cosim_rv64ui_add` PASS (or expected-divergence for v4 stub) |
| **M1** | RV64I 1-wide pure Tomasulo (ALU + branch only) | `test_cosim_rv64ui_{add,addi,addw,addiw,and,andi,or,ori,xor,xori,sll,slli,sra,srai,srl,srli,sub,subw}` all PASS (no divergence) |
| **M2** | RV64I full (LOAD/STORE toy mem) | rv64ui-* all PASS in cosim |
| **M3** | M extension (MUL/DIV) | rv64um-* PASS in cosim |
| **M4** | CSR + M-mode + interrupt + A ext | rv64ua + rv64ui-Zicsr + tb/test_clint + tb/test_amo_fail PASS in cosim |
| **M5** | dcache adapter + LSQ + dmem_mmu + imem_mmu + S-mode + Sv39 | rv64ua + tb/test_smode_* PASS in cosim |
| **M6** | F + D ext | rv64uf + rv64ud PASS in cosim |
| **M7** | C ext + RVC expand + unaligned fetch | rv64uc + full arch-test PASS in cosim |
| **M8** | L1 I$ + L2 + memory_bus + SMP arbiter | arch_rv64ui full SoC + coremark PASS in cosim |
| **M9** | Linux boot N=1 → N=2 → N=4 | SBI shutdown reached (arch_shadow[3]==0xAA) |
| **cleanup** | v1 削除 + core_v4 → core rename + CORE_VERSION 廃止 | n/a |

### Width progression

- M1-M5: **1-wide** throughout. dual-issue is M6's responsibility (combined with FP/checkpoint).
- M6: 2-wide front-end + dispatch + commit + dual CDB
- M7-M9: stay at 2-wide

## Open questions for the v4 build

1. **--test filter root cause**: needs M0 investigation. Possibly Veryl test discovery bug, possibly intended exact-match. Workaround: invoke with `--include-ignored` and grep test output.
2. **Shared dcache for v1 and v4 in cosim?** No — keep independent. Tohost is per-side. Memory state diff is by-design.
3. **CLINT/PLIC determinism**: Both cores need identical CLINT timing for retire-order alignment under IRQ. M4 onwards needs deterministic mtime advance (both cores tick at same rate from cycle 0). Easy with shared mtime register driven from cycle counter.
4. **IRQ at Linux boot timescale**: cosim of full Linux boot may be too slow for daily use. M9 acceptance may be "cosim runs to first 100K retires without divergence" + "v4-only boot reaches SBI shutdown" — splitting the burden.

## Migration steps (this session)

1. Write this doc ← done
2. Commit doc to current master (e4c3a4b state) so it travels with the v3 archive
3. `git branch phase7-v3-experimental` — archive current state
4. `git reset --hard 5f834d2` — return master to Phase 6 baseline
5. Cherry-pick this doc back onto reset master (so v4 dev has it)
6. Begin M0 in next session

## Cross-references

Memory entries to retain (not invalidated by archive):
- `project_phase7_start.md` — Phase 7 starting decisions (v3, now v4 too)
- `project_phase7_v3_commit_blocker.md` — root-cause findings on v3 commit bug
- `feedback_*` — all v3-era feedback memories carry over
- `project_sim_*` — sim bug records carry over (those are Veryl, not v3-specific)
