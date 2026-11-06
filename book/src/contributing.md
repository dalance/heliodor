# Contributing

This chapter describes how to change Heliodor: the workflow, the rules the
source follows, and the checks a change has to pass.

## Workflow

1. Build the tools: [Getting started](getting-started.md).
2. Make the change on a branch.
3. Run the fast tests and the tests of the area you touched.
4. For a change to the memory system, caches, MMU, coherence, interrupts or
   anything shared by several harts, also run the multi-hart boots (see the
   regression ladder below). A change that passes every single-hart test can
   still break a multi-hart boot.
5. Review the comments and the module headers you touched. Delete comments that
   restate the code.
6. Commit.

Experiments that switch a behavior (a measurement variant, a different policy)
belong on a branch. Do not leave them in `master` as a configuration knob.

## Rules for the RTL

- **One concept, one module.** A module that grows past about 600 lines
  (excluding its header) needs a reason.
- **The core top is wiring.** `heliodor_core` holds instances and connections,
  with no state and no logic.
- **Every module starts with a header comment** in this form:

  ```text
  // <module>: <one-line responsibility>
  //
  // Ports (timing contract):
  //   i_x_valid/i_x : group handshake, lanes contiguous from lane 0
  //   o_x_ready     : registered state only
  //   i_kill        : applied on the capture edge of every entry and stage
  // Owns:
  //   - <invariant this module guarantees, stated so that it can be checked>
  // Rationale:
  //   - <design-specific choice and why; omit if there is none>
  ```

  A reader should be able to use the module from its header alone.
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
  `if_reset`.
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
  mechanism is either untested (write a directed test) or dead (delete it). A
  bit-identical result in a test where a mechanism never fired says nothing
  about that mechanism.
- **Invariant checkers.** `chk_*` modules only observe; they never feed a signal
  back. Their sticky flags reach `o_chk`, and every test checks that the flags
  are zero at the end.
- **Retire records.** `o_retire` is the observation contract of the core.
  Compare against a reference model through it.

## Comments

Comments are in English and state only the rationale and non-obvious constraints.
Do not restate what the code says, do not refer to plans, issue numbers or other
projects, and do not write numbers that go stale. When the code works, read the
comments once more and delete the ones that earn nothing.

Prose in documentation and comments avoids em-dashes: use a colon or a comma.

## Formatting

Format with `veryl fmt`. Be careful: a bare `veryl fmt` reformats the whole
repository. Before a focused change, format by hand in the style of the
surrounding code, or restrict `veryl fmt` to your files.

## Lint

A new module has no warnings. After you update Veryl, count the warnings by kind
and compare them with the previous count: a kind that has appeared is a bug report
until proven otherwise.

## The regression ladder

After a change, run these steps in order. Fix a failure before you go on. Run the
long ones in the background.

1. `veryl test`: unit tests, directed tests, and the architecture suites
   (`rv64ui`, `um`, `ua`, `mi`, `si`, `uf`, `ud`, and the vector suites). It takes
   from seconds to a few minutes.
2. `veryl test --ignored --test test_w2_litmus_4hart`: memory-model litmus tests
   on four harts. A hit on a forbidden outcome is a memory-model bug.
3. `veryl test --ignored --test test_w2_smp_linux_boot_2hart`: 2-hart Linux boot.
   The 1-hart boot is `--ignored --test test_w2_linux_boot`.
4. `veryl test --ignored --test test_w2_smp_linux_boot_4hart`: 4-hart Linux boot.
   It takes about an hour of CPU time. Run it for every change to the memory
   system: it has caught livelocks that no smaller test showed.
5. `veryl test --ignored --test test_w2_hvlinux`: guest Linux under the
   hypervisor. A change to the shared data-side MMU or the load path can pass
   steps 1 to 4 and still deadlock here.

Repeat the boots for the 4-wide core by replacing `w2` with `w4`. See
[Verification](verification.md) for the meaning of each step.

Cycle counts of boots and litmus tests drift with every performance change. Treat
a large unexplained jump as a regression. The cycle counter of a boot advances in
steps of 10,000, so two runs that print the same count are only equal to within
that step; the benchmark programs (`dhrystone`, `coremark`) report exact counts.

To rule out a simulator bug, rerun a suspicious test on a second backend
(`--backend cranelift` or `--backend interpret`), and for the boots, on
Verilator.

## Compiler and simulator bugs

If a failure is caused by the Veryl compiler or simulator, do not work around it
in the RTL. Fix it in your clone of Veryl in `./veryl/`, on a branch, and send it
upstream. Add the regression test to the simulator's own tests.

## Commits

- Write the commit message in English as a single short subject line.
- Stage the files you changed by name. Do not stage a whole directory.
- Keep related fixes on one branch, and in one commit unless there is a reason to
  split them.

## Design documents

`doc/` holds design records of the core written in Japanese, including
`doc/phase15_core_design.md` (the design of the current core) and
`doc/phase15_verification_plan.md`. They record the reasons behind decisions.
This book is the user-facing documentation.
