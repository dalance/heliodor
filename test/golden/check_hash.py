#!/usr/bin/env python3
"""Compare the final `H <count> <hash>` line of a test log with the golden final.

    test/golden/check_hash.py LOG GOLDEN [--test NAME] [--partial]

LOG is either a `veryl test --format json` report (each test's own output is
checked) or plain text (the last H line in the file is the final one; give
--test only to label it). GOLDEN is either
  - a checkpoint file `*.ck.hex` (one test; the final count and hash are its
    last two words, word 0 must equal TRACER_VER), or
  - a final table `*.final`: lines `<test> <count> <hash> [<image sha256>]`,
    `#` comments. Every test of the table must be in the JSON report unless
    --partial; report tests absent from the table are ignored.

Exit code 0 only if every compared test matches; 1 on a mismatch, a missing
H line or a missing test; 2 on a usage or stale-golden error.
"""

import argparse
import json
import re
import sys
from pathlib import Path

MASTER = Path(__file__).resolve().parents[2]
RE_H = re.compile(r"^H\s+(\d+)\s+([0-9a-fA-F]+)\s*$")
RE_VER = re.compile(r"TRACER_VER\s*:\s*logic<64>\s*=\s*64'h([0-9a-fA-F_]+)")


def final_h(text):
    # The UART console prints NUL padding that can share a line with the H line.
    hs = [m for m in map(RE_H.match, text.replace("\x00", "").splitlines()) if m]
    if not hs:
        return None
    return int(hs[-1].group(1)), int(hs[-1].group(2), 16)


def load_log(path):
    """Return {test name: output text}; plain text maps to {None: text}."""
    text = Path(path).read_text(errors="replace")
    if text.lstrip().startswith("{"):
        try:
            rep = json.loads(text)
            return {t["name"]: t.get("output", "") for t in rep.get("tests", [])}
        except json.JSONDecodeError:
            pass
    return {None: text}


def load_golden(path):
    """Return {test name or None: (count, hash)}."""
    p = Path(path)
    if p.name.endswith(".ck.hex"):
        words = [int(w, 16) for w in p.read_text().split()]
        m = RE_VER.search((MASTER / "src" / "pkg" / "retire_pkg.veryl").read_text())
        ver = int(m.group(1).replace("_", ""), 16) if m else None
        if len(words) < 5 or words[0] != ver or len(words) != words[2] + 5:
            raise SystemExit(f"check_hash: {p} is stale or malformed (TRACER_VER {ver})")
        return {None: (words[-2], words[-1])}
    out = {}
    for ln in p.read_text().splitlines():
        f = ln.split("#", 1)[0].split()
        if f:
            out[f[0]] = (int(f[1], 0), int(f[2], 16))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("golden")
    ap.add_argument("--test")
    ap.add_argument("--partial", action="store_true")
    a = ap.parse_args()

    logs = load_log(a.log)
    gold = load_golden(a.golden)
    pairs = []
    if None in gold:
        if None in logs:
            pairs.append((a.test or "<log>", logs[None], gold[None]))
        elif a.test:
            pairs.append((a.test, logs.get(a.test), gold[None]))
        elif len(logs) == 1:
            (name, out), = logs.items()
            pairs.append((name, out, gold[None]))
        else:
            print("check_hash: a .ck.hex golden against a multi-test report needs --test", file=sys.stderr)
            return 2
    elif None in logs:
        if not a.test:
            print("check_hash: a plain-text log against a .final table needs --test", file=sys.stderr)
            return 2
        if a.test not in gold:
            print(f"check_hash: {a.test} not in {a.golden}", file=sys.stderr)
            return 2
        pairs.append((a.test, logs[None], gold[a.test]))
    else:
        for name, exp in gold.items():
            if name in logs:
                pairs.append((name, logs[name], exp))
            elif not a.partial:
                pairs.append((name, None, exp))

    if not pairs:
        print("check_hash: nothing to compare", file=sys.stderr)
        return 1
    bad = 0
    for name, out, (ec, eh) in pairs:
        if out is None:
            print(f"MISSING {name}: not in the log")
            bad += 1
            continue
        got = final_h(out)
        if got is None:
            print(f"NO_H    {name}: no H line (expected H {ec} {eh:016x})")
            bad += 1
        elif got != (ec, eh):
            print(f"DIFF    {name}: H {got[0]} {got[1]:016x}, golden H {ec} {eh:016x}")
            bad += 1
        else:
            print(f"OK      {name}: H {ec} {eh:016x}")
    print(f"check_hash: {len(pairs) - bad}/{len(pairs)} match")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
