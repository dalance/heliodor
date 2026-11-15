"""Privileged random streams for the spike cosim (gen.py --priv).

The program moves between M, S and U in segments. S and U run with Sv39 on
one of a few address spaces (each its own root table and ASID) or with satp
Bare. Code is identity-mapped in every address space (S code and the
handlers in .text, U code in .utext) and never remapped; each mode has a
private 8 KiB home region at gp/sp for the scalar mix of gen.Gen. Data
windows are VA slots (4 KiB, NAPOT 64 KiB, 2 MiB and 1 GiB leaves) that
every address space maps with its own random permissions, A/D bits and
targets, or leaves invalid; the stream accesses them, rewrites their PTEs
followed by a covering fence (sfence.vma in its four forms or the Svinval
sequence), switches satp, toggles SUM/MXR, uses MPRV from M, reprograms PMP
over the window pages, and reads and writes the M and S CSRs with WARL
fields.

Traps: medeleg is random (ecall from U and from S are never both
delegated, so M stays reachable). The M and S handlers share one scheme:
an ecall is followed by a word, 0 to return after it, else 1 + an index
into gr_desc (target pc, mode, satp, fence) for a mode change; fetch faults
resume at the address the stream stored in the resume slot; a load or store
page fault on a window is resolved from gr_rtab (the window's full-access
PTE for the faulting mode, then a fence, then retry) when the table marks
it resolvable and the same pc did not just fault, and skipped otherwise;
everything else is skipped. Interrupts are never enabled.

The program never loads a PTE: an OoO core may set A speculatively under
Svadu, which only such a load could observe. menvcfg.ADUE is fixed per
program for the same reason.
"""

import gen

POOL = 0x8030_0000
HOME_MS = POOL               # M and S home, two pages, identity
HOME_U_PA = POOL + 0x2000    # U home, two pages
SHARED_PA = POOL + 0x4000    # resume slot and FP constants, reachable from U
WIN_PA = POOL + 0x1_0000     # window pages, 64 KiB aligned for NAPOT
WIN_PAGES = 16
DATA_PA = 0x8020_0000
PT_PA = 0x8021_0000
UH_VA = 0xC000_0000          # U home and the shared page in every address space
RES_OFF = 0
FPC_OFF = 0x100

SATP_SV39 = 8 << 60
V, R, W, X, U, G, A, D = (1 << i for i in range(8))
N_BIT = 1 << 63

MSTATUS_SUM = 1 << 18
MSTATUS_MXR = 1 << 19
MSTATUS_MPRV = 1 << 17
# Never written at random: MPRV (only in the MPRV snippets), TVM and TSR (the
# S handler uses satp, sfence.vma and sret), TW, SDT and MDT (a trap with
# them set is a double trap), MPV and GVA (H).
MSTATUS_KEEP = (1 << 17) | (1 << 20) | (1 << 21) | (1 << 22) | (1 << 24) | (1 << 42) | (1 << 39) | (1 << 38)
SSTATUS_KEEP = 1 << 24
# menvcfg: STCE (stimecmp would raise STIP), PMM (pointer masking), SSE/LPE
# (not implemented) and ADUE (fixed per program) are not written at random.
MENVCFG_KEEP = (1 << 63) | (1 << 61) | (3 << 32) | (1 << 3) | (1 << 2)
SENVCFG_KEEP = (3 << 32) | (1 << 3) | (1 << 2)

PRIV_EXCLUDED = {
    "interrupts (mie, sie, mip, sip writes; Sstc)": "no source is enabled: a timer or software interrupt is taken "
                                                     "where the DUT's pipeline lets it, so the program would not be "
                                                     "a function of the seed",
    "loads of PTEs": "Svadu allows the A bit to be set speculatively; only a load of the PTE could see it",
    "menvcfg.ADUE changes inside a program": "a PTE whose A the DUT set speculatively under ADUE=1 would not "
                                             "fault after ADUE=0",
    "mstatus.TVM/TSR/TW/MPRV/MDT/SDT/MPV/GVA random writes": "they would break the handlers or raise double traps; "
                                                             "MPRV is used in dedicated snippets",
    "PTE PBMT != 0, bits 60:59": "IO/NC on DRAM changes misaligned and atomic behaviour per implementation; spike "
                                 "has no Svrsw60t59b",
    "pointer masking (PMM in menvcfg, senvcfg, mseccfg)": "left for a later stream",
    "PMP lock bit, mseccfg": "a locked entry stays until reset and applies to M",
    "PTE writes without a covering fence": "which translation a stale TLB entry gives is implementation-defined",
    "misaligned accesses across a window boundary": "which part's fault is reported is implementation-defined",
    "trigger CSRs": "breakpoints are a debug stream",
}


# The privileged instructions the stream should contain, on top of the scalar
# mix (run_gr.py --priv lists the ones no program contains).
PRIV_MNEMONICS = """
csrrc csrrci csrrs csrrsi csrrw csrrwi ebreak c.ebreak ecall fence.i mret sret sfence.vma sinval.vma
sfence.w.inval sfence.inval.ir cbo.zero cbo.clean prefetch.w amocas.w lr.d sc.w
""".split()


def canon(va):
    return va | 0xFFFF_FF80_0000_0000 if va >> 38 & 1 else va


def pte(pa, fl):
    return ((pa >> 12) << 10) | fl


class Slot:
    """A VA range each address space maps with one leaf (or leaves invalid)."""

    def __init__(self, va, level, napot=False):
        self.va, self.level, self.napot = va, level, napot
        self.size = 1 << (12 + 9 * level)
        if napot:
            self.size = 0x1_0000

    def base_pa(self):
        return {0: None, 1: DATA_PA, 2: 0x8000_0000}[self.level]

    def win_off(self):
        """Offset in the slot of the first window page."""
        if self.level == 0:
            return 0
        return WIN_PA - self.base_pa()


class AddrSpace:
    def __init__(self, idx, asid, root):
        self.idx, self.asid, self.root = idx, asid, root
        self.satp = SATP_SV39 | (asid << 44) | (root >> 12)
        self.ptes = {}  # slot index -> (PTE address, initial target PA)


class PrivGen(gen.Gen):
    def __init__(self, seed, length):
        super().__init__(seed, length)
        self.out = {"text": [], "utext": []}
        self.sec = "text"
        self.lines = self.out["text"]
        self.mode = 3
        self.cur = None  # current address space, None for Bare
        self.deleg = 0
        self.desc = []
        self.rtab = []
        self.pt = {}  # pa -> value
        self.pt_next = PT_PA
        self.adue = self.p(0.5)

    # Page tables.
    def alloc(self):
        a = self.pt_next
        self.pt_next += 0x1000
        return a

    def setpte(self, table, idx, v):
        self.pt[table + 8 * idx] = v

    def build_tables(self):
        r = self.r
        id_l1, id_l0, uh_l1, uh_l0 = (self.alloc() for _ in range(4))
        self.setpte(id_l1, 0, pte(id_l0, V))
        self.setpte(id_l1, 1, pte(DATA_PA, V | R | W | A | D | G))
        for i in range(512):
            pa = 0x8000_0000 + 0x1000 * i
            if i == 1:
                fl = V | R | W | A | D | G
            elif i < 0x100:
                fl = V | R | X | A | G
            else:
                fl = V | R | X | U | A | G
            self.setpte(id_l0, i, pte(pa, fl))
        self.setpte(uh_l1, 0, pte(uh_l0, V))
        for i, pa in enumerate([HOME_U_PA, HOME_U_PA + 0x1000, SHARED_PA]):
            self.setpte(uh_l0, i, pte(pa, V | R | W | U | A | D | G))

        # Slots: VPN2 0-3 are the holes, the identity map and the U home.
        vpn2s = r.sample(list(range(4, 512)), 8)
        self.slots = []
        for v2 in vpn2s[:r.randrange(1, 3)]:
            self.slots.append(Slot(canon(v2 << 30), 2))
        self.l1_regions = vpn2s[2:2 + r.randrange(1, 3)]
        for v2 in self.l1_regions:
            vpn1s = r.sample(range(512), 6)
            for v1 in vpn1s[:r.randrange(0, 3)]:
                self.slots.append(Slot(canon((v2 << 30) | (v1 << 21)), 1))
            for v1 in vpn1s[3:3 + r.randrange(1, 3)]:
                vpn0s = r.sample(range(0, 512, 16), 6)
                for v0 in vpn0s[:r.randrange(2, 6)]:
                    self.slots.append(Slot(canon((v2 << 30) | (v1 << 21) | (v0 << 12)), 0))
                if self.p(0.6):
                    v0 = vpn0s[5]
                    self.slots.append(Slot(canon((v2 << 30) | (v1 << 21) | (v0 << 12)), 0, napot=True))
        # Address spaces; sometimes two share an ASID.
        n = r.randrange(2, 5)
        asids = r.sample(range(1 << 16), n)
        if n > 2 and self.p(0.3):
            asids[-1] = asids[0]
        self.spaces = []
        for k in range(n):
            s = AddrSpace(k, asids[k], self.alloc())
            self.setpte(s.root, 2, pte(id_l1, V))
            self.setpte(s.root, 3, pte(uh_l1, V))
            l1 = {}
            l0 = {}
            for i, sl in enumerate(self.slots):
                v2 = sl.va >> 30 & 511
                v1 = sl.va >> 21 & 511
                v0 = sl.va >> 12 & 511
                if sl.level == 2:
                    addr = s.root + 8 * v2
                else:
                    if v2 not in l1:
                        l1[v2] = self.alloc()
                        self.setpte(s.root, v2, pte(l1[v2], V))
                    if sl.level == 1:
                        addr = l1[v2] + 8 * v1
                    else:
                        if (v2, v1) not in l0:
                            l0[(v2, v1)] = self.alloc()
                            self.setpte(l1[v2], v1, pte(l0[(v2, v1)], V))
                        addr = l0[(v2, v1)] + 8 * v0
                tgt = self.target(sl)
                val = self.rand_leaf(sl, tgt) if self.p(0.85) else 0
                self.pt[addr] = val
                s.ptes[i] = (addr, tgt)
                fix = V | R | W | A | D
                self.rtab.append((s.satp, ~(sl.size - 1) & (2**64 - 1), sl.va, addr,
                                  self.leaf(sl, tgt, fix), self.leaf(sl, tgt, fix | U), int(self.p(0.8))))
            self.spaces.append(s)

    def target(self, sl):
        if sl.level:
            return sl.base_pa()
        if sl.napot:
            return WIN_PA
        return WIN_PA + 0x1000 * self.r.randrange(WIN_PAGES)

    def leaf(self, sl, tgt, fl):
        v = pte(tgt, fl)
        if sl.napot:
            v |= N_BIT | (0b1000 << 10)
        return v

    def rand_leaf(self, sl, tgt):
        r = self.r
        perm = r.choices([R, R | W, R | X, R | W | X, X, W, W | X], [4, 6, 2, 3, 2, 1, 1])[0]
        fl = V | perm
        if self.p(0.5):
            fl |= U
        if self.p(0.75):
            fl |= A
        if self.p(0.6):
            fl |= D
        if self.p(0.03):
            fl &= ~V
        v = self.leaf(sl, tgt, fl)
        k = r.random()
        if k < 0.03:
            v |= 1 << r.randrange(54, 59)  # reserved
        elif k < 0.06 and sl.level:
            v |= 1 << (10 + 9 * (sl.level - 1) + r.randrange(9 if sl.level == 2 else 1))  # misaligned superpage
        elif k < 0.08 and sl.level == 0:
            v |= N_BIT  # N with a PPN that is not a 64 KiB NAPOT encoding
        return v

    # Mode-dependent addresses.
    def translated(self):
        return self.mode != 3 and self.cur is not None

    def home(self):
        if self.mode == 0:
            return UH_VA if self.translated() else HOME_U_PA
        return HOME_MS

    def shared(self):
        return UH_VA + 0x2000 if self.mode == 0 and self.translated() else SHARED_PA

    def set_section(self, sec):
        if not self.rvc:
            self.put("    .option pop")
            self.rvc = True
        self.sec = sec
        self.lines = self.out[sec]

    def enter(self, label):
        self.set_section("utext" if self.mode == 0 else "text")
        self.put(f"{label}:")
        h = self.home()
        self.li(3, h + 0x800)
        self.li(2, h + 0x1800)

    # Overrides of the scalar mix.
    def fp_reload(self):
        rx = self.ch(self.pool)
        self.li(rx, self.shared() + FPC_OFF)
        self.emit(f"fld {gen.ff(self.ch(gen.FR))}, {8 * self.r.randrange(len(self.fpconst))}({gen.fx(rx)})")

    def call(self):
        f = f"gr_{'u' if self.mode == 0 else ''}func{self.r.randrange(self.nfunc)}"
        k = self.r.randrange(3)
        if k == 0:
            self.emit(f"jal ra, {f}")
        else:
            rx = self.ch(self.pool)
            self.emit(f"la {gen.fx(rx)}, {f}", 2)
            self.emit(f"c.jalr {gen.fx(rx)}" if self.rvc and k == 1 else f"jalr ra, {gen.fx(rx)}, 0")
        self.dyn += self.fsize * self.mult

    def g_trap(self):
        r = self.r
        k = r.randrange(10)
        if k == 0:
            self.emit("ecall")
            self.put("    .word 0")
            self.dyn += 30 * self.mult
            return
        self.dyn += 20 * self.mult
        if k == 1 and not self.in_func:
            # Fetch fault: a hole, an unmapped or a non-canonical VA.
            back = self.label("resume")
            ra_, rb_ = r.sample(self.pool, 2)
            self.li(ra_, self.shared() + RES_OFF)
            self.emit(f"la {gen.fx(rb_)}, {back}", 2)
            self.emit(f"sd {gen.fx(rb_)}, 0({gen.fx(ra_)})")
            tgt = self.ch(gen.HOLES + [0x40_0000_0000, 0xFFFF_FF00_0000_0000 | (r.randrange(1 << 20) << 12)])
            self.li(ra_, tgt)
            self.emit(f"jalr {gen.fx(self.xw())}, 0({gen.fx(ra_)})")
            self.put(f"{back}:")
        elif k == 2:
            self.emit(self.ch(["ebreak"] + (["c.ebreak"] if self.rvc else [])))
        elif k == 3 and self.rvc:
            self.emit(f".insn 2, {self.ch([0x0000, 0x0004, 0x4002, 0x6002, 0x8002, 0x6281, 0x6101]):#06x}")
        elif k == 4:
            rx = self.ch(self.pool)
            self.emit(f"fsrmi {gen.fx(rx)}, {self.ch([5, 6, 7])}")
            self.emit(f"fadd.d {gen.ff(self.ch(gen.FR))}, {gen.ff(self.ch(gen.FR))}, {gen.ff(self.ch(gen.FR))}, dyn")
            self.emit(f"fsrm {gen.fx(rx)}")
        elif k in (5, 6):
            rx = self.ch(self.pool)
            self.li(rx, self.ch(gen.HOLES) + r.randrange(0, 0x100, 8))
            op = self.ch(["lb", "lw", "ld", "sh", "sd", "amoadd.w", "lr.d", "sc.w"])
            if op.startswith(("amo", "sc")):
                self.emit(f"{op} {gen.fx(self.xw())}, {gen.fx(self.xr())}, ({gen.fx(rx)})")
            elif op.startswith("lr"):
                self.emit(f"{op} {gen.fx(self.xw())}, ({gen.fx(rx)})")
            elif op.startswith("s"):
                self.emit(f"{op} {gen.fx(self.xr())}, 0({gen.fx(rx)})")
            else:
                self.emit(f"{op} {gen.fx(self.xw())}, 0({gen.fx(rx)})")
        elif k == 7:
            w, size = self.ch([(".w", 4), (".d", 8)])
            rx = self.ptr(self.addr(size, True) + r.randrange(1, size))
            self.emit(f"{self.ch(['amoadd', 'amoswap'])}{w} {gen.fx(self.xw())}, {gen.fx(self.xr())}, ({gen.fx(rx)})")
        else:
            self.emit(f".insn 4, {self.illegal32():#010x}")

    # Window accesses.
    def win_addr(self, size):
        """(address, aligned) of an access in a window of the current mode."""
        r = self.r
        if self.mode == 3 or not self.translated():
            base = WIN_PA
            return base + r.randrange(0, WIN_PAGES * 0x1000 - size)
        sl = self.ch(self.slots)
        if sl.level == 0:
            # A NAPOT slot only sets the PTE of its first page.
            off = r.randrange(0, 0x1000 - size + 1)
        else:
            span = WIN_PAGES * 0x1000
            off = sl.win_off() + r.randrange(0, span - size + 1)
            if sl.level == 2 and self.p(0.05):
                off = 0x40_0000 + r.randrange(0, 0x10_0000, 8)  # past DRAM: access fault
        return sl.va + off

    def mprv_addr(self, size):
        sl = self.ch(self.slots)
        off = sl.win_off() + self.r.randrange(0, 0x1000 - size + 1)
        return sl.va + off

    def g_vmem(self, addr_fn=None):
        r = self.r
        addr_fn = addr_fn or self.win_addr
        op, size = self.ch([("lb", 1), ("lh", 2), ("lw", 4), ("ld", 8), ("lbu", 1), ("lhu", 2), ("lwu", 4),
                            ("sb", 1), ("sh", 2), ("sw", 4), ("sd", 8), ("flw", 4), ("fsd", 8), ("amoadd.w", 4),
                            ("amoswap.d", 8), ("amoor.b", 1), ("lr.d", 8), ("sc.w", 4), ("amocas.w", 4),
                            ("cbo.zero", 64), ("cbo.clean", 64), ("prefetch.w", 64)])
        a = addr_fn(size)
        if op.startswith(("amo", "lr", "sc")) or size == 64:
            a &= ~(size - 1)
        elif self.p(0.7):
            a &= ~(size - 1)
        rx = self.ch(self.pool)
        self.li(rx, a)
        if op.startswith(("amo", "sc")):
            self.emit(f"{op} {gen.fx(self.xw())}, {gen.fx(self.xr())}, ({gen.fx(rx)})")
        elif op.startswith("lr"):
            self.emit(f"{op} {gen.fx(self.xw())}, ({gen.fx(rx)})")
        elif op.startswith("cbo"):
            self.emit(f"{op} ({gen.fx(rx)})")
        elif op.startswith("prefetch"):
            self.emit(f"{op} 0({gen.fx(rx)})")
        elif op.startswith("f"):
            self.emit(f"{op} {gen.ff(self.ch(gen.FR))}, 0({gen.fx(rx)})")
        elif op.startswith("s"):
            self.emit(f"{op} {gen.fx(self.xr())}, 0({gen.fx(rx)})")
        else:
            self.emit(f"{op} {gen.fx(self.xw())}, 0({gen.fx(rx)})")

    def g_mprv(self):
        """M only: loads and stores through the current satp as S or U."""
        t = self.ch(self.pool)
        self.li(t, 0x1800)
        self.emit(f"csrc mstatus, {gen.fx(t)}")
        self.li(t, MSTATUS_MPRV | (self.ch([0, 1]) << 11) | (self.ch([0, MSTATUS_SUM]) | self.ch([0, MSTATUS_MXR])))
        self.emit(f"csrs mstatus, {gen.fx(t)}")
        for _ in range(self.r.randrange(1, 5)):
            self.g_vmem(self.mprv_addr)
        self.li(t, MSTATUS_MPRV | MSTATUS_SUM | MSTATUS_MXR)
        self.emit(f"csrc mstatus, {gen.fx(t)}")

    # PTE rewrites and fences.
    def fence_for(self, sp, va):
        r = self.r
        rv, ra_ = r.sample(self.pool, 2)
        k = r.randrange(6)
        if k == 0:
            self.emit("sfence.vma")
            return
        self.li(rv, va)
        self.li(ra_, sp.asid)
        if k == 1:
            self.emit(f"sfence.vma {gen.fx(rv)}, x0")
        elif k == 2:
            self.emit(f"sfence.vma x0, {gen.fx(ra_)}")
        elif k == 3:
            self.emit(f"sfence.vma {gen.fx(rv)}, {gen.fx(ra_)}")
        else:
            self.emit("sfence.w.inval")
            self.emit(f"sinval.vma {gen.fx(rv)}, {gen.fx(ra_) if k == 4 else 'x0'}")
            self.emit("sfence.inval.ir")

    def g_remap(self):
        """S or M only: in U under Bare the PTE store would succeed but the
        fence would not."""
        r = self.r
        sp = self.cur if self.cur is not None and self.p(0.7) else self.ch(self.spaces)
        i = r.randrange(len(self.slots))
        sl = self.slots[i]
        addr, tgt = sp.ptes[i]
        if sl.level == 0 and not sl.napot and self.p(0.5):
            tgt = WIN_PA + 0x1000 * r.randrange(WIN_PAGES)
        k = r.random()
        if k < 0.15:
            v = 0
        elif k < 0.35:
            v = self.leaf(sl, tgt, V | R | W | A | D | (U if self.p(0.5) else 0))
        else:
            v = self.rand_leaf(sl, tgt)
        ra_, rb_ = r.sample(self.pool, 2)
        self.li(ra_, addr)
        self.li(rb_, v)
        self.emit(f"sd {gen.fx(rb_)}, 0({gen.fx(ra_)})")
        self.fence_for(sp, sl.va + r.randrange(0, 0x1000 if sl.napot else sl.size, 8))

    def g_fence(self):
        r = self.r
        k = r.randrange(6)
        rv, ra_ = r.sample(self.pool, 2)
        if k == 0:
            self.emit("sfence.vma")
        elif k == 1:
            self.emit(f"sfence.vma {gen.fx(self.xr())}, {gen.fx(self.xr())}")
        elif k == 2:
            self.emit("fence.i")
        elif k == 3:
            self.emit("sfence.w.inval")
            self.emit(f"sinval.vma {gen.fx(self.xr())}, {gen.fx(self.xr())}")
            self.emit("sfence.inval.ir")
        else:
            sl = self.ch(self.slots)
            self.li(rv, sl.va)
            self.emit(f"sfence.vma {gen.fx(rv)}, x0")

    # CSRs.
    def csr_val(self, name):
        r = self.r
        v = self.xval() if self.p(0.5) else r.getrandbits(64)
        if name == "mstatus":
            v &= ~MSTATUS_KEEP
        elif name == "sstatus":
            v &= ~SSTATUS_KEEP
        elif name == "medeleg":
            v = (v & ~0x300) | self.deleg
        elif name == "menvcfg":
            v = (v & ~MENVCFG_KEEP) | (int(self.adue) << 61)
        elif name == "senvcfg":
            v &= ~SENVCFG_KEEP
        elif name == "satp":
            v = (v & ~(0xF << 60)) | (self.ch([1, 2, 7, 9, 10, 15]) << 60)
        return v & (2**64 - 1)

    M_CSRS = ["mstatus", "medeleg", "mideleg", "mcounteren", "menvcfg", "mstateen0", "mepc", "mcause", "mtval",
              "mcountinhibit"]
    S_CSRS = ["sstatus", "scounteren", "senvcfg", "sepc", "scause", "stval", "sstateen0", "satp"]
    RESTORE = ["mtvec", "mscratch", "stvec", "sscratch"]
    READ_ONLY = ["misa", "mvendorid", "marchid", "mimpid", "mhartid", "mconfigptr", "mie", "sie", "mip", "sip",
                 "pmpcfg0", "pmpaddr3", "pmpaddr15"]

    def g_csr(self):
        r = self.r
        if self.mode == 3:
            names = self.M_CSRS + self.S_CSRS
        elif self.mode == 1:
            names = self.S_CSRS + (self.M_CSRS[:3] if self.p(0.1) else [])
        else:
            names = self.S_CSRS if self.p(0.2) else []
        k = r.random()
        if not names or k < 0.15:
            name = self.ch(self.READ_ONLY + names)
            self.emit(f"{self.ch(['csrrs', 'csrrc'])} {gen.fx(self.xw())}, {name}, x0")
            return
        if k < 0.25:
            name = self.ch([n for n in self.RESTORE if self.mode == 3 or n[0] == "s"])
            old, new, rd = r.sample(self.pool, 3)
            v = r.getrandbits(64) if self.p(0.5) else self.xval()
            self.li(new, v)
            self.emit(f"csrrw {gen.fx(old)}, {name}, {gen.fx(new)}")
            self.emit(f"csrr {gen.fx(rd)}, {name}")
            self.emit(f"csrw {name}, {gen.fx(old)}")
            return
        name = self.ch(names)
        if name == "medeleg" and self.mode != 3:
            return
        rx = self.ch(self.pool)
        op = r.random()
        if op < 0.6 or name == "satp":
            self.li(rx, self.csr_val(name))
            self.emit(f"csrrw {gen.fx(self.xw())}, {name}, {gen.fx(rx)}")
        elif name in ("mstatus", "sstatus", "medeleg", "menvcfg", "senvcfg"):
            # Set and clear only the bits a random write may change.
            keep = {"mstatus": MSTATUS_KEEP, "sstatus": SSTATUS_KEEP, "medeleg": 0x300, "menvcfg": MENVCFG_KEEP,
                    "senvcfg": SENVCFG_KEEP}[name]
            self.li(rx, r.getrandbits(64) & ~keep)
            self.emit(f"{self.ch(['csrrs', 'csrrc'])} {gen.fx(self.xw())}, {name}, {gen.fx(rx)}")
        else:
            if self.p(0.5):
                self.emit(f"{self.ch(['csrrsi', 'csrrci', 'csrrwi'])} {gen.fx(self.xw())}, {name}, {r.randrange(32)}")
            else:
                self.li(rx, self.csr_val(name))
                self.emit(f"{self.ch(['csrrs', 'csrrc'])} {gen.fx(self.xw())}, {name}, {gen.fx(rx)}")

    def g_summxr(self):
        t = self.ch(self.pool)
        self.li(t, self.ch([MSTATUS_SUM, MSTATUS_MXR, MSTATUS_SUM | MSTATUS_MXR]))
        csr = "mstatus" if self.mode == 3 else "sstatus"
        self.emit(f"{self.ch(['csrs', 'csrc'])} {csr}, {gen.fx(t)}")

    # Top-level state changes.
    def t_pmp(self):
        """Random PMP entries 0-7 over the window pages; entry 15 is the catch-all."""
        r = self.r
        lo, hi = WIN_PA, WIN_PA + WIN_PAGES * 0x1000
        cfg = 0
        t = self.ch(self.pool)
        for i in range(r.randrange(1, 8)):
            m = r.choice(["off", "tor", "na4", "napot"] if i else ["off", "na4", "napot"])
            if m == "napot":
                sz = 1 << r.randrange(3, 15)
                base = lo + r.randrange(0, (hi - lo) // sz) * sz
                raw = (base >> 2) | ((sz >> 3) - 1)
                a = 3
            elif m == "na4":
                raw = r.randrange(lo, hi, 4) >> 2
                a = 2
            else:
                raw = r.randrange(lo, hi + 1, 4) >> 2
                a = 1 if m == "tor" else 0
            perm = r.randrange(8)
            cfg |= ((a << 3) | perm | (r.getrandbits(2) << 5 if self.p(0.1) else 0)) << (8 * i)
            self.li(t, raw)
            self.emit(f"csrw pmpaddr{i}, {gen.fx(t)}")
        self.li(t, cfg)
        self.emit(f"csrw pmpcfg0, {gen.fx(t)}")
        self.emit("sfence.vma")
        if self.p(0.3):
            self.emit(f"csrr {gen.fx(self.xw())}, pmpaddr{r.randrange(8)}")

    def t_deleg(self):
        r = self.r
        self.deleg = r.choice([0, 0x100, 0x200])
        t = self.ch(self.pool)
        v = r.getrandbits(16) & 0xb3ff & ~0x300 | self.deleg
        self.li(t, v)
        self.emit(f"csrw medeleg, {gen.fx(t)}")

    def satp_of(self, sp):
        return 0 if sp is None else sp.satp

    def needs_fence(self, a, b):
        """Switching to b must flush its ASID when another address space
        shares it: that one's entries may still be cached under the ASID."""
        return b is not None and b is not a and any(s is not b and s.asid == b.asid for s in self.spaces)

    def t_satp(self):
        new = self.ch(self.spaces + [None])
        t = self.ch(self.pool)
        self.li(t, self.satp_of(new))
        self.emit(f"csrw satp, {gen.fx(t)}")
        if self.needs_fence(self.cur, new) or self.p(0.2):
            self.emit(self.ch(["sfence.vma", f"sfence.vma x0, {gen.fx(t)}"]) if not self.needs_fence(self.cur, new)
                      else "sfence.vma")
        self.cur = new
        if self.mode != 3:
            h = self.home()
            self.li(3, h + 0x800)
            self.li(2, h + 0x1800)

    def transition(self, final=False):
        """End the segment: move to a new (mode, address space)."""
        r = self.r
        m = self.mode
        if final:
            # Head for M.
            if m == 3:
                self.emit("j gr_pass")
                return None
            route_m = (m == 0 and not self.deleg & 0x100) or (m == 1 and not self.deleg & 0x200)
            if route_m:
                nxt = (3, None)
            elif m == 0:
                nxt = (1, self.cur)
            else:
                nxt = (0, self.cur)
        else:
            nxt = (r.choice([3, 1, 1, 0, 0]), r.choice(self.spaces + [None]))
        label = self.label("seg")
        tmode, tsp = nxt
        if m == 3:
            how = "mret" if self.p(0.8) else "ecall"
        elif m == 1:
            if tmode == 0 and self.p(0.6):
                how = "sret"
            elif tmode == 1 and self.p(0.4):
                how = "inline"
            else:
                how = "ecall"
        else:
            how = "ecall"
        if how == "ecall":
            to_s = (m == 0 and self.deleg & 0x100) or (m == 1 and self.deleg & 0x200)
            if to_s and tmode == 3:
                tmode = 1
            self.emit("ecall")
            fence = int(self.needs_fence(self.cur, tsp) or self.p(0.2))
            self.desc.append((label, tmode, self.satp_of(tsp), fence))
            self.put(f"    .word {len(self.desc)}")
            self.dyn += 40
        elif how == "mret":
            t = self.ch(self.pool)
            self.emit(f"la {gen.fx(t)}, {label}", 2)
            self.emit(f"csrw mepc, {gen.fx(t)}")
            self.li(t, 0x1800)
            self.emit(f"csrc mstatus, {gen.fx(t)}")
            if tmode:
                self.li(t, tmode << 11)
                self.emit(f"csrs mstatus, {gen.fx(t)}")
            self.li(t, self.satp_of(tsp))
            self.emit(f"csrw satp, {gen.fx(t)}")
            if self.needs_fence(self.cur, tsp):
                self.emit("sfence.vma")
            self.emit("mret")
        elif how == "sret":
            t = self.ch(self.pool)
            if tsp is not self.cur:
                self.li(t, self.satp_of(tsp))
                self.emit(f"csrw satp, {gen.fx(t)}")
                if self.needs_fence(self.cur, tsp):
                    self.emit("sfence.vma")
            self.emit(f"la {gen.fx(t)}, {label}", 2)
            self.emit(f"csrw sepc, {gen.fx(t)}")
            self.li(t, 1 << 8)
            self.emit(f"csrc sstatus, {gen.fx(t)}")
            self.emit("sret")
        else:
            t = self.ch(self.pool)
            self.li(t, self.satp_of(tsp))
            self.emit(f"csrw satp, {gen.fx(t)}")
            if self.needs_fence(self.cur, tsp):
                self.emit("sfence.vma")
            self.emit(f"j {label}")
        self.mode, self.cur = tmode, tsp
        self.enter(label)
        return label

    def one(self):
        k = self.r.random()
        tbl = [(0.16, self.g_alu), (0.21, self.g_mul), (0.27, self.g_rvc), (0.34, self.g_load),
               (0.40, self.g_store), (0.45, self.g_cmem), (0.48, self.g_fmem), (0.55, self.g_fp),
               (0.59, self.g_amo), (0.61, self.g_hint), (0.62, self.g_cmo), (0.68, self.g_trap),
               (0.80, self.g_vmem), (0.88, self.g_csr), (0.92, self.g_vmem if self.mode == 0 else self.g_remap),
               (0.95, self.g_fence),
               (0.97, self.g_summxr), (1.0, self.g_mprv if self.mode == 3 else self.g_vmem)]
        for lim, f in tbl:
            if k < lim:
                return f()

    def segment(self, length):
        end = self.dyn + length
        while self.dyn < end:
            self.section_mode()
            k = self.r.random()
            if k < 0.04 and self.mode in (1, 3):
                self.set_section(self.sec)
                self.t_satp()
            elif k < 0.06 and self.mode == 3:
                self.set_section(self.sec)
                self.t_deleg()
            elif k < 0.08 and self.mode == 3:
                self.set_section(self.sec)
                self.t_pmp()
            else:
                self.block()

    def build(self):
        r = self.r
        self.fpconst = ([v for v in gen.D_SPECIAL] + [0xffffffff00000000 | v for v in gen.S_SPECIAL]
                        + [0xffffffffffff0000 | v for v in gen.H_SPECIAL]
                        + [r.getrandbits(64) for _ in range(8)]
                        + [0xffffffff00000000 | r.getrandbits(32) for _ in range(4)])
        self.build_tables()
        self.nfunc = r.randrange(2, 5)
        self.fsize = 30
        out = [f"# Generated by test/gr/gen.py --priv --seed {self.seed} --length {self.length}. Do not edit."]
        out.append(HEAD.format(pmp15=0x1f << 56, adue=int(self.adue) << 61 | 0xf0 | (1 << 62 if self.p(0.5) else 0)))
        self.lines = []
        self.li(5, r.randrange(32) | (r.randrange(5) << 5))
        self.emit("fscsr x5")
        for i in gen.FR:
            self.emit(f"fld f{i}, {8 * r.randrange(len(self.fpconst))}(x6)")
        self.deleg = r.choice([0, 0x100, 0x200])
        self.li(5, r.getrandbits(16) & 0xb3ff & ~0x300 | self.deleg)
        self.emit("csrw medeleg, x5")
        for x in gen.XW:
            self.li(x, self.xval())
        out += [f"    li x6, {SHARED_PA + FPC_OFF:#x}"] + self.lines
        out.append("    j gr_main")
        init = self.lines

        self.out = {"text": [], "utext": []}
        self.lines = self.out["text"]
        self.sec = "text"
        self.rvc = True
        self.mode, self.cur = 3, None
        self.enter("gr_main")
        nseg = max(2, self.length // self.r.randrange(150, 600))
        per = self.length // nseg
        while self.dyn < self.length:
            self.segment(r.randrange(per // 2, per * 3 // 2 + 1))
            if self.dyn < self.length:
                self.transition()
        while self.mode != 3:
            self.transition(final=True)
        self.set_section("text")
        self.emit("j gr_pass")
        body_dyn = self.dyn
        self.in_func = True
        for sec, pre, mode in (("text", "", 1), ("utext", "u", 0)):
            self.mode = mode
            self.set_section(sec)
            for i in range(self.nfunc):
                self.put(f"gr_{pre}func{i}:")
                save, self.mult = self.mult, 1
                for _ in range(r.randrange(1, 4)):
                    self.block(allow_loop=False, allow_call=False)
                self.mult = save
                self.emit(self.ch(["ret", "c.jr ra", "jalr x0, 0(ra)"]))
        self.set_section("text")
        out.append("    .text")
        out.append(handler("m"))
        out.append(handler("s"))
        out.append(TAIL)
        out += self.out["text"]
        out.append('    .section .utext, "ax"')
        out += self.out["utext"]

        out.append("    .data")
        out.append("    .align 6")
        for x in "ms":
            out.append(f"gr_{x}save:")
            out.append(f"    .zero {64 + 8 * 32}")
        out.append("gr_desc:")
        for label, mode, satp, fence in self.desc:
            out.append(f"    .dword {label}, {mode}, {satp:#x}, {fence}")
        out.append("gr_rtab:")
        for e in self.rtab:
            out.append("    .dword " + ", ".join(f"{v:#x}" for v in e) + ", 0")
        out.append("    .dword 0, 0, 0, 0, 0, 0, 0, 0")

        out.append('    .section .pt, "aw", @progbits')
        last = PT_PA
        for a in sorted(self.pt):
            if a != last:
                out.append(f"    .zero {a - last}")
            out.append(f"    .dword {self.pt[a]:#018x}")
            last = a + 8
        if self.pt_next != last:
            out.append(f"    .zero {self.pt_next - last}")

        out.append('    .section .pool, "aw", @progbits')
        pool = [r.getrandbits(64) for _ in range(0x4000 // 8)]
        for i in range(0, len(pool), 7):
            pool[i] = r.choice(gen.D_SPECIAL + [0xffffffff00000000 | v for v in gen.S_SPECIAL])
        out += [f"    .dword {v:#018x}" for v in pool]
        shared = [0] * (FPC_OFF // 8) + self.fpconst
        shared += [0] * (0x1000 // 8 - len(shared))
        out += [f"    .dword {v:#018x}" for v in shared]
        out.append(f"    .zero {WIN_PA - SHARED_PA - 0x1000}")
        win = [r.getrandbits(64) for _ in range(WIN_PAGES * 0x1000 // 8)]
        out += [f"    .dword {v:#018x}" for v in win]
        return "\n".join(out) + "\n", body_dyn


HEAD = """\
    .section .text.init, "ax"
    .globl _start
_start:
    la t0, gr_mtrap
    csrw mtvec, t0
    la t0, gr_strap
    csrw stvec, t0
    la t0, gr_msave
    csrw mscratch, t0
    la t0, gr_ssave
    csrw sscratch, t0
    li t0, -1
    csrw pmpaddr15, t0
    li t0, {pmp15:#x}
    csrw pmpcfg2, t0
    csrw pmpcfg0, zero
    li t0, {adue:#x}
    csrw menvcfg, t0
    csrw mideleg, zero
    csrw mie, zero
    csrw satp, zero
    li t0, 3 << 13
    csrs mstatus, t0
    li tp, 0
    li ra, 0"""


def handler(x):
    """The M (x = 'm') or S trap handler; see the module docstring."""
    pp_mask, pp_shift = (0x1800, 11) if x == "m" else (0x100, 8)
    sum_on = "" if x == "m" else "    li t2, 1 << 18\n    csrrs t2, sstatus, t2\n"
    sum_off = "" if x == "m" else "    csrw sstatus, t2\n"
    is_u = ("    csrr t3, mstatus\n    srli t3, t3, 11\n    andi t3, t3, 3\n    bnez t3, 4f\n" if x == "m" else
            "    csrr t3, sstatus\n    andi t3, t3, 0x100\n    bnez t3, 4f\n")
    return f"""\
    .align 2
gr_{x}trap:
    csrrw sp, {x}scratch, sp
    sd t0, 0(sp)
    sd t1, 8(sp)
    sd t2, 16(sp)
    sd t3, 24(sp)
    sd t4, 32(sp)
    csrr t0, {x}cause
    bltz t0, gr_fail
    li t1, 16
    bgeu t0, t1, gr_fail
    slli t1, t0, 3
    add t1, t1, sp
    ld t2, 64(t1)
    addi t2, t2, 1
    sd t2, 64(t1)
    li t1, 8
    beq t0, t1, .L{x}ecall
    li t1, 9
    beq t0, t1, .L{x}ecall
    li t1, 11
    beq t0, t1, .L{x}ecall
    li t1, 1
    beq t0, t1, .L{x}resume
    li t1, 12
    beq t0, t1, .L{x}resume
    li t1, 13
    beq t0, t1, .L{x}pf
    li t1, 15
    beq t0, t1, .L{x}pf
.L{x}skip:
    sd zero, 40(sp)
    csrr t0, {x}epc
{sum_on}    lhu t1, 0(t0)
{sum_off}    andi t1, t1, 3
    li t3, 3
    addi t0, t0, 2
    bne t1, t3, 1f
    addi t0, t0, 2
1:  csrw {x}epc, t0
.L{x}ret:
    ld t0, 0(sp)
    ld t1, 8(sp)
    ld t2, 16(sp)
    ld t3, 24(sp)
    ld t4, 32(sp)
    csrrw sp, {x}scratch, sp
    {x}ret
.L{x}resume:
    sd zero, 40(sp)
    li t0, {SHARED_PA + RES_OFF:#x}
    ld t0, 0(t0)
    csrw {x}epc, t0
    j .L{x}ret
.L{x}ecall:
    sd zero, 40(sp)
    csrr t0, {x}epc
{sum_on}    lwu t1, 4(t0)
{sum_off}    addi t0, t0, 8
    csrw {x}epc, t0
    beqz t1, .L{x}ret
    addi t1, t1, -1
    slli t1, t1, 5
    la t2, gr_desc
    add t1, t1, t2
    ld t2, 0(t1)
    csrw {x}epc, t2
    ld t2, 8(t1)
    li t3, {pp_mask:#x}
    csrc {x}status, t3
    slli t2, t2, {pp_shift}
    csrs {x}status, t2
    ld t2, 16(t1)
    csrw satp, t2
    ld t2, 24(t1)
    beqz t2, .L{x}ret
    sfence.vma
    j .L{x}ret
.L{x}pf:
    csrr t0, {x}epc
    ld t1, 40(sp)
    sd t0, 40(sp)
    beq t0, t1, .L{x}skip
    csrr t0, {x}tval
    csrr t1, satp
    la t2, gr_rtab
2:  ld t3, 0(t2)
    beqz t3, .L{x}skip
    bne t3, t1, 3f
    ld t4, 8(t2)
    and t4, t4, t0
    ld t3, 16(t2)
    bne t3, t4, 3f
    ld t3, 48(t2)
    beqz t3, .L{x}skip
    ld t4, 24(t2)
{is_u}    ld t3, 40(t2)
    j 5f
4:  ld t3, 32(t2)
5:  sd t3, 0(t4)
    sfence.vma t0, zero
    j .L{x}ret
3:  addi t2, t2, 64
    j 2b
"""


TAIL = """\
gr_fail:
    li t0, 3
    li t1, 0x80001000
    sw t0, 0(t1)
6:  j 6b
gr_pass:
    li t0, 1
    la t1, tohost
    sw t0, 0(t1)
7:  j 7b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
    .globl fromhost
fromhost:
    .dword 0
    .text"""
