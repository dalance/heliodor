# Veryl native-sim vs Verilator — standardized boot benchmark

How to compare the **Veryl native simulator** (`veryl test`, AOT-C backend) against
**Verilator** on the Linux-boot workload, consistently across the phase branches.
Both toolchains run the *same* RTL, so a boot is cy-exact on both; the comparison
is wall-time (and, for sim-opt work, retired instructions).

Start on **`master`** (this doc lives here); `git checkout <phase>` to measure a
given phase, then come back. The doc is intentionally not duplicated per branch.

## 1. Per-phase boot test + Verilator wrapper

The N=1 boot is the trustworthy comparison point (SMP wall is easily load-polluted).
Test names shifted when the OoO SoC landed: **phase1–6 use `test_linux_boot`**,
**phase7+ use `test_soc_linux_boot`**.

| Branch       | N=1 boot test           | Verilator wrapper (`sim/verilator/`) | SMP boot tests                              |
|--------------|-------------------------|--------------------------------------|---------------------------------------------|
| phase1/2/3   | `test_linux_boot`       | `tb_linux_boot.sv`                   | —                                           |
| phase5       | `test_linux_boot`       | `tb_linux_boot.sv`                   | `test_smp_linux_boot` (2h) / `tb_linux_boot_smp.sv` |
| phase6       | `test_linux_boot`       | `tb_linux_boot.sv`                   | + `test_smp_linux_boot_4hart` / `tb_linux_boot_smp_4hart.sv` |
| phase7/8     | `test_soc_linux_boot`   | `tb_soc_linux_boot.sv`               | `test_soc_smp_linux_boot_{2,4}hart` / `tb_soc_smp_linux_boot_{2,4}hart.sv` |
| phase9       | `test_soc_linux_boot`   | `tb_soc_linux_boot.sv`               | + `_8hart`                                  |
| phase12      | `test_soc_linux_boot`   | `tb_soc_linux_boot.sv`               | `test_soc_smp_linux_boot_{2,4,8}hart` (+ kernel variants, below) |
| phase13      | `test_soc_linux_boot`   | `tb_soc_linux_boot.sv`               | `test_soc_smp_linux_boot_{2,4}hart`         |

The Verilator top-module name equals the wrapper's `module` name (same as the file
stem). Wrappers instantiate the `<test>_harness` module that `veryl build` emits.

### Kernel variants and `--test` isolation
`veryl test --test X` is a **substring** filter. Where a branch has extra kernel
boots (Linux 6.6 / 7.1 / 7.1-vector), naming matters:
- **phase12 / phase13**: variants are named `test_soc_{66,71,71v}_linux_boot`
  and `test_soc_{66,71}_smp_linux_boot_{2,4}hart` — the kernel tag sits *before*
  `linux_boot`, so `--test test_soc_linux_boot` matches **only** the base boot.
- **phase1–9**: no N=1 kernel variants, so `--test test_soc_linux_boot` /
  `--test test_linux_boot` already isolates.

When a filter matches several boots they run on parallel workers and pollute each
other's wall time; always confirm the run reports `1 passed` before trusting a
warm number.

## 2. What to measure (in priority order)

1. **Retired instructions** — `perf stat -e instructions,cycles`. Deterministic
   for a fixed workload, so **load-independent**: the primary signal for a sim-opt
   A/B. Same RTL ⇒ same cycle count on both sims, but the host instruction/cycle
   count differs and is what codegen work moves.
2. **Warm run_ms** — sim-only wall from a profile build (below). Load-sensitive;
   only compare Veryl-vs-Verilator numbers taken in the **same time window** on the
   **same host**, and prefer the ratio over absolutes.
3. **cy-exact** — both sims must boot to the same `x3 == 0xAA` and identical cycle
   count. A mismatch is a bug, not a perf result.

Never compare wall across hosts (Zen vs Xeon differ 50%+). Don't bench under high
load; for direction a 1-sample run is fine, for a landing take a 5-sample median.

## 3. Warm vs cold

Both toolchains have front-end → codegen → run. **cold** = nothing cached (build
the model, then run); **warm** = model already built (run only).

- **Veryl warm is not `veryl test` wall.** `veryl test` re-parses + rebuilds IR +
  dlopens the `.so` every run, so its wall is never sim-only. The warm number is
  the `run_ms` from a **profile build**, taken on a **second, cache-hot** run (the
  first run still pays Cranelift warm-up + the overlapped `cc` compile).
- **Verilator warm** = re-running the built binary (pure sim).
- `veryl build` (`.veryl`→SV) is a Veryl-side prerequisite, not a Verilator cost —
  generate the SV once as untimed setup and exclude it from the Verilator cold time.

## 4. Commands

Set the pair for the phase (example: phase7+ N=1):

```bash
T=test_soc_linux_boot                    # phase1-6: test_linux_boot
W=sim/verilator/tb_soc_linux_boot.sv     # phase1-6: sim/verilator/tb_linux_boot.sv
TOP=tb_soc_linux_boot                    # phase1-6: tb_linux_boot
MDIR=sim/verilator/build_$TOP
V=veryl/target/release-verylup/veryl
```

### Veryl
```bash
# profile build is needed for the sim-only run_ms (warm number)
cargo build --manifest-path veryl/Cargo.toml --profile release-verylup --features profile

# cold: clear the AOT-C cache → wall = parse + IR + (cc compile, overlapped) + sim
rm -rf ~/.cache/veryl/aot_c; rm -f .build/lock
/usr/bin/time -v $V test --ignored --test $T 2>&1 | grep -E "Elapsed|PROFILE_SPLIT"

# warm (sim-only): run AGAIN, cache now hot → run_ms is pure AOT-C sim
rm -f .build/lock
$V test --ignored --test $T 2>&1 | grep PROFILE_SPLIT
#   -> PROFILE_SPLIT test=... build_ms=... run_ms=<warm sim-only ms>
```

### Verilator
```bash
$V build                                 # emit SV + heliodor.f (untimed setup)

# cold: wipe the model dir so Verilator recompiles from the SV, then run
rm -rf "$MDIR"
/usr/bin/time -v sh -c \
  "verilator --binary --top-module $TOP -f heliodor.f $W --timing -Wno-fatal -O3 \
     --Mdir $MDIR -o $TOP && $MDIR/$TOP" 2>&1 | grep Elapsed

# warm (sim-only): re-run the built binary
/usr/bin/time -v "$MDIR/$TOP" 2>&1 | grep Elapsed
```

Comment lines in a wrapper must not start with the word `verilator` (Verilator
parses `// verilator …` as a pragma). Old phases may need `-Wno-ENUMVALUE`.

### Fair pairing
- **cold vs cold**: Veryl `veryl test` Elapsed (cache cleared) ↔ Verilator
  `verilator --binary` + run Elapsed (SV pre-generated).
- **warm vs warm**: Veryl 2nd-run `run_ms` ↔ Verilator binary re-run Elapsed.
- Take both sides in one window so shared-host load cancels in the ratio.

## 5. Sim-opt A/B (instruction count)

For a Veryl-side change, the load-independent verdict is the retired-instruction
delta on the solo boot:

```bash
# NEW (change applied): build, then
perf stat -e instructions,cycles $V test --ignored --test $T
# OLD (baseline): toggle the change off and rebuild, then re-run
git -C veryl stash        # ... rebuild ... perf stat ... git -C veryl stash pop
```

Confirm cy-exact across the two (same boot cycle count) before trusting the delta,
and cross-check correctness with `veryl test --backend-validate` (dual-runs cc vs
cranelift, panics on divergence).

Measured results and their attribution live in the auto-memory / `doc/cp_*`, not
here — this file is the procedure only.
