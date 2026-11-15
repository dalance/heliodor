"""Parse RISC-V .litmus tests and herd7 results.

A litmus test is the header line `RISCV <name>`, free text and key=value
lines, the init block `{...}`, one code row per line with the threads
separated by `|`, and a final condition (exists, ~exists, forall, with an
optional locations clause or filter). herd7 prints, per test, the final
states it allows projected on the condition's (and locations') variables.
"""

import re
from dataclasses import dataclass, field

ABI = {n: i for i, n in enumerate(
    "zero ra sp gp tp t0 t1 t2 s0 s1 a0 a1 a2 a3 a4 a5 a6 a7 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t3 t4 t5 t6".split())}
ABI["fp"] = 8
REG = re.compile(r"\b(x(?:[12]?[0-9]|3[01])|" + "|".join(sorted(ABI, key=len, reverse=True)) + r")\b")

TYPES = {"int": (4, True), "int32_t": (4, True), "uint32_t": (4, False), "int64_t": (8, True),
         "uint64_t": (8, False), "int16_t": (2, True), "uint16_t": (2, False), "int8_t": (1, True),
         "uint8_t": (1, False), "long": (8, True)}


def regnum(tok):
    return int(tok[1:]) if tok.startswith("x") and tok[1:].isdigit() else ABI[tok]


@dataclass
class Test:
    name: str
    path: str
    threads: list                                  # per thread: list of code lines
    reg_init: list = field(default_factory=list)   # per thread: {reg: int | ('addr', loc) | ('label', lbl)}
    locs: dict = field(default_factory=dict)       # loc -> (size, signed, init value)
    cond: str = ""
    kind: str = "exists"
    has_filter: bool = False

    @property
    def n_threads(self):
        return len(self.threads)


def _strip_comments(text):
    return re.sub(r"\(\*.*?\*\)", "", text, flags=re.S)


def _value(v):
    v = v.strip()
    try:
        return int(v, 0)
    except ValueError:
        return v


def parse(path, text):
    text = _strip_comments(text)
    head, _, rest = text.partition("{")
    first = head.lstrip().splitlines()[0].split()
    if len(first) < 2 or first[0] != "RISCV":
        raise ValueError("not a RISCV litmus test")
    name = first[1]
    init, _, rest = rest.partition("}")
    lines = [ln for ln in rest.splitlines() if ln.strip()]
    hdr = [c.strip().rstrip(";").strip() for c in lines[0].split("|")]
    if not all(re.fullmatch(r"P\d+", h) for h in hdr):
        raise ValueError(f"bad thread header {lines[0]!r}")
    n = len(hdr)
    threads = [[] for _ in range(n)]
    cond_at = len(lines)
    for i, ln in enumerate(lines[1:], 1):
        s = ln.strip()
        if re.match(r"(exists|~exists|forall|locations|filter)\b", s):
            cond_at = i
            break
        cols = s.rstrip(";").split("|")
        if len(cols) != n:
            raise ValueError(f"code row with {len(cols)} columns: {ln!r}")
        for t, c in enumerate(cols):
            c = c.strip()
            if c:
                threads[t].append(c)
    cond = " ".join(ln.strip() for ln in lines[cond_at:])
    kind = "exists"
    for k in ("~exists", "forall", "exists"):
        if re.search(r"(^|\s)" + re.escape(k) + r"\b", cond):
            kind = k
            break
    t = Test(name=name, path=str(path), threads=threads, reg_init=[{} for _ in range(n)], cond=cond, kind=kind,
             has_filter="filter" in cond)
    for decl in filter(None, (d.strip() for d in init.split(";"))):
        m = re.fullmatch(r"(?:([A-Za-z_][A-Za-z0-9_]*)(?:\s*(\*)\s*|\s+))?(?:(\d+):)?([A-Za-z_][A-Za-z0-9_]*)(?:\s*=\s*(.+))?",
                         decl.replace("\n", " "))
        if not m:
            raise ValueError(f"init {decl!r}")
        ty, ptr, proc, var, val = m.groups()
        if ptr and proc is None:
            if not (val and re.fullmatch(r"&\w+", val.strip())):
                raise ValueError(f"pointer {decl!r}")
            t.locs.setdefault(val.strip()[1:], None)
            t.locs[var] = (8, False, ("addr", val.strip()[1:]))
            continue
        if ty and ty not in TYPES:
            raise ValueError(f"type {ty!r}")
        if proc is not None:
            p = int(proc)
            if val is None:
                continue
            v = _value(val)
            if isinstance(v, str):
                lm = re.fullmatch(r"P(\d+):(\w+)", v)
                v = ("label", int(lm.group(1)), lm.group(2)) if lm else ("addr", v)
                if v[0] == "addr":
                    t.locs.setdefault(v[1], None)
            t.reg_init[p][regnum(var)] = v
        else:
            size, signed = TYPES[ty] if ty else (None, True)
            old = t.locs.get(var)
            v = _value(val) if val is not None else (old[2] if old else 0)
            if isinstance(v, str):
                v = ("addr", v)
                t.locs.setdefault(v[1], None)
            if size is None and old:
                size, signed = old[0], old[1]
            t.locs[var] = (size, signed, v)
    for loc, d in list(t.locs.items()):
        if d is None:
            t.locs[loc] = (4, True, 0)
        elif d[0] is None:
            t.locs[loc] = (4, True, d[2])
    return t


@dataclass
class HerdResult:
    name: str
    vars: list          # observed variables in a fixed order
    states: list        # list of tuples (one value per var; int or location name)
    hash: str = ""      # herd's hash of the test


def parse_herd(text):
    """herd7 output of one or more tests -> {name: HerdResult}."""
    out = {}
    for m in re.finditer(r"^Test (\S+) \S+\nStates (\d+)\n(.*?)^(Ok|No)$(.*?)^Hash=(\S+)$", text, re.S | re.M):
        name, n = m.group(1), int(m.group(2))
        rows = [r for r in m.group(3).splitlines() if r.strip()]
        if len(rows) != n and (n, rows) != (1, []):
            continue
        states, keys = [], None
        for r in rows:
            kv = [p.strip() for p in r.split(";") if p.strip()]
            d = {}
            for p in kv:
                k, _, v = p.partition("=")
                d[k.strip()] = _value(v)
            if keys is None:
                keys = sorted(d, key=_var_order)
            if sorted(d, key=_var_order) != keys:
                raise ValueError(f"{name}: states over different variables")
            st = tuple(d[k] for k in keys)
            if st not in states:
                states.append(st)
        out[name] = HerdResult(name, keys or [], states or ([()] if n else []), m.group(6))
    return out


def _var_order(v):
    p, _, r = v.partition(":")
    return (0, int(p), r) if r else (1, 0, v)
