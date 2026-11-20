#!/usr/bin/env python3
"""Aggregate a cells.tcl dump by hierarchy or by signal.

  cells.py <dump> hier <prefix> [depth]   LUT/FF/LUTRAM/CARRY/MUXF/DSP per child
  cells.py <dump> sig <prefix> [fields]   the same per signal stem in <prefix>

Signal stems come from cell names: Vivado names a register after its signal
(`ent_q_reg[3][pdst][2]`) and most LUTs after the net they drive, so a stem
groups the storage and the logic that computes or reads one signal. Indices
become [], and `fields` keeps that many struct field levels.

Counts are primitive cells, so LUT runs somewhat above report_utilization,
which counts a LUT6_2 pair once; LUTRAM counts one per RAMD/RAMS primitive.
"""
import re
import signal
import sys
from collections import defaultdict

KINDS = ('LUT', 'FF', 'LUTRAM', 'CARRY', 'MUXF', 'DSP', 'BRAM')


def kind(ref):
    if ref.startswith('LUT'):
        return 'LUT'
    if ref.startswith('FD'):
        return 'FF'
    if ref.startswith('RAMD') or ref.startswith('RAMS'):
        return 'LUTRAM'
    if ref.startswith('RAMB'):
        return 'BRAM'
    if ref.startswith('CARRY'):
        return 'CARRY'
    if ref.startswith('MUXF'):
        return 'MUXF'
    if ref == 'DSP_ALU':  # one per DSP48E2 macro
        return 'DSP'
    return None


def split_path(name):
    # Split on '/' outside brackets; escaped generate names keep their dots.
    parts, depth, cur = [], 0, ''
    for ch in name:
        if ch == '[':
            depth += 1
        elif ch == ']':
            depth -= 1
        if ch == '/' and depth == 0:
            parts.append(cur)
            cur = ''
        else:
            cur += ch
    parts.append(cur)
    return [p.lstrip('\\').rstrip(' ') for p in parts]


SUFFIX = re.compile(r'(_reg|_i_\d+|_INST_0|__\d+|_rep|_replica|_bret|_inv|_lopt)+$')


def stem(leaf, fields):
    s = leaf
    while True:
        t = SUFFIX.sub('', s)
        t = re.sub(r'(_reg|_i_\d+|_INST_0|__\d+)(?=\[)', '', t)
        if t == s:
            break
        s = t
    out = re.sub(r'\[\d+\]', '[]', s)
    out = re.sub(r'\[\]((\[\])+)', '[]', out)
    names = re.findall(r'\[([A-Za-z_]\w*)\]', out)
    base = re.split(r'\[', out)[0]
    base = re.sub(r'_(i|INST)_\d+.*$', '', base)
    return '.'.join([base] + names[:fields])


def main():
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    dump, mode, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
    arg = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    pre = split_path(prefix) if prefix else []
    acc = defaultdict(lambda: defaultdict(int))
    for line in open(dump):
        ref, name = line.rstrip('\n').split(' ', 1)
        k = kind(ref)
        if not k:
            continue
        p = split_path(name)
        if p[:len(pre)] != pre:
            continue
        rest = p[len(pre):]
        if mode == 'hier':
            key = '/'.join(rest[:arg]) if len(rest) > arg else '(' + '/'.join(rest[:-1]) + ')'
        else:
            key = stem(rest[-1], arg) if len(rest) >= 1 else '?'
            if len(rest) > 1:
                key = rest[0] + '/' + key
        acc[key][k] += 1
        acc['TOTAL'][k] += 1
    rows = sorted(acc.items(), key=lambda kv: -(kv[1]['LUT'] + kv[1]['FF'] + kv[1]['LUTRAM']))
    print(f"{'key':60s} " + ' '.join(f'{k:>7s}' for k in KINDS))
    for key, v in rows:
        print(f'{key[:60]:60s} ' + ' '.join(f'{v[k]:7d}' for k in KINDS))


main()
