#!/usr/bin/env python3
"""Random instruction stream generator for the spike cosim (GR).

    test/gr/gen.py --seed N [--length L] [--priv] [--vec] [--out DIR] [--no-build]

Writes DIR/gr_<seed>.S (default DIR test/gr/build) and, unless --no-build,
assembles it with riscv64-unknown-elf-gcc into gr_<seed>.elf and the
$readmemh image gr_<seed>.hex: DRAM at PA 0x8000_0000, tohost at PA
0x8000_1000 (TOHOST_IDX 1024), M-mode from reset. The program is a pure
function of the seed and the length; correctness is judged by the spike cosim
comparing every retired instruction, so the program computes no expected
values and ends with tohost = 1.

Covered: RV64 I/M/A (LR/SC, AMOs, Zabha, Zacas), C with Zcb and Zcmop, F/D,
Zfhmin, Zfa, Zba/Zbb/Zbs, Zicond, Zimop, Zicbom/Zicboz/Zicbop, the
Zihintntl/Zihintpause hints, loads and stores of every width (aligned and
misaligned, also across a page) in a private data region, forward branches,
bounded loops, direct and indirect jumps, calls to leaf functions, static and
dynamic rounding modes, and synchronous exceptions taken deliberately
(illegal encodings, ecall, ebreak, access faults, misaligned atomics). The M
trap handler counts each cause and resumes after the faulting instruction (or
at a recorded resume point after a fetch fault).

EXCLUDED lists what the generator never emits, with the reason.

--priv writes grp_<seed> instead: a stream that moves between M, S and U with
Sv39 paging, delegation, PMP and random CSR accesses (test/gr/priv.py, whose
PRIV_EXCLUDED adds to EXCLUDED). --vec mixes RVV 1.0 into either stream
(grv_<seed>, grvp_<seed>; test/gr/vec.py, whose VEC_EXCLUDED adds to the
table).
"""

import argparse
import json
import os
import random
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MASTER = HERE.parents[1]

MARCH = ("rv64imafdc_zicsr_zifencei_zicond_zba_zbb_zbs_zfhmin_zfa_zabha_zacas_zawrs_zcb_zcmop_zimop"
         "_zicbom_zicboz_zicbop_zihintntl_zihintpause")
MARCH_V = MARCH.replace("rv64imafdc_", "rv64imafdcv_") + "_zvbb_zvfhmin"

EXCLUDED = {
    "wfi, wrs.nto, wrs.sto": "stall until an interrupt or a reservation loss that never comes; spike treats "
                             "them as no-ops",
    "cycle/time/instret/hpmcounter reads": "timing values; the cosim copies them from the DUT, but the program "
                                           "would no longer be a function of the seed",
    "CLINT, PLIC, UART and Debug Module accesses": "device reads return the DUT's values; out of scope here",
    "misaligned access across the end of DRAM": "which bytes a split access performs before faulting is "
                                                "implementation-defined",
    "faulting PAs at or above 2^32": "the implemented PA width decides access fault versus wrap",
    "stores to code, fence.i-dependent code": "self-modifying code is left out of the scalar stream",
    "LR/SC retry loops": "an SC may fail for reasons outside the architecture, so a retry loop has no bound",
    "c.addi16sp and other sp/gp/tp/ra writes": "sp and gp are the data pointers, tp the loop counter, ra the "
                                               "link register",
    "instruction encodings longer than 32 bits": "the illegal-instruction tval of a longer encoding is "
                                                  "implementation-defined",
    "CSR writes other than fcsr/frm/fflags, xRET, privilege changes": "the CSR and privilege stream comes later",
    "vector, H": "separate streams",
}

DRAM = 0x8000_0000
DATA_SIZE = 0x2000
HOLES = [0x0000_1000, 0x2000_0000, 0x7fff_f000, 0x8040_0000]
TRAP_CAUSES = 16

# What the stream should contain, in objdump -M no-aliases spelling (run_gr.py
# lists the ones no program contains).
MNEMONICS = """
add add.uw addi addiw addw amoadd.b amoadd.d amoadd.h amoadd.w amoand.b amoand.d amoand.h amoand.w amocas.b
amocas.d amocas.h amocas.q amocas.w amomax.b amomax.d amomax.h amomax.w amomaxu.b amomaxu.d amomaxu.h
amomaxu.w amomin.b amomin.d amomin.h amomin.w amominu.b amominu.d amominu.h amominu.w amoor.b amoor.d amoor.h
amoor.w amoswap.b amoswap.d amoswap.h amoswap.w amoxor.b amoxor.d amoxor.h amoxor.w and andi andn auipc bclr
bclri beq bext bexti bge bgeu binv binvi blt bltu bne bset bseti c.add c.addi c.addi4spn c.addiw c.addw c.and
c.andi c.beqz c.bnez c.ebreak c.fld c.fldsp c.fsd c.fsdsp c.j c.jalr c.jr c.lbu c.ld c.ldsp c.lh c.lhu c.li
c.lui c.lw c.lwsp c.mop.N c.mul c.mv c.not c.ntl.all c.ntl.p1 c.ntl.pall c.ntl.s1 c.or c.sb c.sd c.sdsp
c.sext.b c.sext.h c.sh c.slli c.srai c.srli c.sub c.subw c.sw c.swsp c.xor c.zext.b c.zext.h c.zext.w
cbo.clean cbo.flush cbo.inval cbo.zero clz clzw cpop cpopw csrrc csrrci csrrs csrrsi csrrw csrrwi ctz ctzw
czero.eqz czero.nez div divu divuw divw ebreak ecall fadd.d fadd.s fclass.d fclass.s fcvt.d.h fcvt.d.l
fcvt.d.lu fcvt.d.s fcvt.d.w fcvt.d.wu fcvt.h.d fcvt.h.s fcvt.l.d fcvt.l.s fcvt.lu.d fcvt.lu.s fcvt.s.d
fcvt.s.h fcvt.s.l fcvt.s.lu fcvt.s.w fcvt.s.wu fcvt.w.d fcvt.w.s fcvt.wu.d fcvt.wu.s fcvtmod.w.d fdiv.d fdiv.s
fence fence.i fence.tso feq.d feq.s fld fle.d fle.s fleq.d fleq.s flh fli.d fli.s flt.d flt.s fltq.d fltq.s
flw fmadd.d fmadd.s fmax.d fmax.s fmaxm.d fmaxm.s fmin.d fmin.s fminm.d fminm.s fmsub.d fmsub.s fmul.d fmul.s
fmv.d.x fmv.h.x fmv.w.x fmv.x.d fmv.x.h fmv.x.w fnmadd.d fnmadd.s fnmsub.d fnmsub.s fround.d fround.s
froundnx.d froundnx.s fsd fsgnj.d fsgnj.s fsgnjn.d fsgnjn.s fsgnjx.d fsgnjx.s fsh fsqrt.d fsqrt.s fsub.d
fsub.s fsw jal jalr lb lbu ld lh lhu lr.d lr.w lui lw lwu max maxu min minu mop.r.N mop.rr.N mul mulh mulhsu
mulhu mulw ntl.all ntl.p1 ntl.pall ntl.s1 or orc.b ori orn pause prefetch.i prefetch.r prefetch.w rem remu
remuw remw rev8 rol rolw ror rori roriw rorw sb sc.d sc.w sd sext.b sext.h sh sh1add sh1add.uw sh2add
sh2add.uw sh3add sh3add.uw sll slli slli.uw slliw sllw slt slti sltiu sltu sra srai sraiw sraw srl srli srliw
srlw sub subw sw xnor xor xori zext.h
""".split()

XW = [r for r in range(5, 32)]          # writable: x1-x4 are reserved
XC = list(range(8, 16))                  # compressible
FR = list(range(32))
FC = list(range(8, 16))
RMS = ["rne", "rtz", "rdn", "rup", "rmm", "dyn"]

# FP special values.
D_SPECIAL = [0x0, 0x8000000000000000, 0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000,
             0x7ff4000000000000, 0xfff8000000000001, 0x0000000000000001, 0x800fffffffffffff,
             0x0010000000000000, 0x7fefffffffffffff, 0x3ff0000000000000, 0xbff0000000000000,
             0x3fe0000000000000, 0x4330000000000000, 0x43e0000000000000, 0xc3e0000000000000,
             0x41dfffffffc00000, 0x3ff8000000000000]
S_SPECIAL = [0x0, 0x80000000, 0x7f800000, 0xff800000, 0x7fc00000, 0x7fa00000, 0xffc00001, 0x1, 0x807fffff,
             0x00800000, 0x7f7fffff, 0x3f800000, 0xbf800000, 0x3f000000, 0x4b000000, 0x5f000000, 0xcf000000,
             0x4f000000, 0x3fc00000]
H_SPECIAL = [0x0, 0x8000, 0x7c00, 0xfc00, 0x7e00, 0x7d00, 0xfe01, 0x0001, 0x83ff, 0x0400, 0x7bff, 0x3c00,
             0xbc00, 0x3800, 0x6400, 0x3e00]
X_SPECIAL = [0, 1, 2, 0xffffffffffffffff, 0x8000000000000000, 0x7fffffffffffffff, 0x80000000, 0x7fffffff,
             0xffffffff, 0xffffffff80000000, 0x100000000, 0xff, 0x80, 0xffff, 0x8000, 31, 32, 63, 64]


def fx(r):
    return f"x{r}"


def ff(r):
    return f"f{r}"


class Gen:
    def __init__(self, seed, length):
        self.r = random.Random(seed)
        self.seed = seed
        self.length = length
        self.lines = []
        self.lab = 0
        self.dyn = 0
        self.mult = 1
        self.rvc = True
        self.in_func = False
        self.nfunc = 0
        self.pool, self.cpool = XW, XC
        self.win = (0, DATA_SIZE - 16)

    # Helpers.
    def label(self, stem):
        self.lab += 1
        return f".L{stem}{self.lab}"

    def emit(self, s, n=1):
        self.lines.append("    " + s)
        self.dyn += n * self.mult

    def put(self, s):
        self.lines.append(s)

    def ch(self, seq):
        return self.r.choice(seq)

    def p(self, prob):
        return self.r.random() < prob

    def xw(self):
        # x0 as destination is a HINT or a discarded result.
        return 0 if self.p(0.03) else self.ch(self.pool)

    def xr(self):
        if self.pool is XW:
            return self.r.randrange(32)
        return self.ch(self.pool + [0, 2, 3])

    def xval(self):
        k = self.r.random()
        if k < 0.4:
            return self.ch(X_SPECIAL)
        if k < 0.6:
            return self.r.randrange(-2048, 2048) & (2**64 - 1)
        if k < 0.75:
            return self.r.getrandbits(32) | (0xffffffff00000000 if self.p(0.5) else 0)
        return self.r.getrandbits(64)

    def li(self, rd, v):
        v &= 2**64 - 1
        sv = v - 2**64 if v >> 63 else v
        self.emit(f"li {fx(rd)}, {sv}", 1 if -2048 <= sv < 2048 else 4)

    def rm(self):
        return self.ch(RMS)

    # Addresses in the data region: gp = DATA + 0x800, sp = DATA + 0x1800.
    def addr(self, size, aligned):
        lo, hi = self.win
        a = self.r.randrange(lo, hi)
        if aligned:
            a &= ~(size - 1)
        elif size > 1 and a % size == 0:
            a += self.r.randrange(1, size)
        if self.p(0.08) and self.pool is XW:
            # Straddle the page boundary inside the region.
            a = 0x1000 - self.r.randrange(1, size + 1) if not aligned and size > 1 else a
        return a

    def base_for(self, off):
        """(base register, immediate) reaching DATA + off; may emit an addi."""
        for b, boff in ((3, 0x800), (2, 0x1800)):
            imm = off - boff
            if -2048 <= imm < 2048 and self.p(0.5):
                return b, imm
        rx = self.ch(self.pool)
        imm = self.r.randrange(-64, 64)
        b, boff = (3, 0x800) if off < 0x1000 else (2, 0x1800)
        if not -2048 <= off - boff - imm < 2048:
            imm = 0
        self.emit(f"addi {fx(rx)}, {fx(b)}, {off - boff - imm}")
        return rx, imm

    def ptr(self, off, regs=None):
        """A register holding DATA + off."""
        rx = self.ch(regs or self.pool)
        b, boff = (3, 0x800) if off < 0x1000 else (2, 0x1800)
        self.emit(f"addi {fx(rx)}, {fx(b)}, {off - boff}")
        return rx

    # Instruction groups.
    def g_alu(self):
        k = self.r.random()
        rd = self.xw()
        if k < 0.45:
            op = self.ch(["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and", "addw", "subw",
                          "sllw", "srlw", "sraw", "sh1add", "sh2add", "sh3add", "add.uw", "sh1add.uw",
                          "sh2add.uw", "sh3add.uw", "andn", "orn", "xnor", "max", "maxu", "min", "minu", "rol",
                          "ror", "rolw", "rorw", "bclr", "bset", "binv", "bext", "czero.eqz", "czero.nez"])
            self.emit(f"{op} {fx(rd)}, {fx(self.xr())}, {fx(self.xr())}")
        elif k < 0.75:
            op = self.ch(["addi", "slti", "sltiu", "xori", "ori", "andi", "addiw", "slli", "srli", "srai",
                          "slliw", "srliw", "sraiw", "slli.uw", "rori", "roriw", "bclri", "bseti", "binvi",
                          "bexti"])
            if op in ("slliw", "srliw", "sraiw", "roriw"):
                imm = self.r.randrange(32)
            elif op in ("slli", "srli", "srai", "slli.uw", "rori", "bclri", "bseti", "binvi", "bexti"):
                imm = self.r.randrange(64)
            else:
                imm = self.r.randrange(-2048, 2048)
            rs = self.xr()
            if op == "ori" and rd == 0 and imm & 31 == 0:
                imm |= 1  # ori x0 with imm[4:0] = 0 is prefetch.i
            self.emit(f"{op} {fx(rd)}, {fx(rs)}, {imm}")
        elif k < 0.85:
            op = self.ch(["clz", "ctz", "cpop", "clzw", "ctzw", "cpopw", "sext.b", "sext.h", "zext.h", "rev8",
                          "orc.b", "zext.w"])
            self.emit(f"{op} {fx(rd)}, {fx(self.xr())}")
        elif k < 0.9:
            self.emit(f"{self.ch(['lui', 'auipc'])} {fx(rd)}, {self.r.randrange(1 << 20)}")
        else:
            self.li(self.ch(self.pool), self.xval())

    def g_mul(self):
        op = self.ch(["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu", "mulw", "divw", "divuw",
                      "remw", "remuw"])
        self.emit(f"{op} {fx(self.xw())}, {fx(self.xr())}, {fx(self.xr())}")

    def g_rvc(self):
        if not self.rvc:
            return self.g_alu()
        k = self.r.randrange(12)
        rc, rc2 = self.ch(self.cpool), self.ch(self.cpool)
        rd = self.ch(self.pool)
        if k == 0:
            imm = self.ch([i for i in range(-32, 32) if i])
            self.emit(f"c.addi {fx(rd)}, {imm}")
        elif k == 1:
            self.emit(f"c.addiw {fx(rd)}, {self.r.randrange(-32, 32)}")
        elif k == 2:
            self.emit(f"c.li {fx(rd)}, {self.r.randrange(-32, 32)}")
        elif k == 3:
            self.emit(f"c.lui {fx(rd)}, {self.ch(list(range(1, 32)) + list(range(0xfffe0, 0x100000)))}")
        elif k == 4:
            self.emit(f"{self.ch(['c.srli', 'c.srai'])} {fx(rc)}, {self.r.randrange(1, 64)}")
        elif k == 5:
            self.emit(f"c.andi {fx(rc)}, {self.r.randrange(-32, 32)}")
        elif k == 6:
            self.emit(f"c.slli {fx(rd)}, {self.r.randrange(1, 64)}")
        elif k == 7:
            self.emit(f"{self.ch(['c.mv', 'c.add'])} {fx(rd)}, {fx(self.r.randrange(1, 32))}")
        elif k == 8:
            op = self.ch(["c.and", "c.or", "c.xor", "c.sub", "c.addw", "c.subw", "c.mul"])
            self.emit(f"{op} {fx(rc)}, {fx(rc2)}")
        elif k == 9:
            op = self.ch(["c.zext.b", "c.sext.b", "c.zext.h", "c.sext.h", "c.zext.w", "c.not"])
            self.emit(f"{op} {fx(rc)}")
        elif k == 10:
            self.emit(f"c.addi4spn {fx(rc)}, sp, {4 * self.r.randrange(1, 256)}")
        else:
            self.emit(self.ch(["c.nop", f"c.mop.{self.ch(range(1, 16, 2))}"]))

    def g_hint(self):
        self.emit(self.ch(["fence", "fence rw, rw", "fence r, r", "fence w, w", "fence.tso", "fence.i",
                           "pause", "ntl.p1", "ntl.pall", "ntl.s1", "ntl.all", "nop",
                           f"mop.r.{self.r.randrange(32)} {fx(self.xw())}, {fx(self.xr())}",
                           f"mop.rr.{self.r.randrange(8)} {fx(self.xw())}, {fx(self.xr())}, {fx(self.xr())}"]))

    def g_cmo(self):
        off = self.r.randrange(0, DATA_SIZE - 64)
        k = self.r.randrange(3)
        if k == 0:
            rx = self.ptr(off)
            self.emit(f"{self.ch(['cbo.zero', 'cbo.clean', 'cbo.flush', 'cbo.inval'])} ({fx(rx)})")
        else:
            b, imm = self.base_for(off)
            imm &= ~31
            self.emit(f"{self.ch(['prefetch.r', 'prefetch.w', 'prefetch.i'])} {imm}({fx(b)})")

    def g_load(self):
        op, size = self.ch([("lb", 1), ("lh", 2), ("lw", 4), ("ld", 8), ("lbu", 1), ("lhu", 2), ("lwu", 4)])
        b, imm = self.base_for(self.addr(size, self.p(0.7)))
        self.emit(f"{op} {fx(self.xw())}, {imm}({fx(b)})")

    def g_store(self):
        op, size = self.ch([("sb", 1), ("sh", 2), ("sw", 4), ("sd", 8)])
        b, imm = self.base_for(self.addr(size, self.p(0.7)))
        self.emit(f"{op} {fx(self.xr())}, {imm}({fx(b)})")

    def g_fmem(self):
        op, size, st = self.ch([("flh", 2, 0), ("flw", 4, 0), ("fld", 8, 0), ("fsh", 2, 1), ("fsw", 4, 1),
                                ("fsd", 8, 1)])
        b, imm = self.base_for(self.addr(size, self.p(0.75)))
        self.emit(f"{op} {ff(self.ch(FR))}, {imm}({fx(b)})")

    def g_cmem(self):
        if not self.rvc:
            return self.g_load()
        k = self.r.randrange(4)
        if k == 0:
            # sp-relative.
            op, size, scale, f = self.ch([("c.lwsp", 4, 64, 0), ("c.ldsp", 8, 64, 0), ("c.fldsp", 8, 64, 1),
                                          ("c.swsp", 4, 64, 2), ("c.sdsp", 8, 64, 2), ("c.fsdsp", 8, 64, 3)])
            imm = size * self.r.randrange(scale)
            r = ff(self.ch(FR)) if f & 1 else fx(self.ch(self.pool) if f == 0 else self.r.randrange(1, 32))
            if f == 2 and self.p(0.2):
                r = fx(0)
            self.emit(f"{op} {r}, {imm}(sp)")
            return
        op, size, n, f = self.ch([("c.lw", 4, 32, 0), ("c.ld", 8, 32, 0), ("c.fld", 8, 32, 1), ("c.sw", 4, 32, 0),
                                  ("c.sd", 8, 32, 0), ("c.fsd", 8, 32, 1), ("c.lbu", 1, 4, 0), ("c.lhu", 2, 2, 0),
                                  ("c.lh", 2, 2, 0), ("c.sb", 1, 4, 0), ("c.sh", 2, 2, 0)])
        imm = size * self.r.randrange(n)
        off = self.addr(size, self.p(0.7)) & ~0xff
        rb = self.ptr(off, self.cpool)
        if self.p(0.3):
            rb_val_off = off
            rb_val_off += self.r.randrange(1, size) if size > 1 else 0
            self.emit(f"addi {fx(rb)}, {fx(rb)}, {rb_val_off - off}")
        r = ff(self.ch(FC)) if f else fx(self.ch(self.cpool))
        self.emit(f"{op} {r}, {imm}({fx(rb)})")

    def g_amo(self):
        k = self.r.random()
        ordr = self.ch(["", ".aq", ".rl", ".aqrl"])
        if k < 0.6:
            op = self.ch(["amoswap", "amoadd", "amoxor", "amoand", "amoor", "amomin", "amomax", "amominu",
                          "amomaxu", "amocas"])
            w, size = self.ch([(".w", 4), (".d", 8), (".b", 1), (".h", 2)])
            rx = self.ptr(self.addr(size, True))
            self.emit(f"{op}{w}{ordr} {fx(self.xw())}, {fx(self.xr())}, ({fx(rx)})")
        elif k < 0.7:
            rx = self.ptr(self.addr(16, True))
            rd = self.ch(range(6, 31, 2))
            self.emit(f"amocas.q{ordr} {fx(rd)}, {fx(self.ch(range(0, 31, 2)))}, ({fx(rx)})")
        else:
            # One LR/SC attempt; the SC may succeed or fail.
            w, size = self.ch([(".w", 4), (".d", 8)])
            rx = self.ptr(self.addr(size, True))
            rd = self.ch([r for r in self.pool if r != rx])
            self.emit(f"lr{w}{self.ch(['', '.aq', '.aqrl'])} {fx(rd)}, ({fx(rx)})")
            for _ in range(self.r.randrange(4)):
                self.g_alu_safe(rx)
            if self.p(0.15):
                rx2 = self.ptr(self.addr(size, True), [r for r in self.pool if r != rx])
                rx = rx2
            sd = self.ch([r for r in self.pool if r != rx])
            self.emit(f"sc{w}{self.ch(['', '.rl', '.aqrl'])} {fx(sd)}, {fx(self.xr())}, ({fx(rx)})")

    def g_alu_safe(self, keep):
        rd = self.ch([r for r in self.pool if r != keep])
        op = self.ch(["add", "xor", "sub", "and", "or", "mul", "sh1add", "max"])
        self.emit(f"{op} {fx(rd)}, {fx(self.xr())}, {fx(self.xr())}")

    def g_fp(self):
        k = self.r.randrange(17)
        s = self.ch(["s", "d"])
        fd, f1, f2, f3 = (self.ch(FR) for _ in range(4))
        if k == 0:
            op = self.ch(["fadd", "fsub", "fmul", "fdiv"])
            self.emit(f"{op}.{s} {ff(fd)}, {ff(f1)}, {ff(f2)}, {self.rm()}")
        elif k == 1:
            self.emit(f"fsqrt.{s} {ff(fd)}, {ff(f1)}, {self.rm()}")
        elif k == 2:
            op = self.ch(["fmin", "fmax", "fsgnj", "fsgnjn", "fsgnjx", "fminm", "fmaxm"])
            self.emit(f"{op}.{s} {ff(fd)}, {ff(f1)}, {ff(f2)}")
        elif k in (3, 4):
            op = self.ch(["fmadd", "fmsub", "fnmadd", "fnmsub"])
            self.emit(f"{op}.{s} {ff(fd)}, {ff(f1)}, {ff(f2)}, {ff(f3)}, {self.rm()}")
        elif k == 5:
            op = self.ch(["feq", "flt", "fle", "fleq", "fltq"])
            self.emit(f"{op}.{s} {fx(self.xw())}, {ff(f1)}, {ff(f2)}")
        elif k == 6:
            self.emit(f"fclass.{s} {fx(self.xw())}, {ff(f1)}")
        elif k == 7:
            t = self.ch(["w", "wu", "l", "lu"])
            self.emit(f"fcvt.{t}.{s} {fx(self.xw())}, {ff(f1)}, {self.rm()}")
        elif k == 8:
            t = self.ch(["w", "wu", "l", "lu"])
            exact = s == "d" and t in ("w", "wu")
            self.emit(f"fcvt.{s}.{t} {ff(fd)}, {fx(self.xr())}" + ("" if exact else f", {self.rm()}"))
        elif k == 9:
            if self.p(0.5):
                self.emit(f"fcvt.s.d {ff(fd)}, {ff(f1)}, {self.rm()}")
            else:
                self.emit(f"fcvt.d.s {ff(fd)}, {ff(f1)}")
        elif k == 10:
            op = self.ch([f"fmv.x.w {fx(self.xw())}, {ff(f1)}", f"fmv.w.x {ff(fd)}, {fx(self.xr())}",
                          f"fmv.x.d {fx(self.xw())}, {ff(f1)}", f"fmv.d.x {ff(fd)}, {fx(self.xr())}",
                          f"fmv.x.h {fx(self.xw())}, {ff(f1)}", f"fmv.h.x {ff(fd)}, {fx(self.xr())}"])
            self.emit(op)
        elif k == 11:
            self.emit(self.ch([f"fcvt.h.s {ff(fd)}, {ff(f1)}, {self.rm()}", f"fcvt.h.d {ff(fd)}, {ff(f1)}, {self.rm()}",
                               f"fcvt.s.h {ff(fd)}, {ff(f1)}", f"fcvt.d.h {ff(fd)}, {ff(f1)}"]))
        elif k == 12:
            op = self.ch(["fround", "froundnx"])
            self.emit(f"{op}.{s} {ff(fd)}, {ff(f1)}, {self.rm()}")
        elif k == 13:
            self.emit(f"fcvtmod.w.d {fx(self.xw())}, {ff(f1)}, rtz")
        elif k == 14:
            fmt = 0 if s == "s" else 1
            enc = ((0x78 | fmt) << 25) | (1 << 20) | (self.r.randrange(32) << 15) | (fd << 7) | 0x53
            self.emit(f".insn 4, {enc:#010x}")
        elif k == 15:
            self.fp_reload()
        else:
            self.g_fcsr()

    def fp_reload(self):
        rx = self.ch(self.pool)
        n = len(self.fpconst)
        i = self.r.randrange(n)
        self.emit(f"la {fx(rx)}, gr_fpconst", 2)
        self.emit(f"fld {ff(self.ch(FR))}, {8 * i}({fx(rx)})")

    def g_fcsr(self):
        k = self.r.randrange(8)
        rd, rs = self.xw(), self.xr()
        if k == 0:
            self.emit(f"fsrmi {fx(rd)}, {self.r.randrange(5)}")
        elif k == 1:
            self.emit(f"fsflagsi {fx(rd)}, {self.r.randrange(32)}")
        elif k == 2:
            self.emit(f"{self.ch(['frcsr', 'frrm', 'frflags'])} {fx(rd)}")
        elif k == 3:
            v = self.r.randrange(32) | (self.r.randrange(5) << 5)
            rx = self.ch(self.pool)
            self.li(rx, v)
            self.emit(f"fscsr {fx(rd)}, {fx(rx)}")
        elif k == 4:
            self.emit(f"fsflags {fx(rd)}, {fx(rs)}")
        elif k == 5:
            self.emit(f"{self.ch(['csrrs', 'csrrc'])} {fx(rd)}, fflags, {fx(rs)}")
        elif k == 6:
            self.emit(f"{self.ch(['csrrsi', 'csrrci'])} {fx(rd)}, fcsr, {self.r.randrange(32)}")
        else:
            rx = self.ch(self.pool)
            self.li(rx, self.r.randrange(5))
            self.emit(f"fsrm {fx(rd)}, {fx(rx)}")

    # Deliberate synchronous exceptions.
    def g_trap(self):
        k = self.r.randrange(12)
        if k == 0:
            self.emit(self.ch(["ecall", "ebreak"] + (["c.ebreak"] if self.rvc else [])))
        elif k == 1:
            self.emit(f".insn 4, {self.illegal32():#010x}")
        elif k == 2 and self.rvc:
            self.emit(f".insn 2, {self.ch([0x0000, 0x0004, 0x4002, 0x6002, 0x8002, 0x6281, 0x6101]):#06x}")
        elif k == 3:
            # Reserved dynamic rounding mode, then restore a valid one.
            rx = self.ch(self.pool)
            self.emit(f"fsrmi {fx(rx)}, {self.ch([5, 6, 7])}")
            s = self.ch(["s", "d"])
            self.emit(f"fadd.{s} {ff(self.ch(FR))}, {ff(self.ch(FR))}, {ff(self.ch(FR))}, dyn")
            self.emit(f"fsrm {fx(rx)}")
        elif k in (4, 5):
            rx = self.ch(self.pool)
            self.li(rx, self.ch(HOLES) + self.r.randrange(0, 0x100, 8))
            op = self.ch(["lb", "lhu", "lw", "ld", "sb", "sh", "sw", "sd", "flw", "fsd", "amoadd.w",
                          "amoswap.d", "lr.d", "sc.w", "amocas.d"])
            if op.startswith(("amo", "sc")):
                self.emit(f"{op} {fx(self.xw())}, {fx(self.xr())}, ({fx(rx)})")
            elif op.startswith("lr"):
                self.emit(f"{op} {fx(self.xw())}, ({fx(rx)})")
            elif op.startswith("f"):
                self.emit(f"{op} {ff(self.ch(FR))}, 0({fx(rx)})")
            elif op.startswith("s"):
                self.emit(f"{op} {fx(self.xr())}, 0({fx(rx)})")
            else:
                self.emit(f"{op} {fx(self.xw())}, 0({fx(rx)})")
        elif k in (6, 7):
            # Misaligned atomics take an access fault.
            w, size = self.ch([(".w", 4), (".d", 8), (".h", 2)])
            a = self.addr(size, True) + self.r.randrange(1, size)
            rx = self.ptr(a)
            op = self.ch(["amoadd", "amoswap", "amomaxu", "amocas"] + (["lr", "sc"] if w != ".h" else []))
            if op == "lr":
                self.emit(f"lr{w} {fx(self.xw())}, ({fx(rx)})")
            else:
                self.emit(f"{op}{w} {fx(self.xw())}, {fx(self.xr())}, ({fx(rx)})")
        elif k == 8 and not self.in_func:
            # Fetch from a hole; the handler resumes at the recorded point.
            back = self.label("resume")
            ra_, rb_ = self.r.sample(self.pool, 2)
            self.emit(f"la {fx(ra_)}, gr_resume", 2)
            self.emit(f"la {fx(rb_)}, {back}", 2)
            self.emit(f"sd {fx(rb_)}, 0({fx(ra_)})")
            self.li(ra_, self.ch(HOLES))
            self.emit(f"jalr {fx(self.xw())}, 0({fx(ra_)})")
            self.put(f"{back}:")
        else:
            self.emit(f".insn 4, {self.illegal32():#010x}")

    def illegal32(self):
        """A 32-bit encoding the configuration makes illegal."""
        r = self.r
        rd, rs1, rs2 = r.randrange(32), r.randrange(32), r.randrange(32)
        k = r.randrange(16)
        if k == 0:
            return 0xc0001073  # csrrw x0, cycle, x0
        if k == 1:
            # FP op with a reserved static rm
            return (r.randrange(2) << 25) | (rs2 << 20) | (rs1 << 15) | (r.choice([5, 6]) << 12) | (rd << 7) | 0x53
        if k == 2:
            # Zfa half-precision ops need Zfh: fli.h, fminm.h, fround.h, fleq.h
            return r.choice([(0x7a << 25) | (1 << 20) | (rs1 << 15) | (rd << 7) | 0x53,
                             (0x16 << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x53,
                             (0x22 << 25) | (4 << 20) | (rs1 << 15) | (rd << 7) | 0x53,
                             (0x52 << 25) | (rs2 << 20) | (rs1 << 15) | (4 << 12) | (rd << 7) | 0x53])
        if k == 3:
            # Zfh arithmetic without Zfh: fadd.h, fmul.h, fsqrt.h; fmadd.h, fnmadd.q
            rs3 = r.randrange(32)
            return r.choice([(0x02 << 25) | (rs2 << 20) | 0x53, (0x0a << 25) | (rs2 << 20) | 0x53, (0x2e << 25) | 0x53,
                             (rs3 << 27) | (2 << 25) | (rs2 << 20) | 0x43,
                             (rs3 << 27) | (3 << 25) | (rs2 << 20) | 0x4f]) | (rs1 << 15) | (rd << 7)
        if k == 4:
            # RV32-only fmvh.x.d, fmvp.d.x
            return r.choice([(0x71 << 25) | (1 << 20) | (rs1 << 15) | (rd << 7) | 0x53,
                             (0x59 << 25) | (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x53])
        if k == 5:
            # OP-IMM-32: shamt[5] set, an undefined funct3 or funct7
            return r.choice([0x0200101b | (rs2 << 20), 0x0200501b | (rs2 << 20), 0x4200501b | (rs2 << 20),
                             (r.choice([2, 3, 4, 6, 7]) << 12) | (r.getrandbits(12) << 20) | 0x1b,
                             (r.choice([0x01, 0x10, 0x40, 0x7f]) << 25) | (rs2 << 20) | (1 << 12) | 0x1b]) \
                | (rs1 << 15) | (rd << 7)
        if k == 6:
            # lr.d with rs2 != 0, on the data region
            return (0x02 << 27) | (r.randrange(1, 32) << 20) | (3 << 15) | (3 << 12) | (rd << 7) | 0x2f
        if k == 7:
            # amocas.q with an odd rd, on the data region
            return (0x05 << 27) | (rs2 << 20) | (3 << 15) | (4 << 12) | ((rd | 1) << 7) | 0x2f
        if k == 8:
            # OP-32 with an undefined funct7/funct3 pair
            f7, f3 = r.choice([(0x00, 2), (0x00, 4), (0x00, 7), (0x20, 1), (0x20, 6), (0x01, 1), (0x01, 3),
                               (0x7f, 0), (0x08, 0), (0x40, 5)])
            return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x3b
        if k == 9:
            # OP-FP: fsqrt and fmv.x/fclass with rs2 != 0 or another funct3,
            # fmv.?.x and fli with funct3 != 000
            f7, f3, v = r.choice([(0x2c, 0, 3), (0x2d, 7, 1), (0x70, 0, 2), (0x71, 1, 4), (0x70, 2, 0),
                                  (0x71, 5, 0), (0x78, 1, 0), (0x79, 3, 1), (0x78, 7, 0)])
            return (f7 << 25) | (v << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x53
        if k == 10:
            # BRANCH funct3 01x: target self+8 would be harmless if taken
            return (r.choice([2, 3]) << 12) | (rs2 << 20) | (rs1 << 15) | (8 << 7) | 0x63
        if k == 11:
            # JALR funct3 != 000, through gp
            return (r.randrange(1, 8) << 12) | (3 << 15) | (rd << 7) | 0x67
        if k == 12:
            # MISC-MEM funct3 011-111
            return (r.getrandbits(12) << 20) | (rs1 << 15) | (r.randrange(3, 8) << 12) | (rd << 7) | 0x0f
        if k == 13:
            # ECALL/EBREAK/MRET/WFI with rd or rs1 != 0
            f12 = r.choice([0x000, 0x001, 0x302, 0x105])
            rd_, rs1_ = r.choice([(r.randrange(1, 32), 0), (0, r.randrange(1, 32))])
            return (f12 << 20) | (rs1_ << 15) | (rd_ << 7) | 0x73
        if k == 14:
            # A SYSTEM funct3 000 op no extension defines
            return (r.choice([0x7ff, 0x303, 0x100, 0x002]) << 20) | 0x73
        # custom-0 opcode: no custom extension is implemented
        return (r.getrandbits(25) << 7) | 0x0b

    # Control flow.
    def straight(self, n):
        for _ in range(n):
            self.one()

    def one(self):
        k = self.r.random()
        tbl = [(0.22, self.g_alu), (0.30, self.g_mul), (0.40, self.g_rvc), (0.50, self.g_load),
               (0.58, self.g_store), (0.66, self.g_cmem), (0.71, self.g_fmem), (0.88, self.g_fp),
               (0.94, self.g_amo), (0.96, self.g_hint), (0.985, self.g_cmo), (1.0, self.g_trap)]
        for lim, f in tbl:
            if k < lim:
                return f()

    def fwd_branch(self, n):
        t = self.label("f")
        k = self.r.randrange(4)
        if k == 0 and self.rvc:
            self.emit(f"{self.ch(['c.beqz', 'c.bnez'])} {fx(self.ch(self.cpool))}, {t}")
        elif k == 1:
            self.emit(f"{self.ch(['j', 'c.j' if self.rvc else 'j'])} {t}")
            self.put(f"    .insn 4, {self.illegal32():#010x}")
            n = self.r.randrange(3)
        else:
            op = self.ch(["beq", "bne", "blt", "bge", "bltu", "bgeu"])
            self.emit(f"{op} {fx(self.xr())}, {fx(self.xr())}, {t}")
        self.straight(n)
        self.put(f"{t}:")

    def indirect(self):
        t = self.label("i")
        rx = self.ch(self.pool)
        self.emit(f"la {fx(rx)}, {t}", 2)
        if self.rvc and self.p(0.4):
            self.emit(f"c.jr {fx(rx)}")
        else:
            self.emit(f"jalr {fx(self.ch([0] + self.pool))}, 0({fx(rx)})")
        self.put(f"    .insn 4, {self.illegal32():#010x}")
        self.put(f"{t}:")

    def call(self):
        f = f"gr_func{self.r.randrange(self.nfunc)}"
        k = self.r.randrange(4)
        if k == 0:
            self.emit(f"call {f}", 2)
        elif k == 1:
            self.emit(f"jal ra, {f}")
        else:
            rx = self.ch(self.pool)
            self.emit(f"la {fx(rx)}, {f}", 2)
            self.emit(f"c.jalr {fx(rx)}" if self.rvc and k == 2 else f"jalr ra, {fx(rx)}, 0")
        self.dyn += self.fsize * self.mult

    def block(self, allow_loop=True, allow_call=True):
        k = self.r.random()
        if k < 0.45:
            self.straight(self.r.randrange(3, 16))
        elif k < 0.65:
            self.fwd_branch(self.r.randrange(1, 8))
        elif k < 0.72:
            self.indirect()
        elif k < 0.82 and allow_call and self.nfunc:
            self.call()
        elif k < 0.92 and allow_loop:
            self.loop()
        elif k < 0.96:
            self.dense()
        else:
            self.straight(self.r.randrange(1, 6))

    def dense(self):
        """A run on few registers and one 64-byte window: back-to-back
        dependences and store-to-load overlap."""
        self.pool = self.r.sample(XC, 2) + self.r.sample([r for r in XW if r not in XC], self.r.randrange(1, 4))
        self.cpool = [r for r in self.pool if r in XC]
        lo = self.ch([0x1000 - 32, self.r.randrange(0, DATA_SIZE - 80, 8)])
        self.win = (lo, lo + 64 - 8)
        self.straight(self.r.randrange(8, 32))
        self.pool, self.cpool = XW, XC
        self.win = (0, DATA_SIZE - 16)

    def loop(self):
        n = self.r.randrange(1, 9)
        top = self.label("loop")
        self.emit(f"li tp, {n}")
        self.put(f"{top}:")
        save = self.mult
        self.mult *= n
        for _ in range(self.r.randrange(1, 5)):
            self.block(allow_loop=False)
        self.emit("addi tp, tp, -1")
        self.emit(f"bnez tp, {top}")
        self.mult = save

    def section_mode(self):
        rvc = self.p(0.7)
        if rvc != self.rvc:
            self.put("    .option pop" if rvc else "    .option push\n    .option norvc")
            self.rvc = rvc

    # Program.
    def build(self):
        r = self.r
        self.fpconst = ([v for v in D_SPECIAL] + [0xffffffff00000000 | v for v in S_SPECIAL]
                        + [0xffffffffffff0000 | v for v in H_SPECIAL]
                        + [r.getrandbits(64) for _ in range(8)]
                        + [0xffffffff00000000 | r.getrandbits(32) for _ in range(4)])
        self.nfunc = r.randrange(2, 6)
        self.fsize = 30
        out = []
        out.append(f"# Generated by test/gr/gen.py --seed {self.seed} --length {self.length}. Do not edit.")
        out.append(self.HEAD)
        # Initial state.
        self.lines = []
        self.emit(f"li x5, {r.randrange(32) | (r.randrange(5) << 5)}")
        self.emit("fscsr x5")
        for i in FR:
            self.emit(f"fld f{i}, {8 * r.randrange(len(self.fpconst))}(x6)")
        for x in XW:
            self.li(x, self.xval())
        self.init_extra()
        out += ["    la x6, gr_fpconst"] + self.lines
        out.append("    j gr_main")
        out.append(self.TRAP)

        self.lines = []
        self.put("    .text")
        self.put("gr_main:")
        self.rvc = True
        while self.dyn < self.length and len(self.lines) < 40 * self.length:
            self.section_mode()
            self.block()
        if not self.rvc:
            self.put("    .option pop")
        self.rvc = True
        self.finish()
        self.put("    j gr_pass")
        body_dyn = self.dyn
        # Leaf functions: no loops, calls or writes of tp/ra.
        fdyn = []
        self.in_func = True
        for i in range(self.nfunc):
            self.put(f"gr_func{i}:")
            d0, self.mult = self.dyn, 1
            for _ in range(r.randrange(1, 5)):
                self.block(allow_loop=False, allow_call=False)
            self.emit(self.ch(["ret", "c.jr ra", "jalr x0, 0(ra)"]))
            fdyn.append(self.dyn - d0)
        out += self.lines

        data = [r.getrandbits(64) for _ in range(DATA_SIZE // 8)]
        for i in range(0, len(data), 7):
            data[i] = r.choice(D_SPECIAL + [0xffffffff00000000 | v for v in S_SPECIAL]
                               + [(r.choice(S_SPECIAL) << 32) | r.choice(S_SPECIAL)])
        out.append("    .data")
        out.append("    .align 12")
        out.append("gr_data:")
        out += [f"    .dword {v:#018x}" for v in data]
        out.append("gr_fpconst:")
        out += [f"    .dword {v:#018x}" for v in self.fpconst]
        out.append("    .align 3")
        out.append("gr_resume:")
        out.append("    .dword 0")
        out.append("gr_save:")
        out.append(f"    .zero {8 * (8 + TRAP_CAUSES)}")
        out += self.data_extra()
        return "\n".join(out) + "\n", body_dyn

    # Hooks for the streams built on this one.
    def init_extra(self):
        pass

    def finish(self):
        pass

    def data_extra(self):
        return []


HEAD = """\
    .section .text.init, "ax"
    .globl _start
_start:
    la t0, gr_trap
    csrw mtvec, t0
    la t0, gr_save
    csrw mscratch, t0
    li t0, 3 << 13
    csrs mstatus, t0
    la gp, gr_data + 0x800
    la sp, gr_data + 0x1800
    li tp, 0
    li ra, 0"""

TRAP = """\
    .align 2
gr_trap:
    csrrw sp, mscratch, sp
    sd t0, 0(sp)
    sd t1, 8(sp)
    sd t2, 16(sp)
    csrr t0, mcause
    bltz t0, gr_fail
    andi t1, t0, {n}
    slli t1, t1, 3
    add t1, t1, sp
    ld t2, 64(t1)
    addi t2, t2, 1
    sd t2, 64(t1)
    li t1, 1
    beq t0, t1, 1f
    csrr t0, mepc
    lhu t1, 0(t0)
    andi t1, t1, 3
    li t2, 3
    addi t0, t0, 2
    bne t1, t2, 2f
    addi t0, t0, 2
    j 2f
1:  la t0, gr_resume
    ld t0, 0(t0)
2:  csrw mepc, t0
    ld t0, 0(sp)
    ld t1, 8(sp)
    ld t2, 16(sp)
    csrrw sp, mscratch, sp
    mret
gr_fail:
    li t0, 3
    la t1, tohost
    sw t0, 0(t1)
3:  j 3b
gr_pass:
    li t0, 1
    la t1, tohost
    sw t0, 0(t1)
4:  j 4b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
    .globl fromhost
fromhost:
    .dword 0
""".format(n=TRAP_CAUSES - 1)

Gen.HEAD = HEAD
Gen.TRAP = TRAP


def tool(name):
    """A riscv64-unknown-elf tool: the pinned toolchain/ of this tree or of the
    main checkout, else PATH."""
    exe = f"riscv64-unknown-elf-{name}"
    roots = [MASTER]
    try:
        common = subprocess.run(["git", "-C", str(MASTER), "rev-parse", "--git-common-dir"], text=True,
                                capture_output=True, check=True).stdout.strip()
        roots.append((MASTER / common).resolve().parent)
    except (OSError, subprocess.CalledProcessError):
        pass
    for root in roots:
        p = root / "toolchain" / "elf" / "bin" / exe
        if p.exists():
            return str(p)
    found = shutil.which(exe)
    if found:
        return found
    raise SystemExit(f"gen.py: {exe} not found (toolchain/fetch.sh elf)")


def bin2hex(binp, hexp):
    data = Path(binp).read_bytes()
    data += b"\0" * (-len(data) % 4)
    words = [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]
    Path(hexp).write_text("".join(f"{w:08X}\n" for w in words))


def stem_of(seed, priv=False, vec=False):
    return f"gr{'v' if vec else ''}{'p' if priv else ''}_{seed}"


def generate(seed, length, out, build=True, priv=False, vec=False):
    """Write gr[v][p]_<seed>.S (and .elf/.hex); returns (hex path, dynamic
    estimate)."""
    out.mkdir(parents=True, exist_ok=True)
    stem = out / stem_of(seed, priv, vec)
    march = MARCH_V if vec else MARCH
    if priv:
        import priv as privgen
        cls = privgen.PrivGen
        if vec:
            import vec as vecgen
            cls = vecgen.VecPrivGen
        src, dyn = cls(seed, length).build()
        ld, march = HERE / "gr_priv.ld", march + "_svinval"
    else:
        cls = Gen
        if vec:
            import vec as vecgen
            cls = vecgen.VecGen
        src, dyn = cls(seed, length).build()
        ld = HERE / "gr.ld"
    Path(f"{stem}.S").write_text(src)
    if build:
        subprocess.run([tool("gcc"), f"-march={march}", "-mabi=lp64d", "-nostdlib", "-nostartfiles", "-static", "-Wl,--no-warn-rwx-segments",
                        "-T", str(ld), "-o", f"{stem}.elf", f"{stem}.S"], check=True)
        subprocess.run([tool("objcopy"), "-O", "binary", f"{stem}.elf", f"{stem}.bin"], check=True)
        bin2hex(f"{stem}.bin", f"{stem}.hex")
        os.unlink(f"{stem}.bin")
    return Path(f"{stem}.hex"), dyn


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--length", type=int, default=3000, help="dynamic instructions to aim for (default 3000)")
    ap.add_argument("--out", type=Path, default=HERE / "build")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--priv", action="store_true", help="the privileged stream (test/gr/priv.py)")
    ap.add_argument("--vec", action="store_true", help="mix in the vector stream (test/gr/vec.py)")
    ap.add_argument("--excluded", action="store_true", help="print the exclusion table and exit")
    a = ap.parse_args()
    if a.excluded:
        table = dict(EXCLUDED)
        if a.priv:
            import priv as privgen
            table.pop("CSR writes other than fcsr/frm/fflags, xRET, privilege changes")
            table.update(privgen.PRIV_EXCLUDED)
        if a.vec:
            import vec as vecgen
            table.pop("vector, H")
            table["H"] = "a separate stream"
            table.update(vecgen.VEC_EXCLUDED)
        for k, v in table.items():
            print(f"{k}: {v}")
        return 0
    hexp, dyn = generate(a.seed, a.length, a.out, not a.no_build, a.priv, a.vec)
    print(json.dumps({"seed": a.seed, "hex": str(hexp), "dyn": dyn}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
