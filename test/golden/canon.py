#!/usr/bin/env python3
"""Canonicalize retire trace text so two traces compare with `cmp`.

    test/golden/canon.py [-o OUT] [LOG ...]      (stdin if no LOG)

Keeps only R/T/I/H lines (K checkpoint lines, console output and every other
line are dropped), removes a trailing `#TAG` annotation, collapses whitespace,
and rewrites every number in a fixed form: decimal fields (order, count,
register numbers, priv/virt) without leading zeros, hex fields in lowercase
without leading zeros, insn as 8 hex digits plus the `c` RVC suffix. A
masked value `*` is kept. Line formats are those printed by tb/rvfi_tracer.veryl.

A line that starts with R/T/I/H but does not parse is an error (exit code 2),
so a format drift between the tracer and this script cannot pass silently.
Use --lenient to drop such lines instead (console text interleaved into a
trace line).
"""

import argparse
import re
import sys

KINDS = ("R", "T", "I", "H")
_DEC = re.compile(r"^\d+$")
_HEX = re.compile(r"^[0-9a-fA-F]+$")
_REG = re.compile(r"^([xf])(\d+)=(\S+)$")


class Bad(Exception):
    pass


def dec(t):
    if not _DEC.match(t):
        raise Bad(t)
    return str(int(t))


def hx(t):
    if t == "*":
        return t
    if not _HEX.match(t):
        raise Bad(t)
    return format(int(t, 16), "x")


def insn(t):
    if t in ("*", "*c"):
        return t
    rvc = len(t) == 9 and t.endswith("c")
    body = t[:-1] if rvc else t
    if len(body) > 8:
        raise Bad(t)
    return format(int(hx(body), 16), "08x") + ("c" if rvc else "")


def privvirt(t):
    if not re.match(r"^[0-3][01]$", t):
        raise Bad(t)
    return t


def rest_r(toks):
    out, i = [], 0
    while i < len(toks):
        t = toks[i]
        if m := _REG.match(t):
            out.append(f"{m.group(1)}{int(m.group(2))}={hx(m.group(3))}")
            i += 1
        elif t.startswith("y="):
            out.append("y=" + hx(t[2:]))
            i += 1
        elif t == "S":
            out += ["S", hx(toks[i + 1]), hx(toks[i + 2]), hx(toks[i + 3])]
            i += 4
            if i < len(toks) and toks[i] == "IO":
                out.append("IO")
                i += 1
        elif t == "C":
            csr, val = toks[i + 1].split("=", 1)
            out += ["C", f"{hx(csr)}={hx(val)}"]
            i += 2
        elif t == "F":
            out += ["F", hx(toks[i + 1])]
            i += 2
        elif t == "V":
            out += ["V"] + [hx(x) for x in toks[i + 1:i + 6]]
            if len(toks) < i + 6:
                raise Bad(t)
            i += 6
        else:
            raise Bad(t)
    return out


def canon_line(line):
    """Return the canonical line, None for a line that is not a trace line."""
    s = line.split("#", 1)[0].split()
    if not s or s[0] not in KINDS:
        return None
    k = s[0]
    try:
        if k == "R":
            if len(s) < 5:
                raise Bad(line)
            out = ["R", dec(s[1]), privvirt(s[2]), hx(s[3]), insn(s[4])] + rest_r(s[5:])
        elif k == "T":
            if len(s) != 7:
                raise Bad(line)
            out = ["T", dec(s[1]), privvirt(s[2]), hx(s[3]), insn(s[4]), hx(s[5]), hx(s[6])]
        elif k == "I":
            if len(s) != 4:
                raise Bad(line)
            out = ["I", dec(s[1]), hx(s[2]), hx(s[3])]
        else:
            if len(s) != 3:
                raise Bad(line)
            out = ["H", dec(s[1]), hx(s[2])]
    except (Bad, IndexError, ValueError) as ex:
        raise Bad(f"unparsable {k} line: {line.rstrip()!r} ({ex})")
    return " ".join(out)


def canon(lines, lenient=False):
    for ln in lines:
        try:
            c = canon_line(ln)
        except Bad:
            if lenient:
                continue
            raise
        if c is not None:
            yield c


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("logs", nargs="*")
    ap.add_argument("-o", "--out")
    ap.add_argument("--lenient", action="store_true")
    a = ap.parse_args()
    out = open(a.out, "w") if a.out else sys.stdout
    try:
        for src in a.logs or ["-"]:
            f = sys.stdin if src == "-" else open(src, errors="replace")
            with f:
                for c in canon(f, a.lenient):
                    out.write(c + "\n")
    except Bad as ex:
        print(f"canon: {ex}", file=sys.stderr)
        return 2
    finally:
        if a.out:
            out.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
