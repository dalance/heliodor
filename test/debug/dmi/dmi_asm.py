#!/usr/bin/env python3
"""Assemble a DMI script (.dmi) into the dm_seq hex image.

    test/debug/dmi/dmi_asm.py <in.dmi> <out.hex>

One command per line, `#` starts a comment. Numbers are C-style (0x.., decimal);
an address is a number or a DM register name (dmcontrol, dmstatus, ...).

    WR   <addr> <data> [<strobes>]             (strobes default to 0xf)
    RD   <addr> <expect> [<mask>]              (mask defaults to all ones)
    POLL <addr> <expect> <mask> <max reads>
    WAIT <cycles>
    MARK <id>
    END

Each command is one 128-bit line {op, addr, 16'd0, a, b, c} (see tb/dm_seq.veryl);
an END is appended.
"""

import sys

OPS = {"END": 0, "WR": 1, "RD": 2, "POLL": 3, "WAIT": 4, "MARK": 5}
REGS = {
    "data0": 0x04, "data1": 0x05,
    "dmcontrol": 0x10, "dmstatus": 0x11, "hartinfo": 0x12, "haltsum1": 0x13,
    "hawindowsel": 0x14, "hawindow": 0x15, "abstractcs": 0x16, "command": 0x17,
    "abstractauto": 0x18, "confstrptr0": 0x19, "nextdm": 0x1D,
    "progbuf0": 0x20, "authdata": 0x30, "dmcs2": 0x32, "haltsum2": 0x34,
    "haltsum3": 0x35, "sbaddress3": 0x37, "sbcs": 0x38, "sbaddress0": 0x39,
    "sbaddress1": 0x3A, "sbaddress2": 0x3B, "sbdata0": 0x3C, "sbdata1": 0x3D,
    "sbdata2": 0x3E, "sbdata3": 0x3F, "haltsum0": 0x40,
}
NARGS = {"END": (0, 0), "WR": (2, 3), "RD": (2, 3), "POLL": (4, 4), "WAIT": (1, 1), "MARK": (1, 1)}


def num(s):
    return int(s, 0)


def addr(s):
    v = REGS.get(s.lower())
    v = num(s) if v is None else v
    if not 0 <= v < 0x80:
        raise ValueError(f"DMI address out of range: {s}")
    return v


def assemble(lines, where):
    out = []
    for n, raw in enumerate(lines, 1):
        f = raw.split("#", 1)[0].split()
        if not f:
            continue
        op = f[0].upper()
        if op not in OPS:
            raise ValueError(f"{where}:{n}: unknown command {f[0]!r}")
        lo, hi = NARGS[op]
        args = f[1:]
        if not lo <= len(args) <= hi:
            raise ValueError(f"{where}:{n}: {op} takes {lo}..{hi} operands")
        ad, a, b, c = 0, 0, 0, 0
        if op == "WR":
            ad, a = addr(args[0]), num(args[1])
            b = num(args[2]) if len(args) == 3 else 0xF
            if b > 0xF:
                raise ValueError(f"{where}:{n}: strobes are 4 bits")
        elif op == "RD":
            ad, a = addr(args[0]), num(args[1])
            b = num(args[2]) if len(args) == 3 else 0xFFFFFFFF
        elif op == "POLL":
            ad, a, b, c = addr(args[0]), num(args[1]), num(args[2]), num(args[3])
            if c < 1:
                raise ValueError(f"{where}:{n}: POLL needs at least one read")
        elif op in ("WAIT", "MARK"):
            a = num(args[0])
        for v in (a, b, c):
            if not 0 <= v <= 0xFFFFFFFF:
                raise ValueError(f"{where}:{n}: operand out of 32-bit range")
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
    if len(lines) > 256:
        print(f"{src}: {len(lines)} commands, dm_seq holds 256", file=sys.stderr)
        return 1
    with open(dst, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
