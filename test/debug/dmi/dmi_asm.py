#!/usr/bin/env python3
"""Assemble a DMI script (.dmi) into the dm_seq hex image.

    test/debug/dmi/dmi_asm.py <in.dmi> <out.hex>

One command per line, `#` starts a comment. Numbers are C-style (0x.., decimal)
or @symbol[+-offset] (see SYMS); an address is a number or a DM register name
(dmcontrol, dmstatus, ...).

    WR   <addr> <data> [<strobes>]             (strobes default to 0xf)
    RD   <addr> <expect> [<mask>]              (mask defaults to all ones)
    POLL <addr> <expect> <mask> <max reads>
    WAIT <cycles>
    MARK <id>
    RDS  <addr> <slot>                         read and keep the value (slot 0-3)
    RDEQ <addr> <slot> [<mask>]                read; must equal the kept value
    RDNE <addr> <slot> [<mask>]                read; must differ from it
    END

Abstract command macros (Access Register, Debug Spec 3.7.1.1). <reg> is a
GPR (x5, a0, s0, ...), an FPR (f0-f31), a CSR name (dcsr, dpc, mstatus, ...)
or a number taken as the regno; a size-2 access is written <reg>.w.

    ACMD <command> [<cmderr>]   write command, wait for !busy, check cmderr
                                (default 0) and leave it set
    ARD  <reg> <lo> [<hi>]      read reg; data0 must be lo (and data1 hi)
    ARDM <reg> <lo> <mask>      read reg; data0 & mask must be lo
    ARDS <reg> <slot>           read reg; keep data0 in slot
    ARDEQ/ARDNE <reg> <slot>    read reg; data0 must equal / differ from slot
    AWR  <reg> <lo> [<hi>]      write reg from data0/data1 (hi defaults to 0)
    RESHALT                     resumereq hart 0, wait for resumeack, then
                                for halted (a step or an ebreak)
    SYMS <elf>                  take @symbols from this ELF (path relative to
                                test/debug)

Each command is one 128-bit line {op, addr, 16'd0, a, b, c} (see tb/dm_seq.veryl);
an END is appended.
"""

import os
import subprocess
import sys

OPS = {"END": 0, "WR": 1, "RD": 2, "POLL": 3, "WAIT": 4, "MARK": 5, "RDS": 6, "RDEQ": 7, "RDNE": 8}
DEPTH = 1024
BUSY_POLLS = 4000
REGS = {
    "data0": 0x04, "data1": 0x05,
    "dmcontrol": 0x10, "dmstatus": 0x11, "hartinfo": 0x12, "haltsum1": 0x13,
    "hawindowsel": 0x14, "hawindow": 0x15, "abstractcs": 0x16, "command": 0x17,
    "abstractauto": 0x18, "confstrptr0": 0x19, "nextdm": 0x1D,
    "progbuf0": 0x20, "progbuf1": 0x21, "progbuf2": 0x22, "progbuf3": 0x23, "progbuf4": 0x24,
    "progbuf5": 0x25, "progbuf6": 0x26, "progbuf7": 0x27, "authdata": 0x30, "dmcs2": 0x32, "haltsum2": 0x34,
    "haltsum3": 0x35, "sbaddress3": 0x37, "sbcs": 0x38, "sbaddress0": 0x39,
    "sbaddress1": 0x3A, "sbaddress2": 0x3B, "sbdata0": 0x3C, "sbdata1": 0x3D,
    "sbdata2": 0x3E, "sbdata3": 0x3F, "haltsum0": 0x40,
}
NARGS = {"END": (0, 0), "WR": (2, 3), "RD": (2, 3), "POLL": (4, 4), "WAIT": (1, 1), "MARK": (1, 1),
         "RDS": (2, 2), "RDEQ": (2, 3), "RDNE": (2, 3)}

ABI = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1"] + [f"a{i}" for i in range(8)] + \
    [f"s{i}" for i in range(2, 12)] + [f"t{i}" for i in range(3, 7)]
CSRS = {
    "fflags": 0x001, "frm": 0x002, "fcsr": 0x003, "sstatus": 0x100, "satp": 0x180,
    "mstatus": 0x300, "misa": 0x301, "mie": 0x304, "mtvec": 0x305, "mscratch": 0x340, "mepc": 0x341,
    "mcause": 0x342, "mtval": 0x343, "mip": 0x344, "dcsr": 0x7B0, "dpc": 0x7B1, "dscratch0": 0x7B2,
    "dscratch1": 0x7B3, "mcycle": 0xB00, "minstret": 0xB02, "cycle": 0xC00, "time": 0xC01,
    "instret": 0xC02, "mhartid": 0xF14,
}
SYMS = {}


def num(s):
    if s.startswith("@"):
        name, off = s[1:], 0
        for sep in "+-":
            if sep in name:
                name, o = name.split(sep, 1)
                off = int(o, 0) * (1 if sep == "+" else -1)
                break
        if name not in SYMS:
            raise ValueError(f"unknown symbol {name!r}")
        return (SYMS[name] + off) & 0xFFFFFFFF
    return int(s, 0)


def load_syms(path):
    out = subprocess.run(["riscv64-unknown-elf-nm", path], check=True, capture_output=True, text=True).stdout
    for line in out.splitlines():
        f = line.split()
        if len(f) == 3:
            SYMS[f[2]] = int(f[0], 16)


def regno(s):
    """Access Register regno and aarsize of a register operand."""
    size = 3
    if s.endswith(".w"):
        s, size = s[:-2], 2
    k = s.lower()
    if k in ABI:
        return 0x1000 + ABI.index(k), size
    if k == "fp":
        return 0x1008, size
    if k[0] in "xf" and k[1:].isdigit() and int(k[1:]) < 32:
        return (0x1000 if k[0] == "x" else 0x1020) + int(k[1:]), size
    if k in CSRS:
        return CSRS[k], size
    return num(s), size


def access(reg, write):
    r, size = regno(reg)
    return (size << 20) | (1 << 17) | ((1 if write else 0) << 16) | r


def expand(op, args):
    """Abstract command macros as primitive commands."""
    def acmd(cmd, err=0):
        return [("WR", ["command", str(cmd)]),
                ("POLL", ["abstractcs", "0", "0x1000", str(BUSY_POLLS)]),
                ("RD", ["abstractcs", str(err << 8), "0x700"])]
    if op == "RESHALT":
        return [("WR", ["dmcontrol", "0x40000001"]),
                ("POLL", ["dmstatus", "0x20000", "0x20000", str(BUSY_POLLS)]),
                ("POLL", ["dmstatus", "0x300", "0x300", str(BUSY_POLLS)])]
    if op == "ACMD":
        return acmd(num(args[0]), num(args[1]) if len(args) > 1 else 0)
    if op == "AWR":
        hi = args[2] if len(args) > 2 else "0"
        return [("WR", ["data0", args[1]]), ("WR", ["data1", hi])] + acmd(access(args[0], True))
    rd = acmd(access(args[0], False))
    if op == "ARD":
        return rd + [("RD", ["data0", args[1]])] + ([("RD", ["data1", args[2]])] if len(args) > 2 else [])
    if op == "ARDM":
        return rd + [("RD", ["data0", args[1], args[2]])]
    if op == "ARDS":
        return rd + [("RDS", ["data0", args[1]])]
    return rd + [("RDEQ" if op == "ARDEQ" else "RDNE", ["data0", args[1]])]


MACROS = {"ACMD": (1, 2), "AWR": (2, 3), "ARD": (2, 3), "ARDM": (3, 3), "ARDS": (2, 2), "ARDEQ": (2, 2),
          "ARDNE": (2, 2), "RESHALT": (0, 0)}


def addr(s):
    v = REGS.get(s.lower())
    v = num(s) if v is None else v
    if not 0 <= v < 0x80:
        raise ValueError(f"DMI address out of range: {s}")
    return v


def assemble(lines, where):
    cmds = []
    for n, raw in enumerate(lines, 1):
        f = raw.split("#", 1)[0].split()
        if not f:
            continue
        op, args = f[0].upper(), f[1:]
        try:
            if op == "SYMS":
                load_syms(os.path.join(os.path.dirname(os.path.abspath(where)), "..", args[0]))
            elif op in MACROS:
                lo, hi = MACROS[op]
                if not lo <= len(args) <= hi:
                    raise ValueError(f"{op} takes {lo}..{hi} operands")
                cmds += [(n, o, a) for o, a in expand(op, args)]
            else:
                cmds.append((n, op, args))
        except ValueError as e:
            raise ValueError(f"{where}:{n}: {e}") from None
    out = []
    for n, op, args in cmds:
        if op not in OPS:
            raise ValueError(f"{where}:{n}: unknown command {op!r}")
        lo, hi = NARGS[op]
        if not lo <= len(args) <= hi:
            raise ValueError(f"{where}:{n}: {op} takes {lo}..{hi} operands")
        ad, a, b, c = 0, 0, 0, 0
        try:
            if op == "WR":
                ad, a = addr(args[0]), num(args[1])
                b = num(args[2]) if len(args) == 3 else 0xF
                if b > 0xF:
                    raise ValueError("strobes are 4 bits")
            elif op == "RD":
                ad, a = addr(args[0]), num(args[1])
                b = num(args[2]) if len(args) == 3 else 0xFFFFFFFF
            elif op == "POLL":
                ad, a, b, c = addr(args[0]), num(args[1]), num(args[2]), num(args[3])
                if c < 1:
                    raise ValueError("POLL needs at least one read")
            elif op in ("WAIT", "MARK"):
                a = num(args[0])
            elif op in ("RDS", "RDEQ", "RDNE"):
                ad, a = addr(args[0]), num(args[1])
                b = num(args[2]) if len(args) == 3 else 0xFFFFFFFF
                if a > 3:
                    raise ValueError("slots are 0-3")
            for v in (a, b, c):
                if not 0 <= v <= 0xFFFFFFFF:
                    raise ValueError("operand out of 32-bit range")
        except ValueError as e:
            raise ValueError(f"{where}:{n}: {e}") from None
        out.append(f"{OPS[op]:02x}{ad:02x}0000{a:08x}{b:08x}{c:08x}")
        if op == "END":
            break
    else:
        out.append("0" * 32)
    return out


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    with open(src) as fh:
        lines = assemble(fh.read().splitlines(), src)
    if len(lines) > DEPTH:
        print(f"{src}: {len(lines)} commands, dm_seq holds {DEPTH}", file=sys.stderr)
        return 1
    with open(dst, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
