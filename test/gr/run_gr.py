#!/usr/bin/env python3
"""Run random instruction streams (test/gr/gen.py) under the spike cosim.

    test/gr/run_gr.py [--core w2|w4] [--priv | --hyp] [--vec] [--seeds 1-50] [--length 3000]
                      [--long 1001-1003] [--long-length 30000]
                      [--batch N] [--log-dir DIR] [--keep] [--no-run]

Generates and assembles one program per seed into test/gr/build/, writes the
`#[ignore]` wrappers tb/test_gc_<core>_gr.veryl (gen_core_tests.py --cosim
form, test_gc_<core>_gr_s<seed>), runs `veryl test --ignored --test
test_gc_<core>_gr_ --format json` ($VERYL, else
veryl/target/release-verylup/veryl) and requires every program to pass: the
DUT writes tohost = 1 and the cosim reports no mismatch. Needs spike
(SPIKE_HOME) for the spike_cosim component. The wrappers are deleted
afterwards unless --keep. --priv runs the privileged stream (gen.py --priv)
as test_gc_<core>_grp_s<seed>, by default seeds 1-300 and 1001-1005. --vec
mixes in the vector stream (gen.py --vec) as test_gc_<core>_grv[p]_s<seed>,
by default seeds 1-500 and 1001-1005. --hyp runs the H stream (gen.py
--hyp, combinable with --vec) as test_gc_<core>_gr[v]h_s<seed>, by default
seeds 1-400 and 1001-1005.

Prints the mnemonics the programs contain (static counts from objdump, summed
over the seeds) and the ones of gen.MNEMONICS no program contains; with a
report, the records compared and the sim time per seed, and the cosim's
coverage summed over the seeds: traps by source mode, handler level and
cause, interrupts, and mode changes (with --hyp also the H causes and mode
changes no program reached).

Exit code 0 only if every program passes.
"""

import argparse
import collections
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MASTER = HERE.parents[1]
sys.path.insert(0, str(MASTER / "test" / "gates"))
sys.path.insert(0, str(HERE))
import gatelist  # noqa: E402
import gen  # noqa: E402
import gen_core_tests  # noqa: E402

CYCLES_PER_INSN = 40
PRIV_CYCLES_PER_INSN = 80
VEC_CYCLES_PER_INSN = 400


def seed_list(spec):
    out = []
    for part in filter(None, spec.split(",")):
        lo, _, hi = part.partition("-")
        out += range(int(lo), int(hi or lo) + 1)
    return out


def mnemonics(elf):
    p = subprocess.run([gen.tool("objdump"), "-d", "-M", "no-aliases", str(elf)], text=True, capture_output=True,
                       check=True)
    c = collections.Counter()
    for line in p.stdout.splitlines():
        f = line.split("\t")
        if len(f) >= 3 and f[0].strip().endswith(":"):
            m = re.sub(r"\.(aqrl|aq|rl)$", "", f[2].strip().split()[0])
            m = re.sub(r"^(c\.mop|mop\.rr?)\.\d+$", r"\1.N", m)
            c[m] += 1
    return c


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--core", default="w2", choices=sorted(gen_core_tests.CORE_CONST))
    ap.add_argument("--priv", action="store_true", help="the privileged stream (gen.py --priv)")
    ap.add_argument("--vec", action="store_true", help="mix in the vector stream (gen.py --vec)")
    ap.add_argument("--hyp", action="store_true", help="the H stream (gen.py --hyp)")
    ap.add_argument("--seeds", default=None, help="short seeds (default 1-50, with --priv 1-300)")
    ap.add_argument("--length", type=int, default=3000)
    ap.add_argument("--long", default=None, help="seeds run at --long-length ('' for none; default 1001-1003, "
                                                 "with --priv 1001-1005)")
    ap.add_argument("--long-length", type=int, default=30000)
    ap.add_argument("--batch", type=int, default=100, help="programs per veryl run (default 100)")
    ap.add_argument("--log-dir", type=Path, default=MASTER / ".build" / "run_gr")
    ap.add_argument("--keep", action="store_true", help="keep the generated wrappers (renamed per batch)")
    ap.add_argument("--no-run", action="store_true", help="generate, build and count only")
    a = ap.parse_args()
    if a.seeds is None:
        a.seeds = "1-400" if a.hyp else "1-500" if a.vec else "1-300" if a.priv else "1-50"
    if a.long is None:
        a.long = "1001-1005" if a.priv or a.vec or a.hyp else "1001-1003"
    suite = gen.stem_of(0, a.priv, a.vec, a.hyp)[:-2]
    cpi = VEC_CYCLES_PER_INSN if a.vec else PRIV_CYCLES_PER_INSN if a.priv or a.hyp else CYCLES_PER_INSN

    progs = [(s, a.length) for s in seed_list(a.seeds)] + [(s, a.long_length) for s in seed_list(a.long)]
    if len({s for s, _ in progs}) != len(progs):
        print("run_gr: a seed is listed twice", file=sys.stderr)
        return 2
    out = HERE / "build"
    entries, cover = [], collections.Counter()
    for seed, length in progs:
        hexp, dyn = gen.generate(seed, length, out, priv=a.priv, vec=a.vec, hyp=a.hyp)
        cover += mnemonics(hexp.with_suffix(".elf"))
        budget = -(-max(dyn * cpi, 100_000) // gatelist.EARLY_EXIT_STEP) * gatelist.EARLY_EXIT_STEP
        entries.append(gatelist.Entry(suite=suite, name=f"s{seed}", budget=budget,
                                      hex=str(hexp.relative_to(MASTER)), tohost=gatelist.DEFAULT_TOHOST,
                                      lockstep=False))
    print(f"run_gr: {len(entries)} programs, {sum(cover.values())} instructions, {len(cover)} mnemonics")
    print(" ".join(f"{m}:{n}" for m, n in sorted(cover.items())))
    want = list(gen.MNEMONICS)
    if a.priv or a.hyp:
        import priv
        want += [m for m in priv.PRIV_MNEMONICS if m not in want]
    if a.hyp:
        import hyp
        want += [m for m in hyp.HYP_MNEMONICS if m not in want]
    if a.vec:
        import vec
        want += vec.VEC_MNEMONICS
    missing = [m for m in want if m not in cover]
    if missing:
        print(f"never generated: {' '.join(missing)}")
    if a.no_run:
        return 0

    tb = MASTER / "tb"
    path = tb / f"test_gc_{a.core}_{suite}.veryl"
    veryl = os.environ.get("VERYL") or str(MASTER / "veryl" / "target" / "release-verylup" / "veryl")
    cmd = [veryl, "test", "--ignored", "--test", f"test_gc_{a.core}_{suite}_", "--format", "json"]
    a.log_dir.mkdir(parents=True, exist_ok=True)
    tests = []
    for n in range(0, len(entries), a.batch):
        batch = entries[n:n + a.batch]
        path.write_text(gen_core_tests.HEADER.format(src="test/gr/run_gr.py")
                        + "".join(gen_core_tests.gen_cosim_module(e, a.core) for e in batch))
        b = n // a.batch
        print(f"run_gr: batch {b}: {' '.join(cmd)} ({len(batch)} programs)", file=sys.stderr, flush=True)
        try:
            p = subprocess.run(cmd, cwd=MASTER, text=True, capture_output=True)
        finally:
            if a.keep:
                path.rename(path.with_suffix(f".veryl.b{b}"))
            else:
                path.unlink(missing_ok=True)
        (a.log_dir / f"{a.core}.{b}.json").write_text(p.stdout)
        (a.log_dir / f"{a.core}.{b}.err").write_text(p.stderr)
        try:
            rep = json.loads(p.stdout)
        except json.JSONDecodeError:
            print(f"run_gr: veryl exited {p.returncode} without a JSON report, see {a.log_dir}/{a.core}.{b}.err",
                  file=sys.stderr)
            return 2
        tests += rep.get("tests", [])
        fell = sum(d.get("fell_back", 0) for d in rep.get("dispatch", []))
        if fell:
            print(f"run_gr: batch {b}: fell_back {fell}", file=sys.stderr)
    return judge(a, entries, tests)


MISMATCH = re.compile(r"spike mismatch[^\n]*")
RECORDS = re.compile(r"spike cosim: (\d+) records")
COVERAGE = re.compile(r"spike cosim coverage: ([^\n]*)")


def judge(a, entries, tests):
    report = {t["name"]: t for t in tests}
    bad, n_pass, recs, sim = [], 0, 0, 0.0
    cov = collections.Counter()
    for e in entries:
        t = report.get(f"test_gc_{a.core}_{e.ident}")
        ok = t is not None and t.get("status") == "pass"
        n_pass += ok
        out = (t or {}).get("output", "")
        m = RECORDS.search(out)
        r = int(m.group(1)) if m else 0
        recs += r
        m = COVERAGE.search(out)
        for kv in (m.group(1).split(", ") if m and m.group(1) else []):
            k, _, n = kv.rpartition("=")
            cov[k] += int(n)
        sim += (t or {}).get("sim_s", 0.0)
        print(f"{e.name}: {'pass' if ok else 'FAIL'} records {r} sim {(t or {}).get('sim_s', 0.0):.1f}s")
        if not ok:
            why = "not run" if t is None else t.get("status")
            mm = MISMATCH.search((t or {}).get("message", "") + out)
            bad.append(f"FAIL {e.name}: {why}" + (f": {mm.group(0)}" if mm else ""))
    print("coverage: " + ", ".join(f"{k}={n}" for k, n in sorted(cov.items())))
    if a.hyp:
        import hyp
        causes = {int(k.rpartition(":")[2]) for k in cov if k.startswith("trap ")}
        lost = [str(c) for c in hyp.HYP_CAUSES if c not in causes]
        lost += [m for m in hyp.HYP_MODES if f"mode {m}" not in cov]
        if lost:
            print(f"never reached: {' '.join(lost)}")
    print(f"total pass {n_pass}/{len(entries)}, {recs} records, sim {sim:.0f}s")
    for b in bad:
        print(b)
    return 0 if n_pass == len(entries) else 1


if __name__ == "__main__":
    sys.exit(main())
