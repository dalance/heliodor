"""Vector random streams for the spike cosim (gen.py --vec [--priv]).

RVV 1.0 as the configuration declares it (Zve64d with VLEN 128, Zvbb/Zvkb,
Zvfhmin, Zvkt) mixed into the scalar stream (gen.Gen) or the privileged one
(priv.PrivGen). The generator tracks vtype, vl (or that it is unknown after a
fault-only-first load) and mstatus.VS, and emits only register groups that
are legal under the tracked vtype, except in the deliberate traps.

Control flow: the vector state must be the same on every path that reaches an
instruction. A forward branch or a loop body that changes it ends with a
vset that restores the state of its entry (made exact first), VS changes stay
outside branches and loops, and leaf functions carry no vector code.

Memory: unit-stride, strided (positive, negative and zero strides),
indexed (ordered and unordered; the index vector is built in place with
vid/vxor/vsll under a vtype of the index EEW and the same VLMAX, so its
values are known and distinct), segment (every NFIELDS the group rules
allow), whole-register, mask and fault-only-first accesses. Misaligned
elements trap (the configuration has no misaligned vector access). In the
M-mode stream a run of accesses ends at the top of DRAM, so an element past
it takes an access fault (or trims vl after element 0 of a fault-only-first
load). In the privileged stream accesses also go to the paged windows, where
a page fault on a later element resumes at vstart after the handler fixes the
PTE. A load or store may start at a vstart written just before it.

Handlers: an instruction that traps is skipped; when VS is on, the handler
first reads vstart and then clears it, so the next instruction starts at 0.

VEC_EXCLUDED lists what the stream never emits, with the reason.
"""

import gen
import priv

VLEN = 128
SEWS = (8, 16, 32, 64)
END = 0x8040_0000  # top of DRAM in the riscv-tests map: the next byte faults
END_PAGE = END - 0x1000

VEC_EXCLUDED = {
    "a load or store with vstart at or above its element count": "spike executes it, the configuration (and "
                                                                 "Sail) reserve it as illegal",
    "masked ops whose source group (or store data) contains v0; vwmacc/vwmaccu/vwmaccsu/vwmaccus with vd "
    "overlapping a source; masked reductions with vs2 or vs1 in v0": "spike executes these register-group "
                                                                     "encodings, which RVV reserves and the "
                                                                     "configuration (and Sail) make illegal",
    "a mask-producing op whose vd is a register of a source group other than its lowest": "spike raises "
        "illegal-instruction, the DUT executes it (the overlap rule of RVV 1.0 section 5.2 reserves it)",
    "masked vfredusum/vfwredusum": "with no active element the result is implementation-defined: spike adds "
                                   "the additive identity (a NaN vs1[0] becomes the canonical NaN), the DUT "
                                   "copies vs1[0] (VFREDUSUM_NAN no_change)",
    "vmv<nr>r.v while vill is set": "spike raises illegal-instruction (it checks vill), RVV says whole-register "
                                    "moves do not depend on vtype",
    "vector FP at SEW 16 other than the Zvfhmin conversions": "Zvfh is not implemented: only illegal",
    "unordered indexed stores whose elements overlap": "which element's value is kept is implementation-defined",
    "vector accesses to CLINT, PLIC, UART and Debug Module": "device reads return the DUT's values; vector "
                                                              "accesses are not given them",
    "vector code in leaf functions and VS changes inside branches or loops": "the generator would not know the "
                                                                              "vector state on every path",
    "vstart writes other than right before a load or store": "the next arithmetic op would trap on both "
                                                             "sides; the stream covers that case on purpose",
    "vector instructions before the first vset": "the reset vtype is implementation-defined (the DUT resets it to "
                                                 "0, spike to vill)",
    "the reserved encodings of the unit-stride lumop/sumop and of mew": "not covered by the decoder sweep of "
                                                                        "the stream",
}

FP_SEWS = (32, 64)


def vlmax(sew, lx):
    v = VLEN // sew
    return v << lx if lx >= 0 else v >> -lx


def legal(sew, lx):
    return sew in SEWS and -3 <= lx <= 3 and (lx >= 0 or sew <= 64 >> -lx)


def gs(x):
    """Registers in a group of EMUL 2^x."""
    return 1 << x if x > 0 else 1


def lg(n):
    return n.bit_length() - 1


def lmul_s(lx):
    return f"m{1 << lx}" if lx >= 0 else f"mf{1 << -lx}"


def vtype_s(sew, lx, ta, ma):
    return f"e{sew}, {lmul_s(lx)}, {'ta' if ta else 'tu'}, {'ma' if ma else 'mu'}"


def vtype_v(sew, lx, ta, ma):
    return (lg(sew // 8) << 3) | (lx & 7) | (ta << 6) | (ma << 7)


def ovl(a, an, b, bn):
    return a < b + bn and b < a + an


def v(r):
    return f"v{r}"


# Integer ops by operand forms (objdump spelling op.form).
I_VVXI = ["vadd", "vand", "vor", "vxor", "vsaddu", "vsadd"]
I_SHIFT = ["vsll", "vsrl", "vsra", "vssrl", "vssra"]   # .vi takes uimm5
I_VVX = ["vsub", "vminu", "vmin", "vmaxu", "vmax", "vssubu", "vssub", "vsmul", "vmul", "vmulh", "vmulhu",
         "vmulhsu", "vdivu", "vdiv", "vremu", "vrem", "vaaddu", "vaadd", "vasubu", "vasub", "vandn", "vrol"]
I_VXI = ["vrsub"]
I_MAC = ["vmacc", "vnmsac", "vmadd", "vnmsub"]
I_CMP_VVXI = ["vmseq", "vmsne", "vmsleu", "vmsle"]
I_CMP_VVX = ["vmsltu", "vmslt"]
I_CMP_VXI = ["vmsgtu", "vmsgt"]
I_RED = ["vredsum", "vredand", "vredor", "vredxor", "vredminu", "vredmin", "vredmaxu", "vredmax"]
I_WRED = ["vwredsumu", "vwredsum"]
W_VVX = ["vwaddu", "vwadd", "vwsubu", "vwsub", "vwmulu", "vwmulsu", "vwmul"]
W_W = ["vwaddu", "vwadd", "vwsubu", "vwsub"]          # .wv .wx
W_MAC = ["vwmaccu", "vwmacc", "vwmaccsu"]             # .vv .vx; vwmaccus .vx only
N_WVXI = ["vnsrl", "vnsra", "vnclipu", "vnclip"]
BB_UN = ["vbrev.v", "vbrev8.v", "vrev8.v", "vclz.v", "vctz.v", "vcpop.v"]
MASK_MM = ["vmand", "vmnand", "vmandn", "vmxor", "vmor", "vmnor", "vmorn", "vmxnor"]
F_VVF = ["vfadd", "vfsub", "vfmul", "vfdiv", "vfmin", "vfmax", "vfsgnj", "vfsgnjn", "vfsgnjx"]
F_VF = ["vfrsub", "vfrdiv"]
F_MAC = ["vfmacc", "vfnmacc", "vfmsac", "vfnmsac", "vfmadd", "vfnmadd", "vfmsub", "vfnmsub"]
F_UN = ["vfsqrt.v", "vfrsqrt7.v", "vfrec7.v", "vfclass.v"]
F_CMP_VVF = ["vmfeq", "vmfne", "vmflt", "vmfle"]
F_CMP_VF = ["vmfgt", "vmfge"]
F_RED = ["vfredusum", "vfredosum", "vfredmin", "vfredmax"]
F_CVT = ["vfcvt.xu.f.v", "vfcvt.x.f.v", "vfcvt.f.xu.v", "vfcvt.f.x.v", "vfcvt.rtz.xu.f.v", "vfcvt.rtz.x.f.v"]
FW_VVF = ["vfwadd", "vfwsub", "vfwmul"]
FW_W = ["vfwadd", "vfwsub"]                           # .wv .wf
FW_MAC = ["vfwmacc", "vfwnmacc", "vfwmsac", "vfwnmsac"]
FW_RED = ["vfwredusum", "vfwredosum"]
# Widening and narrowing conversions: mnemonic -> SEWs it is legal at.
FW_CVT = {"vfwcvt.xu.f.v": (32,), "vfwcvt.x.f.v": (32,), "vfwcvt.rtz.xu.f.v": (32,), "vfwcvt.rtz.x.f.v": (32,),
          "vfwcvt.f.xu.v": (16, 32), "vfwcvt.f.x.v": (16, 32), "vfwcvt.f.f.v": (16, 32)}
FN_CVT = {"vfncvt.xu.f.w": (16, 32), "vfncvt.x.f.w": (16, 32), "vfncvt.rtz.xu.f.w": (16, 32),
          "vfncvt.rtz.x.f.w": (16, 32), "vfncvt.f.xu.w": (32,), "vfncvt.f.x.w": (32,), "vfncvt.f.f.w": (16, 32),
          "vfncvt.rod.f.f.w": (32,)}
# The same conversions at the SEWs where they need Zvfh (illegal here).
FW_CVT_ZVFH = {"vfwcvt.xu.f.v": 16, "vfwcvt.x.f.v": 16, "vfwcvt.f.x.v": 8, "vfwcvt.f.xu.v": 8}
FN_CVT_ZVFH = {"vfncvt.f.x.w": 16, "vfncvt.f.xu.w": 16, "vfncvt.rod.f.f.w": 16, "vfncvt.xu.f.w": 8}

VCSRS = ["vstart", "vxsat", "vxrm", "vcsr", "vl", "vtype", "vlenb"]


def vec_mnemonics():
    m = ["vsetvli", "vsetivli", "vsetvl"]
    m += [f"{o}.{f}" for o in I_VVXI + I_SHIFT for f in ("vv", "vx", "vi")]
    m += [f"{o}.{f}" for o in I_VVX for f in ("vv", "vx")]
    m += ["vrsub.vx", "vrsub.vi", "vror.vv", "vror.vx", "vror.vi"]
    m += [f"{o}.{f}" for o in I_MAC for f in ("vv", "vx")]
    m += [f"{o}.{f}" for o in I_CMP_VVXI for f in ("vv", "vx", "vi")]
    m += [f"{o}.{f}" for o in I_CMP_VVX for f in ("vv", "vx")]
    m += [f"{o}.{f}" for o in I_CMP_VXI for f in ("vx", "vi")]
    m += [f"{o}.vs" for o in I_RED + I_WRED + F_RED + FW_RED]
    m += [f"{o}.{f}" for o in W_VVX for f in ("vv", "vx")]
    m += [f"{o}.{f}" for o in W_W for f in ("wv", "wx")]
    m += [f"{o}.{f}" for o in W_MAC for f in ("vv", "vx")] + ["vwmaccus.vx"]
    m += ["vwsll.vv", "vwsll.vx", "vwsll.vi"]
    m += [f"{o}.{f}" for o in N_WVXI for f in ("wv", "wx", "wi")]
    m += [f"v{s}ext.vf{k}" for s in "zs" for k in (2, 4, 8)]
    m += BB_UN
    m += ["vadc.vvm", "vadc.vxm", "vadc.vim", "vsbc.vvm", "vsbc.vxm", "vmadc.vvm", "vmadc.vxm", "vmadc.vim",
          "vmadc.vv", "vmadc.vx", "vmadc.vi", "vmsbc.vvm", "vmsbc.vxm", "vmsbc.vv", "vmsbc.vx"]
    m += ["vmerge.vvm", "vmerge.vxm", "vmerge.vim", "vmv.v.v", "vmv.v.x", "vmv.v.i", "vmv.x.s", "vmv.s.x"]
    m += [f"vmv{n}r.v" for n in (1, 2, 4, 8)]
    m += ["vslideup.vx", "vslideup.vi", "vslidedown.vx", "vslidedown.vi", "vslide1up.vx", "vslide1down.vx",
          "vrgather.vv", "vrgather.vx", "vrgather.vi", "vrgatherei16.vv", "vcompress.vm"]
    m += [f"{o}.mm" for o in MASK_MM]
    m += ["vcpop.m", "vfirst.m", "vmsbf.m", "vmsif.m", "vmsof.m", "viota.m", "vid.v"]
    m += [f"{o}.{f}" for o in F_VVF for f in ("vv", "vf")]
    m += [f"{o}.vf" for o in F_VF]
    m += [f"{o}.{f}" for o in F_MAC for f in ("vv", "vf")]
    m += F_UN + F_CVT
    m += [f"{o}.{f}" for o in F_CMP_VVF for f in ("vv", "vf")]
    m += [f"{o}.vf" for o in F_CMP_VF]
    m += ["vfmerge.vfm", "vfmv.v.f", "vfmv.f.s", "vfmv.s.f", "vfslide1up.vf", "vfslide1down.vf"]
    m += [f"{o}.{f}" for o in FW_VVF for f in ("vv", "vf")]
    m += [f"{o}.{f}" for o in FW_W for f in ("wv", "wf")]
    m += [f"{o}.{f}" for o in FW_MAC for f in ("vv", "vf")]
    m += list(FW_CVT) + list(FN_CVT)
    for e in SEWS:
        m += [f"vle{e}.v", f"vse{e}.v", f"vle{e}ff.v", f"vlse{e}.v", f"vsse{e}.v"]
        m += [f"v{o}ei{e}.v" for o in ("lux", "lox", "sux", "sox")]
        for nf in range(2, 9):
            m += [f"vlseg{nf}e{e}.v", f"vsseg{nf}e{e}.v", f"vlseg{nf}e{e}ff.v", f"vlsseg{nf}e{e}.v",
                  f"vssseg{nf}e{e}.v"]
            m += [f"v{o}seg{nf}ei{e}.v" for o in ("lux", "lox", "sux", "sox")]
        m += [f"vl{n}re{e}.v" for n in (1, 2, 4, 8)]
    m += [f"vs{n}r.v" for n in (1, 2, 4, 8)] + ["vlm.v", "vsm.v"]
    return m


VEC_MNEMONICS = vec_mnemonics()


class VecMixin:
    """The vector part of a stream; mixed in front of gen.Gen or
    priv.PrivGen."""

    VEC_P = 0.45

    def v_init_state(self):
        self.vs = 1
        self.vill = True
        self.sew, self.lx, self.ta, self.ma = 8, 0, 0, 0
        self.vl = 0
        self.depth = 0
        self.vs_off_left = 0
        self.no_vset = False

    # State.
    def vstate(self):
        return (self.vill, self.sew, self.lx, self.ta, self.ma, self.vl)

    def vlmax_(self):
        return 0 if self.vill else vlmax(self.sew, self.lx)

    def G(self):
        return gs(self.lx)

    def W(self):
        """Registers in a group of EMUL 2*LMUL."""
        return gs(self.lx + 1)

    def emul(self, eew):
        x = self.lx + lg(eew) - lg(self.sew)
        return x if -3 <= x <= 3 else None

    def pick(self, n, avoid=(), nov0=False, base=None):
        c = [b for b in range(0, 32, n) if not (nov0 and b == 0) and not any(ovl(b, n, a, an) for a, an in avoid)]
        if base is not None and base in c:
            return base
        return self.ch(c) if c else None

    def xreg(self):
        return self.ch(self.pool)

    def vm(self, ok=True):
        return ok and self.p(0.3)

    def mk(self, masked):
        return ", v0.t" if masked else ""

    def vtrapped(self):
        """Whether a vector op traps now: VS off or vill."""
        return self.vs == 0 or self.vill

    # vset.
    def v_set_raw(self, sew, lx, ta, ma, form=None, avl=None, rd=None):
        """Emit a vset* to a legal vtype and track the result."""
        vt = vtype_s(sew, lx, ta, ma)
        vmax = vlmax(sew, lx)
        rd = (0 if self.p(0.3) else self.xreg()) if rd is None else rd
        form = form or self.ch(["vli", "vli", "vli", "vli0", "ivli", "ivli", "vl", "vl0"])
        if form == "keep":
            self.emit(f"vsetvli x0, x0, {vt}")
            self.sew, self.lx, self.ta, self.ma = sew, lx, ta, ma
            return
        if avl is None:
            avl = self.avl(vmax)
        if form == "ivli":
            avl = min(avl, 31) if avl >= 0 else self.r.randrange(32)
            self.emit(f"vsetivli {gen.fx(rd)}, {avl}, {vt}")
            vl = min(avl, vmax)
        elif form in ("vli0", "vl0"):
            rd = rd or self.ch(self.pool)
            if form == "vli0":
                self.emit(f"vsetvli {gen.fx(rd)}, x0, {vt}")
            else:
                rt = self.xreg()
                self.li(rt, vtype_v(sew, lx, ta, ma))
                self.emit(f"vsetvl {gen.fx(rd)}, x0, {gen.fx(rt)}")
            vl = vmax
        else:
            ra = self.xreg()
            self.li(ra, avl)
            if form == "vli":
                self.emit(f"vsetvli {gen.fx(rd)}, {gen.fx(ra)}, {vt}")
            else:
                rt = self.ch([x for x in self.pool if x != ra])
                self.li(rt, vtype_v(sew, lx, ta, ma))
                self.emit(f"vsetvl {gen.fx(rd)}, {gen.fx(ra)}, {gen.fx(rt)}")
            vl = min(avl & (2**64 - 1), vmax)
        self.vill = False
        self.sew, self.lx, self.ta, self.ma, self.vl = sew, lx, ta, ma, vl

    def avl(self, vmax):
        r = self.r
        k = r.randrange(11)
        return [0, 1, r.randrange(1, vmax + 1), vmax - 1 if vmax > 1 else 1, vmax, vmax, vmax + 1,
                r.randrange(vmax + 1, 2 * vmax), 2 * vmax, r.getrandbits(64), (1 << r.randrange(5, 40))][k]

    def rand_mode(self, pred=None):
        modes = [(s, x) for s in SEWS for x in range(-3, 4) if legal(s, x) and (pred is None or pred(s, x))]
        return self.ch(modes)

    def ensure(self, pred=None):
        """Make vtype legal (and satisfy pred) with a vset when it is not.
        While no_vset, only the assumed vtype of a trapping op changes."""
        if self.vill or (pred and not pred(self.sew, self.lx)):
            s, x = self.rand_mode(pred)
            if self.no_vset:
                self.sew, self.lx = s, x
                return
            self.v_set_raw(s, x, self.r.randrange(2), self.r.randrange(2))

    def g_vset(self):
        r = self.r
        k = r.random()
        if k < 0.75:
            s, x = self.rand_mode()
            if not self.vill and self.p(0.15):
                # Keep vl: a vtype with the same VLMAX.
                same = [(s2, x2) for s2 in SEWS for x2 in range(-3, 4)
                        if legal(s2, x2) and vlmax(s2, x2) == vlmax(self.sew, self.lx)]
                s, x = self.ch(same)
                self.v_set_raw(s, x, r.randrange(2), r.randrange(2), form="keep")
                return
            self.v_set_raw(s, x, r.randrange(2), r.randrange(2))
            return
        if k < 0.82 and not self.vill:
            # vsetvli x0, x0 with another VLMAX: reserved, sets vill.
            s, x = self.ch([(s2, x2) for s2 in SEWS for x2 in range(-3, 4)
                            if legal(s2, x2) and vlmax(s2, x2) != vlmax(self.sew, self.lx)])
            self.emit(f"vsetvli x0, x0, {vtype_s(s, x, r.randrange(2), r.randrange(2))}")
            self.set_vill()
            return
        # A reserved vtype: vill = 1, vl = 0.
        ill = r.choice([
            (lambda: (lg(r.choice(SEWS) // 8) << 3) | 4 | (r.getrandbits(2) << 6)),           # LMUL code 4
            (lambda: (r.randrange(4, 8) << 3) | r.choice([0, 1, 2, 3, 5, 6, 7])),               # SEW >= 128
            (lambda: self.frac_ill()),                                                           # SEW > LMUL*ELEN
            (lambda: vtype_v(*self.rand_mode(), r.randrange(2), r.randrange(2)) | (1 << 8)),   # altfmt
            (lambda: vtype_v(*self.rand_mode(), 0, 0) | (1 << r.randrange(9, 11))),
        ])()
        rd = 0 if self.p(0.3) else self.xreg()
        form = r.randrange(4)
        if form == 0 and ill < 1 << 11:
            ra = self.xreg()
            self.li(ra, self.avl(16))
            self.emit(f"vsetvli {gen.fx(rd)}, {gen.fx(ra)}, {ill}")
        elif form == 1 and ill < 1 << 10:
            self.emit(f"vsetivli {gen.fx(rd)}, {r.randrange(32)}, {ill}")
        else:
            if self.p(0.3):
                ill = r.getrandbits(64) | (1 << r.randrange(11, 64))
            ra, rt = r.sample(self.pool, 2)
            self.li(ra, self.avl(16))
            self.li(rt, ill)
            self.emit(f"vsetvl {gen.fx(rd)}, {gen.fx(ra)}, {gen.fx(rt)}")
        self.set_vill()

    def frac_ill(self):
        x = self.r.randrange(-3, 0)
        s = self.ch([s for s in SEWS if s > 64 >> -x])
        return vtype_v(s, x, self.r.randrange(2), self.r.randrange(2))

    def set_vill(self):
        self.vill = True
        self.vl = 0

    def v_restore(self, st):
        """Set the vector state to st (vl exact)."""
        vill, sew, lx, ta, ma, vl = st
        if vill:
            ra, rt = self.r.sample(self.pool, 2)
            self.li(rt, 1 << 63)
            self.emit(f"vsetvl x0, {gen.fx(ra)}, {gen.fx(rt)}")
            self.set_vill()
            return
        if vl < 32:
            self.emit(f"vsetivli x0, {vl}, {vtype_s(sew, lx, ta, ma)}")
        else:
            ra = self.xreg()
            self.li(ra, vl)
            self.emit(f"vsetvli x0, {gen.fx(ra)}, {vtype_s(sew, lx, ta, ma)}")
        self.vill, self.sew, self.lx, self.ta, self.ma, self.vl = st

    def v_exact(self):
        """Make vl known (it is unknown after a fault-only-first load)."""
        if self.vs and not self.vill and self.vl is None:
            self.v_restore((False, self.sew, self.lx, self.ta, self.ma, self.r.randrange(vlmax(self.sew, self.lx) + 1)))

    def vec_ok(self):
        return not self.in_func

    def v_region_begin(self):
        if not self.vec_ok():
            return None
        self.v_exact()
        self.depth += 1
        return self.vstate()

    def v_region_end(self, st):
        if st is None:
            return
        self.depth -= 1
        if self.vstate() != st and self.vs:
            self.v_restore(st)

    def fwd_branch(self, n):
        st = self.v_region_begin()
        super().fwd_branch(n)
        self.v_region_end(st)

    def loop(self):
        if not self.vec_ok():
            return super().loop()
        st = self.v_region_begin()
        n = self.r.randrange(1, 9)
        top = self.label("loop")
        self.emit(f"li tp, {n}")
        self.put(f"{top}:")
        save = self.mult
        self.mult *= n
        for _ in range(self.r.randrange(1, 5)):
            self.block(allow_loop=False)
        if self.vstate() != st and self.vs:
            self.v_restore(st)
        self.emit("addi tp, tp, -1")
        self.emit(f"bnez tp, {top}")
        self.mult = save
        self.depth -= 1

    def one(self):
        if self.vec_ok() and self.p(self.VEC_P):
            return self.g_vec()
        return super().one()

    # VS.
    def can_write_vs(self):
        return self.depth == 0

    def vs_csr(self):
        return "mstatus"

    def g_vs(self, val=None):
        if not self.can_write_vs():
            return False
        val = self.ch([0, 1, 2, 3]) if val is None else val
        csr = self.vs_csr()
        t = self.xreg()
        self.li(t, 3 << 9)
        self.emit(f"csrc {csr}, {gen.fx(t)}")
        if val:
            self.li(t, val << 9)
            self.emit(f"csrs {csr}, {gen.fx(t)}")
        if self.p(0.3):
            self.emit(f"csrr {gen.fx(self.xw())}, {csr}")
        self.vs = val
        self.vs_off_left = self.r.randrange(1, 4) if val == 0 else 0
        return True

    # Dispatch.
    def g_vec(self):
        r = self.r
        if self.vs == 0:
            if self.vs_off_left <= 0 and self.g_vs(self.ch([1, 2, 3])):
                return
            self.vs_off_left -= 1
            st = self.vstate()
            self.v_body(trapping=True)
            self.vill, self.sew, self.lx, self.ta, self.ma, self.vl = st
            return
        if self.vill:
            k = r.random()
            if k < 0.25:
                st = self.vstate()
                self.v_body(trapping=True)
                self.vill, self.sew, self.lx, self.ta, self.ma, self.vl = st
                return
            if k < 0.35:
                return self.g_vwhole()
            if k < 0.4:
                return self.g_vcsr()
            self.ensure()
            return
        if self.p(0.01) and self.g_vs():
            return
        self.v_body()

    def v_body(self, trapping=False):
        """One vector group. With trapping, the op runs while VS is off or
        vill is set: it is generated under a legal vtype that the state is
        restored from afterwards."""
        vill = trapping and self.vill
        if vill:
            # Nothing may execute a vset: vill must stay set.
            s, x = self.rand_mode()
            self.vill, self.sew, self.lx, self.vl = False, s, x, vlmax(s, x)
            self.no_vset = True
        tbl = [(0.06, self.g_vset), (0.20, self.g_vint), (0.26, self.g_vcmp), (0.33, self.g_vwide),
               (0.38, self.g_vnarrow), (0.43, self.g_vcarry), (0.48, self.g_vred), (0.55, self.g_vperm),
               (0.60, self.g_vmask), (0.70, self.g_vfp), (0.76, self.g_vfcvt), (0.80, self.g_vbb),
               (0.95, self.g_vldst), (0.975, self.g_vcsr), (1.0, self.g_vtrap)]
        if trapping:
            tbl = tbl[1:-1] if vill else tbl[1:]
        k = self.r.random() * tbl[-1][0]
        try:
            for lim, f in tbl:
                if k < lim:
                    return f()
            return tbl[-1][1]()
        finally:
            self.no_vset = False

    # Integer.
    def same3(self, masked, need_vs1=True, dis_vd_vs2=False, dis_vd_vs1=False):
        """(vd, vs2, vs1) groups at EEW SEW."""
        n = self.G()
        vs2 = self.pick(n, nov0=masked)
        vs1 = self.pick(n, nov0=masked) if need_vs1 else None
        avoid = []
        if dis_vd_vs2:
            avoid.append((vs2, n))
        if dis_vd_vs1 and vs1 is not None:
            avoid.append((vs1, n))
        base = None if avoid or self.p(0.7) else self.ch([vs2] + ([vs1] if vs1 is not None else []))
        vd = self.pick(n, avoid, nov0=masked, base=base)
        if vd is None:
            return None
        return vd, vs2, vs1

    def simm5(self):
        return self.r.randrange(-16, 16)

    def g_vint(self):
        r = self.r
        self.ensure()
        k = r.random()
        masked = self.vm()
        regs = self.same3(masked)
        if regs is None:
            return
        vd, vs2, vs1 = regs
        m = self.mk(masked)
        if k < 0.35:
            op = self.ch(I_VVXI + I_SHIFT + I_VVX + I_VXI + ["vror"])
            forms = (["vv", "vx", "vi"] if op in I_VVXI + I_SHIFT + ["vror"] else
                     ["vx", "vi"] if op in I_VXI else ["vv", "vx"])
            f = self.ch(forms)
            if f == "vv":
                self.emit(f"{op}.vv {v(vd)}, {v(vs2)}, {v(vs1)}{m}")
            elif f == "vx":
                self.emit(f"{op}.vx {v(vd)}, {v(vs2)}, {gen.fx(self.xr())}{m}")
            else:
                imm = r.randrange(64) if op == "vror" else r.randrange(32) if op in I_SHIFT else self.simm5()
                self.emit(f"{op}.vi {v(vd)}, {v(vs2)}, {imm}{m}")
        elif k < 0.5:
            op = self.ch(I_MAC)
            if self.p(0.5):
                self.emit(f"{op}.vv {v(vd)}, {v(vs1)}, {v(vs2)}{m}")
            else:
                self.emit(f"{op}.vx {v(vd)}, {gen.fx(self.xr())}, {v(vs2)}{m}")
        elif k < 0.6:
            # vmerge / vmv.v: v0 is the selector of vmerge.
            if self.p(0.6):
                regs = self.same3(True)
                if regs is None:
                    return
                vd, vs2, vs1 = regs
                f = self.ch(["vvm", "vxm", "vim"])
                src = {"vvm": v(vs1), "vxm": gen.fx(self.xr()), "vim": self.simm5()}[f]
                self.emit(f"vmerge.{f} {v(vd)}, {v(vs2)}, {src}, v0")
            else:
                f = self.ch(["v", "x", "i"])
                src = {"v": v(vs1), "x": gen.fx(self.xr()), "i": self.simm5()}[f]
                self.emit(f"vmv.v.{f} {v(vd)}, {src}")
        elif k < 0.75:
            # Extensions: the source EEW is SEW/f.
            f = self.ch([2, 4, 8])
            ex = self.lx - lg(f)
            if self.sew // f < 8 or ex < -3:
                return self.emit(f"vadd.vi {v(vd)}, {v(vs2)}, {self.simm5()}{m}")
            src = self.pick(gs(ex), nov0=masked)
            dst = self.pick(self.G(), [(src, gs(ex))], nov0=masked)
            if dst is None:
                return
            self.emit(f"v{self.ch('zs')}ext.vf{f} {v(dst)}, {v(src)}{m}")
        elif k < 0.85:
            # Scalar moves.
            if self.p(0.5):
                self.emit(f"vmv.x.s {gen.fx(self.xw())}, {v(r.randrange(32))}")
            else:
                self.emit(f"vmv.s.x {v(r.randrange(32))}, {gen.fx(self.xr())}")
        elif not self.no_vset:
            n = self.ch([1, 2, 4, 8])
            self.emit(f"vmv{n}r.v {v(self.pick(n))}, {v(self.pick(n))}")

    def g_vbb(self):
        self.ensure()
        masked = self.vm()
        regs = self.same3(masked)
        if regs is None:
            return
        vd, vs2, vs1 = regs
        self.emit(f"{self.ch(BB_UN)} {v(vd)}, {v(vs2)}{self.mk(masked)}")

    def g_vcmp(self):
        r = self.r
        self.ensure()
        masked = self.vm()
        n = self.G()
        vs2 = self.pick(n, nov0=masked)
        vs1 = self.pick(n, nov0=masked)
        if self.p(0.15):
            vd = vs2  # the lowest register of the source group
        else:
            vd = self.pick(1, [(vs2, n), (vs1, n)])
        if vd is None:
            return
        m = self.mk(masked)
        op = self.ch(I_CMP_VVXI + I_CMP_VVX + I_CMP_VXI)
        forms = ["vv", "vx", "vi"] if op in I_CMP_VVXI else ["vv", "vx"] if op in I_CMP_VVX else ["vx", "vi"]
        f = self.ch(forms)
        src = {"vv": v(vs1), "vx": gen.fx(self.xr()), "vi": self.simm5()}[f]
        self.emit(f"{op}.{f} {v(vd)}, {v(vs2)}, {src}{m}")

    def g_vcarry(self):
        self.ensure()
        n = self.G()
        r = self.r
        op = self.ch(["vadc", "vsbc", "vmadc", "vmsbc"])
        carry = op in ("vadc", "vsbc") or self.p(0.5)
        vs2 = self.pick(n, nov0=carry)
        vs1 = self.pick(n, nov0=carry)
        if op in ("vadc", "vsbc"):
            vd = self.pick(n, nov0=True, base=None if self.p(0.7) else vs2)
        else:
            vd = vs2 if self.p(0.15) else self.pick(1, [(vs2, n), (vs1, n)], nov0=carry)
        if vd is None:
            return
        forms = ["vv", "vx"] + (["vi"] if op in ("vadc", "vmadc") else [])
        f = self.ch(forms)
        src = {"vv": v(vs1), "vx": gen.fx(self.xr()), "vi": self.simm5()}[f]
        if carry:
            self.emit(f"{op}.{f}m {v(vd)}, {v(vs2)}, {src}, v0")
        else:
            self.emit(f"{op}.{f} {v(vd)}, {v(vs2)}, {src}")

    def g_vwide(self):
        """Widening integer ops, vwsll and the widening FP ops."""
        r = self.r
        fp = self.p(0.35)
        if fp:
            self.ensure(lambda s, x: s == 32 and x <= 2)
        else:
            self.ensure(lambda s, x: s <= 32 and x <= 2)
        n = self.G()
        w = self.W()
        masked = self.vm()
        m = self.mk(masked)
        vd = self.pick(w, nov0=masked)
        k = r.random()
        wform = k < 0.25
        mac = 0.25 <= k < 0.5
        strict = mac
        vs2w = None
        if wform:
            vs2w = vd if self.p(0.3) else self.pick(w, nov0=masked)
        avoid = [(vd, w)] if strict or self.lx < 0 or self.p(0.7) else []
        # A source in the upper half of the destination is allowed (source EMUL >= 1).
        hi = vd + n if not avoid and self.lx >= 0 else None
        vs2 = self.pick(n, avoid, nov0=masked, base=hi)
        vs1 = self.pick(n, avoid + ([(vs2w, w)] if wform else []), nov0=masked, base=hi)
        if vs2 is None or vs1 is None:
            return
        rs = gen.fx(self.xr())
        fs = gen.ff(self.ch(gen.FR))
        if fp:
            if wform:
                f = self.ch(["wv", "wf"])
                self.emit(f"{self.ch(FW_W)}.{f} {v(vd)}, {v(vs2w)}, {v(vs1) if f == 'wv' else fs}{m}")
            elif mac:
                if self.p(0.5):
                    self.emit(f"{self.ch(FW_MAC)}.vv {v(vd)}, {v(vs1)}, {v(vs2)}{m}")
                else:
                    self.emit(f"{self.ch(FW_MAC)}.vf {v(vd)}, {fs}, {v(vs2)}{m}")
            else:
                f = self.ch(["vv", "vf"])
                self.emit(f"{self.ch(FW_VVF)}.{f} {v(vd)}, {v(vs2)}, {v(vs1) if f == 'vv' else fs}{m}")
            return
        if wform:
            f = self.ch(["wv", "wx"])
            self.emit(f"{self.ch(W_W)}.{f} {v(vd)}, {v(vs2w)}, {v(vs1) if f == 'wv' else rs}{m}")
        elif mac:
            op = self.ch(W_MAC + ["vwmaccus"])
            if op != "vwmaccus" and self.p(0.5):
                self.emit(f"{op}.vv {v(vd)}, {v(vs1)}, {v(vs2)}{m}")
            else:
                self.emit(f"{op}.vx {v(vd)}, {rs}, {v(vs2)}{m}")
        elif k < 0.65:
            f = self.ch(["vv", "vx", "vi"])
            src = {"vv": v(vs1), "vx": rs, "vi": r.randrange(32)}[f]
            self.emit(f"vwsll.{f} {v(vd)}, {v(vs2)}, {src}{m}")
        else:
            f = self.ch(["vv", "vx"])
            self.emit(f"{self.ch(W_VVX)}.{f} {v(vd)}, {v(vs2)}, {v(vs1) if f == 'vv' else rs}{m}")

    def g_vnarrow(self):
        r = self.r
        self.ensure(lambda s, x: s <= 32 and x <= 2)
        n = self.G()
        w = self.W()
        masked = self.vm()
        vs2 = self.pick(w, nov0=masked)
        vd = vs2 if self.p(0.15) else self.pick(n, [(vs2, w)], nov0=masked)
        vs1 = self.pick(n, [(vs2, w)], nov0=masked)
        if vd is None or vs1 is None:
            return
        f = self.ch(["wv", "wx", "wi"])
        src = {"wv": v(vs1), "wx": gen.fx(self.xr()), "wi": r.randrange(32)}[f]
        self.emit(f"{self.ch(N_WVXI)}.{f} {v(vd)}, {v(vs2)}, {src}{self.mk(masked)}")

    def g_vred(self):
        r = self.r
        k = r.random()
        if k < 0.45:
            self.ensure()
            ops, w = I_RED, False
        elif k < 0.6:
            self.ensure(lambda s, x: s <= 32)
            ops, w = I_WRED, True
        elif k < 0.85:
            self.ensure(lambda s, x: s in FP_SEWS)
            ops, w = F_RED, False
        else:
            self.ensure(lambda s, x: s == 32)
            ops, w = FW_RED, True
        op = self.ch(ops)
        masked = self.vm(op not in ("vfredusum", "vfwredusum"))
        n = self.G()
        vs2 = self.pick(n, nov0=masked)
        vs1 = self.pick(1, [(vs2, n)] if w else [], nov0=masked)
        vd = self.pick(1, [(vs2, n)] if w else [])
        if vs1 is None or vd is None:
            return
        self.emit(f"{op}.vs {v(vd)}, {v(vs2)}, {v(vs1)}{self.mk(masked)}")

    def g_vperm(self):
        r = self.r
        k = r.random()
        if k < 0.12:
            self.ensure(lambda s, x: s in FP_SEWS)
        else:
            self.ensure()
        n = self.G()
        masked = self.vm()
        m = self.mk(masked)
        vs2 = self.pick(n, nov0=masked)
        rs = gen.fx(self.xreg())
        if k < 0.12:
            op = self.ch(["vfslide1up", "vfslide1down"])
            vd = self.pick(n, [(vs2, n)] if op == "vfslide1up" else [], nov0=masked)
            self.emit(f"{op}.vf {v(vd)}, {v(vs2)}, {gen.ff(self.ch(gen.FR))}{m}")
        elif k < 0.4:
            op = self.ch(["vslideup", "vslidedown", "vslide1up", "vslide1down"])
            up = op in ("vslideup", "vslide1up")
            vd = self.pick(n, [(vs2, n)] if up else [], nov0=masked)
            if op.startswith("vslide1"):
                self.emit(f"{op}.vx {v(vd)}, {v(vs2)}, {rs}{m}")
            elif self.p(0.5):
                if self.p(0.5):
                    self.li(int(rs[1:]), self.ch([0, 1, 2, 3, r.randrange(256), 2**64 - 1, 1 << 40]))
                self.emit(f"{op}.vx {v(vd)}, {v(vs2)}, {rs}{m}")
            else:
                self.emit(f"{op}.vi {v(vd)}, {v(vs2)}, {r.randrange(32)}{m}")
        elif k < 0.75:
            f = self.ch(["vv", "vx", "vi", "ei16"])
            if f == "ei16":
                ex = self.emul(16)
                if ex is None:
                    f = "vv"
            if f in ("vv", "ei16"):
                n1 = n if f == "vv" else gs(ex)
                vs1 = self.pick(n1, [(vs2, n)] if n1 != n or f == "ei16" else [], nov0=masked)
                vd = self.pick(n, [(vs2, n), (vs1, n1)], nov0=masked)
                if vs1 is None or vd is None:
                    return
                self.emit(f"{'vrgatherei16.vv' if f == 'ei16' else 'vrgather.vv'} {v(vd)}, {v(vs2)}, {v(vs1)}{m}")
            else:
                vd = self.pick(n, [(vs2, n)], nov0=masked)
                if vd is None:
                    return
                if f == "vx":
                    if self.p(0.5):
                        self.li(int(rs[1:]), r.randrange(self.vlmax_() + 2))
                    self.emit(f"vrgather.vx {v(vd)}, {v(vs2)}, {rs}{m}")
                else:
                    self.emit(f"vrgather.vi {v(vd)}, {v(vs2)}, {r.randrange(32)}{m}")
        else:
            vs2 = self.pick(n)
            vs1 = self.pick(1, [(vs2, n)])
            vd = self.pick(n, [(vs2, n), (vs1, 1)])
            if vd is None or vs1 is None:
                return
            self.emit(f"vcompress.vm {v(vd)}, {v(vs2)}, {v(vs1)}")

    def g_vmask(self):
        r = self.r
        self.ensure()
        k = r.random()
        masked = self.vm()
        m = self.mk(masked)
        if k < 0.3:
            self.emit(f"{self.ch(MASK_MM)}.mm {v(r.randrange(32))}, {v(r.randrange(32))}, {v(r.randrange(32))}")
        elif k < 0.5:
            self.emit(f"{self.ch(['vcpop.m', 'vfirst.m'])} {gen.fx(self.xw())}, {v(r.randrange(32))}{m}")
        elif k < 0.7:
            vs2 = r.randrange(32)
            vd = self.pick(1, [(vs2, 1)], nov0=masked)
            self.emit(f"{self.ch(['vmsbf.m', 'vmsif.m', 'vmsof.m'])} {v(vd)}, {v(vs2)}{m}")
        elif k < 0.85:
            vs2 = r.randrange(32)
            vd = self.pick(self.G(), [(vs2, 1)], nov0=masked)
            if vd is None:
                return
            self.emit(f"viota.m {v(vd)}, {v(vs2)}{m}")
        else:
            self.emit(f"vid.v {v(self.pick(self.G(), nov0=masked))}{m}")

    # FP.
    def g_vfp(self):
        r = self.r
        self.ensure(lambda s, x: s in FP_SEWS)
        k = r.random()
        masked = self.vm()
        m = self.mk(masked)
        regs = self.same3(masked)
        if regs is None:
            return
        vd, vs2, vs1 = regs
        fs = gen.ff(self.ch(gen.FR))
        if k < 0.3:
            op = self.ch(F_VVF + F_VF)
            f = "vf" if op in F_VF or self.p(0.5) else "vv"
            self.emit(f"{op}.{f} {v(vd)}, {v(vs2)}, {v(vs1) if f == 'vv' else fs}{m}")
        elif k < 0.5:
            op = self.ch(F_MAC)
            if self.p(0.5):
                self.emit(f"{op}.vv {v(vd)}, {v(vs1)}, {v(vs2)}{m}")
            else:
                self.emit(f"{op}.vf {v(vd)}, {fs}, {v(vs2)}{m}")
        elif k < 0.62:
            self.emit(f"{self.ch(F_UN + F_CVT)} {v(vd)}, {v(vs2)}{m}")
        elif k < 0.75:
            op = self.ch(F_CMP_VVF + F_CMP_VF)
            f = "vf" if op in F_CMP_VF or self.p(0.5) else "vv"
            n = self.G()
            w = self.W()
            d = vs2 if self.p(0.15) else self.pick(1, [(vs2, n), (vs1, n)])
            if d is None:
                return
            self.emit(f"{op}.{f} {v(d)}, {v(vs2)}, {v(vs1) if f == 'vv' else fs}{m}")
        elif k < 0.85:
            regs = self.same3(True)
            if regs is None:
                return
            self.emit(f"vfmerge.vfm {v(regs[0])}, {v(regs[1])}, {fs}, v0")
        elif k < 0.92:
            self.emit(f"vfmv.v.f {v(vd)}, {fs}")
        else:
            if self.p(0.5):
                self.emit(f"vfmv.f.s {fs}, {v(r.randrange(32))}")
            else:
                self.emit(f"vfmv.s.f {v(r.randrange(32))}, {fs}")
        if self.p(0.1):
            self.v_fpload()

    def g_vfcvt(self):
        r = self.r
        if self.p(0.5):
            op = self.ch(list(FW_CVT))
            sews = FW_CVT[op]
            self.ensure(lambda s, x: s in sews and x <= 2)
            n = self.G()
            w = self.W()
            masked = self.vm()
            vd = self.pick(w, nov0=masked)
            vs2 = self.pick(n, [(vd, w)], nov0=masked)
            if vs2 is None:
                return
            self.emit(f"{op} {v(vd)}, {v(vs2)}{self.mk(masked)}")
        else:
            op = self.ch(list(FN_CVT))
            sews = FN_CVT[op]
            self.ensure(lambda s, x: s in sews and x <= 2)
            n = self.G()
            w = self.W()
            masked = self.vm()
            vs2 = self.pick(w, nov0=masked)
            vd = vs2 if self.p(0.15) else self.pick(n, [(vs2, w)], nov0=masked)
            if vd is None:
                return
            self.emit(f"{op} {v(vd)}, {v(vs2)}{self.mk(masked)}")

    def v_fpload(self):
        """Load FP special values into a register group."""
        e = self.sew
        x = self.emul(e)
        rb = self.xreg()
        self.v_fpconst_ptr(rb, self.r.randrange(0, 8 * 32, 8))
        vd = self.pick(gs(x))
        self.emit(f"vle{e}.v {v(vd)}, ({gen.fx(rb)})")

    def v_fpconst_ptr(self, rx, off):
        self.emit(f"la {gen.fx(rx)}, gr_fpconst + {off}", 2)

    # CSRs.
    def g_vcsr(self):
        r = self.r
        k = r.random()
        rd = self.xw()
        if k < 0.4:
            self.emit(f"csrr {gen.fx(rd)}, {self.ch(VCSRS)}")
        elif k < 0.6:
            self.emit(f"csrwi vxrm, {r.randrange(4)}")
        elif k < 0.8:
            name = self.ch(["vxrm", "vxsat", "vcsr"])
            rx = self.xreg()
            self.li(rx, self.xval())
            self.emit(f"{self.ch(['csrrw', 'csrrs', 'csrrc'])} {gen.fx(rd)}, {name}, {gen.fx(rx)}")
        else:
            name = self.ch(["vxrm", "vxsat", "vcsr"])
            self.emit(f"{self.ch(['csrrwi', 'csrrsi', 'csrrci'])} {gen.fx(rd)}, {name}, {r.randrange(32)}")

    # Deliberate traps.
    def g_vtrap(self):
        r = self.r
        k = r.randrange(12)
        if k == 0:
            # Arithmetic with vstart != 0.
            self.ensure()
            self.emit(f"csrwi vstart, {r.randrange(1, 32)}")
            self.emit(f"vadd.vv {v(self.pick(self.G()))}, {v(self.pick(self.G()))}, {v(self.pick(self.G()))}")
        elif k == 1:
            # Vector FP at SEW 8 or 16 (no Zvfh).
            s, x = self.rand_mode(lambda s, x: s <= 16)
            self.v_set_raw(s, x, r.randrange(2), r.randrange(2))
            op = self.ch(["vfadd.vv v8, v16, v24", "vfmul.vf v8, v16, f1", "vfsqrt.v v8, v16", "vfmv.f.s f2, v3",
                          "vfmv.s.f v3, f2", "vmfeq.vv v1, v2, v3", "vfredosum.vs v1, v2, v3",
                          "vfcvt.x.f.v v8, v16"])
            self.emit(op)
        elif k == 2:
            # Conversions that need Zvfh.
            op, s = self.ch(list(FW_CVT_ZVFH.items()) + list(FN_CVT_ZVFH.items()))
            x = self.ch([x for x in range(-3, 3) if legal(s, x)])
            self.v_set_raw(s, x, r.randrange(2), r.randrange(2))
            self.emit(f"{op} v8, v16")
        elif k == 3:
            # Widening at SEW 64 or LMUL 8, narrowing from EMUL 16.
            if self.p(0.5):
                self.v_set_raw(64, r.randrange(0, 3), r.randrange(2), r.randrange(2))
            else:
                self.v_set_raw(self.ch([8, 16, 32]), 3, r.randrange(2), r.randrange(2))
            self.emit(self.ch(["vwadd.vv v8, v16, v24", "vwmul.vx v8, v16, x5", "vnsrl.wv v8, v16, v24",
                               "vfwadd.vv v8, v16, v24", "vzext.vf2 v8, v16", "vwredsum.vs v1, v8, v2"]))
        elif k == 4:
            # Register-group misalignment and overlaps that spike also rejects.
            s, x = self.rand_mode(lambda s, x: 1 <= x <= 2 and s <= 32)
            self.v_set_raw(s, x, r.randrange(2), r.randrange(2))
            n = gs(x)
            odd = r.randrange(1, n)
            w = gs(x + 1)
            self.emit(self.ch([
                f"vadd.vv v{8 + odd}, v16, v24",
                f"vadd.vv v8, v{16 + odd}, v24",
                f"vadd.vv v8, v16, v{24 + odd}",
                f"vle{s}.v v{8 + odd}, (sp)",
                f"vwadd.vv v8, v8, v{8 + w}",                       # source in the low half of vd
                f"vnsrl.wv v{8 + n}, v8, v16",                     # vd in the high half of vs2
                "vrgather.vv v8, v8, v16",
                "vrgather.vv v8, v16, v8",
                "vslideup.vx v8, v8, x5",
                "vcompress.vm v8, v8, v1",
                "viota.m v8, v8",
                "vmsbf.m v8, v8",
                f"vzext.vf2 v8, v8",
                f"vl2re{s}.v v{2 * r.randrange(16) + 1}, (sp)",
            ]))
        elif k == 5:
            # Masked op writing v0 (its result is not a mask).
            self.ensure()
            self.emit(self.ch([f"vadd.vv v0, v{self.G() * 2 % 32 or 8}, v{self.G() * 2 % 32 or 8}, v0.t",
                               f"vid.v v0, v0.t", f"vle{self.sew}.v v0, (sp), v0.t", "viota.m v0, v1, v0.t",
                               "vmsbf.m v0, v1, v0.t"]))
        elif k == 6:
            # Reserved frm with vector FP.
            self.ensure(lambda s, x: s in FP_SEWS)
            t = self.xreg()
            self.emit(f"fsrmi {gen.fx(t)}, {r.choice([5, 6, 7])}")
            n = self.G()
            self.emit(self.ch([f"vfadd.vv v{n}, v{2 * n % 32}, v{3 * n % 32}", f"vfsgnj.vv v{n}, v{n}, v{n}",
                               f"vmfeq.vf v1, v{2 * n % 32}, f3", f"vfmv.f.s f4, v{n}", f"vfmv.s.f v{n}, f5",
                               f"vfclass.v v{n}, v{2 * n % 32}", f"vfmv.v.f v{n}, f6",
                               f"vfredusum.vs v1, v{n}, v2", f"vfcvt.f.x.v v{n}, v{n}"]))
            self.emit(f"fsrm {gen.fx(t)}")
        elif k == 7:
            # Segment register span: NFIELDS*EMUL > 8 or past v31.
            s, x = self.rand_mode(lambda s, x: x >= 1)
            self.v_set_raw(s, x, r.randrange(2), r.randrange(2))
            n = gs(x)
            nf = 8 // n + 1
            if nf <= 8 and (n == 8 or self.p(0.5)):
                self.emit(f"vlseg{nf}e{s}.v v{n}, (sp)")
            else:
                nf = r.randrange(2, 8 // n + 1)
                self.emit(f"vsseg{nf}e{s}.v v{32 - n}, (sp)")
        elif k == 8:
            # Writes to read-only vector CSRs.
            self.emit(f"{self.ch(['csrw', 'csrs'])} {self.ch(['vl', 'vtype', 'vlenb'])}, {gen.fx(self.r.randrange(1, 32))}")
        elif k == 9:
            # Reserved OPV encodings: funct6 holes of OPIVV/OPIVI/OPMVV.
            vd, vs2, vs1 = (r.randrange(32) for _ in range(3))
            f6, f3 = self.ch([(f, 0) for f in (0b000011, 0b011110, 0b011111, 0b001111)]
                             + [(f, 3) for f in (0b000010, 0b000100, 0b000101, 0b000110, 0b000111, 0b011010,
                                                 0b011011, 0b100010, 0b100011, 0b010010, 0b010011)]
                             + [(f, 2) for f in (0b001100, 0b001101, 0b010001, 0b010101, 0b101000, 0b101010,
                                                 0b111001, 0b111110)])
            enc = (f6 << 26) | (1 << 25) | (vs2 << 20) | (vs1 << 15) | (f3 << 12) | (vd << 7) | 0x57
            self.ensure()
            self.emit(f".insn 4, {enc:#010x}")
        elif k == 10:
            # vtype-dependent op after a reserved vtype.
            ra, rt = r.sample(self.pool, 2)
            self.li(rt, self.frac_ill())
            self.emit(f"vsetvl x0, {gen.fx(ra)}, {gen.fx(rt)}")
            self.set_vill()
            self.emit(self.ch(["vadd.vv v1, v2, v3", "vmv.x.s x0, v1", "vle8.v v1, (sp)", "vcpop.m x5, v1",
                               "vfmv.f.s f1, v2"]))
        else:
            # Unordered indexed load with a misaligned index element.
            self.g_vindexed(misalign=True)

    # Memory.
    def g_vldst(self):
        r = self.r
        k = r.random()
        if k < 0.3:
            self.g_vunit()
        elif k < 0.48:
            self.g_vstrided()
        elif k < 0.66:
            self.g_vindexed()
        elif k < 0.78:
            self.g_vwhole()
        elif k < 0.86:
            self.g_vmaskmem()
        else:
            self.g_vunit(ff=True)

    def v_vstart(self, count):
        """Maybe start the next access at a vstart below its element count."""
        if count > 1 and self.p(0.12):
            k = self.r.randrange(1, count)
            if k < 32:
                self.emit(f"csrwi vstart, {k}")
            else:
                t = self.xreg()
                self.li(t, k)
                self.emit(f"csrw vstart, {gen.fx(t)}")

    def fields(self, nf, g, masked, extra=()):
        """Base of nf consecutive groups of g registers (segment fields)."""
        c = [b for b in range(0, 33 - nf * g, g) if not (masked and b == 0)
             and not any(ovl(b, nf * g, a, an) for a, an in extra)]
        return self.ch(c) if c else None

    def mem_seg(self, g):
        """NFIELDS for groups of g registers."""
        if self.p(0.6) or 8 // g < 2:
            return 1
        return self.r.randrange(2, 8 // g + 1)

    def fault_dist(self, n, elem):
        """Byte distance from the base to the faulting boundary for an
        access whose element i starts at i * elem (n elements), or None."""
        if not self.p(0.12):
            return None
        return self.r.randrange(n) * elem + self.r.randrange(0, max(elem, 1))

    def g_vunit(self, ff=False):
        self.ensure()
        st = self.p(0.45) and not ff
        e = self.ch([e for e in SEWS if self.emul(e) is not None])
        g = gs(self.emul(e))
        nf = self.mem_seg(g)
        masked = self.vm()
        vd = self.fields(nf, g, masked)
        if vd is None:
            return
        size = e // 8
        vmax = self.vlmax_()
        rb, crossed = self.v_base(0, vmax * nf * size, size, self.fault_dist(vmax, nf * size))
        if not crossed:
            self.v_vstart(vmax)
        seg = "" if nf == 1 else f"seg{nf}"
        self.emit(f"v{'s' if st else 'l'}{seg}e{e}{'ff' if ff else ''}.v {v(vd)}, ({gen.fx(rb)}){self.mk(masked)}")
        if ff:
            self.vl = None

    def g_vstrided(self):
        r = self.r
        self.ensure()
        st = self.p(0.45)
        e = self.ch([e for e in SEWS if self.emul(e) is not None])
        g = gs(self.emul(e))
        nf = self.mem_seg(g)
        masked = self.vm()
        vd = self.fields(nf, g, masked)
        if vd is None:
            return
        size = e // 8
        vmax = self.vlmax_()
        k = r.random()
        if k < 0.1:
            stride = 0
        elif k < 0.15:
            stride = r.randrange(1, 64) * self.ch([1, -1])  # misaligned unless a multiple of the size
        else:
            hi = max(1, 2048 // ((vmax - 1) * size) if vmax > 1 else 64)
            stride = (nf * size if self.p(0.3) else r.randrange(1, hi + 1) * size) * self.ch([1, 1, -1])
        lo = min(0, (vmax - 1) * stride)
        hi_ = max(0, (vmax - 1) * stride) + nf * size
        fd = self.fault_dist(vmax, stride) if stride > 0 else None
        rb, crossed = self.v_base(lo, hi_, size, fd)
        rs = 0
        if stride:
            rs = self.ch([x for x in self.pool if x != rb])
            self.li(rs, stride)
        if not crossed:
            self.v_vstart(vmax)
        seg = "" if nf == 1 else f"seg{nf}"
        self.emit(f"v{'s' if st else 'l'}s{seg}e{e}.v {v(vd)}, ({gen.fx(rb)}), {gen.fx(rs)}{self.mk(masked)}")

    def g_vindexed(self, misalign=False):
        r = self.r
        self.ensure()
        st = self.p(0.45)
        ei = self.ch([e for e in SEWS if self.emul(e) is not None])
        xi = self.emul(ei)
        gi = gs(xi)
        g = self.G()
        nf = self.mem_seg(g)
        masked = self.vm()
        vi = self.pick(gi, nov0=masked)
        vd = self.fields(nf, g, masked, [(vi, gi)])
        if vd is None:
            return
        size = self.sew // 8
        vmax = self.vlmax_()
        step = nf * size
        sh_min = lg(step) + (1 if step & (step - 1) else 0)
        cap = 255 if ei == 8 else 2048
        if (vmax - 1) << sh_min > cap:
            return
        sh_max = sh_min
        while (vmax - 1) << (sh_max + 1) <= cap and sh_max < 11:
            sh_max += 1
        sh = r.randrange(sh_min, sh_max + 1)
        c = r.randrange(vmax)
        mis = r.randrange(1, size) if (misalign or self.p(0.04)) and size > 1 else 0
        # The index vector, built under e<ei> with the same VLMAX: element
        # i is (i ^ c) << sh, all distinct; mis makes some misaligned.
        self.emit(f"vsetvli x0, x0, {vtype_s(ei, xi, r.randrange(2), r.randrange(2))}")
        self.emit(f"vid.v {v(vi)}")
        if c:
            if c < 16 and self.p(0.5):
                self.emit(f"vxor.vi {v(vi)}, {v(vi)}, {c}")
            else:
                t = self.xreg()
                self.li(t, c)
                self.emit(f"vxor.vx {v(vi)}, {v(vi)}, {gen.fx(t)}")
        if sh:
            self.emit(f"vsll.vi {v(vi)}, {v(vi)}, {sh}")
        if mis:
            self.emit(f"vadd.vi {v(vi)}, {v(vi)}, {mis}" + (", v0.t" if vi and self.p(0.7) else ""))
        self.emit(f"vsetvli x0, x0, {vtype_s(self.sew, self.lx, self.ta, self.ma)}")
        hi = ((vmax - 1) << sh) + mis + step
        fd = r.randrange(0, hi) if self.p(0.08) else None
        rb, crossed = self.v_base(0, hi, size, fd)
        if not crossed:
            self.v_vstart(vmax)
        o = self.ch("uo")
        seg = "ei" if nf == 1 else f"seg{nf}ei"
        self.emit(f"v{'s' if st else 'l'}{o}x{seg}{ei}.v {v(vd)}, ({gen.fx(rb)}), {v(vi)}{self.mk(masked)}")

    def g_vwhole(self):
        n = self.ch([1, 2, 4, 8])
        e = self.ch(SEWS)
        st = self.p(0.45)
        size = 1 if st else e // 8
        count = n * VLEN // 8 // size
        rb, crossed = self.v_base(0, n * VLEN // 8, size, self.fault_dist(count, size))
        if not crossed:
            self.v_vstart(count)
        if st:
            self.emit(f"vs{n}r.v {v(self.pick(n))}, ({gen.fx(rb)})")
        else:
            self.emit(f"vl{n}re{e}.v {v(self.pick(n))}, ({gen.fx(rb)})")

    def g_vmaskmem(self):
        self.ensure()
        st = self.p(0.45)
        rb, crossed = self.v_base(0, VLEN // 8, 1, self.fault_dist(VLEN // 8, 1))
        if not crossed:
            self.v_vstart(VLEN // 8)
        self.emit(f"{'vsm.v' if st else 'vlm.v'} {v(self.r.randrange(32))}, ({gen.fx(rb)})")

    # Addresses (M-mode stream; the privileged stream overrides v_base).
    VREGIONS = (("gr_vdata", 0x2000), ("gr_data", 0x2000))

    def v_base(self, lo, hi, size, fault=None):
        """A register holding a base address such that the byte offsets
        [lo, hi) from it fall in a data region; with fault, the top of DRAM
        is that many bytes above the base instead. Returns (register,
        whether a later element may fault)."""
        r = self.r
        rb = self.xreg()
        if fault is not None:
            base = END - fault
            base -= base % size
            self.li(rb, base)
            return rb, True
        name, sz = self.ch(self.VREGIONS)
        if hi - lo > sz:
            return self.v_base(lo, hi, size, r.randrange(hi))
        off = r.randrange(-lo, sz - hi + 1)
        off -= off % size
        if off + lo < 0:
            off += size
        if size > 1 and self.p(0.03):
            off += r.randrange(1, size)
        self.emit(f"la {gen.fx(rb)}, {name} + {off}", 2)
        return rb, False

    # Program pieces.
    def v_prologue(self):
        """Initial vector state: VS on, a vtype, the 32 registers from
        gr_vinit."""
        s, x = self.rand_mode()
        self.v_set_raw(s, x, self.r.randrange(2), self.r.randrange(2))
        rx = self.xreg()
        self.emit(f"la {gen.fx(rx)}, gr_vinit", 2)
        for i in range(4):
            self.emit(f"vl8re8.v v{8 * i}, ({gen.fx(rx)})")
            if i < 3:
                self.emit(f"addi {gen.fx(rx)}, {gen.fx(rx)}, 128")
        self.emit(f"csrwi vxrm, {self.r.randrange(4)}")
        s, x = self.rand_mode()
        self.v_set_raw(s, x, self.r.randrange(2), self.r.randrange(2))

    def v_epilogue(self):
        """Read back the memory vector stores may have written."""
        if self.vs == 0:
            self.g_vs(1)
        rx = self.xreg()
        for name, sz in self.VREGIONS[:1] + (("end", 0x1000),):
            if name == "end":
                self.li(rx, END_PAGE)
            else:
                self.emit(f"la {gen.fx(rx)}, {name}", 2)
            for i in range(sz // 128):
                self.emit(f"vl8re64.v v{8 * (i % 4)}, ({gen.fx(rx)})")
                self.emit(f"addi {gen.fx(rx)}, {gen.fx(rx)}, 128")

    def v_data(self, vdata=True):
        r = self.r
        out = ["    .align 12"]
        if vdata:
            out.append("gr_vdata:")
            data = [r.getrandbits(64) for _ in range(0x2000 // 8)]
            for i in range(0, len(data), 5):
                data[i] = r.choice(gen.D_SPECIAL + [(r.choice(gen.S_SPECIAL) << 32) | r.choice(gen.S_SPECIAL)])
            out += [f"    .dword {x:#018x}" for x in data]
        out.append("gr_vinit:")
        init = [r.getrandbits(64) for _ in range(512 // 8)]
        for i in range(0, len(init), 3):
            init[i] = r.choice(gen.D_SPECIAL + [(r.choice(gen.S_SPECIAL) << 32) | r.choice(gen.S_SPECIAL)])
        out += [f"    .dword {x:#018x}" for x in init]
        return out


class VecGen(VecMixin, gen.Gen):
    def __init__(self, seed, length):
        super().__init__(seed, length)
        self.v_init_state()

    HEAD = gen.HEAD.replace("li t0, 3 << 13", "li t0, (3 << 13) | (1 << 9)")
    TRAP = gen.TRAP.replace("2:  csrw mepc, t0\n", """\
2:  csrw mepc, t0
    csrr t1, mstatus
    srli t1, t1, 9
    andi t1, t1, 3
    beqz t1, 5f
    csrr t1, vstart
    csrwi vstart, 0
5:
""")

    def init_extra(self):
        self.v_prologue()

    def finish(self):
        self.v_epilogue()

    def data_extra(self):
        return self.v_data()


class VecPrivGen(VecMixin, priv.PrivGen):
    # VS changes only through g_vs, so the generator knows it.
    MS_KEEP = priv.MSTATUS_KEEP | (3 << 9)
    SS_KEEP = priv.SSTATUS_KEEP | (3 << 9)
    HEAD = priv.HEAD.replace("li t0, 3 << 13", "li t0, (3 << 13) | (1 << 9)")

    def __init__(self, seed, length):
        super().__init__(seed, length)
        self.v_init_state()
        self.v_mprv = False

    def handler(self, x):
        """The handler of priv.py, plus: a skipped instruction clears
        vstart (after reading it) when VS is on, and a page fault is
        retried unless the same pc faulted at the same address just
        before (a vector access may fault on a later page after a fix)."""
        h = priv.handler(x)
        old = f"1:  csrw {x}epc, t0\n.L{x}ret:\n"
        assert old in h
        h = h.replace(old, f"""1:  csrw {x}epc, t0
    csrr t1, {x}status
    srli t1, t1, 9
    andi t1, t1, 3
    beqz t1, .L{x}ret
    csrr t1, vstart
    csrwi vstart, 0
.L{x}ret:
""")
        old = f"    sd t0, 40(sp)\n    beq t0, t1, .L{x}skip\n"
        assert old in h
        return h.replace(old, f"""    sd t0, 40(sp)
    csrr t2, {x}tval
    ld t3, 48(sp)
    sd t2, 48(sp)
    bne t0, t1, 8f
    beq t2, t3, .L{x}skip
8:
""")

    def csr_val(self, name):
        v = super().csr_val(name)
        if name in ("mstatus", "sstatus"):
            v = (v & ~(3 << 9)) | (self.vs << 9)
        return v

    def g_csr(self):
        # A leaf function may run under either VS value: no status writes.
        if self.in_func:
            self.M_CSRS = [c for c in priv.PrivGen.M_CSRS if c != "mstatus"]
            self.S_CSRS = [c for c in priv.PrivGen.S_CSRS if c != "sstatus"]
        try:
            super().g_csr()
        finally:
            self.__dict__.pop("M_CSRS", None)
            self.__dict__.pop("S_CSRS", None)

    def can_write_vs(self):
        return self.depth == 0 and self.mode in (1, 3)

    def vs_csr(self):
        return "mstatus" if self.mode == 3 else "sstatus"

    def v_fpconst_ptr(self, rx, off):
        self.li(rx, self.shared() + priv.FPC_OFF + off)

    def v_regions(self):
        """(base, size, faults past the end) of the data regions of the
        current mode."""
        home = (self.home(), 0x2000, False)
        if self.v_mprv:
            return [(sl.va + sl.win_off(), 0x1000, sl.level == 0) for sl in self.slots]
        if not self.translated():
            return [home, (priv.WIN_PA, priv.WIN_PAGES * 0x1000, False)]
        out = [home]
        for sl in self.slots:
            if sl.level == 0:
                out.append((sl.va, 0x1000, True))
            else:
                out.append((sl.va + sl.win_off(), priv.WIN_PAGES * 0x1000, False))
        return out

    def v_base(self, lo, hi, size, fault=None):
        r = self.r
        rb = self.xreg()
        regs = [g for g in self.v_regions() if g[1] >= hi - lo] or [max(self.v_regions(), key=lambda g: g[1])]
        base, sz, edge = self.ch(regs)
        if fault is not None and edge:
            a = base + sz - fault
            a -= a % size
            self.li(rb, a)
            return rb, True
        off = r.randrange(-lo, max(-lo, sz - hi) + 1)
        off -= off % size
        if off + lo < 0:
            off += size
        if size > 1 and self.p(0.03):
            off += r.randrange(1, size)
        self.li(rb, base + off)
        return rb, False

    def g_mprv(self):
        """The MPRV snippet of priv.py with vector accesses mixed in."""
        if not self.p(0.4):
            return super().g_mprv()
        t = self.ch(self.pool)
        self.li(t, 0x1800)
        self.emit(f"csrc mstatus, {gen.fx(t)}")
        self.li(t, priv.MSTATUS_MPRV | (self.ch([0, 1]) << 11) | (self.ch([0, priv.MSTATUS_SUM])
                                                                  | self.ch([0, priv.MSTATUS_MXR])))
        self.emit(f"csrs mstatus, {gen.fx(t)}")
        self.v_mprv = True
        for _ in range(self.r.randrange(1, 4)):
            if self.vs and self.p(0.6):
                self.ch([self.g_vunit, self.g_vstrided, self.g_vwhole, lambda: self.g_vunit(ff=True)])()
            else:
                self.g_vmem(self.mprv_addr)
        self.v_mprv = False
        self.li(t, priv.MSTATUS_MPRV | priv.MSTATUS_SUM | priv.MSTATUS_MXR)
        self.emit(f"csrc mstatus, {gen.fx(t)}")

    def v_epilogue(self):
        if self.vs == 0:
            self.g_vs(1)
        rx = self.xreg()
        for base, sz in ((priv.WIN_PA, priv.WIN_PAGES * 0x1000), (priv.HOME_MS, 0x4000)):
            self.li(rx, base)
            for i in range(sz // 128):
                self.emit(f"vl8re64.v v{8 * (i % 4)}, ({gen.fx(rx)})")
                self.emit(f"addi {gen.fx(rx)}, {gen.fx(rx)}, 128")

    def init_extra(self):
        self.v_prologue()

    def finish(self):
        self.v_epilogue()

    def data_extra(self):
        return self.v_data(vdata=False)
