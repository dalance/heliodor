#!/usr/bin/env python3
"""Order SV files so every package is compiled before its first use.

Vivado's non-project flow compiles files in the order given; heliodor.f is not
in package dependency order. Reads a file list on stdin, writes it on stdout.
"""
import re
import sys

files = [l.strip() for l in sys.stdin if l.strip()]
pkg_def = re.compile(r'^\s*package\s+(\w+)\s*;', re.M)
pkg_use = re.compile(r'\b(\w+)::')
defs, uses = {}, {}
owner = {}
for f in files:
    text = open(f).read()
    defs[f] = set(pkg_def.findall(text))
    uses[f] = set(pkg_use.findall(text))
    for p in defs[f]:
        owner[p] = f
deps = {f: {owner[p] for p in uses[f] if p in owner and owner[p] != f} for f in files}

out, state = [], {}


def visit(f):
    if state.get(f) == 2:
        return
    if state.get(f) == 1:
        sys.exit(f'package cycle through {f}')
    state[f] = 1
    for d in sorted(deps[f], key=files.index):
        visit(d)
    state[f] = 2
    out.append(f)


for f in files:
    visit(f)
print('\n'.join(out))
