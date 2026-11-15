#!/usr/bin/env python3
"""Functional coverage (GCV) from the spike cosim's records.

    test/gates/cov_report.py run [--out DIR] [--sets gc,act,gr,...] [--core w2]
    test/gates/cov_report.py report [--out DIR]

`run` runs each gate set under the spike cosim with HELIODOR_COV_DIR set to
<out>/raw/<set>, so every cosim instance writes its coverage keys there
(cosim/spike/src/cov.rs), logs to <out>/log/<set>.log and then reports.
Sets (SETS): gc = run_gc.py (the arch and directed lists, mv_probe included),
act = run_act.py --cosim (all ACT4 suites), gr/grp/grv/grvp/grh/grvh =
run_gr.py with its default seeds (scalar, privileged, vector, vector +
privileged, H, H + vector), boot = the N=1 boots under the cosim (5.15, 6.6,
7.1, 7.1v). Needs
SPIKE_HOME, as the runners do.

`report` merges <out>/raw/*/ into <out>/report.json and <out>/summary.txt:
instructions by mnemonic and mode, traps by cause, source mode and handling
level, CSR accesses by kind, mode and outcome, the vtype lattice per vector
class, and memory accesses by class, mode, translation, alignment and SC
outcome. Each axis is measured against an implemented universe (the GR
mnemonic tables plus IMPL_EXTRA, csr_pkg::csr_exists, the configuration's
delegation rules), so a hole is an implemented case no set reached. Raw
instruction words are named with the pinned objdump (-M no-aliases).

The default <out> is .build/cov (gitignored).
"""

import argparse
import collections
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

MASTER = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(MASTER / "test" / "gr"))
import gen  # noqa: E402
import hyp  # noqa: E402
import priv  # noqa: E402
import vec  # noqa: E402

GATES = MASTER / "test" / "gates"
SETS = {
    "gc": [sys.executable, str(GATES / "run_gc.py"), "--core", "{core}"],
    "act": [sys.executable, str(GATES / "run_act.py"), "--core", "{core}", "--cosim"],
    "gr": [sys.executable, str(MASTER / "test" / "gr" / "run_gr.py"), "--core", "{core}"],
    "grp": [sys.executable, str(MASTER / "test" / "gr" / "run_gr.py"), "--core", "{core}", "--priv"],
    "grv": [sys.executable, str(MASTER / "test" / "gr" / "run_gr.py"), "--core", "{core}", "--vec"],
    "grvp": [sys.executable, str(MASTER / "test" / "gr" / "run_gr.py"), "--core", "{core}", "--vec", "--priv"],
    "grh": [sys.executable, str(MASTER / "test" / "gr" / "run_gr.py"), "--core", "{core}", "--hyp"],
    "grvh": [sys.executable, str(MASTER / "test" / "gr" / "run_gr.py"), "--core", "{core}", "--hyp", "--vec"],
    "boot": ["{veryl}", "test", "--ignored", "--test", "test_cosim_spike_w2_linux_boot", "--format", "json"],
}
DEFAULT_SETS = "gc,act,gr,grp,grv,grvp,grh,grvh,boot"

# Implemented instructions the GR tables leave out (they list what the
# generator emits): stalls, Debug Mode and sp writes. objdump -M no-aliases
# spells c.nop as c.addi.
IMPL_EXTRA = ["wrs.nto", "wrs.sto", "dret", "c.addi16sp"]

MODES = {3: "M", 1: "HS", 0: "U", 5: "VS", 4: "VU"}
MODE_ORDER = ["M", "HS", "U", "VS", "VU"]
LEVELS = {1: "M", 2: "HS", 3: "VS"}
MEM_CLASSES = ["load", "store", "fload", "fstore", "amo", "lr", "sc", "vload", "vstore", "cbo", "hlv", "hsv"]
CSR_KINDS = ["read", "write", "set", "clear"]


def field(k, lsb, w):
    return (k >> lsb) & ((1 << w) - 1)


# --- running ---------------------------------------------------------------

def run_sets(a):
    veryl = os.environ.get("VERYL") or str(MASTER / "veryl" / "target" / "release-verylup" / "veryl")
    (a.out / "log").mkdir(parents=True, exist_ok=True)
    times = {}
    tf = a.out / "times.json"
    if tf.exists():
        times = json.loads(tf.read_text())
    for name in a.sets.split(","):
        cmd = [c.format(core=a.core, veryl=veryl) for c in SETS[name]]
        raw = a.out / "raw" / name
        if raw.exists():
            for f in raw.glob("*.json"):
                f.unlink()
        env = dict(os.environ, HELIODOR_COV_DIR=str(raw))
        print(f"cov_report: {name}: {' '.join(cmd)}", file=sys.stderr, flush=True)
        t0 = time.time()
        with open(a.out / "log" / f"{name}.log", "w") as log:
            p = subprocess.run(cmd, cwd=MASTER, env=env, stdout=log, stderr=subprocess.STDOUT)
        times[name] = {"wall_s": round(time.time() - t0), "rc": p.returncode}
        print(f"cov_report: {name}: exit {p.returncode}, {times[name]['wall_s']} s", file=sys.stderr, flush=True)
        tf.write_text(json.dumps(times, indent=1) + "\n")


# --- decoding --------------------------------------------------------------

def insn_len(w):
    if w & 3 != 3:
        return 2
    if w & 0x1c != 0x1c:
        return 4
    return 0


def disassemble(words):
    """Mnemonic of each raw instruction word (objdump -M no-aliases)."""
    names = {}
    todo = []
    for w in sorted(words):
        n = insn_len(w)
        if w == 0:
            names[w] = "(fetch fault)"
        elif n == 0:
            names[w] = "(long encoding)"
        else:
            todo.append((w, n))
    if not todo:
        return names
    march = gen.MARCH_V + "_svinval_h"
    with tempfile.TemporaryDirectory() as d:
        src, obj = Path(d) / "w.S", Path(d) / "w.o"
        lines = [".text"] + [f".insn {n}, {w:#x}" for w, n in todo]
        src.write_text("\n".join(lines) + "\n")
        subprocess.run([gen.tool("gcc"), f"-march={march}", "-mabi=lp64d", "-c", str(src), "-o", str(obj)],
                       check=True)
        p = subprocess.run([gen.tool("objdump"), "-d", "-M", "no-aliases", str(obj)], text=True,
                           capture_output=True, check=True)
    got = []
    for line in p.stdout.splitlines():
        f = line.split("\t")
        if len(f) >= 3 and f[0].strip().endswith(":"):
            got.append(f[2].strip().split()[0] if f[2].strip() else ".insn")
    if len(got) != len(todo):
        raise SystemExit(f"cov_report: objdump gave {len(got)} instructions for {len(todo)} words")
    for (w, _), m in zip(todo, got):
        # FENCE and FENCE.I with reserved fields execute as the base form.
        if m == ".insn" and w & 0x7f == 0x0f and (w >> 12) & 7 < 2:
            m = ("fence", "fence.i")[(w >> 12) & 7]
        m = re.sub(r"\.(aqrl|aq|rl)$", "", m)
        m = re.sub(r"^(c\.mop|mop\.rr?)\.\d+$", r"\1.N", m)
        names[w] = m
    return names


# --- universes -------------------------------------------------------------

def insn_universe():
    u = list(gen.MNEMONICS)
    for extra in (priv.PRIV_MNEMONICS, hyp.HYP_MNEMONICS, vec.VEC_MNEMONICS, IMPL_EXTRA):
        u += [m for m in extra if m not in u]
    return u


def csr_universe():
    """Addresses of csr_pkg::csr_exists, as the decoder accepts them."""
    text = (MASTER / "src" / "pkg" / "csr_pkg.veryl").read_text()
    body = text[text.index("function csr_exists"):]
    body = body[:body.index("function csr_ireg")]
    out = {int(h, 16) for h in re.findall(r"12'h([0-9A-Fa-f]{3})", body.split("default:")[0])}
    for lo, hi in re.findall(r"a >= 12'h([0-9A-Fa-f]{3}) && a <= 12'h([0-9A-Fa-f]{3})", body):
        out |= set(range(int(lo, 16), int(hi, 16) + 1))
    for h in (1, 2):
        out |= {(h << 8) | 0x50 | k for k in range(1, 8) if k != 4}
    return sorted(out)


CSR_NAMES = {
    0x001: "fflags", 0x002: "frm", 0x003: "fcsr", 0x008: "vstart", 0x009: "vxsat", 0x00A: "vxrm", 0x00F: "vcsr",
    0xC20: "vl", 0xC21: "vtype", 0xC22: "vlenb", 0xF11: "mvendorid", 0xF12: "marchid", 0xF13: "mimpid",
    0xF14: "mhartid", 0xF15: "mconfigptr", 0x300: "mstatus", 0x301: "misa", 0x302: "medeleg", 0x303: "mideleg",
    0x304: "mie", 0x305: "mtvec", 0x306: "mcounteren", 0x30A: "menvcfg", 0x320: "mcountinhibit",
    0x340: "mscratch", 0x341: "mepc", 0x342: "mcause", 0x343: "mtval", 0x344: "mip", 0x34A: "mtinst",
    0x34B: "mtval2", 0x3A0: "pmpcfg0", 0x3A2: "pmpcfg2", 0x747: "mseccfg", 0x100: "sstatus", 0x104: "sie",
    0x105: "stvec", 0x106: "scounteren", 0x10A: "senvcfg", 0x140: "sscratch", 0x141: "sepc", 0x142: "scause",
    0x143: "stval", 0x144: "sip", 0x14D: "stimecmp", 0x180: "satp", 0xDA0: "scountovf", 0x600: "hstatus",
    0x602: "hedeleg", 0x603: "hideleg", 0x604: "hie", 0x605: "htimedelta", 0x606: "hcounteren", 0x607: "hgeie",
    0x60A: "henvcfg", 0x643: "htval", 0x644: "hip", 0x645: "hvip", 0x64A: "htinst", 0x680: "hgatp",
    0xE12: "hgeip", 0x200: "vsstatus", 0x204: "vsie", 0x205: "vstvec", 0x240: "vsscratch", 0x241: "vsepc",
    0x242: "vscause", 0x243: "vstval", 0x244: "vsip", 0x24D: "vstimecmp", 0x280: "vsatp", 0xB00: "mcycle",
    0xB02: "minstret", 0xC00: "cycle", 0xC01: "time", 0xC02: "instret", 0x7A0: "tselect", 0x7A1: "tdata1",
    0x7A2: "tdata2", 0x7A3: "tdata3", 0x7A4: "tinfo", 0x7B0: "dcsr", 0x7B1: "dpc", 0x7B2: "dscratch0",
    0x7B3: "dscratch1", 0x30C: "mstateen0", 0x30D: "mstateen1", 0x30E: "mstateen2", 0x30F: "mstateen3",
    0x60C: "hstateen0", 0x60D: "hstateen1", 0x60E: "hstateen2", 0x60F: "hstateen3", 0x10C: "sstateen0",
    0x10D: "sstateen1", 0x10E: "sstateen2", 0x10F: "sstateen3", 0x120: "scountinhibit", 0x181: "srmcfg",
    0x150: "siselect", 0x250: "vsiselect", 0x350: "miselect",
}


def csr_name(a):
    if a in CSR_NAMES:
        return CSR_NAMES[a]
    for base, name in ((0xB00, "mhpmcounter"), (0xC00, "hpmcounter"), (0x320, "mhpmevent")):
        if base + 3 <= a <= base + 31:
            return f"{name}{a - base}"
    if 0x3B0 <= a <= 0x3BF:
        return f"pmpaddr{a - 0x3B0}"
    if a & 0xCF8 == 0x050 and a >> 8 in (1, 2):
        k = a & 7
        return ("s" if a >> 8 == 1 else "vs") + "ireg" + ("" if k == 1 else str(k))
    return f"csr{a:#05x}"


def csr_denied_modes(a):
    """Modes from which an access to CSR a is refused for its privilege
    field alone, and the cause: M CSRs from HS/U/VS/VU (illegal), H and VS
    CSRs from U (illegal) and from VS/VU (virtual), S CSRs from U (illegal)
    and VU (virtual)."""
    lvl = (a >> 8) & 3
    if a >> 4 == 0x7B:
        return {}
    if lvl == 3:
        return {m: 2 for m in ("HS", "U", "VS", "VU")}
    if lvl == 2:
        return {"U": 2, "VS": 22, "VU": 22}
    if lvl == 1:
        return {"U": 2, "VU": 22}
    return {}


# Exception causes the configuration can raise, the source modes each can
# come from (M includes MPRV accesses), and the levels it can be taken at
# (medeleg/hedeleg writable bits). Reasons for the causes left out are in
# TRAP_UNREACHABLE.
ALL5 = ("M", "HS", "U", "VS", "VU")
EXC = {
    1: ALL5, 2: ALL5, 3: ALL5, 4: ALL5, 5: ALL5, 6: ALL5, 7: ALL5, 8: ("U", "VU"), 9: ("HS",), 10: ("VS",),
    11: ("M",), 12: ("HS", "U", "VS", "VU"), 13: ALL5, 15: ALL5, 20: ("VS", "VU"), 21: ALL5, 22: ("VS", "VU"), 23: ALL5,
}
HEDELEG = {0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 13, 15}
MEDELEG_NOT = {11, 16}
TRAP_UNREACHABLE = {
    "exception 0": "IALIGN is 16 (C is not writable in misa), so no control transfer can be misaligned",
    "exception 14, 17, 24-31": "reserved",
    "exception 16 (double trap) other than to M": "a double trap always goes to M",
    "exception 18": "software check (Zicfiss/Zicfilp) is not implemented",
    "exception 19": "hardware error is not raised",
    "exception 12 from M, 20 from M/HS/U": "fetch is never translated in M, and passes the G-stage only with "
                                           "V = 1",
    "interrupt 12 (SGEI), and VS external from IMSIC": "GEILEN is 0",
}


def exc_universe():
    u = set()
    for c, srcs in EXC.items():
        for s in srcs:
            if c in (21, 23) and s == "M":
                u.add((c, s, "M"))  # MPRV with MPV, or HLV/HSV
                continue
            u.add((c, s, "M"))
            if s != "M" and c not in MEDELEG_NOT:
                u.add((c, s, "HS"))
            if s in ("VS", "VU") and c in HEDELEG:
                u.add((c, s, "VS"))
    u.add((16, "HS", "M"))
    u.add((16, "VS", "M"))
    return u


def irq_universe():
    """(cause as taken, source mode, level). VS-level interrupts arrive as
    their VS cause (1, 5, 9)."""
    u = set()
    for c in (1, 3, 5, 7, 9, 11, 13):
        for s in ALL5:
            u.add((c, s, "M"))
    for c in (1, 5, 9, 13, 2, 6, 10):
        for s in ("HS", "U", "VS", "VU"):
            u.add((c, s, "HS"))
    for c in (1, 5, 9):
        for s in ("VS", "VU"):
            u.add((c, s, "VS"))
    return u


# --- vector classes --------------------------------------------------------

LMULS = {0: 1, 1: 2, 2: 4, 3: 8, 5: 0.125, 6: 0.25, 7: 0.5}
LMUL_NAME = {0: "m1", 1: "m2", 2: "m4", 3: "m8", 5: "mf8", 6: "mf4", 7: "mf2"}
WIDE_I = tuple(f"{o}." for o in vec.W_VVX + vec.W_MAC + vec.N_WVXI + vec.I_WRED + ["vwmaccus", "vwsll"])
FW = tuple(f"{o}." for o in vec.FW_VVF + vec.FW_MAC + vec.FW_RED)


def vclass(m):
    """(class, EEW of the memory data or index, NFIELDS, widening) of a
    vector mnemonic; None if vtype does not shape it."""
    if m in ("vsetvli", "vsetivli", "vsetvl"):
        return ("vset", None, 1, None)
    if re.match(r"vmv\dr\.v$", m) or re.match(r"vl\dre\d+\.v$", m) or re.match(r"vs\dr\.v$", m):
        return None
    mm = re.match(r"v([ls])(seg(\d))?e(\d+)(ff)?\.v$", m)
    if mm:
        return ("vld-unit" if mm[1] == "l" else "vst-unit", int(mm[4]), int(mm[3] or 1), None)
    mm = re.match(r"v([ls])s(seg(\d))?e(\d+)\.v$", m)
    if mm:
        return ("vld-stride" if mm[1] == "l" else "vst-stride", int(mm[4]), int(mm[3] or 1), None)
    mm = re.match(r"v([ls])([uo])x(seg(\d))?ei(\d+)\.v$", m)
    if mm:
        return ("vld-index" if mm[1] == "l" else "vst-index", -int(mm[5]), int(mm[4] or 1), None)
    if m in ("vlm.v", "vsm.v"):
        return ("vmask-ls", None, 1, None)
    if m.startswith(("vfwcvt", "vfncvt")):
        sews = vec.FW_CVT.get(m) or vec.FN_CVT.get(m)
        return ("vf-cvt-wn", None, 1, sews)
    if m.startswith(FW) or m.startswith(("vfwadd.w", "vfwsub.w")):
        return ("vf-widen", None, 1, (32,))
    if m.startswith("vf") or m.startswith("vmf"):
        return ("vf", None, 1, None)
    if m.startswith(("vzext", "vsext")):
        return ("vext", None, 1, None)
    if m.startswith(WIDE_I) or m.startswith(("vwaddu.w", "vwadd.w", "vwsubu.w", "vwsub.w")):
        return ("vint-widen", None, 1, None)
    if m.startswith(("vred", "vwred")):
        return ("vred", None, 1, None)
    if m.endswith(".mm") or m in ("vcpop.m", "vfirst.m", "vmsbf.m", "vmsif.m", "vmsof.m", "viota.m", "vid.v"):
        return ("vmask", None, 1, None)
    if m.startswith(("vslide", "vrgather", "vcompress", "vmv.x.s", "vmv.s.x")):
        return ("vperm", None, 1, None)
    return ("vint", None, 1, None)


def legal_cell(cls, sew, lmul_code, info):
    """Whether (SEW, LMUL) is a legal, non-trapping shape for the class."""
    lmul = LMULS[lmul_code]
    if sew > 64 * lmul:
        return False
    _, eew, nf, sews = info
    if cls in ("vf",):
        return sew in (32, 64)
    if cls == "vf-widen":
        return sew == 32 and lmul <= 4
    if cls == "vf-cvt-wn":
        return sew in (sews or ()) and lmul <= 4
    if cls == "vint-widen":
        return sew <= 32 and lmul <= 4
    if cls == "vext":
        return sew >= 16
    if eew is not None:
        e = abs(eew)
        emul = e * lmul / sew
        if not 0.125 <= emul <= 8:
            return False
        if eew < 0:  # indexed: data EMUL = LMUL
            return nf * max(lmul, 1) <= 8
        return nf * max(emul, 1) <= 8
    return True


# --- report ----------------------------------------------------------------

def load(raw_root):
    per_set = {}
    for d in sorted(p for p in raw_root.iterdir() if p.is_dir()):
        keys = collections.Counter()
        files = recs = 0
        for f in d.glob("*.json"):
            j = json.loads(f.read_text())
            files += 1
            recs += j["records"]
            for k, n in j["keys"]:
                keys[k] += n
        per_set[d.name] = (keys, files, recs)
    return per_set


def pct(a, b):
    return f"{100.0 * a / b:.1f} %" if b else "-"


def report(a):
    per_set = load(a.out / "raw")
    if not per_set:
        raise SystemExit(f"cov_report: nothing under {a.out / 'raw'}")
    allk = collections.Counter()
    for keys, _, _ in per_set.values():
        allk.update(keys)
    words = {field(k, 0, 32) for k in allk if k >> 60 in (1, 2)}
    names = disassemble(words)

    rep = {"sets": {s: {"files": f, "records": r, "keys": len(k)} for s, (k, f, r) in per_set.items()}}
    lines = ["GCV functional coverage", ""]
    lines.append("sets: " + ", ".join(f"{s} {v['files']} runs {v['records']} records"
                                      for s, v in rep["sets"].items()))
    tf = a.out / "times.json"
    if tf.exists():
        rep["times"] = json.loads(tf.read_text())

    # Instructions by mnemonic and mode.
    uni = insn_universe()
    exe = collections.defaultdict(collections.Counter)    # mnemonic -> mode -> executed count
    trp = collections.defaultdict(collections.Counter)    # mnemonic -> cause -> count
    by_set = collections.defaultdict(set)
    csr = collections.Counter()                           # (addr, kind, mode, outcome)
    for s, (keys, _, _) in per_set.items():
        for k, n in keys.items():
            if k >> 60 != 1:
                continue
            w, mode, lvl, cause = field(k, 0, 32), MODES[field(k, 32, 3)], field(k, 35, 2), field(k, 37, 6)
            m = names[w]
            # ecall and ebreak complete by trapping.
            done = lvl and ((m == "ecall" and cause in (8, 9, 10, 11)) or (m in ("ebreak", "c.ebreak") and cause == 3))
            if lvl and not done:
                trp[m][cause] += n
            else:
                exe[m][mode] += n
                by_set[m].add(s)
            if w & 0x7f == 0x73 and (w >> 12) & 3:
                f3, rs1, addr = (w >> 12) & 7, (w >> 15) & 31, w >> 20
                kind = "write" if f3 & 3 == 1 else ("read" if rs1 == 0 else ("set" if f3 & 3 == 2 else "clear"))
                out = "ok" if not lvl else {2: "illegal", 22: "virtual"}.get(cause, f"cause{cause}")
                csr[(addr, kind, mode, out)] += n
    hit = [m for m in uni if exe.get(m)]
    holes = [m for m in uni if not exe.get(m)]
    trapped_only = [m for m in holes if trp.get(m)]
    outside = sorted(m for m in exe if m not in uni)
    per_mode = {md: sum(1 for m in uni if exe.get(m, {}).get(md)) for md in MODE_ORDER}
    rep["insn"] = {
        "universe": len(uni), "hit": len(hit), "holes": holes, "trapped_only": trapped_only,
        "outside_universe": {m: dict(exe[m]) for m in outside},
        "per_mode": per_mode,
        "by_mnemonic": {m: {"exec": dict(exe.get(m, {})), "trap": {str(c): n for c, n in trp.get(m, {}).items()},
                            "sets": sorted(by_set.get(m, ()))} for m in uni},
    }
    lines += ["", f"instructions: {len(hit)}/{len(uni)} implemented mnemonics executed ({pct(len(hit), len(uni))})"]
    lines.append("  per mode: " + ", ".join(f"{md} {per_mode[md]}" for md in MODE_ORDER))
    lines.append(f"  never executed ({len(holes)}): {' '.join(holes)}")
    if trapped_only:
        lines.append(f"  of those, seen only trapping: {' '.join(trapped_only)}")
    if outside:
        lines.append(f"  executed outside the universe: {' '.join(outside)}")

    # Instruction classes by mode.
    def iclass(m):
        if m in uni and m in vec.VEC_MNEMONICS:
            c = vclass(m)
            return "vector-mem" if c and c[0].startswith(("vld", "vst", "vmask-ls")) or (c is None and m.startswith(("vl", "vs"))) else "vector"
        if m.startswith(("hlv", "hsv")):
            return "hlv/hsv"
        if m.startswith(("hfence", "hinval")):
            return "hfence"
        if m.startswith(("sfence", "sinval")):
            return "sfence"
        if m in ("mret", "sret", "dret"):
            return "xret"
        if m in ("wfi", "wrs.nto", "wrs.sto"):
            return "wait"
        if m in ("ecall", "ebreak", "c.ebreak"):
            return "ecall/ebreak"
        if m.startswith("csrr"):
            return "csr"
        if m.startswith("cbo") or m.startswith("prefetch"):
            return "cmo"
        if m.startswith(("lr.", "sc.")):
            return "lr/sc"
        if m.startswith("amo"):
            return "amo"
        if m in ("flw", "fld", "flh", "fsw", "fsd", "fsh", "c.fld", "c.fsd", "c.fldsp", "c.fsdsp"):
            return "fp-mem"
        if m.startswith("f") and not m.startswith("fence"):
            return "fp"
        if re.match(r"(c\.)?(l[bhwd]u?|s[bhwd])(sp)?$", m):
            return "int-mem"
        if m.startswith("fence"):
            return "fence"
        return "int"
    cls_mode = collections.defaultdict(collections.Counter)
    for m, md in exe.items():
        if m in uni:
            for mode, n in md.items():
                cls_mode[iclass(m)][mode] += n
    rep["insn_class_mode"] = {c: dict(v) for c, v in sorted(cls_mode.items())}
    # Modes in which each class can execute without a trap.
    can = {"xret": ("M", "HS", "VS"), "hfence": ("M", "HS"), "hlv/hsv": ("M", "HS", "U"),
           "sfence": ("M", "HS", "VS"), "wait": ("M", "HS", "VS")}
    cm_holes = [f"{c}@{md}" for c in sorted(set(map(iclass, uni)))
                for md in can.get(c, ALL5) if not cls_mode[c].get(md)]
    rep["insn_class_mode_holes"] = cm_holes
    lines.append("  class x mode holes: " + (" ".join(cm_holes) or "none"))

    # Traps.
    exc, irq = collections.Counter(), collections.Counter()
    for k, n in allk.items():
        if k >> 60 != 5:
            continue
        c, src, lvl, intr = field(k, 0, 6), MODES[field(k, 6, 3)], LEVELS.get(field(k, 9, 2), "?"), field(k, 11, 1)
        (irq if intr else exc)[(c, src, lvl)] += n
    eu, iu = exc_universe(), irq_universe()
    eh = sorted(eu - set(exc), key=lambda t: (t[0], MODE_ORDER.index(t[1]), t[2]))
    ih = sorted(iu - set(irq), key=lambda t: (t[0], MODE_ORDER.index(t[1]), t[2]))
    eo = sorted(set(exc) - eu)
    io = sorted(set(irq) - iu)
    rep["traps"] = {
        "exceptions": {f"{c}:{s}>{lv}": n for (c, s, lv), n in sorted(exc.items())},
        "interrupts": {f"{c}:{s}>{lv}": n for (c, s, lv), n in sorted(irq.items())},
        "exception_universe": len(eu), "exception_hit": len(eu & set(exc)),
        "exception_holes": [f"{c}:{s}>{lv}" for c, s, lv in eh],
        "interrupt_universe": len(iu), "interrupt_hit": len(iu & set(irq)),
        "interrupt_holes": [f"{c}:{s}>{lv}" for c, s, lv in ih],
        "outside_universe": [f"{c}:{s}>{lv}" for c, s, lv in eo + io],
        "unreachable": TRAP_UNREACHABLE,
    }
    lines += ["", f"exceptions (cause:source>level): {len(eu & set(exc))}/{len(eu)} ({pct(len(eu & set(exc)), len(eu))})"]
    lines.append("  holes: " + " ".join(f"{c}:{s}>{lv}" for c, s, lv in eh))
    lines.append(f"interrupts: {len(iu & set(irq))}/{len(iu)} ({pct(len(iu & set(irq)), len(iu))})")
    lines.append("  holes: " + " ".join(f"{c}:{s}>{lv}" for c, s, lv in ih))
    if eo or io:
        lines.append("  outside the universe: " + " ".join(f"{c}:{s}>{lv}" for c, s, lv in eo + io))

    # CSRs.
    cu = csr_universe()
    rows, never, no_write, no_set, no_clear, no_deny = {}, [], [], [], [], []
    for addr in cu:
        acc = {(kd, md, o): n for (ad, kd, md, o), n in csr.items() if ad == addr}
        ro = addr >> 10 == 3
        ok = {kd for (kd, md, o) in acc if o == "ok"}
        rows[csr_name(addr)] = {f"{kd}:{md}:{o}": n for (kd, md, o), n in sorted(acc.items())}
        if not acc:
            never.append(csr_name(addr))
            continue
        if not ro:
            if "write" not in ok:
                no_write.append(csr_name(addr))
            if "set" not in ok:
                no_set.append(csr_name(addr))
            if "clear" not in ok:
                no_clear.append(csr_name(addr))
        den = csr_denied_modes(addr)
        if den and not any(md in den and o in ("illegal", "virtual") for (_, md, o) in acc):
            no_deny.append(csr_name(addr))
    outside = sorted({ad for (ad, kd, md, o) in csr if ad not in cu and o == "ok"})
    rep["csr"] = {"universe": len(cu), "accessed": len(cu) - len(never), "never": never,
                  "never_written": no_write, "never_set": no_set, "never_cleared": no_clear,
                  "never_denied": no_deny, "ok_outside_universe": [f"{a:#05x}" for a in outside], "by_csr": rows}
    lines += ["", f"CSRs: {len(cu) - len(never)}/{len(cu)} implemented addresses accessed "
                  f"({pct(len(cu) - len(never), len(cu))})"]
    lines.append(f"  never accessed ({len(never)}): {' '.join(never)}")
    lines.append(f"  writable, never written ({len(no_write)}): {' '.join(no_write)}")
    lines.append(f"  writable, never set ({len(no_set)}): {' '.join(no_set)}")
    lines.append(f"  writable, never cleared ({len(no_clear)}): {' '.join(no_clear)}")
    lines.append(f"  never refused from a less privileged mode ({len(no_deny)}): {' '.join(no_deny)}")
    if outside:
        lines.append(f"  accessed without a trap outside csr_exists: {' '.join(f'{a:#05x}' for a in outside)}")

    # Vector lattice.
    vcells = collections.defaultdict(collections.Counter)  # class -> (sew, lmul) -> n
    vtama = collections.defaultdict(collections.Counter)
    vlcls = collections.defaultdict(collections.Counter)
    vstart = collections.Counter()
    vmodes = collections.defaultdict(collections.Counter)
    infos = {}
    for k, n in allk.items():
        if k >> 60 != 2 or field(k, 47, 1):
            continue
        m = names[field(k, 0, 32)]
        info = vclass(m)
        if info is None:
            continue
        c = info[0]
        infos.setdefault(c, set()).add(m)
        vt = field(k, 32, 9)
        if vt >> 8:
            vlcls[c]["vill"] += n
            continue
        sew, lm = 8 << ((vt >> 3) & 7), vt & 7
        vcells[c][(sew, lm)] += n
        vtama[c][f"ta{(vt >> 6) & 1}ma{(vt >> 7) & 1}"] += n
        vlcls[c][["vl0", "vl<vlmax", "vl=vlmax", "?"][field(k, 41, 2)]] += n
        vmodes[c][MODES[field(k, 44, 3)]] += n
        if field(k, 43, 1):
            vstart[c] += n
    vrep, vlines = {}, []
    all_cls = sorted({vclass(m)[0] for m in vec.VEC_MNEMONICS if vclass(m)})
    for c in all_cls:
        legal = set()
        for m in vec.VEC_MNEMONICS:
            info = vclass(m)
            if info and info[0] == c:
                legal |= {(8 << s, lm) for s in range(4) for lm in LMULS if legal_cell(c, 8 << s, lm, info)}
        got = set(vcells[c])
        miss = sorted(legal - got, key=lambda t: (t[0], LMULS[t[1]]))
        vrep[c] = {"cells_legal": len(legal), "cells_hit": len(legal & got),
                   "missing": [f"e{s}{LMUL_NAME[lm]}" for s, lm in miss],
                   "ta_ma": dict(vtama[c]), "vl": dict(vlcls[c]), "vstart_nonzero": vstart[c],
                   "modes": dict(vmodes[c])}
        missing_tama = [t for t in ("ta0ma0", "ta0ma1", "ta1ma0", "ta1ma1") if not vtama[c].get(t)]
        missing_vl = [t for t in ("vl0", "vl<vlmax", "vl=vlmax") if not vlcls[c].get(t)]
        vrep[c]["missing_ta_ma"] = missing_tama
        vrep[c]["missing_vl"] = missing_vl
        vrep[c]["missing_modes"] = [md for md in ALL5 if not vmodes[c].get(md)]
        vlines.append(f"  {c}: SEWxLMUL {len(legal & got)}/{len(legal)}"
                      + (f" missing {' '.join(vrep[c]['missing'])}" if miss else "")
                      + (f"; ta/ma missing {' '.join(missing_tama)}" if missing_tama else "")
                      + (f"; vl missing {' '.join(missing_vl)}" if missing_vl else "")
                      + (f"; modes missing {' '.join(vrep[c]['missing_modes'])}" if vrep[c]['missing_modes'] else "")
                      + f"; vstart!=0 {vstart[c]}")
    rep["vector"] = vrep
    tot_l = sum(v["cells_legal"] for v in vrep.values())
    tot_h = sum(v["cells_hit"] for v in vrep.values())
    lines += ["", f"vtype lattice (class x SEW x LMUL, executed): {tot_h}/{tot_l} ({pct(tot_h, tot_l)})"] + vlines

    # Memory.
    mem = collections.Counter()
    sc = collections.Counter()
    for k, n in allk.items():
        if k >> 60 == 3:
            mem[k & ((1 << 60) - 1)] += n
        elif k >> 60 == 4:
            sc[(field(k, 0, 3), field(k, 3, 1), MODES[field(k, 4, 3)])] += n
    xl = collections.Counter()
    span = collections.Counter()
    for k, n in mem.items():
        cls = MEM_CLASSES[field(k, 0, 4)]
        eff = {7: "HLV"}.get(field(k, 10, 3)) or MODES.get(field(k, 10, 3), "?")
        s1 = {15: "-", 0: "bare", 8: "sv39"}.get(field(k, 13, 4), str(field(k, 13, 4)))
        g = {15: "-", 0: "bare", 8: "sv39x4"}.get(field(k, 17, 4), str(field(k, 17, 4)))
        trap = field(k, 22, 1)
        xl[(cls, eff, s1, g, bool(field(k, 21, 1)), f"cause{field(k, 23, 6)}" if trap else "ok")] += n
        if field(k, 29, 1):
            span[(cls, 1 << field(k, 4, 3), bool(field(k, 7, 1)), bool(field(k, 8, 1)), bool(field(k, 9, 1)))] += n
    want_xl = []
    for cls in MEM_CLASSES:
        if cls in ("hlv", "hsv"):
            combos = [("HLV", s1, g) for s1 in ("bare", "sv39") for g in ("bare", "sv39x4")]
        else:
            combos = [("M", "-", "-")] + [(md, s1, "-") for md in ("HS", "U") for s1 in ("bare", "sv39")]
            combos += [(md, s1, g) for md in ("VS", "VU") for s1 in ("bare", "sv39") for g in ("bare", "sv39x4")]
        for e, s1, g in combos:
            want_xl.append((cls, e, s1, g))
    got_xl = {(c, e, s1, g) for (c, e, s1, g, _, o) in xl if o == "ok"}
    xl_holes = [f"{c}@{e}/{s1}/{g}" for c, e, s1, g in want_xl if (c, e, s1, g) not in got_xl]
    mprv = sorted({(c, e) for (c, e, s1, g, mp, o) in xl if mp and o == "ok"})
    sp_cls = ("load", "store", "fload", "fstore", "amo", "lr", "sc")
    mis = {c for (c, sz, mi, cr, io) in span if mi}
    cross = {c for (c, sz, mi, cr, io) in span if cr}
    iocls = {c for (c, sz, mi, cr, io) in span if io}
    rep["mem"] = {
        "translation": {f"{c}@{e}/{s1}/{g}{'/mprv' if mp else ''}:{o}": n for (c, e, s1, g, mp, o), n in
                        sorted(xl.items())},
        "translation_holes": xl_holes,
        "mprv": [f"{c}@{e}" for c, e in mprv],
        "span": {f"{c}/{sz}B{'/mis' if mi else ''}{'/cross' if cr else ''}{'/io' if io else ''}": n
                 for (c, sz, mi, cr, io), n in sorted(span.items())},
        "misaligned_classes": sorted(mis), "page_cross_classes": sorted(cross), "io_classes": sorted(iocls),
        "sc": {f"{'w' if w == 2 else 'd' if w == 3 else w}:{'fail' if f else 'ok'}:{md}": n
               for (w, f, md), n in sorted(sc.items())},
    }
    lines += ["", f"memory (class x effective mode x stage-1 x G-stage, performed): "
                  f"{len(want_xl) - len(xl_holes)}/{len(want_xl)} ({pct(len(want_xl) - len(xl_holes), len(want_xl))})"]
    lines.append("  holes: " + " ".join(xl_holes))
    lines.append("  MPRV in effect: " + " ".join(f"{c}@{e}" for c, e in mprv))
    lines.append("  misaligned performed: " + " ".join(sorted(mis)) + "; missing "
                 + " ".join(c for c in sp_cls if c not in mis and c not in ("amo", "lr", "sc")))
    lines.append("  page crossing performed: " + " ".join(sorted(cross)))
    lines.append("  device (io) accesses: " + " ".join(sorted(iocls)))
    lines.append("  SC outcomes: " + ", ".join(f"{k}={n}" for k, n in rep["mem"]["sc"].items()))

    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / "report.json").write_text(json.dumps(rep, indent=1, sort_keys=True) + "\n")
    (a.out / "summary.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["run", "report"])
    ap.add_argument("--out", type=Path, default=MASTER / ".build" / "cov")
    ap.add_argument("--sets", default=DEFAULT_SETS, help=f"comma-separated, of {', '.join(SETS)}")
    ap.add_argument("--core", default="w2")
    a = ap.parse_args()
    a.out = a.out.resolve()
    if a.cmd == "run":
        unknown = [s for s in a.sets.split(",") if s not in SETS]
        if unknown:
            ap.error(f"unknown set {' '.join(unknown)}")
        run_sets(a)
    report(a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
