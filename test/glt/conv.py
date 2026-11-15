"""Turn a list of litmus tests into one bare-metal program for heliodor.

All harts boot at 0x8000_0000 in M-mode and run every test of the program
in order. A test runs `iters` iterations. In each one hart 0 resets the
locations, a sense-reversing barrier releases the harts, each hart waits a
pseudo-random delay (a 16-bit LFSR per hart) and runs its thread with the
registers set to the test's initial values, then stores the registers the
model observes. After a second barrier hart 0 reads the final memory values
and the other harts' registers, packs every observed value into a field of a
64-bit key (the field holds the index of the value among the values the
model allows for that variable, or an escape index), and counts the key in
the test's table of allowed final states. A key not in the table is a
forbidden outcome: up to FORB distinct ones are counted and the raw values
of the first one are kept. At the end hart 0 prints every table on the UART
and writes tohost = 1, or 3 if any forbidden outcome was seen. A trap on any
hart prints the hart, mcause, mepc and mtval and writes tohost = 5.
"""

import re
import subprocess

import litmus

UART = 0x1000_0000
BARRIER = 0x8000_4000
CTX = 0x8000_5000          # per hart, CTX_STRIDE apart
CTX_STRIDE = 0x400
OBS = 0x40                 # observed registers inside a hart's context
RAW = 0x8000_6000          # hart 0: the values of the current iteration
FAIL = 0x8000_6800
VARS = 0x8000_8000         # one 64-byte line per location
TEXT = 0x8001_0000
FORB = 4
MARCH = "rv64ima_zicsr_zifencei"
FREE_ORDER = [31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5,
              4, 3, 2, 1]
LOAD = {(1, True): "lb", (1, False): "lbu", (2, True): "lh", (2, False): "lhu", (4, True): "lw",
        (4, False): "lwu", (8, True): "ld", (8, False): "ld"}
STORE = {1: "sb", 2: "sh", 4: "sw", 8: "sd"}


class Unsupported(Exception):
    pass


def _thread_regs(lines, init):
    used = set(init)
    for ln in lines:
        if ln.endswith(":"):
            continue
        for tok in litmus.REG.findall(ln):
            used.add(litmus.regnum(tok))
    used.discard(0)
    return used


def _labels(lines):
    return {ln[:-1].strip() for ln in lines if ln.endswith(":")}


def plan(test, herd):
    """Check the test against the model's result and lay out its key."""
    vars_ = []
    for v in herd.vars:
        p, _, r = v.partition(":")
        if r:
            vars_.append(("reg", int(p), litmus.regnum(r)))
        else:
            loc = v.strip("[]")
            if loc not in test.locs:
                raise Unsupported(f"observed location {v} is not declared")
            vars_.append(("mem", loc))
    values = [[] for _ in vars_]
    for s in herd.states:
        for i, v in enumerate(s):
            if isinstance(v, str):
                v = v.strip("[]")
                if v not in test.locs:
                    raise Unsupported(f"state value {v} is not a location")
                v = ("addr", v)
            if v not in values[i]:
                values[i].append(v)
    bits, shift = [], 0
    for vs in values:
        b = max(1, len(vs).bit_length())
        bits.append((shift, b))
        shift += b
    if shift > 63:
        raise Unsupported(f"key needs {shift} bits")

    def key(state):
        k = 0
        for i, v in enumerate(state):
            if isinstance(v, str):
                v = ("addr", v.strip("[]"))
            k |= values[i].index(v) << bits[i][0]
        return k

    keys = sorted(key(s) for s in herd.states)
    if len(set(keys)) != len(keys):
        raise Unsupported("two states share a key")
    return {"vars": vars_, "values": values, "bits": bits, "keys": keys}


def _li(rd, v, loc_addr):
    if isinstance(v, tuple) and v[0] == "addr":
        return [f"    li {rd}, {loc_addr[v[1]]:#x}"]
    return [f"    li {rd}, {v}"]


def emit_test(k, test, pl, nh, iters):
    """Assembly of test k, run by every hart."""
    loc_addr = {loc: VARS + 64 * i for i, loc in enumerate(test.locs)}
    if len(loc_addr) > 64:
        raise Unsupported("more than 64 locations")
    obs = {p: [v[2] for v in pl["vars"] if v[0] == "reg" and v[1] == p] for p in range(test.n_threads)}
    a = [f"# test {k}: {test.name}", f"T{k}:", f"    li s1, {iters}", f"T{k}_loop:", f"    bnez s0, T{k}_rst"]
    for loc, (size, _, init) in test.locs.items():
        a += _li("t0", init, loc_addr) + [f"    li t1, {loc_addr[loc]:#x}", "    sd x0, 0(t1)",
                                           f"    {STORE[size]} t0, 0(t1)"]
    a += ["    fence rw, rw", f"T{k}_rst:", "    call barrier", "    call jitter"]
    for p in range(test.n_threads):
        a += [f"    li t0, {p}", f"    beq s0, t0, T{k}_h{p}"]
    a += [f"    j T{k}_sync"]
    for p, lines in enumerate(test.threads):
        init = test.reg_init[p]
        regs = _thread_regs(lines, init) | set(obs[p])
        free = next((r for r in FREE_ORDER if r not in regs), None)
        if free is None:
            raise Unsupported(f"thread {p} uses every register")
        labels = _labels(lines)

        def ren(s, p=p, labels=labels):
            return re.sub(r"\b(" + "|".join(map(re.escape, labels)) + r")\b", lambda m: f"L{k}_{p}_{m.group(1)}",
                          s) if labels else s

        a += [f"T{k}_h{p}:", "    sd s1, 0(s2)", "    sd s6, 8(s2)", "    sd s7, 16(s2)"]
        for r in sorted(regs - set(init)):
            a.append(f"    li x{r}, 0")
        for r, v in sorted(init.items()):
            if isinstance(v, tuple) and v[0] == "label":
                a.append(f"    la x{r}, L{k}_{v[1]}_{v[2]}")
            else:
                a += _li(f"x{r}", v, loc_addr)
        for ln in lines:
            if re.search(r"\b(lb|lh|lw|ld|sb|sh|sw|sd)\.(aq|rl)", ln):
                raise Unsupported("Zalasr")
            ln = re.sub(r"\.aq\.rl\b", ".aqrl", ln)
            a.append(("" if ln.endswith(":") else "    ") + ren(ln))
        a.append(f"    csrr x{free}, mscratch")
        a += [f"    sd x{r}, {OBS + 8 * i}(x{free})" for i, r in enumerate(obs[p])]
        a += [f"    mv s2, x{free}", "    ld s1, 0(s2)", "    ld s6, 8(s2)", "    ld s7, 16(s2)",
              "    csrr s0, mhartid", f"    li s3, {BARRIER:#x}", f"    j T{k}_sync"]
    a += [f"T{k}_sync:", "    call barrier", f"    bnez s0, T{k}_next", "    li a0, 0", f"    li a5, {RAW:#x}"]
    for i, var in enumerate(pl["vars"]):
        if var[0] == "reg":
            p, r = var[1], var[2]
            a += [f"    li t4, {CTX + p * CTX_STRIDE + OBS + 8 * obs[p].index(r):#x}", "    ld t0, 0(t4)"]
        else:
            size, signed, _ = test.locs[var[1]]
            a += [f"    li t4, {loc_addr[var[1]]:#x}", f"    {LOAD[(size, signed)]} t0, 0(t4)"]
        sh, _ = pl["bits"][i]
        a += [f"    sd t0, {8 * i}(a5)", f"    li t2, {len(pl['values'][i])}"]
        for j, v in enumerate(pl["values"][i]):
            a += _li("t1", v, loc_addr) + [f"    bne t0, t1, T{k}_v{i}_{j}", f"    li t2, {j}", f"    j T{k}_v{i}",
                                           f"T{k}_v{i}_{j}:"]
        a += [f"T{k}_v{i}:", f"    slli t2, t2, {sh}", "    or a0, a0, t2"]
    a += [f"    la a1, TAB{k}", f"    li a2, {len(pl['vars'])}", "    call lookup", f"T{k}_next:",
          "    addi s1, s1, -1", f"    bnez s1, T{k}_loop"]
    return a


def table_words(pl):
    """Dwords of a test's table after the key list: counts, forbidden table, raw."""
    n = len(pl["keys"])
    return n + 1 + 2 * FORB + 1 + len(pl["vars"])


COMMON = r"""
    .section .text.init
    .globl _start
_start:
    la t0, trap
    csrw mtvec, t0
    csrr s0, mhartid
    li s2, {ctx:#x}
    li t0, {ctx_stride}
    mul t0, t0, s0
    add s2, s2, t0
    csrw mscratch, s2
    li s3, {barrier:#x}
    li s7, 0
    li s6, {seed:#x}
    li t0, 0x1234
    mul t0, t0, s0
    add s6, s6, t0
    li t0, 0xffff
    and s6, s6, t0
    bnez s6, 1f
    li s6, 1
1:
    la t0, main
    jr t0

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost: .dword 0
    .globl fromhost
fromhost: .dword 0

    .text
# Sense-reversing barrier over {nh} harts. The last hart to arrive leaves
# first, so it returns t3 = {skew} extra delay iterations, the others t3 = 0.
# Clobbers t0-t3.
barrier:
    xori s7, s7, 1
    li t1, 1
    amoadd.w.aqrl t0, t1, 0(s3)
    li t2, {nh_m1}
    li t3, 0
    bne t0, t2, 2f
    sw x0, 0(s3)
    fence rw, w
    sw s7, 64(s3)
    li t3, {skew}
    j 3f
2:
    lw t0, 64(s3)
    bne t0, s7, 2b
3:
    fence rw, rw
    ret

# t3 + 0..{jmask} iterations of delay; steps the LFSR in s6. Clobbers t0, t1.
jitter:
    andi t0, s6, 1
    srli s6, s6, 1
    beqz t0, 1f
    li t1, 0xb400
    xor s6, s6, t1
1:
    andi t0, s6, {jmask}
    add t0, t0, t3
2:
    beqz t0, 3f
    addi t0, t0, -1
    j 2b
3:
    ret

# a0 = key, a1 = table, a2 = number of observed variables.
lookup:
    ld t0, 0(a1)
    addi t1, a1, 8
    slli t2, t0, 3
    add t3, t1, t2
1:
    beqz t0, 2f
    ld t4, 0(t1)
    beq t4, a0, 9f
    addi t1, t1, 8
    addi t3, t3, 8
    addi t0, t0, -1
    j 1b
9:
    ld t4, 0(t3)
    addi t4, t4, 1
    sd t4, 0(t3)
    ret
2:
    li t0, {fail:#x}
    li t4, 1
    sd t4, 0(t0)
    ld t0, 0(a1)
    slli t0, t0, 4
    add t3, a1, t0
    addi t3, t3, 8
    ld t0, 0(t3)
    addi t1, t3, 8
    mv t2, t0
3:
    beqz t2, 4f
    ld t4, 0(t1)
    beq t4, a0, 5f
    addi t1, t1, 8
    addi t2, t2, -1
    j 3b
5:
    ld t4, {forb8}(t1)
    addi t4, t4, 1
    sd t4, {forb8}(t1)
    ret
4:
    li t4, {forb}
    bltu t0, t4, 6f
    ld t4, {ovf}(t3)
    addi t4, t4, 1
    sd t4, {ovf}(t3)
    ret
6:
    sd a0, 0(t1)
    li t4, 1
    sd t4, {forb8}(t1)
    addi t4, t0, 1
    sd t4, 0(t3)
    bnez t0, 8f
    addi t3, t3, {raw}
    li t1, {rawbuf:#x}
7:
    beqz a2, 8f
    ld t4, 0(t1)
    sd t4, 0(t3)
    addi t1, t1, 8
    addi t3, t3, 8
    addi a2, a2, -1
    j 7b
8:
    ret

# Print a0 in hex without leading zeros. Clobbers t0-t3.
puthex:
    li t0, {uart:#x}
    li t1, 60
    li t3, 0
1:
    srl t2, a0, t1
    andi t2, t2, 15
    or t3, t3, t2
    bnez t1, 2f
    li t3, 1
2:
    beqz t3, 4f
    addi t2, t2, 48
    li t4, 58
    bltu t2, t4, 3f
    addi t2, t2, 39
3:
    sb t2, 0(t0)
4:
    addi t1, t1, -4
    bgez t1, 1b
    ret

putc:
    li t0, {uart:#x}
    sb a0, 0(t0)
    ret

# Print every table as "@<test> <dword> ...", one line per test.
report:
    mv s4, ra
    la s5, TABS
    li s8, 0
1:
    ld s9, 0(s5)
    beqz s9, 9f
    ld s10, 8(s5)
    li a0, 64
    call putc
    mv a0, s8
    call puthex
2:
    beqz s10, 3f
    li a0, 32
    call putc
    ld a0, 0(s9)
    call puthex
    addi s9, s9, 8
    addi s10, s10, -1
    j 2b
3:
    li a0, 10
    call putc
    addi s5, s5, 16
    addi s8, s8, 1
    j 1b
9:
    mv ra, s4
    ret

trap:
    csrr s0, mhartid
    li a0, 33
    call putc
    mv a0, s0
    call puthex
    li a0, 32
    call putc
    csrr a0, mcause
    call puthex
    li a0, 32
    call putc
    csrr a0, mepc
    call puthex
    li a0, 32
    call putc
    csrr a0, mtval
    call puthex
    li a0, 10
    call putc
    li t0, 5
    la t1, tohost
    sd t0, 0(t1)
1:
    j 1b
"""

MAIN_END = r"""
    call barrier
    bnez s0, park
    call report
    li t0, {fail:#x}
    ld t0, 0(t0)
    li t1, 1
    beqz t0, 1f
    li t1, 3
1:
    la t0, tohost
    sd t1, 0(t0)
park:
    j park
"""

LD = """OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{{
  . = 0x80000000;
  .text.init : {{ *(.text.init) }}
  . = 0x80001000;
  .tohost : {{ *(.tohost) }}
  . = {text:#x};
  .text : {{ *(.text) }}
  .data : {{ *(.data) }}
}}
"""


def emit_program(tests, nh, iters, seed, jmask, skew):
    """tests: list of (Test, plan). Returns the assembly text."""
    a = [COMMON.format(ctx=CTX, ctx_stride=CTX_STRIDE, barrier=BARRIER, seed=seed & 0xffff or 1, nh=nh, nh_m1=nh - 1,
                       jmask=jmask, skew=skew, fail=FAIL, forb=FORB, forb8=8 * FORB, ovf=8 + 16 * FORB,
                       raw=16 + 16 * FORB, rawbuf=RAW, uart=UART), "main:"]
    for k, (t, pl) in enumerate(tests):
        a += emit_test(k, t, pl, nh, iters)
    a.append(MAIN_END.format(fail=FAIL))
    a += ["    .data", "    .align 3", "TABS:"]
    for k, (t, pl) in enumerate(tests):
        a += [f"    .dword TAB{k} + {8 + 8 * len(pl['keys'])}, {table_words(pl)}"]
    a += ["    .dword 0, 0"]
    for k, (t, pl) in enumerate(tests):
        a += [f"TAB{k}:", f"    .dword {len(pl['keys'])}"]
        a += [f"    .dword {x:#x}" for x in pl["keys"]]
        a += [f"    .zero {8 * table_words(pl)}"]
    return "\n".join(a) + "\n"


def build(tests, nh, iters, seed, jmask, skew, out, stem, tool):
    """Assemble, link and convert to the harness hex; returns the hex path."""
    out.mkdir(parents=True, exist_ok=True)
    s = out / f"{stem}.S"
    ld = out / f"{stem}.ld"
    elf = out / f"{stem}.elf"
    s.write_text(emit_program(tests, nh, iters, seed, jmask, skew))
    ld.write_text(LD.format(text=TEXT))
    subprocess.run([tool("gcc"), f"-march={MARCH}", "-mabi=lp64", "-nostdlib", "-nostartfiles", "-static",
                    "-T", str(ld), "-o", str(elf), str(s)], check=True, capture_output=True, text=True)
    binp = out / f"{stem}.bin"
    subprocess.run([tool("objcopy"), "-O", "binary", str(elf), str(binp)], check=True)
    data = binp.read_bytes()
    data += b"\0" * (-len(data) % 4)
    hexp = out / f"{stem}.hex"
    hexp.write_text("".join(f"{int.from_bytes(data[i:i + 4], 'little'):08X}\n" for i in range(0, len(data), 4)))
    binp.unlink()
    return hexp


def decode(pl, words):
    """Table dwords printed by the program -> (counts per allowed state,
    {forbidden key: count}, overflow count, raw values of the first forbidden)."""
    n = len(pl["keys"])
    counts = words[:n]
    nf = words[n]
    fk = words[n + 1:n + 1 + FORB]
    fc = words[n + 1 + FORB:n + 1 + 2 * FORB]
    ovf = words[n + 1 + 2 * FORB]
    raw = words[n + 2 + 2 * FORB:]
    return counts, {fk[i]: fc[i] for i in range(nf)}, ovf, raw


def key_values(pl, key):
    """The values a key stands for (None for an escape field)."""
    out = []
    for (sh, b), vs in zip(pl["bits"], pl["values"]):
        i = (key >> sh) & ((1 << b) - 1)
        out.append(vs[i] if i < len(vs) else None)
    return out
