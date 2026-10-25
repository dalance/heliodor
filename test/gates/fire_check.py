#!/usr/bin/env python3
"""GF: check the firing matrix of the new core's o_perf events.

    test/gates/fire_check.py [--matrix test/gates/fire_matrix.txt] [--zero]
                             <gate>=<log> [<gate>=<log> ...]

Each log is the output of a run whose harness instantiates tb/perf_acc.veryl
(plain text or a `veryl test --format json` report). perf_acc prints, per
test, one `PERF` layout line, `PB <core> <bit> <count>` for every nonzero bit
of core_types::CorePerf and `PK <core> <kind> <count>` for full kills by
RedirKind; tb/mc_perf_acc.veryl prints the same lines as core 0 for the SoC's
soc_pkg::McPerf. This script sums the counts per (gate, core), names the bits
from the struct definitions in src/core/common/core_types.veryl, xlate_pkg.veryl
and src/core/soc_pkg.veryl (checking the width against the PERF line), and
judges every matrix row:

    <event> <gate>[:w2|:w4|:mc][,<gate>...]

<event> names a leaf (`dc.r_bank`) or a prefix of leaves (`mp`, `iq[1]`);
an event without an index matches every element (`mp.split` = `mp[*].split`);
`flush.full_kind.<KIND>` names a RedirKind count. The row passes if the sum
over its gates is nonzero. A row whose gates have no log is reported as not
run and does not fail. --zero also lists every leaf that is zero in all logs.

Exit code 0 only if every row that ran passed.
"""

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = [ROOT / "src/core/common/core_types.veryl", ROOT / "src/core/common/xlate_pkg.veryl",
       ROOT / "src/core/soc_pkg.veryl"]
CORES = {0: "mc", 2: "w2", 4: "w4"}
ROOTS = {0: "McPerf"}  # the struct a core id's PB bits index, CorePerf otherwise

# Readable names for the bits of plain vector fields, MSB first.
VEC_NAMES = {
    "iq": ["tok_wait", "wb_blk"],
    "rs": ["hf_late", "hf_grant"],
    "pdr": ["V5", "V4", "V3", "V2", "V1"],
}
# Fields that qualify another field: their raw bits are not events.
QUALIFIERS = {"flush.full_kind"}


def strip_comments(s):
    return re.sub(r"//[^\n]*", "", s)


def parse_sources():
    structs, enums, consts = {}, {}, {}
    for f in SRC:
        s = strip_comments(f.read_text())
        for m in re.finditer(r"\bconst\s+(\w+)\s*:\s*u32\s*=\s*(\d+)\s*;", s):
            consts[m.group(1)] = int(m.group(2))
        for m in re.finditer(r"\benum\s+(\w+)\s*:\s*logic\s*<\s*(\d+)\s*>\s*\{(.*?)\}", s, re.S):
            members = [x.strip().split("=")[0].strip() for x in m.group(3).split(",") if x.strip()]
            enums[m.group(1)] = (int(m.group(2)), members)
        for m in re.finditer(r"\bstruct\s+(\w+)\s*\{(.*?)\}", s, re.S):
            fields = []
            for item in re.split(r",(?![^<]*>)", m.group(2)):
                item = item.strip()
                if item:
                    name, _, typ = item.partition(":")
                    fields.append((name.strip(), re.sub(r"\s+", "", typ)))
            if all(t for _, t in fields):
                structs[m.group(1)] = fields
    return structs, enums, consts


def eval_dim(expr, syms):
    expr = expr.replace("CFG::", "")
    for k, v in syms.items():
        expr = re.sub(r"\b%s\b" % k, str(v), expr)
    if not re.fullmatch(r"[0-9+*\-() ]+", expr):
        raise ValueError("cannot evaluate dimension %r" % expr)
    return eval(expr)


def split_type(typ, syms):
    m = re.fullmatch(r"([\w:]+)(?:<(.*)>)?", typ)
    base = m.group(1).split("::")[-1]
    dims = [eval_dim(d, syms) for d in m.group(2).split(",")] if m.group(2) else []
    return base, dims


class Layout:
    def __init__(self, structs, enums, syms):
        self.structs, self.enums, self.syms = structs, enums, syms

    def width(self, base, dims=()):
        n = 1
        for d in dims:
            n *= d
        if base == "logic":
            return n
        if base in self.enums:
            return n * self.enums[base][0]
        return n * sum(self.width(*split_type(t, self.syms)) for _, t in self.structs[base])

    def leaves(self, base, prefix, offset, out):
        """Append (lsb, width, name) for every leaf of `base` placed at `offset`."""
        fields = self.structs[base]
        pos = offset + self.width(base)
        for name, typ in fields:
            fb, dims = split_type(typ, self.syms)
            w = self.width(fb, dims)
            pos -= w
            self.place(fb, dims, prefix + name, name, pos, out)

    def place(self, fb, dims, full, short, lsb, out):
        if not dims:
            if fb == "logic" or fb in self.enums:
                out.append((lsb, self.width(fb), full))
            else:
                self.leaves(fb, full + ".", lsb, out)
            return
        if fb == "logic" and len(dims) == 1:
            names = VEC_NAMES.get(short)
            if full in QUALIFIERS or short == "retire_n" or names is None:
                for i in range(dims[0]):
                    out.append((lsb + i, 1, "%s[%d]" % (full, i)))
            else:
                for i, n in enumerate(names):
                    out.append((lsb + dims[0] - 1 - i, 1, "%s.%s" % (full, n)))
            return
        inner = self.width(fb, dims[1:])
        for i in range(dims[0]):
            sub = "%s[%d]" % (full, i)
            if fb == "logic" and len(dims) == 2 and short in VEC_NAMES:
                for j, n in enumerate(VEC_NAMES[short]):
                    out.append((lsb + i * inner + dims[1] - 1 - j, 1, "%s.%s" % (sub, n)))
            else:
                self.place(fb, dims[1:], sub, short, lsb + i * inner, out)


def read_log(path):
    text = Path(path).read_text(errors="replace")
    if text.lstrip().startswith(("{", "[")):
        try:
            parts = []

            def walk(x):
                if isinstance(x, str):
                    parts.append(x)
                elif isinstance(x, dict):
                    for v in x.values():
                        walk(v)
                elif isinstance(x, list):
                    for v in x:
                        walk(v)

            walk(json.loads(text))
            text = "\n".join(parts)
        except json.JSONDecodeError:
            pass
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--matrix", type=Path, default=ROOT / "test/gates/fire_matrix.txt")
    ap.add_argument("--zero", action="store_true", help="list leaves that are zero in every log")
    ap.add_argument("--nonzero", action="store_true", help="list leaves with their counts, nonzero only")
    ap.add_argument("logs", nargs="+", metavar="gate=log")
    a = ap.parse_args()

    structs, enums, consts = parse_sources()
    bits = defaultdict(lambda: defaultdict(int))  # (gate, core) -> bit -> count
    kinds = defaultdict(lambda: defaultdict(int))  # (gate, core) -> kind -> count
    hdr = {}  # core -> PERF fields
    tests = defaultdict(int)
    for spec in a.logs:
        gate, path = spec.split("=", 1)
        for line in read_log(path).splitlines():
            t = line.split()
            if len(t) == 9 and t[0] == "PERF":
                v = [int(x) for x in t[1:]]
                if hdr.setdefault(v[0], v) != v:
                    print("fire_check: conflicting PERF lines for core %d" % v[0], file=sys.stderr)
                    return 2
                tests[(gate, v[0])] += 1
            elif len(t) == 4 and t[0] == "PB":
                bits[(gate, int(t[1]))][int(t[2])] += int(t[3])
            elif len(t) == 4 and t[0] == "PK":
                kinds[(gate, int(t[1]))][int(t[2])] += int(t[3])
    if not hdr:
        print("fire_check: no PERF lines in the logs", file=sys.stderr)
        return 2

    rk_w, rk_names = enums["RedirKind"]
    layouts = {}
    for core, (_, perf_w, width, n_iq, iw, mw, wbn, rcw) in hdr.items():
        syms = dict(consts, N_IQ=n_iq, ISSUE_W=iw, MEM_W=mw, WB_N=wbn, RETIRE_CNT_W=rcw)
        lay = Layout(structs, enums, syms)
        top = ROOTS.get(core, "CorePerf")
        w = lay.width(top)
        if w != width or w > perf_w:
            print("fire_check: core %d %s is %d bits in the sources, %d in the run (PERF_W %d)"
                  % (core, top, w, width, perf_w), file=sys.stderr)
            return 2
        out = []
        lay.leaves(top, "", 0, out)
        layouts[core] = out

    def leaf_counts(gate, core):
        """name -> count for one (gate, core); multi-bit leaves sum their bits."""
        res = {}
        b = bits.get((gate, core), {})
        for lsb, w, name in layouts[core]:
            if name.split("[")[0] in QUALIFIERS:
                continue
            res[name] = sum(b.get(lsb + i, 0) for i in range(w))
        k = kinds.get((gate, core), {})
        for i, n in enumerate(rk_names if core not in ROOTS else []):
            if n != "BR":  # partial kills, counted by flush.partial
                res["flush.full_kind." + n] = k.get(i, 0)
        return res

    gates = sorted({g for g, _ in tests})
    counts = {(g, c): leaf_counts(g, c) for g, c in tests}
    for (g, c), n in sorted(tests.items()):
        print("log %s:%s  %d tests" % (g, CORES.get(c, c), n))

    def matches(name, ev):
        for n in (name, re.sub(r"\[\d+\]", "", name)):
            if n == ev or n.startswith(ev + ".") or n.startswith(ev + "["):
                return True
        return False

    fail = 0
    print("\n%-34s %-26s %s" % ("event", "gates", "count"))
    for raw in a.matrix.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        ev, gspec = line.split()
        total, ran, known = 0, False, False
        for g in gspec.split(","):
            gname, _, cname = g.partition(":")
            for (lg, c), cnt in counts.items():
                if lg != gname or (cname and CORES.get(c) != cname):
                    continue
                ran = True
                for name, v in cnt.items():
                    if matches(name, ev):
                        known = True
                        total += v
        if ran and not known:
            print("fire_check: matrix event %r names no leaf" % ev, file=sys.stderr)
            return 2
        verdict = "not run" if not ran else ("ok" if total else "ZERO")
        fail += ran and not total
        print("%-34s %-26s %-12s %s" % (ev, gspec, total if ran else "-", verdict))

    if a.nonzero:
        for (g, c), cnt in sorted(counts.items()):
            print("\nnonzero in %s:%s:" % (g, CORES.get(c, c)))
            for n, v in cnt.items():
                if v:
                    print("  %-32s %d" % (n, v))

    if a.zero:
        for core in sorted(layouts):
            agg = defaultdict(int)
            for (g, c), cnt in counts.items():
                if c == core:
                    for name, v in cnt.items():
                        agg[name] += v
            zero = [n for n, v in agg.items() if v == 0]
            print("\nzero in every log (%s, %d of %d leaves, gates %s):"
                  % (CORES.get(core, core), len(zero), len(agg), ",".join(gates)))
            for n in zero:
                print("  " + n)
    print("\nfire_check: %d matrix row(s) zero" % fail)
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
