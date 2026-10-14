"""Gate list parser shared by gen_core_tests.py and test/golden/run_golden.py.

A gate list (test/gates/<milestone>.list) holds one test per line:

    <suite>/<name> [budget=<cycles>] [hex=<path>] [tohost=<word index>]

`#` starts a comment. The defaults follow the riscv-tests layout: the image is
test/riscv-arch-test/build/<suite>/<name>.hex, tohost is word 1024 (PA
0x8000_1000) and the budget is 300,000 cycles. The budget is an upper bound;
the generated tests stop early once tohost is written.
"""

import re
from dataclasses import dataclass
from pathlib import Path

DEFAULT_BUDGET = 300000
DEFAULT_TOHOST = 1024
EARLY_EXIT_STEP = 1000

_IDENT = re.compile(r"^[A-Za-z0-9_]+$")


@dataclass(frozen=True)
class Entry:
    suite: str
    name: str
    budget: int
    hex: str
    tohost: int

    @property
    def key(self) -> str:
        return f"{self.suite}/{self.name}"

    @property
    def ident(self) -> str:
        return f"{self.suite}_{self.name}"

    @property
    def ck_file(self) -> str:
        return f"test/golden/arch/{self.suite}/{self.name}.ck.hex"


def parse(path) -> list:
    entries = []
    seen = set()
    for lineno, raw in enumerate(Path(path).read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        where = f"{path}:{lineno}"
        if fields[0].count("/") != 1:
            raise ValueError(f"{where}: expected <suite>/<name>, got {fields[0]!r}")
        suite, name = fields[0].split("/")
        if not (_IDENT.match(suite) and _IDENT.match(name)):
            raise ValueError(f"{where}: suite and name must be identifiers")
        opts = {}
        for f in fields[1:]:
            if "=" not in f:
                raise ValueError(f"{where}: expected key=value, got {f!r}")
            k, v = f.split("=", 1)
            if k not in ("budget", "hex", "tohost"):
                raise ValueError(f"{where}: unknown option {k!r}")
            opts[k] = v
        budget = int(opts.get("budget", DEFAULT_BUDGET))
        if budget <= 0 or budget % EARLY_EXIT_STEP:
            raise ValueError(f"{where}: budget must be a positive multiple of {EARLY_EXIT_STEP}")
        e = Entry(
            suite=suite,
            name=name,
            budget=budget,
            hex=opts.get("hex", f"test/riscv-arch-test/build/{suite}/{name}.hex"),
            tohost=int(opts.get("tohost", str(DEFAULT_TOHOST)), 0),
        )
        if e.key in seen:
            raise ValueError(f"{where}: duplicate entry {e.key}")
        seen.add(e.key)
        entries.append(e)
    return entries


def by_suite(entries) -> dict:
    out = {}
    for e in entries:
        out.setdefault(e.suite, []).append(e)
    return out
