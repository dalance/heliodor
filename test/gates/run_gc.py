#!/usr/bin/env python3
"""Run gate lists under the spike cosim (GC): every retire record checked
against spike.

    test/gates/run_gc.py --core w2 [--list L ...] [--suite S,...] [--log-dir DIR]
                         [--keep] [--batch N] [--from-json REPORT]

Needs spike: SPIKE_HOME (or toolchain/spike) for the spike_cosim component in
cosim/spike. Without --list it runs the arch and directed lists the default
`veryl test` runs on the core (DEFAULT_LISTS); entries with dmi= are skipped
(gen_core_tests.cosim_ok). Entries with harts > 1 run under spike_cosim_smp.
For ACT4 use run_act.py --cosim.

Steps: write tb/test_gc_<core>_<suite>.veryl with gen_core_tests.py --cosim
(`#[ignore]`), run `veryl test --ignored --test test_gc_<core>_ --format json`
($VERYL, else veryl/target/release-verylup/veryl) once per batch of whole
suites, and require every test to pass: the DUT passes the image and the
cosim reports no mismatch. The wrappers are deleted afterwards unless --keep.

Tests in SPIKE_GAPS are not run: they exercise behaviour the configuration
fixes and spike cannot be set to through its public API; the reason is
printed instead.

Exit code 0 only if every selected test passes.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

MASTER = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(MASTER / "test" / "gates"))
import gatelist  # noqa: E402
import gen_core_tests  # noqa: E402
from run_act import batches  # noqa: E402

DEFAULT_LISTS = [
    "m1b", "m2_csr", "m2_csr_pf", "m2_directed", "m2_fp", "m2_fp_pf", "m2_io_pf", "m2_lsu", "m2_lsu_pf",
    "m2_mmu_pf", "m2_probe_pf", "m2_scalar", "m3_mem_pf", "m5_h", "m5_hprobe", "m5_vec", "m5_vprobe",
    "mi_probe",
]

SPIKE_GAPS = {
    "miprobe/mi_csr_warl": "spike implements mseccfg.MML/MMWP/RLB whenever PMP exists (the configuration has "
                           "no Smepmp), and MML/MMWP are sticky",
    "miprobe/mi_svrsw": "spike has no Svrsw60t59b: PTE bits 60:59 are reserved and fault",
    "miprobe/mi_csrind": "spike's Smcdeleg sireg aliases the read-only hpmcounterN, so a delegated counter "
                         "write is illegal",
    "miprobe/mi_vstart": "spike executes a vector access with vstart >= VLMAX, which the configuration "
                         "(and Sail) reserve as illegal",
    "miprobe/mi_vemul": "spike executes register-group encodings RVV reserves (EMUL, overlap, v0 rules) that "
                        "the configuration (and Sail) make illegal",
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--core", required=True, choices=sorted(gen_core_tests.CORE_CONST))
    ap.add_argument("--list", type=Path, action="append", help="gate list (repeatable; default DEFAULT_LISTS)")
    ap.add_argument("--suite", default="", help="comma-separated suites (default: all)")
    ap.add_argument("--log-dir", type=Path, default=MASTER / ".build" / "run_gc")
    ap.add_argument("--keep", action="store_true", help="keep the generated wrappers (renamed per batch)")
    ap.add_argument("--batch", type=int, default=400, help="tests per veryl run (default 400)")
    ap.add_argument("--from-json", type=Path, help="judge this saved report instead of running")
    a = ap.parse_args()

    lists = a.list or [MASTER / "test" / "gates" / f"{n}.list" for n in DEFAULT_LISTS]
    want = {s for s in a.suite.split(",") if s}
    entries, seen = [], set()
    for path in lists:
        for e in gatelist.parse(path):
            if gen_core_tests.cosim_ok(e) and e.key not in seen and (not want or e.suite in want):
                seen.add(e.key)
                entries.append(e)
    for e in entries:
        if e.key in SPIKE_GAPS:
            print(f"SKIP {e.key}: {SPIKE_GAPS[e.key]}")
    entries = [e for e in entries if e.key not in SPIKE_GAPS]
    if not entries:
        print("run_gc: no tests selected", file=sys.stderr)
        return 2
    if a.from_json:
        return judge(a, entries, json.loads(a.from_json.read_text()))

    tb = MASTER / "tb"
    for old in tb.glob(f"test_gc_{a.core}_*.veryl"):
        old.unlink()
    veryl = os.environ.get("VERYL") or str(MASTER / "veryl" / "target" / "release-verylup" / "veryl")
    cmd = [veryl, "test", "--ignored", "--test", f"test_gc_{a.core}_", "--format", "json"]
    a.log_dir.mkdir(parents=True, exist_ok=True)
    tests = []
    for n, batch in enumerate(batches(gatelist.by_suite(entries), a.batch)):
        gen = []
        for suite, es in batch:
            path = tb / f"test_gc_{a.core}_{suite}.veryl"
            path.write_text(gen_core_tests.HEADER.format(src="test/gates/run_gc.py")
                            + "".join(gen_core_tests.gen_cosim_module(e, a.core) for e in es))
            gen.append(path)
        count = sum(len(es) for _, es in batch)
        print(f"run_gc: batch {n}: {' '.join(cmd)} ({count} tests)", file=sys.stderr, flush=True)
        try:
            p = subprocess.run(cmd, cwd=MASTER, text=True, capture_output=True)
        finally:
            for path in gen:
                if a.keep:
                    path.rename(path.with_suffix(f".veryl.b{n}"))
                else:
                    path.unlink(missing_ok=True)
        (a.log_dir / f"{a.core}.{n}.json").write_text(p.stdout)
        (a.log_dir / f"{a.core}.{n}.err").write_text(p.stderr)
        try:
            tests += json.loads(p.stdout).get("tests", [])
        except json.JSONDecodeError:
            print(f"run_gc: veryl exited {p.returncode} without a JSON report, see {a.log_dir}/{a.core}.{n}.err",
                  file=sys.stderr)
            return 2
    rep = {"tests": tests}
    (a.log_dir / f"{a.core}.json").write_text(json.dumps(rep))
    return judge(a, entries, rep)


MISMATCH = re.compile(r"spike mismatch(?:(?!\\n)[^\"])*")


def judge(a, entries, rep):
    report = {t["name"]: t for t in rep.get("tests", [])}
    bad, rows = [], []
    for suite, es in gatelist.by_suite(entries).items():
        n_pass = 0
        for e in es:
            t = report.get(f"test_gc_{a.core}_{e.ident}")
            ok = t is not None and t.get("status") == "pass"
            n_pass += ok
            if not ok:
                why = "not run" if t is None else t.get("status")
                m = MISMATCH.search(json.dumps(t)) if t else None
                bad.append(f"FAIL {e.key}: {why}" + (f": {m.group(0)}" if m else ""))
        rows.append((suite, len(es), n_pass))
    w = max(len(r[0]) for r in rows)
    for suite, n, n_pass in rows:
        print(f"{suite.ljust(w)}  pass {n_pass:>3}/{n}")
    tot = [sum(r[i] for r in rows) for i in (1, 2)]
    print(f"{'total'.ljust(w)}  pass {tot[1]:>3}/{tot[0]}")
    for b in bad:
        print(b)
    return 0 if tot[0] == tot[1] else 1


if __name__ == "__main__":
    sys.exit(main())
