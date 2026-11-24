# Contributing

This chapter describes how to change Heliodor: the workflow, the rules the
source follows, and the checks a change has to pass.

## Workflow

1. Build the tools: [Getting started](getting-started.md).
2. Run the fast tests and the tests of the area you touched. A change that can
   alter the retire stream (decode, execute, the CSRs, the MMU) should also pass
   the spike co-simulation: `python3 test/gates/run_gc.py --core w2` and a batch of
   random programs; see [Verification](verification.md).
3. For a change to the memory system, caches, MMU, coherence, interrupts or
   anything shared by several harts, also run the multi-hart boots (see
   [Which tests to run](#which-tests-to-run)). A change that passes every
   single-hart test can still break a multi-hart boot.
4. Commit.

## Rules for the RTL

- **One concept, one module.** A module that grows past about 600 lines
  (excluding its header) needs a reason.
- **The core top is wiring.** `heliodor_core` holds instances and connections,
  with no state and no logic.
- **Every module, package and interface starts with a documentation comment**
  (`///`) in this form:

  ```text
  /// <One-line responsibility>.
  ///
  /// # Owns
  ///
  /// - <invariant this module guarantees, stated so that it can be checked>
  ///
  /// # Rationale
  ///
  /// - <design-specific choice and why; omit if there is none>
  pub module m (
      /// <timing contract of this port: registered or combinational, when it
      /// is valid, what a handshake means>
      i_x: input logic,
  )
  ```

  The timing contract of a port is a `///` comment on that port. A group of
  ports that share one contract (a valid/data pair, a kill and its redirect)
  carries the text on the first port, and the others say "See i_x". A
  statement about the interface as a whole goes under a `# Timing` heading in
  the module comment. A reader should be able to use the module from its
  documentation alone, and `veryl doc` renders it as one page per module.
- **Sizes come from the configuration package.** A size constant is read only by
  its owner and by `core_types`. Other modules use tag types. See
  [Configuration](configuration.md).
- **No behavior-switching constants.** A new module has no `const` or `param` of
  type `bit` that selects between two behaviors. Value parameters such as a
  latency are fine, and they live in one place (`fu_pkg` for latencies that
  cross a module boundary).
- **Stages join through `lane_queue` or `stage_reg`.** Adding a stage then
  changes its two neighbours and one latency constant.
- **No serial reductions.** Do not write an `acc = f(acc, x[i])` loop over the
  entries of a queue. Use the trees and prefix helpers in `tree_pkg`. Synthesis
  does not rebalance such chains. When you add a tree, add an equivalence test
  against the serial version in the style of `tb/test_vmspre.veryl`.
- **No `break` in loops.** Write first-match logic with a prefix.
- **One-hot selection is an AND-OR,** not a priority `if` chain.
- **No `$display` or `$assert` in RTL.** Observation goes through ports. The
  `cc` simulator backend gives up a whole combinational block if it contains one.
- **Reset every valid bit,** and write nothing after the `else` branch of
  `if_reset`. Payload arrays of more than a few hundred bits are written by an
  `always_ff` without a reset, with at most one read and one write port, so that
  synthesis maps them to RAM.
- **Observation-only logic is conditional.** State and logic that only feed the
  observation ports (retire record fields, event wires) go under
  `#[ifdef(HELIODOR_OBS)]`, and checkers under `#[ifdef(HELIODOR_CHK)]`, each with
  an `#[ifndef]` branch that gives the port its constant value. A synthesis build
  defines neither; see [Synthesis](soc-integration.md#synthesis).
- **Do not leave dead scaffolding:** arms guarded by a constant, counters nobody
  reads, reserved state that nothing uses.
- **A module with tagged registers has an `i_kill` port.**
- **`$readmemh` appears only in testbenches.**

Naming:

| Item | Convention |
|---|---|
| Modules | snake_case noun for the concept (`rob`, `mem_pipe`) |
| Ports | `i_` or `o_` prefix; handshakes end in `_valid` and `_ready` |
| Registers | A variable whose output is registered ends in `_q` |
| Types, constants, functions | PascalCase, UPPER_SNAKE, snake_case |
| Indices | `l` for a lane, `p` for a port, `e` for an entry |
| Stage prefixes | `p<n>_` (predictor), `f<n>_` (fetch), `x_` (extract), `d_` (decode), `rn_` (rename and dispatch), `is_` (select), `rr_` (register read), `ex<n>_` (execute), `m<n>_` (memory pipe), `wb_`, `cm_` (commit) |

Use the standard vocabulary: ROB, IQ, LQ, SQ, SB, FTQ, PRF, RAT, MSHR, TLB, PTW,
wakeup, select, retire, commit, flush, kill.

Logic indexed by lane or port is written once in a `for` generate body; do not
special-case lane 0. If lanes differ, describe the difference in a constant
array.

## Observability

Every mechanism of a new module should be visible and checkable.

- **Event wires.** A mechanism (each retry reason, each kind of kill, each way a
  dispatch group is cut, a forward hit, a walk, a replay) has a registered event
  wire in the `CorePerf` struct that reaches `o_perf`. Each wire has to be
  nonzero in at least one test. A wire that is zero everywhere means the
  mechanism is either untested (write a directed test) or dead (delete it).
- **Invariant checkers.** `chk_*` modules only observe; they never feed a signal
  back. Their sticky flags reach `o_chk`, and every test checks that the flags
  are zero at the end.
- **Retire records.** `o_retire` is the observation contract of the core.
  Compare against a reference model through it.

## Comments

Comments are in English and state only the rationale and non-obvious constraints.
Do not restate what the code says, do not refer to plans, issue numbers or other
projects, and do not write numbers that go stale.

## Formatting

Format with `veryl fmt`.

## Lint

A new module has no warnings.

## Which tests to run {#which-tests-to-run}

The tests range from seconds to hours, so pick them by what the change touches.
[Verification](verification.md) describes each test.

| Change | Tests to run |
|---|---|
| Any change | `veryl test` (tens of minutes). It runs on both configurations. |
| Anything that can alter the instructions that retire or their results (decode, execute, the CSRs, the MMU) | The 1-hart boot in lockstep, `test_w2_linux_boot_lockstep`, the spike co-simulation, `python3 test/gates/run_gc.py --core w2`, and a batch of random programs |
| The memory system, the caches, coherence, interrupts, or anything shared by several harts | The 4-hart litmus tests, `test_litmus_4hart`, and the 2-hart and 4-hart boots, `test_soc_smp_linux_boot_2hart` and `test_soc_smp_linux_boot_4hart`. The 4-hart boot takes about three hours, but it has caught livelocks that no smaller test showed. |
| The data-side MMU, the load path, or the hypervisor extension | The guest boot, `test_soc_hvlinux`. It is the only test that runs the two-stage MMU under load. |
| Anything that can differ between the 2-wide and 4-wide configurations | The 4-wide counterparts of the tests above (`test_w4_*`) |

Before a release, run all of these on both configurations. Run the long tests
with `veryl test --ignored --test <name>`; the expected cycle counts are in
[Verification](verification.md#long-tests).

Cycle counts of boots and litmus tests drift with every performance change. Treat
a large unexplained jump as a regression, but remember that a boot takes its time
from `mtime`: a change of a few cycles can move a whole timer tick (about 400,000
cycles) of kernel waiting. The cycle counter that a boot test prints advances in
steps of 10,000, so two runs that print the same count are only equal to within
that step; the `boot:` line of the harness and the benchmark programs
(`dhrystone`, `coremark`) report exact counts.

## Compiler and simulator bugs {#compiler-and-simulator-bugs}

The simulator has three code-generation backends, chosen with `--backend`: `cc`
(the default: emit C and compile it), `cranelift` (an in-process JIT) and
`interpret` (a tree-walking interpreter, the slowest, used as the reference). To
rule out a simulator bug, rerun a suspicious test on a second backend, and for the
boots, on Verilator. Two independent backends that agree make a simulator bug
unlikely.

```bash
veryl test --backend cranelift --test <name>
veryl test --backend interpret --test <name>
```

If a failure is caused by the Veryl compiler or simulator, do not work around it
in the RTL. To debug the compiler, keep a clone of Veryl in `./veryl/` (git ignores
the directory) and build it there:

```bash
git clone https://github.com/veryl-lang/veryl.git veryl
(cd veryl && cargo build --profile release-verylup)
```

The test scripts use `./veryl/target/release-verylup/veryl` when `VERYL` is not
set. Fix the bug on a branch and send it upstream, with the regression test in
the simulator's own tests.

## Design documents

`doc/` holds design records of the core written in Japanese, including
`doc/phase15_core_design.md` (the design of the current core) and
`doc/phase15_verification_plan.md`. They record the reasons behind decisions.
This book is the user-facing documentation.
