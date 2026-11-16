#!/usr/bin/env python3
"""Run the official RISC-V litmus tests (litmus-tests-riscv) on heliodor.

    test/glt/run_glt.py herd [--jobs 16]
    test/glt/run_glt.py list [--set default|full]
    test/glt/run_glt.py run --core w2|w4 --harts 2|4 [--set default|full] [--iters N]
                            [--chunk N] [--seed N] [--log-dir DIR] [--keep] [--no-run]

`herd` runs the pinned herd7 (toolchain/herd, `toolchain/fetch.sh glt`) with
riscv.cat on every test of the pinned suite (test/glt/upstream) and keeps
its output under test/glt/build/herd; mixed-size tests run with
`-variant mixed`. `list` prints the selection: tests run per family and the
excluded ones with the reason. `run` converts the selected tests that need
at most --harts threads (1-2 threads for --harts 2, 3-4 threads for
--harts 4) into programs of --chunk tests (conv.py), writes the `#[ignore]`
wrappers tb/test_<core>_glt<harts>.veryl (test_<core>_glt<harts>_c<i>),
runs them in one `veryl test --ignored --format json` ($VERYL, else
veryl/target/release-verylup/veryl) and compares every observed final state
with the states herd7 allows. An observed state the model forbids fails the
run; allowed states never observed are only counted. The wrappers are
deleted afterwards unless --keep.

The default set is the hand-written and small families in full plus every
SAMPLE-th test of the large generated families; the full set is every
selected test. Exit code 0 only if every program finishes and no forbidden
state is observed.
"""

import argparse
import collections
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
MASTER = HERE.parents[1]
sys.path.insert(0, str(MASTER / "test" / "gates"))
sys.path.insert(0, str(HERE))
import conv  # noqa: E402
import gatelist  # noqa: E402
import gen_core_tests  # noqa: E402
import litmus  # noqa: E402

SUITE = HERE / "upstream" / "litmus-tests-riscv"
TESTS = SUITE / "tests"
HERD_OUT = HERE / "build" / "herd"
LARGE = {"RELAX", "SAFE", "ATOMICS", "SF_THESIS"}
SAMPLE = 16
ITERS = {("default", 2): 100, ("default", 4): 100, ("full", 2): 100, ("full", 4): 50}
CYCLES_PER_ITER = {2: 600, 4: 800}
compared = 0


def herd_tool():
    for root in [MASTER, *_main_checkout()]:
        p = root / "toolchain" / "herd"
        if (p / "bin" / "herd7").exists():
            return p
    sys.exit("run_glt: herd7 not found, run toolchain/fetch.sh glt")


def _main_checkout():
    try:
        common = subprocess.run(["git", "-C", str(MASTER), "rev-parse", "--git-common-dir"], text=True,
                                capture_output=True, check=True).stdout.strip()
        return [(MASTER / common).resolve().parent]
    except (OSError, subprocess.CalledProcessError):
        return []


def all_tests():
    return sorted(str(p.relative_to(TESTS)) for p in TESTS.rglob("*.litmus") if p.parts[len(TESTS.parts)] != "to-AArch64")


def cmd_herd(a):
    h = herd_tool()
    rels = all_tests()

    def one(rel):
        out = HERD_OUT / (rel + ".log")
        out.parent.mkdir(parents=True, exist_ok=True)
        cmd = [str(h / "bin" / "herd7"), "-set-libdir", str(h / "share" / "herdtools7" / "herd"), "-model",
               "riscv.cat"]
        if rel.startswith("mixed-size/"):
            cmd += ["-variant", "mixed"]
        p = subprocess.run(cmd + [rel], cwd=TESTS, text=True, capture_output=True, timeout=1200)
        out.write_text(p.stdout + p.stderr)

    t0 = time.time()
    with ThreadPoolExecutor(a.jobs) as ex:
        list(ex.map(one, rels))
    print(f"run_glt: herd7 on {len(rels)} tests in {time.time() - t0:.0f}s")
    return 0


def family(rel):
    parts = rel.split("/")
    return parts[1] if parts[0] == "non-mixed-size" else "mixed-size/" + parts[1]


def select():
    """-> (selected [(rel, Test, HerdResult, plan)], excluded {rel: reason}, shipped-log disagreements)"""
    shipped = {r.hash: r for r in litmus.parse_herd((SUITE / "model-results" / "herd.logs").read_text()).values()}
    global compared
    sel, exc, seen, disagree = [], {}, {}, []
    for rel in all_tests():
        text = (TESTS / rel).read_text()
        try:
            t = litmus.parse(rel, text)
        except (ValueError, KeyError) as e:
            exc[rel] = "array location (misaligned mixed-size)" if re.search(r"\w\[\d+\]", str(e)) else f"parse: {e}"
            continue
        canon = hashlib.sha1(repr((t.threads, t.reg_init, sorted(t.locs.items()), t.cond)).encode()).hexdigest()
        if canon in seen:
            exc[rel] = f"duplicate of {seen[canon]}"
            continue
        seen[canon] = rel
        if any(re.search(r"\b(lb|lh|lw|ld|sb|sh|sw|sd)\.(aq|rl)\b", ln) for th in t.threads for ln in th):
            exc[rel] = "Zalasr (load-acquire/store-release) not implemented"
            continue
        if rel.startswith("mixed-size/") and (
                any(sz == 8 for sz, _, _ in t.locs.values())
                or any(re.search(r"\b(ld|sd|lr\.d|sc\.d|amo\w+\.d)\b", ln) for th in t.threads for ln in th)):
            exc[rel] = "64-bit mixed-size (herd7 -variant mixed keeps 32-bit values)"
            continue
        if t.has_filter:
            exc[rel] = "filter clause (herd prints only the filtered states)"
            continue
        log = HERD_OUT / (rel + ".log")
        if not log.exists():
            exc[rel] = "no herd7 output (run_glt.py herd)"
            continue
        out = log.read_text()
        if "unrolling limit exceeded" in out:
            exc[rel] = "herd7 unrolling limit, allowed set may be incomplete"
            continue
        res = litmus.parse_herd(out).get(t.name)
        if res is None:
            w = re.search(r"Warning: [^:]*: (.*)", out) or re.search(r'line \d+[^:]*: (.*)', out)
            exc[rel] = "herd7: " + (w.group(1).strip() if w else "no result")
            continue
        if not res.states:
            exc[rel] = "herd7: no final state"
            continue
        if not res.vars:
            exc[rel] = "nothing observed"
            continue
        try:
            pl = conv.plan(t, res)
        except conv.Unsupported as e:
            exc[rel] = f"converter: {e}"
            continue
        s = shipped.get(res.hash)
        compared += s is not None
        if s and not rel.startswith("mixed-size/") and (
                s.vars != [v if ":" in v else v.strip("[]") for v in res.vars] or set(s.states) != set(res.states)):
            disagree.append(rel)
        sel.append((rel, t, res, pl))
    return sel, exc, disagree


def in_set(rel, which):
    if which == "full" or family(rel) not in LARGE:
        return True
    return int(hashlib.sha1(rel.encode()).hexdigest(), 16) % SAMPLE == 0


def cmd_list(a):
    sel, exc, disagree = select()
    fam = collections.Counter()
    for rel, t, _, _ in sel:
        if in_set(rel, a.set):
            fam[(family(rel), 2 if t.n_threads <= 2 else 4)] += 1
    print(f"selected ({a.set}):")
    for (f, n), c in sorted(fam.items()):
        print(f"  {f:28s} N={n} {c}")
    print(f"  total N=2 {sum(c for (f, n), c in fam.items() if n == 2)}, "
          f"N=4 {sum(c for (f, n), c in fam.items() if n == 4)}")
    why = collections.Counter(re.sub(r"duplicate of .*", "duplicate", r) for r in exc.values())
    print("excluded:")
    for r, c in why.most_common():
        print(f"  {c:5d} {r}")
    if a.verbose:
        for rel, r in sorted(exc.items()):
            if not r.startswith("duplicate"):
                print(f"  {rel}: {r}")
    print(f"herd7 results compared with the suite's model-results/herd.logs: {compared}, differing: {len(disagree)}")
    for rel in disagree:
        print(f"  {rel}")
    return 0


def tool(name):
    import importlib.util
    spec = importlib.util.spec_from_file_location("gr_gen", MASTER / "test" / "gr" / "gen.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m.tool(name)


def build_chunk(tests, nh, iters, seed, jmask, skew, out, stem):
    """Build one program; tests the assembler rejects are dropped and returned."""
    dropped = []
    while True:
        try:
            return conv.build(tests, nh, iters, seed, jmask, skew, out, stem, tool), dropped
        except subprocess.CalledProcessError as e:
            bad = None
            for k, item in enumerate(tests):
                try:
                    conv.build([item], nh, 1, seed, jmask, skew, out, stem + "_probe", tool)
                except subprocess.CalledProcessError:
                    bad = k
                    break
            if bad is None:
                raise RuntimeError(e.stderr) from e
            dropped.append(tests.pop(bad))


def cmd_run(a):
    sel, exc, _ = select()
    iters = a.iters or ITERS[(a.set, a.harts)]
    lo = 1 if a.harts == 2 else 3
    todo = [(rel, t, res, pl) for rel, t, res, pl in sel if in_set(rel, a.set) and lo <= t.n_threads <= a.harts]
    if a.only:
        todo = [x for x in todo if re.search(a.only, x[0])]
    print(f"run_glt: {len(todo)} tests on {a.core} N={a.harts}, {iters} iterations", file=sys.stderr)
    out = HERE / "build" / f"{a.core}_n{a.harts}"
    progs, asm_fail = [], []
    for c in range(0, len(todo), a.chunk):
        part = todo[c:c + a.chunk]
        items = [(t, pl) for _, t, _, pl in part]
        hexp, dropped = build_chunk(items, a.harts, iters, a.seed + c, a.jitter, a.skew, out, f"c{c // a.chunk}")
        keep = [x for x in part if (x[1], x[3]) in items]
        asm_fail += [x[0] for x in part if (x[1], x[3]) not in items]
        budget = len(keep) * iters * CYCLES_PER_ITER[a.harts] * 4 + 2_000_000
        budget = -(-budget // gatelist.EARLY_EXIT_STEP) * gatelist.EARLY_EXIT_STEP
        e = gatelist.Entry(suite=f"glt{a.harts}", name=f"c{c // a.chunk}", budget=budget,
                           hex=str(hexp.relative_to(MASTER)), tohost=gatelist.DEFAULT_TOHOST, lockstep=False,
                           harts=a.harts)
        progs.append((e, keep))
    for rel in asm_fail:
        print(f"run_glt: {rel}: the assembler rejects it, dropped", file=sys.stderr)
    if a.no_run:
        return 0
    path = MASTER / "tb" / f"test_{a.core}_glt{a.harts}.veryl"
    veryl = os.environ.get("VERYL") or str(MASTER / "veryl" / "target" / "release-verylup" / "veryl")
    cmd = [veryl, "test", "--ignored", "--test", f"test_{a.core}_glt{a.harts}_", "--format", "json"]
    a.log_dir.mkdir(parents=True, exist_ok=True)
    path.write_text(gen_core_tests.HEADER.format(src="test/glt/run_glt.py")
                    + "".join(gen_core_tests.gen_smp_module(e, a.core, True) for e, _ in progs))
    print(f"run_glt: {' '.join(cmd)} ({len(progs)} programs)", file=sys.stderr, flush=True)
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=MASTER, text=True, capture_output=True)
    finally:
        if not a.keep:
            path.unlink(missing_ok=True)
    wall = time.time() - t0
    stem = f"{a.core}_n{a.harts}_{a.set}"
    (a.log_dir / f"{stem}.json").write_text(p.stdout)
    (a.log_dir / f"{stem}.err").write_text(p.stderr)
    try:
        rep = json.loads(p.stdout)
    except json.JSONDecodeError:
        print(f"run_glt: veryl exited {p.returncode} without a JSON report, see {a.log_dir}/{stem}.err",
              file=sys.stderr)
        return 2
    fell = sum(d.get("fell_back", 0) for d in rep.get("dispatch", []))
    return judge(a, progs, {t["name"]: t for t in rep.get("tests", [])}, iters, wall, fell)


LINE = re.compile(r"^@([0-9a-f]+)((?: [0-9a-f]+)*)$", re.M)
TRAP = re.compile(r"^!([0-9a-f]+) ([0-9a-f]+) ([0-9a-f]+) ([0-9a-f]+)$", re.M)


def fmt_state(res, values):
    return " ".join(f"{v}={'?' if x is None else x[1] if isinstance(x, tuple) else x}"
                    for v, x in zip(res.vars, values))


def judge(a, progs, report, iters, wall, fell):
    fam = collections.defaultdict(lambda: collections.Counter())
    bad, forb_tests, unseen_states, unseen_tests, ran, sim, cycles = [], [], 0, 0, 0, 0.0, 0
    results = {}
    for e, keep in progs:
        t = report.get(f"test_{a.core}_{e.ident}")
        out = (t or {}).get("output", "")
        sim += (t or {}).get("sim_s", 0.0)
        m = re.search(r"cycles=\s*(\d+)", out)
        cycles += int(m.group(1)) if m else 0
        tables = {int(m.group(1), 16): [int(w, 16) for w in m.group(2).split()] for m in LINE.finditer(out)}
        for m in TRAP.finditer(out):
            bad.append(f"{e.name}: trap on hart {m.group(1)}: mcause {m.group(2)} mepc {m.group(3)} "
                       f"mtval {m.group(4)}")
        if t is None or (t.get("status") != "pass" and not tables):
            bad.append(f"{e.name}: {'not run' if t is None else t.get('status')}")
        for k, (rel, test, res, pl) in enumerate(keep):
            f = fam[family(rel)]
            w = tables.get(k)
            if w is None or len(w) != conv.table_words(pl):
                bad.append(f"{e.name}: {rel}: no result")
                f["missing"] += 1
                continue
            counts, forb, ovf, raw = conv.decode(pl, w)
            ran += 1
            f["tests"] += 1
            total = sum(counts) + sum(forb.values()) + ovf
            if total != iters:
                bad.append(f"{e.name}: {rel}: {total} outcomes for {iters} iterations")
            uns = sum(1 for c in counts if c == 0)
            f["states"] += len(counts)
            f["unseen_states"] += uns
            unseen_states += uns
            if uns:
                f["unseen_tests"] += 1
                unseen_tests += 1
            results[rel] = {"counts": counts, "forbidden": {str(k): c for k, c in forb.items()}, "overflow": ovf}
            if forb or ovf:
                f["forbidden"] += 1
                desc = "; ".join(f"[{fmt_state(res, conv.key_values(pl, key))}] x{c}" for key, c in forb.items())
                first = fmt_state(res, [(None, v) if isinstance(v, int) else v for v in raw])
                forb_tests.append(f"FORBIDDEN {rel} ({e.name} test {k}): {desc}"
                                  + (f" (+{ovf} more)" if ovf else "") + f"; first: {first}")
    print(f"{'family':28s} {'tests':>6s} {'forbidden':>9s} {'unseen states':>14s} {'tests w/ unseen':>16s}")
    for name, f in sorted(fam.items()):
        print(f"{name:28s} {f['tests']:6d} {f['forbidden']:9d} {f['unseen_states']:7d}/{f['states']:<6d} "
              f"{f['unseen_tests']:16d}")
    print(f"total: {ran} tests x {iters} iterations on {a.core} N={a.harts}, {len(forb_tests)} with a forbidden "
          f"state, {unseen_states} allowed states unseen in {unseen_tests} tests, {len(progs)} programs, "
          f"{cycles} cycles, sim {sim:.0f}s, wall {wall:.0f}s, fell_back {fell}")
    (a.log_dir / f"{a.core}_n{a.harts}_{a.set}.results.json").write_text(json.dumps(results, indent=0))
    for b in forb_tests + bad:
        print(b)
    return 0 if not forb_tests and not bad else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("herd")
    h.add_argument("--jobs", type=int, default=os.cpu_count())
    ls = sub.add_parser("list")
    ls.add_argument("--set", default="default", choices=["default", "full"])
    ls.add_argument("-v", "--verbose", action="store_true")
    r = sub.add_parser("run")
    r.add_argument("--core", default="w2", choices=sorted(gen_core_tests.CORE_CONST))
    r.add_argument("--harts", type=int, default=2, choices=[2, 4])
    r.add_argument("--set", default="default", choices=["default", "full"])
    r.add_argument("--iters", type=int, default=0, help="iterations per test (default 100, full set at N=4 50)")
    r.add_argument("--chunk", type=int, default=20, help="tests per program")
    r.add_argument("--seed", type=int, default=0xace1)
    r.add_argument("--jitter", type=int, default=63, help="delay mask (iterations of the delay loop)")
    r.add_argument("--skew", type=int, default=16, help="extra delay of the hart that leaves the barrier first")
    r.add_argument("--only", default="", help="regex on the test path")
    r.add_argument("--log-dir", type=Path, default=MASTER / ".build" / "glt")
    r.add_argument("--keep", action="store_true")
    r.add_argument("--no-run", action="store_true")
    a = ap.parse_args()
    if not TESTS.exists():
        sys.exit("run_glt: test/glt/upstream/litmus-tests-riscv missing, run toolchain/fetch.sh glt")
    return {"herd": cmd_herd, "list": cmd_list, "run": cmd_run}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
