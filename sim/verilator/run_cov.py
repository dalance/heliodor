#!/usr/bin/env python3
"""Structural coverage (GCV) of the W2 core on Verilator: line and toggle.

    sim/verilator/run_cov.py build {arch,boot} [--sv-root DIR]
    sim/verilator/run_cov.py arch [--list L ...] [--jobs N] [--every K]
    sim/verilator/run_cov.py boot
    sim/verilator/run_cov.py report [--min-line P] [--min-toggle P]

Run from a tree where `veryl build` has emitted heliodor.f (--sv-root, default
the project root). `build` compiles tb_cov_arch_w2.sv (arch harness, one
binary for every image) or tb_soc_linux_boot_w2.sv (N=1 5.15 boot) with
--coverage-line --coverage-toggle into sim/verilator/build_cov_<top>/.

`arch` runs every single-hart entry of the gate lists (default: the arch and
directed lists run_gc.py runs, then test/gates/mi_act.list, every K-th entry of
each ACT suite with --every) in --jobs parallel work directories, each run writing
its own coverage file; tohost != 1024, interrupt, mtime and dmi entries are
skipped. `boot` runs the boot from the project root. Both log pass/fail per
run under .build/cov_rtl/.

Each arch run's coverage file is folded into .build/cov_rtl/arch.dat and
deleted (one file is over 100 MB). `report` merges arch.dat and boot.dat and
writes line and toggle summaries per source module (summary.txt,
modules.json): a point counts as covered if any instance or
specialization covered it, and only design sources count (not tb/, src/v14/ or Verilator's
library),
and modules under the thresholds are listed.
"""

import argparse
import collections
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

MASTER = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(MASTER / "test" / "gates"))
import gatelist  # noqa: E402
import run_gc  # noqa: E402

HERE = MASTER / "sim" / "verilator"
OUT = MASTER / ".build" / "cov_rtl"
TOPS = {"arch": "tb_cov_arch_w2", "boot": "tb_soc_linux_boot_w2"}


def build(a):
    root = (a.sv_root or MASTER).resolve()
    top = TOPS[a.top]
    mdir = HERE / f"build_cov_{a.top}"
    shutil.rmtree(mdir, ignore_errors=True)
    cmd = ["verilator", "--binary", "--top-module", top, "-f", "heliodor.f", str(HERE / f"{top}.sv"),
           "--timing", "-Wno-fatal", "-O1", "-j", str(a.jobs), "--coverage-line", "--coverage-toggle",
           "--Mdir", str(mdir), "-o", top]
    print(" ".join(cmd), file=sys.stderr, flush=True)
    return subprocess.run(cmd, cwd=root).returncode


def arch_entries(a):
    lists = a.list or ([MASTER / "test" / "gates" / f"{n}.list" for n in run_gc.DEFAULT_LISTS]
                       + [MASTER / "test" / "gates" / "mi_act.list"])
    out, seen = [], set()
    for path in lists:
        es = [e for e in gatelist.parse(path) if e.harts == 1 and not e.dmi and not e.irq and e.mtime == "off"
              and e.tohost == gatelist.DEFAULT_TOHOST and e.key not in seen]
        if path.name == "mi_act.list" and a.every > 1:
            es = [x for suite in gatelist.by_suite(es).values() for x in suite[::a.every]]
        for e in es:
            seen.add(e.key)
            out.append(e)
    return out


def run_one(exe, e, wdir):
    wdir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(MASTER / e.hex, wdir / "cur.hex")
    dat = wdir / "cov.dat"
    t0 = time.time()
    p = subprocess.run([str(exe), f"+budget={e.budget}", f"+verilator+coverage+file+{dat}"], cwd=wdir,
                       text=True, capture_output=True)
    m = re.search(r"COVRESULT pass=(\d) fail=(\d) tohost=(\w+) cy=(\d+)", p.stdout)
    ok = bool(m) and m[1] == "1"
    return e.key, ok, int(m[4]) if m else 0, time.time() - t0, dat


def arch(a):
    exe = HERE / "build_cov_arch" / TOPS["arch"]
    entries = arch_entries(a)
    OUT.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    res = []
    acc = collections.Counter()
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
        futs = [ex.submit(run_one, exe, e, OUT / "work" / f"r{i}") for i, e in enumerate(entries)]
        for f in concurrent.futures.as_completed(futs):
            k, ok, cy, s, dat = f.result()
            res.append((k, ok, cy, s))
            if dat.exists():
                for key, n in read_counts(dat):
                    acc[key] += n
                shutil.rmtree(dat.parent, ignore_errors=True)
            print(f"{k}: {'pass' if ok else 'FAIL'} cy {cy} {s:.1f}s", flush=True)
    write_counts(OUT / "arch.dat", acc)
    shutil.rmtree(OUT / "work", ignore_errors=True)
    n_ok = sum(r[1] for r in res)
    summary = {"runs": len(res), "pass": n_ok, "cycles": sum(r[2] for r in res), "wall_s": round(time.time() - t0),
               "fail": sorted(r[0] for r in res if not r[1])}
    (OUT / "arch.json").write_text(json.dumps(summary, indent=1) + "\n")
    print(f"arch: {n_ok}/{len(res)} pass, {summary['cycles']} cycles, {summary['wall_s']} s")
    return 0


def boot(a):
    exe = HERE / "build_cov_boot" / TOPS["boot"]
    OUT.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    p = subprocess.run([str(exe), f"+verilator+coverage+file+{OUT / 'boot.dat'}"], cwd=MASTER,
                       text=True, capture_output=True)
    (OUT / "boot.log").write_text(p.stdout + p.stderr)
    m = re.search(r"pass=(\d) r3=\w+ cy=(\d+) instret=(\d+)", p.stdout)
    summary = {"pass": bool(m) and m[1] == "1", "cycles": int(m[2]) if m else 0,
               "instret": int(m[3]) if m else 0, "wall_s": round(time.time() - t0)}
    (OUT / "boot.json").write_text(json.dumps(summary, indent=1) + "\n")
    print(f"boot: {summary}")
    return 0 if summary["pass"] else 1


def read_counts(path):
    with open(path, encoding="latin-1") as f:
        for line in f:
            if line.startswith("C '"):
                body, _, cnt = line.rstrip("\n").rpartition("' ")
                yield body[3:], int(cnt)


def write_counts(path, acc):
    with open(path, "w", encoding="latin-1") as f:
        f.write("# SystemC::Coverage-3\n")
        for body, n in acc.items():
            f.write(f"C '{body}' {n}\n")


def parse_dat(paths):
    """(module, kind, file, line, comment, column) -> covered, over every
    instance and file."""
    pts = {}
    for path in paths:
        for body, cnt in read_counts(path):
            kv = dict(x.split("\x02", 1) for x in body.split("\x01") if "\x02" in x)
            # By source file: the arch and boot tops specialize a module
            # under different names.
            kind = kv.get("page", "").partition("/")[0]
            mod = Path(kv.get("f", "")).stem
            key = (mod, kind.replace("v_", ""), kv.get("f", ""), kv.get("l", ""), kv.get("o", ""), kv.get("n", ""))
            pts[key] = pts.get(key, False) or cnt > 0
    return pts


def keep(path):
    """Design sources only: not the testbenches (harnesses, RVFI, perf
    counters), the V14 core or Verilator's own library."""
    return "/src/" in path and "/src/v14/" not in path


def report(a):
    srcs = [s for s in ("arch", "boot") if (OUT / f"{s}.dat").exists()]
    if not srcs:
        raise SystemExit(f"run_cov: no coverage files under {OUT}")
    per_src = {s: parse_dat([OUT / f"{s}.dat"]) for s in srcs}
    pts = {}
    for sp in per_src.values():
        for k, v in sp.items():
            pts[k] = pts.get(k, False) or v
    mods = collections.defaultdict(lambda: collections.Counter())
    for (mod, kind, path, *_), cov in pts.items():
        if not mod or not keep(path):
            continue
        mods[mod][kind] += 1
        mods[mod][kind + "_hit"] += cov
    for src, sp in per_src.items():
        for (mod, kind, *_), cov in sp.items():
            if mod in mods:
                mods[mod][f"{src}_{kind}_hit"] += cov
    rows = {}
    for mod, c in sorted(mods.items()):
        rows[mod] = {k: c[k] for k in sorted(c)}
    tot = collections.Counter()
    for c in mods.values():
        tot.update(c)
    lines = ["GCV structural coverage (Verilator line + toggle, W2)", ""]
    for name in ("arch.json", "boot.json"):
        if (OUT / name).exists():
            lines.append(f"{name[:-5]}: {(OUT / name).read_text().strip()}")
    lines.append("")
    for kind in ("line", "toggle"):
        lines.append(f"total {kind}: {tot[kind + '_hit']}/{tot[kind]} ({100.0 * tot[kind + '_hit'] / max(tot[kind], 1):.1f} %)")
    lines += ["", f"{'module':40} {'line':>16} {'toggle':>18}"]
    low = []
    for mod, c in sorted(mods.items(), key=lambda kv: -kv[1]["line"] - kv[1]["toggle"]):
        lp = 100.0 * c["line_hit"] / c["line"] if c["line"] else 100.0
        tp = 100.0 * c["toggle_hit"] / c["toggle"] if c["toggle"] else 100.0
        lines.append(f"{mod:40} {c['line_hit']:>6}/{c['line']:<6} {lp:5.1f}% {c['toggle_hit']:>7}/{c['toggle']:<7} {tp:5.1f}%")
        if lp < a.min_line or tp < a.min_toggle:
            low.append(mod)
    lines += ["", f"under line {a.min_line} % or toggle {a.min_toggle} %: {' '.join(low)}"]
    (OUT / "modules.json").write_text(json.dumps(rows, indent=1) + "\n")
    (OUT / "summary.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("top", choices=sorted(TOPS))
    b.add_argument("--sv-root", type=Path)
    b.add_argument("--jobs", type=int, default=4)
    r = sub.add_parser("arch")
    r.add_argument("--list", type=Path, action="append")
    r.add_argument("--jobs", type=int, default=4)
    r.add_argument("--every", type=int, default=1, help="run every K-th mi_act.list entry")
    sub.add_parser("boot")
    p = sub.add_parser("report")
    p.add_argument("--min-line", type=float, default=80.0)
    p.add_argument("--min-toggle", type=float, default=50.0)
    a = ap.parse_args()
    return {"build": build, "arch": arch, "boot": boot, "report": report}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
