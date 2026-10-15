#!/usr/bin/env python3
"""Run the ACT4 suites on a new core: GA (pass/fail) and GL-C (final hash).

    test/gates/run_act.py --core w2 [--list test/gates/m2_act.list]
                          [--suite d,zaamo,...] [--pass-fail] [--log-dir DIR] [--keep]
                          [--from-json REPORT]

The images are gitignored: build them with `make -C test/act` (see
test/act/README.md); they land in test/hex/act_<ext>_<name>.hex.

Steps: write tb/test_<core>_act_<ext>.veryl with gen_core_tests.py (pass/fail
wrappers, `#[ignore]`), run `veryl test --ignored --test test_<core>_act_
--format json` once ($VERYL, else veryl/target/release-verylup/veryl), then
judge every test: GA needs the test to pass (tohost == 1, checkers clean);
GL-C needs its final `H <count> <hash>` line to equal the row of
test/golden/act/<ext>.final (the same comparison as test/golden/check_hash.py).
Entries with lockstep=0 are judged by GA only. The wrappers are deleted
afterwards unless --keep, so the default `veryl test` does not compile them.
--from-json judges a saved report (<log-dir>/<core>.json) without running.

Exit code 0 only if every test passes and, without --pass-fail, every
compared hash matches.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

MASTER = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(MASTER / "test" / "gates"))
sys.path.insert(0, str(MASTER / "test" / "golden"))
import check_hash  # noqa: E402
import gatelist  # noqa: E402
import gen_core_tests  # noqa: E402

ACT_SUITE = "act_"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--core", required=True, choices=sorted(gen_core_tests.CORE_CONST))
    ap.add_argument("--list", type=Path, default=MASTER / "test" / "gates" / "m2_act.list")
    ap.add_argument("--suite", default="", help="comma-separated extensions (default: all)")
    ap.add_argument("--pass-fail", action="store_true", help="GA only, do not fail on a hash mismatch")
    ap.add_argument("--log-dir", type=Path, default=MASTER / ".build" / "run_act")
    ap.add_argument("--keep", action="store_true", help="keep the generated wrappers")
    ap.add_argument("--from-json", type=Path, help="judge this saved report instead of running")
    a = ap.parse_args()

    want = {ACT_SUITE + s for s in a.suite.split(",") if s}
    entries = [e for e in gatelist.parse(a.list) if not want or e.suite in want]
    if not entries:
        print("run_act: no tests selected", file=sys.stderr)
        return 2
    if a.from_json:
        return judge(a, entries, json.loads(a.from_json.read_text()))
    missing = [e.hex for e in entries if not (MASTER / e.hex).is_file()]
    if missing:
        print(f"run_act: {len(missing)} images missing (build them with `make -C test/act`), e.g. {missing[0]}",
              file=sys.stderr)
        return 2

    tb = MASTER / "tb"
    for old in tb.glob(f"test_{a.core}_{ACT_SUITE}*.veryl"):
        old.unlink()
    gen = []
    for suite, es in gatelist.by_suite(entries).items():
        path = tb / f"test_{a.core}_{suite}.veryl"
        src = a.list.resolve().relative_to(MASTER) if a.list.resolve().is_relative_to(MASTER) else a.list
        path.write_text(gen_core_tests.HEADER.format(src=src)
                        + "".join(gen_core_tests.gen_module(e, a.core, False, True) for e in es))
        gen.append(path)

    veryl = os.environ.get("VERYL") or str(MASTER / "veryl" / "target" / "release-verylup" / "veryl")
    cmd = [veryl, "test", "--ignored", "--test", f"test_{a.core}_{ACT_SUITE}", "--format", "json"]
    a.log_dir.mkdir(parents=True, exist_ok=True)
    log = a.log_dir / f"{a.core}.json"
    print(f"run_act: {' '.join(cmd)} ({len(entries)} tests)", file=sys.stderr, flush=True)
    try:
        p = subprocess.run(cmd, cwd=MASTER, text=True, capture_output=True)
    finally:
        if not a.keep:
            for path in gen:
                path.unlink(missing_ok=True)
    log.write_text(p.stdout)
    (a.log_dir / f"{a.core}.err").write_text(p.stderr)
    try:
        rep = json.loads(p.stdout)
    except json.JSONDecodeError:
        print(f"run_act: veryl exited {p.returncode} without a JSON report, see {a.log_dir}/{a.core}.err",
              file=sys.stderr)
        return 2
    return judge(a, entries, rep)


def judge(a, entries, rep):
    report = {t["name"]: t for t in rep.get("tests", [])}
    finals = {}
    bad = []
    rows = []
    for suite, es in gatelist.by_suite(entries).items():
        ext = suite[len(ACT_SUITE):]
        fpath = MASTER / "test" / "golden" / "act" / f"{ext}.final"
        gold = finals.setdefault(ext, check_hash.load_golden(fpath) if fpath.is_file() else {})
        n_pass = n_cmp = n_match = 0
        for e in es:
            t = report.get(f"test_{a.core}_{e.ident}")
            ok = t is not None and t.get("status") == "pass"
            n_pass += ok
            if not ok:
                bad.append(f"FAIL     {e.key}: {'not run' if t is None else t.get('status')}")
            if not e.lockstep:
                continue
            exp = gold.get(f"test_{e.ident}")
            got = check_hash.final_h(t.get("output", "")) if t else None
            n_cmp += 1
            if exp is None:
                bad.append(f"NOGOLD   {e.key}: no row in {fpath.relative_to(MASTER)}")
            elif got is None:
                bad.append(f"NO_H     {e.key}: no H line")
            elif got != exp:
                bad.append(f"MISMATCH {e.key}: H {got[0]} {got[1]:016x}, golden H {exp[0]} {exp[1]:016x}")
            else:
                n_match += 1
        rows.append((ext, len(es), n_pass, n_cmp, n_match))

    w = max(len(r[0]) for r in rows)
    for ext, n, n_pass, n_cmp, n_match in rows:
        print(f"{ext.ljust(w)}  pass {n_pass:>3}/{n:<3}  hash {n_match:>3}/{n_cmp}")
    tot = [sum(r[i] for r in rows) for i in range(1, 5)]
    print(f"{'total'.ljust(w)}  pass {tot[1]:>3}/{tot[0]:<3}  hash {tot[3]:>3}/{tot[2]}")
    for b in bad:
        print(b)
    fails = tot[1] != tot[0]
    mism = tot[3] != tot[2]
    return 1 if fails or (mism and not a.pass_fail) else 0


if __name__ == "__main__":
    sys.exit(main())
