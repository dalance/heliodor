#!/usr/bin/env python3
"""GG verdict: compare a heliodor run of the debug suite with the spike reference.

    test/debug/gg_compare.py <heliodor.txt> <spike_ref.txt> --target <name>
                             [--excludes heliodor_excludes.yaml]

<heliodor.txt> is run_gg.sh's output ("<test> <status> [<seconds>]"), the
reference is a run_spike_ref.sh output (spike_ref_*.txt). Prints one line per
test with both statuses and the verdict, then the counts:
  ok        heliodor passes, or neither passes
  excluded  spike passes, heliodor does not, and the test is in the exclusion
            table (U37) under `all` or the target's name
  extra     heliodor passes a test spike does not pass
  FAIL      spike passes, heliodor does not, and the test is not excluded
  not run   the heliodor run did not include the test (a subset run)
Exit code 0 only if there is no FAIL (the GG gate).
"""

import argparse
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent


def read(path):
    res = {}
    for line in Path(path).read_text().splitlines():
        t = line.split()
        if len(t) >= 2 and not line.startswith("#"):
            res[t[0]] = t[1]
    return res


def excludes(path, target):
    table = yaml.safe_load(Path(path).read_text()) or {}
    return set(table.get("all", [])) | set(table.get(target, []))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("heliodor")
    ap.add_argument("spike")
    ap.add_argument("--target", required=True, help="gdbserver.py target name (w2_n1, w2_n4, ...)")
    ap.add_argument("--excludes", default=HERE / "heliodor_excludes.yaml")
    a = ap.parse_args()
    h, s, ex = read(a.heliodor), read(a.spike), excludes(a.excludes, a.target)
    count = {}
    print("%-36s %-15s %-15s %s" % ("test", "spike", "heliodor", "verdict"))
    for t in sorted(set(h) | set(s)):
        sv, hv = s.get(t, "-"), h.get(t, "-")
        if hv == "-":
            v = "not run"
        elif hv == "pass":
            v = "ok" if sv == "pass" else "extra"
        elif sv != "pass":
            v = "ok"
        elif t in ex:
            v = "excluded"
        else:
            v = "FAIL"
        count[v] = count.get(v, 0) + 1
        print("%-36s %-15s %-15s %s" % (t, sv, hv, v))
    hc = {}
    for v in h.values():
        hc[v] = hc.get(v, 0) + 1
    print("heliodor: " + ", ".join("%s %d" % kv for kv in sorted(hc.items())))
    print("verdicts: " + ", ".join("%s %d" % kv for kv in sorted(count.items())))
    return 1 if count.get("FAIL") else 0


if __name__ == "__main__":
    sys.exit(main())
