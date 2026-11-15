"""Hypervisor random streams for the spike cosim (gen.py --hyp [--vec]).

The privileged stream of priv.py with the H extension: the program moves
between M, HS, U, VS and VU in segments. HS and U use the address spaces of
priv.py. Guests run in virtual machines: each VM is a G-stage address space
(hgatp Sv39x4 with its own 16 KiB root and VMID, or hgatp Bare) with one or
two guest address spaces of its own (vsatp Sv39, roots in guest physical
memory) or vsatp Bare. The G-stage maps guest physical addresses identically
over the code and the data, table and pool region, with random permissions
(and sometimes another target) over the window pages, and maps a few
regions above 4 GiB (1 GiB, 2 MiB, 4 KiB and NAPOT leaves, root index up to
2047) onto the window. Guest PTEs of level 0 point at either. Some guest
table pages are given a restricted G-stage leaf, so the VS-stage walk takes
a guest-page fault on its implicit access.

The stream adds to priv.py: hypervisor loads and stores (hlv, hlvx, hsv) in
HS, M and U with hstatus.HU, under random SPVP, SUM and MXR; G-stage PTE
rewrites with hfence.gvma in its four forms or the hinval.gvma sequence;
hfence.vvma and hinval.vvma; MPRV with MPV from M; H and VS CSR accesses
(hstatus, hedeleg, hideleg, hvip, hcounteren, henvcfg, hstateen0, htval,
htinst, mtval2, mtinst, vsstatus, vsepc, vscause, vstval, vsip, and vstvec,
vsscratch, hgatp, vsatp written and restored); counter reads into x0;
short windows with mstatus.TVM/TSR/TW set in HS and hstatus.VTVM/VTW/VTSR set
in VS; CBOs under henvcfg and senvcfg in VS and VU; FS changes of mstatus
and vsstatus; and software-raised interrupts (mip.SSIP, sip.SSIP,
hvip.VSSIP/VSTIP/VSEIP) taken by the M, HS or VS handler, which clears the
pending bit and returns to the interrupted instruction.

Traps: medeleg is random, but the ecalls from U, HS and VS are never all
delegated, so M stays reachable; hedeleg is random. The M, HS and VS
handlers share the scheme of priv.py (an ecall is followed by a word: 0 to
return after it, else 1 + an index into gr_desc for a mode change; fetch
faults, also guest-page ones, resume at the stored resume point). A page
fault is resolved from gr_rtab keyed by satp, or by vsatp when the trap
reports a guest virtual address (GVA); a guest-page fault from gr_gtab keyed
by hgatp with the GPA from htval or mtval2, then hfence.gvma.
"""

import gen
import priv
from priv import V, R, W, X, U, A, D, N_BIT, pte, canon

HGATP_SV39X4 = 8 << 60
GPA_BITS = 41
WIN_PA, WIN_PAGES, DATA_PA = priv.WIN_PA, priv.WIN_PAGES, priv.DATA_PA
CODE_PA = 0x8000_0000

H_GVA, H_SPV, H_SPVP, H_HU = 1 << 6, 1 << 7, 1 << 8, 1 << 9
H_VTVM, H_VTW, H_VTSR = 1 << 20, 1 << 21, 1 << 22
M_TVM, M_TW, M_TSR = 1 << 20, 1 << 21, 1 << 22
M_MPV = 1 << 39
MIP_SSIP, MIP_VSSIP, MIP_VSTIP, MIP_VSEIP = 1 << 1, 1 << 2, 1 << 6, 1 << 10

# Never written at random: VTVM, VTW and VTSR (dedicated windows), VGEIN (no
# guest external interrupts), HUPMM (pointer masking).
HSTATUS_KEEP = H_VTVM | H_VTW | H_VTSR | (0x3f << 12) | (3 << 48)
# henvcfg: STCE (vstimecmp would raise VSTIP), PMM, DTE, SSE/LPE and ADUE
# (fixed per program).
HENVCFG_KEEP = (1 << 63) | (1 << 61) | (1 << 59) | (3 << 32) | (1 << 3) | (1 << 2)
VSSTATUS_KEEP = 1 << 24
ECALL_BITS = 0x700  # medeleg bits of the ecalls from U, HS and VS

SAVE = 512    # bytes per handler save area
CNT = 128     # first trap counter in the save area
LASTPC = 56
LASTTVAL = 64

HYP_EXCLUDED = {
    "counter reads into a register other than x0": "timing values; the cosim copies them from the DUT, but the "
                                                    "program would no longer be a function of the seed",
    "interrupts other than the software-raised ones (timers, Sstc, PLIC, IMSIC, guest external)": "taken where "
        "the DUT's pipeline lets them; a software-raised pending bit (mip.SSIP, sip.SSIP, hvip, vsip.SSIP) stays "
        "pending until the handler clears it, so where it is taken does not change the program",
    "mstatus.MIE/SIE/MPIE/SPIE and vsstatus.SIE/SPIE random writes": "an interrupt taken inside a transition "
        "sequence would overwrite the xepc it sets up; the global enables are set only in the interrupt windows",
    "hie and vsie writes outside the interrupt snippets; VSTI and VSEI delegated to VS": "the enables belong to "
        "the snippet; the guest cannot clear hvip.VSTIP or VSEIP",
    "hstatus.VTVM/VTW/VTSR and mstatus.TVM/TSR/TW outside their windows": "the handlers use satp, sfence.vma and "
        "sret; a window holds only instructions that these bits make trap",
    "hgeie, hstatus.VGEIN": "GEILEN is 0; spike models 31 guest external interrupt files",
    "henvcfg.STCE/PMM/DTE, hstatus.HUPMM, vstimecmp": "Sstc timers, pointer masking and double traps are not in "
                                                     "this stream",
    "henvcfg.ADUE and menvcfg.ADUE changes inside a program": "a PTE whose A the DUT set speculatively under "
                                                              "ADUE=1 would not fault after ADUE=0",
    "loads of G-stage and VS-stage PTEs": "Svadu allows the A bit to be set speculatively; only a load of the "
                                          "PTE could see it",
    "guest PTE rewrites outside VS and the handlers": "hfence.vvma covers only the VMID in hgatp, so a VM's guest "
                                                     "tables change only while that VM is current",
    "WFI that would not trap": "a legal WFI waits for an interrupt that never comes; WFI is emitted only in U, "
                               "VU and the TW and VTW windows",
    "xRET and H state changes in leaf functions": "a leaf function is called from M, HS and VS alike",
    "hcontext": "spike implements it, the configuration does not",
}

# The H instructions the stream should contain (run_gr.py --hyp lists the ones
# no program contains).
HYP_MNEMONICS = """
hlv.b hlv.bu hlv.h hlv.hu hlv.w hlv.wu hlv.d hlvx.hu hlvx.wu hsv.b hsv.h hsv.w hsv.d hfence.vvma hfence.gvma
hinval.vvma hinval.gvma sret mret wfi
""".split()

# The trap causes and mode changes the default set should reach (run_gr.py
# --hyp checks them against the cosim's coverage line).
HYP_CAUSES = [10, 20, 21, 22, 23]
HYP_MODES = ["M>HS", "M>U", "M>VS", "M>VU", "HS>M", "HS>U", "HS>VS", "HS>VU", "U>M", "U>HS", "VS>M", "VS>HS",
             "VS>VU", "VU>M", "VU>HS", "VU>VS"]


class GSlot:
    """A guest physical range each VM maps with one G-stage leaf (or leaves
    invalid)."""

    def __init__(self, gpa, level, napot=False):
        self.gpa, self.level, self.napot = gpa, level, napot
        self.size = 0x1_0000 if napot else 1 << (12 + 9 * level)

    def target(self, r):
        if self.level == 2:
            return CODE_PA
        if self.level == 1:
            return DATA_PA
        if self.napot:
            return WIN_PA
        return WIN_PA + 0x1000 * r.randrange(WIN_PAGES)

    def pages(self):
        """GPAs of the accessible pages."""
        if self.level == 2:
            return [self.gpa + WIN_PA - CODE_PA + 0x1000 * k for k in range(WIN_PAGES)]
        if self.level == 1:
            return [self.gpa + WIN_PA - DATA_PA + 0x1000 * k for k in range(WIN_PAGES)]
        return [self.gpa]


class VM:
    """hgatp: a G-stage address space (Sv39x4) or Bare, and its guest
    address spaces."""

    def __init__(self, idx, vmid, root):
        self.idx, self.vmid, self.root = idx, vmid, root
        self.bare = root is None
        self.hgatp = 0 if self.bare else HGATP_SV39X4 | (vmid << 44) | (root >> 12)
        self.guests = []
        self.gptes = []  # (PTE address, GPA, size, leaf) of the G-stage entries the stream rewrites

    def __repr__(self):
        return f"VM{self.idx}"


class HypGen(priv.PrivGen):
    # SIE, MIE, SPIE and MPIE stay 0 outside the interrupt windows.
    MS_KEEP = priv.MSTATUS_KEEP | 0xaa
    SS_KEEP = priv.SSTATUS_KEEP | 0x22
    VSS_KEEP = VSSTATUS_KEEP | 0x22

    def __init__(self, seed, length):
        super().__init__(seed, length)
        self.v = 0
        self.gvm = None
        self.vcur = None
        self.edeleg = 0
        self.hdeleg = 0
        self.hadue = self.adue and self.p(0.5)
        self.gtab = []
        self.irq_ok = self.p(0.7)

    # Tables.
    def alloc_root(self):
        self.pt_next = (self.pt_next + 0x3fff) & ~0x3fff
        a = self.pt_next
        self.pt_next += 0x4000
        return a

    def guest_space(self, vm, k, asid):
        """A guest address space of vm: the identity and U-home tables of
        priv.py and its own slot tables."""
        s = priv.AddrSpace(k, asid, self.alloc())
        s.vm = vm
        s.tables = []
        self.setpte(s.root, 2, pte(self.id_l1, V))
        self.setpte(s.root, 3, pte(self.uh_l1, V))
        l1, l0 = {}, {}
        for i, sl in enumerate(self.slots):
            v2, v1, v0 = sl.va >> 30 & 511, sl.va >> 21 & 511, sl.va >> 12 & 511
            if sl.level == 2:
                addr = s.root + 8 * v2
            else:
                if v2 not in l1:
                    l1[v2] = self.alloc()
                    s.tables.append(l1[v2])
                    self.setpte(s.root, v2, pte(l1[v2], V))
                if sl.level == 1:
                    addr = l1[v2] + 8 * v1
                else:
                    if (v2, v1) not in l0:
                        l0[(v2, v1)] = self.alloc()
                        s.tables.append(l0[(v2, v1)])
                        self.setpte(l1[v2], v1, pte(l0[(v2, v1)], V))
                    addr = l0[(v2, v1)] + 8 * v0
            tgt = self.guest_target(vm, sl)
            self.pt[addr] = self.rand_leaf(sl, tgt) if self.p(0.85) else 0
            s.ptes[i] = (addr, tgt)
            fix = V | R | W | A | D
            self.rtab.append((s.satp, ~(sl.size - 1) & (2**64 - 1), sl.va, addr,
                              self.leaf(sl, tgt, fix), self.leaf(sl, tgt, fix | U), int(self.p(0.8))))
        return s

    def guest_target(self, vm, sl):
        """The GPA a guest leaf of slot sl maps: the window (identical in the
        G-stage) or, in a VM with a G-stage, a high region or a GPA with no
        G-stage mapping."""
        r = self.r
        if sl.level or sl.napot:
            return sl.base_pa() if sl.level else WIN_PA
        k = r.random()
        if vm.bare or k < 0.65:
            return WIN_PA + 0x1000 * r.randrange(WIN_PAGES)
        if k < 0.93 and self.gslots:
            return self.ch(self.ch(self.gslots).pages())
        if k < 0.96:
            return (1 << GPA_BITS) + (r.randrange(1 << 12) << 12)  # beyond Sv39x4
        return self.unmapped_gpa()

    def unmapped_gpa(self):
        used = {g.gpa >> 30 for g in self.gslots} | {2}
        i = self.ch([i for i in range(4, 1 << (GPA_BITS - 30)) if i not in used])
        return (i << 30) | (self.r.randrange(1 << 18) << 12)

    def build_tables(self):
        super().build_tables()
        r = self.r
        self.id_l1 = priv.PT_PA
        self.uh_l1 = priv.PT_PA + 0x2000
        # High G-stage regions: root index 4-2047 (2 is the identity).
        idx = r.sample(range(4, 1 << (GPA_BITS - 30)), 4)
        self.gslots = []
        if self.p(0.7):
            self.gslots.append(GSlot(idx[0] << 30, 2))
        for j in r.sample(range(512), r.randrange(1, 3)):
            self.gslots.append(GSlot((idx[1] << 30) | (j << 21), 1))
        v1 = r.randrange(512)
        for v0 in r.sample(range(0, 512, 16), r.randrange(2, 5)):
            self.gslots.append(GSlot((idx[2] << 30) | (v1 << 21) | (v0 << 12), 0))
        if self.p(0.6):
            self.gslots.append(GSlot((idx[3] << 30) | (r.randrange(512) << 21) | (r.randrange(0, 512, 16) << 12), 0,
                                     napot=True))
        # VMs: the Bare one and one to three G-stage spaces; VMIDs sometimes
        # shared.
        n = r.randrange(1, 4)
        vmids = r.sample(range(1, 1 << 14), n)
        if n > 1 and self.p(0.3):
            vmids[-1] = vmids[0]
        self.vms = [VM(0, 0, None)] + [VM(k + 1, vmids[k], self.alloc_root()) for k in range(n)]
        for vm in self.vms:
            ng = r.randrange(1, 3)
            asids = r.sample(range(1 << 16), ng)
            if ng > 1 and self.p(0.3):
                asids[-1] = asids[0]
            vm.guests = [self.guest_space(vm, k, asids[k]) for k in range(ng)]
        for vm in self.vms[1:]:
            self.build_gstage(vm)
        assert self.pt_next <= priv.POOL, "page tables overflow into the pool"

    def g_leaf(self, pa, fl, napot=False):
        v = pte(pa, fl)
        if napot:
            v |= N_BIT | (0b1000 << 10)
        return v

    def rand_gleaf(self, pa, napot=False):
        r = self.r
        perm = r.choices([R, R | W, R | X, R | W | X, X, W, W | X], [4, 6, 2, 4, 2, 1, 1])[0]
        fl = V | perm | (U if self.p(0.9) else 0)
        if self.p(0.75):
            fl |= A
        if self.p(0.6):
            fl |= D
        if self.p(0.03):
            fl &= ~V
        return self.g_leaf(pa, fl, napot)

    def build_gstage(self, vm):
        r = self.r
        full = V | R | W | X | U | A | D
        l1 = self.alloc()
        self.setpte(vm.root, 2, pte(l1, V))
        self.setpte(l1, 0, pte(CODE_PA, full))
        l0 = self.alloc()
        self.setpte(l1, 1, pte(l0, V))
        win = range((WIN_PA - DATA_PA) >> 12, ((WIN_PA - DATA_PA) >> 12) + WIN_PAGES)
        # Guest table pages of this VM that take a restricted leaf.
        restrict = set()
        if self.p(0.4):
            tabs = [t for s in vm.guests for t in s.tables]
            if tabs:
                restrict.add(self.ch(tabs))
        for i in range(512):
            gpa = DATA_PA + 0x1000 * i
            addr = l0 + 8 * i
            if i in win:
                tgt = gpa if self.p(0.7) else WIN_PA + 0x1000 * r.randrange(WIN_PAGES)
                self.pt[addr] = self.rand_gleaf(tgt) if self.p(0.9) else 0
                fix = pte(tgt, full)
                self.gtab.append((vm.hgatp, ~0xfff & (2**64 - 1), gpa, addr, fix, int(self.p(0.85))))
                vm.gptes.append((addr, gpa, 0x1000, tgt, False))
            elif gpa in restrict:
                fl = self.ch([0, V | R | U | A | D, V | R | W | A | D, V | R | W | U | D, V | W | U | A | D])
                self.pt[addr] = pte(gpa, fl)
                self.gtab.append((vm.hgatp, ~0xfff & (2**64 - 1), gpa, addr, pte(gpa, V | R | W | U | A | D), 1))
            else:
                self.pt[addr] = pte(gpa, V | R | W | U | A | D)
        l1s, l0s = {}, {}
        for g in self.gslots:
            v2, v1, v0 = g.gpa >> 30, g.gpa >> 21 & 511, g.gpa >> 12 & 511
            if g.level == 2:
                addr = vm.root + 8 * v2
            else:
                if v2 not in l1s:
                    l1s[v2] = self.alloc()
                    self.setpte(vm.root, v2, pte(l1s[v2], V))
                if g.level == 1:
                    addr = l1s[v2] + 8 * v1
                else:
                    if (v2, v1) not in l0s:
                        l0s[(v2, v1)] = self.alloc()
                        self.setpte(l1s[v2], v1, pte(l0s[(v2, v1)], V))
                    addr = l0s[(v2, v1)] + 8 * v0
            tgt = g.target(r)
            self.pt[addr] = self.rand_gleaf(tgt, g.napot) if self.p(0.85) else 0
            self.gtab.append((vm.hgatp, ~(g.size - 1) & (2**64 - 1), g.gpa, addr, self.g_leaf(tgt, full, g.napot),
                              int(self.p(0.8))))
            vm.gptes.append((addr, g.gpa, g.size, tgt, g.napot))

    # Context.
    def translated(self):
        if self.mode == 3:
            return False
        return (self.vcur if self.v else self.cur) is not None

    def gview_pages(self, vm, vcur, slots=True):
        """(VA or GPA base, size) of the regions the guest context (vm, vcur)
        reaches; with vcur None, guest physical."""
        out = []
        if vcur is None:
            out.append((WIN_PA, WIN_PAGES * 0x1000))
            if not vm.bare:
                for g in self.gslots:
                    out += [(p, 0x1000) for p in g.pages()]
            return out
        for i, sl in enumerate(self.slots):
            tgt = vcur.ptes[i][1]
            if sl.level == 0:
                if vm.bare and tgt >= 1 << 32:
                    continue
                out.append((sl.va, 0x1000))
            else:
                out.append((sl.va + sl.win_off(), WIN_PAGES * 0x1000))
        return out

    def guest_addr(self, size):
        """An access address in the current guest view."""
        r = self.r
        if self.vcur is None and not self.gvm.bare and self.p(0.04):
            # No G-stage mapping, or beyond the GPA width.
            return self.ch([self.unmapped_gpa(), (1 << GPA_BITS) + r.randrange(0, 1 << 20, 8)])
        base, sz = self.ch(self.gview_pages(self.gvm, self.vcur))
        return base + r.randrange(0, sz - size + 1)

    def win_addr(self, size):
        if self.v:
            return self.guest_addr(size)
        return super().win_addr(size)

    def mprv_addr(self, size):
        if self.mprv_v:
            return self.guest_addr(size)
        return super().mprv_addr(size)

    # Accesses.
    VMEM_OPS = [("lb", 1), ("lh", 2), ("lw", 4), ("ld", 8), ("lbu", 1), ("lhu", 2), ("lwu", 4), ("sb", 1), ("sh", 2),
                ("sw", 4), ("sd", 8), ("flw", 4), ("fsd", 8), ("amoadd.w", 4), ("amoswap.d", 8), ("amoor.b", 1),
                ("lr.d", 8), ("sc.w", 4), ("amocas.w", 4), ("cbo.zero", 64), ("cbo.clean", 64), ("cbo.flush", 64),
                ("cbo.inval", 64), ("prefetch.w", 64)]

    def g_vmem(self, addr_fn=None):
        addr_fn = addr_fn or self.win_addr
        op, size = self.ch(self.VMEM_OPS)
        a = addr_fn(size)
        if op.startswith("cbo"):
            a &= ~0x1ff
        elif op.startswith(("amo", "lr", "sc")) or size == 64:
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

    HLV = [("hlv.b", 1), ("hlv.bu", 1), ("hlv.h", 2), ("hlv.hu", 2), ("hlv.w", 4), ("hlv.wu", 4), ("hlv.d", 8),
           ("hlvx.hu", 2), ("hlvx.wu", 4), ("hsv.b", 1), ("hsv.h", 2), ("hsv.w", 4), ("hsv.d", 8)]

    def g_hlv(self):
        """Hypervisor loads and stores through vsatp and hgatp."""
        r = self.r
        for _ in range(r.randrange(1, 4)):
            op, size = self.ch(self.HLV)
            rx = self.ch(self.pool)
            if op.startswith("hlvx") and self.p(0.5):
                # Guest code: S code, U code or the current pc.
                k = r.randrange(3)
                if k == 2:
                    self.emit(f"auipc {gen.fx(rx)}, 0")
                    self.emit(f"addi {gen.fx(rx)}, {gen.fx(rx)}, {r.randrange(-64, 64, 2)}")
                else:
                    self.emit(f"la {gen.fx(rx)}, gr_{'u' if k else ''}func{r.randrange(self.nfunc)}", 2)
            else:
                a = self.guest_addr(size)
                if size > 1 and self.p(0.85):
                    a &= ~(size - 1)
                self.li(rx, a)
            if op.startswith("hsv"):
                self.emit(f"{op} {gen.fx(self.xr())}, ({gen.fx(rx)})")
            else:
                self.emit(f"{op} {gen.fx(self.xw())}, ({gen.fx(rx)})")

    def g_mprv(self):
        """M only: MPRV through the current satp, or with MPV through vsatp
        and hgatp as VS or VU."""
        self.mprv_v = self.p(0.4)
        t = self.ch(self.pool)
        self.li(t, 0x1800 | M_MPV)
        self.emit(f"csrc mstatus, {gen.fx(t)}")
        self.li(t, priv.MSTATUS_MPRV | (self.ch([0, 1]) << 11) | (M_MPV if self.mprv_v else 0)
                | self.ch([0, priv.MSTATUS_SUM]) | self.ch([0, priv.MSTATUS_MXR]))
        self.emit(f"csrs mstatus, {gen.fx(t)}")
        self.mprv_body()
        self.li(t, priv.MSTATUS_MPRV | priv.MSTATUS_SUM | priv.MSTATUS_MXR | M_MPV)
        self.emit(f"csrc mstatus, {gen.fx(t)}")
        self.mprv_v = False

    def mprv_body(self):
        for _ in range(self.r.randrange(1, 5)):
            self.g_vmem(self.mprv_addr)

    # PTE rewrites and fences.
    def g_remap(self):
        if self.in_func:
            return self.g_alu()
        if self.v:
            return self.g_vremap()
        if self.p(0.4) and len(self.vms) > 1:
            return self.g_gremap()
        return super().g_remap()

    def g_vremap(self):
        """VS: rewrite a PTE of one of the current VM's guest spaces."""
        r = self.r
        sp = self.vcur if self.vcur is not None and self.p(0.7) else self.ch(self.gvm.guests)
        i = r.randrange(len(self.slots))
        sl = self.slots[i]
        addr, tgt = sp.ptes[i]
        if sl.level == 0 and not sl.napot and self.p(0.5):
            tgt = self.guest_target(self.gvm, sl)
            sp.ptes[i] = (addr, tgt)
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

    def g_gremap(self):
        """HS or M: rewrite a G-stage PTE, then hfence.gvma or the
        hinval.gvma sequence."""
        r = self.r
        vms = self.vms[1:]
        vm = self.gvm if not self.gvm.bare and self.p(0.7) else self.ch(vms)
        addr, gpa, size, tgt, napot = self.ch(vm.gptes)
        k = r.random()
        if k < 0.15:
            v = 0
        elif k < 0.4:
            v = self.g_leaf(tgt, V | R | W | X | U | A | D, napot)
        else:
            v = self.rand_gleaf(tgt, napot)
        ra_, rb_ = r.sample(self.pool, 2)
        self.li(ra_, addr)
        self.li(rb_, v)
        self.emit(f"sd {gen.fx(rb_)}, 0({gen.fx(ra_)})")
        self.gfence_for(vm, gpa + r.randrange(0, min(size, 0x1000), 8))

    def gfence_for(self, vm, gpa):
        r = self.r
        rv, ra_ = r.sample(self.pool, 2)
        k = r.randrange(6)
        if k == 0:
            self.emit("hfence.gvma x0, x0")
            return
        self.li(rv, gpa >> 2)
        self.li(ra_, vm.vmid)
        if k == 1:
            self.emit(f"hfence.gvma {gen.fx(rv)}, x0")
        elif k == 2:
            self.emit(f"hfence.gvma x0, {gen.fx(ra_)}")
        elif k == 3:
            self.emit(f"hfence.gvma {gen.fx(rv)}, {gen.fx(ra_)}")
        else:
            self.emit("sfence.w.inval")
            self.emit(f"hinval.gvma {gen.fx(rv)}, {gen.fx(ra_) if k == 4 else 'x0'}")
            self.emit("sfence.inval.ir")

    def g_hfence(self):
        """hfence/hinval forms that change no translation (any mode: they
        trap below HS)."""
        r = self.r
        rv, ra_ = r.sample(self.pool, 2)
        k = r.randrange(6)
        a = self.guest_addr(8)
        if k == 0:
            self.emit(self.ch(["hfence.vvma x0, x0", "hfence.gvma x0, x0"]))
        elif k in (1, 2):
            self.li(rv, a)
            self.li(ra_, self.vcur.asid if self.vcur is not None else r.randrange(1 << 16))
            self.emit(f"hfence.vvma {gen.fx(rv)}, {gen.fx(ra_) if k == 1 else 'x0'}")
        elif k == 3:
            self.li(rv, a >> 2)
            self.li(ra_, self.gvm.vmid if not self.gvm.bare else r.randrange(1 << 14))
            self.emit(f"hfence.gvma {gen.fx(rv)}, {gen.fx(ra_)}")
        else:
            self.li(rv, a)
            self.li(ra_, r.randrange(1 << 16))
            self.emit("sfence.w.inval")
            if k == 4:
                self.emit(f"hinval.vvma {gen.fx(rv)}, {gen.fx(self.ch([ra_, 0]))}")
            else:
                self.emit(f"hinval.gvma {gen.fx(rv)}, x0")
            self.emit("sfence.inval.ir")

    # CSRs.
    def csr_val(self, name):
        v = super().csr_val(name)
        if name == "medeleg":
            v = (v & ~ECALL_BITS) | self.edeleg
        elif name == "hedeleg":
            v = (v & ~0x100) | self.hdeleg
        elif name == "hstatus":
            v = (v & ~HSTATUS_KEEP) | (2 << 32)
        elif name == "henvcfg":
            v = (v & ~HENVCFG_KEEP) | (int(self.hadue) << 61)
        elif name == "vsstatus":
            v &= ~self.VSS_KEEP
        elif name in ("vsatp", "hgatp"):
            v = (v & ~(0xF << 60)) | (self.ch([0, 1, 7, 8, 9, 10, 15]) << 60)
        return v & (2**64 - 1)

    H_CSRS = ["hstatus", "hedeleg", "hideleg", "hcounteren", "henvcfg", "hstateen0", "htval", "htinst", "hvip",
              "vsstatus", "vsepc", "vscause", "vstval", "vsip"]
    H_READ = ["hip", "hie", "hgeip", "hgeie", "hgatp", "vsatp", "vstvec", "vsscratch", "vsie"]
    H_RESTORE = ["vstvec", "vsscratch", "hgatp", "vsatp"]
    KEEP = {"mstatus": priv.MSTATUS_KEEP, "sstatus": priv.SSTATUS_KEEP, "medeleg": ECALL_BITS, "hedeleg": 0x100,
            "menvcfg": priv.MENVCFG_KEEP, "senvcfg": priv.SENVCFG_KEEP, "hstatus": HSTATUS_KEEP,
            "henvcfg": HENVCFG_KEEP, "vsstatus": VSSTATUS_KEEP}

    def keep_mask(self, name):
        if name == "mstatus":
            return self.MS_KEEP
        if name == "sstatus":
            return self.SS_KEEP
        if name == "vsstatus":
            return self.VSS_KEEP
        return self.KEEP.get(name)

    def g_csr(self):
        r = self.r
        if self.p(0.3) and not self.in_func:
            return self.g_hcsr()
        if self.mode == 3:
            names = self.M_CSRS + self.S_CSRS
        elif self.mode == 1:
            names = self.S_CSRS + (self.M_CSRS[:3] if self.p(0.1) else [])
        else:
            names = self.S_CSRS if self.p(0.2) else []
        if self.in_func:
            names = [n for n in names if n not in ("mstatus", "sstatus", "satp", "medeleg")]
        k = r.random()
        if not names or k < 0.15:
            name = self.ch(self.READ_ONLY + names)
            self.emit(f"{self.ch(['csrrs', 'csrrc'])} {gen.fx(self.xw())}, {name}, x0")
            return
        if k < 0.25:
            name = self.ch([n for n in self.RESTORE if self.mode == 3 or n[0] == "s"])
            self.restore_write(name)
            return
        name = self.ch(names)
        if name == "medeleg" and self.mode != 3:
            return
        self.rand_write(name)

    def restore_write(self, name):
        r = self.r
        old, new, rd = r.sample(self.pool, 3)
        v = r.getrandbits(64) if self.p(0.5) else self.xval()
        if name in ("hgatp", "vsatp"):
            v = self.csr_val(name)
        self.li(new, v)
        self.emit(f"csrrw {gen.fx(old)}, {name}, {gen.fx(new)}")
        self.emit(f"csrr {gen.fx(rd)}, {name}")
        self.emit(f"csrw {name}, {gen.fx(old)}")

    def rand_write(self, name):
        r = self.r
        rx = self.ch(self.pool)
        op = r.random()
        keep = self.keep_mask(name)
        if op < 0.6 or name == "satp":
            self.li(rx, self.csr_val(name))
            self.emit(f"csrrw {gen.fx(self.xw())}, {name}, {gen.fx(rx)}")
        elif keep is not None:
            self.li(rx, r.getrandbits(64) & ~keep)
            self.emit(f"{self.ch(['csrrs', 'csrrc'])} {gen.fx(self.xw())}, {name}, {gen.fx(rx)}")
        elif self.p(0.5):
            self.emit(f"{self.ch(['csrrsi', 'csrrci', 'csrrwi'])} {gen.fx(self.xw())}, {name}, {r.randrange(32)}")
        else:
            self.li(rx, self.csr_val(name))
            self.emit(f"{self.ch(['csrrs', 'csrrc'])} {gen.fx(self.xw())}, {name}, {gen.fx(rx)}")

    def g_hcsr(self):
        """H and VS CSRs; below HS they trap (virtual instruction from VS and
        VU, illegal from U)."""
        r = self.r
        k = r.random()
        below = self.mode != 3 and (self.mode == 0 or self.v)
        if k < 0.25 or below or self.in_func:
            name = self.ch(self.H_READ + self.H_CSRS + (["mtval2", "mtinst"] if self.mode == 3 else []))
            if name == "mtinst":
                name = "0x34a"
            self.emit(f"{self.ch(['csrrs', 'csrrc'])} {gen.fx(self.xw())}, {name}, x0")
            if below and not self.in_func and self.p(0.3):
                # A write: an HS-legal one is a virtual instruction from VS/VU.
                self.emit(f"csrrw {gen.fx(self.xw())}, {self.ch(self.H_CSRS)}, {gen.fx(self.xr())}")
            return
        if k < 0.35:
            self.restore_write(self.ch(self.H_RESTORE))
            return
        names = self.H_CSRS + (["mtval2"] if self.mode == 3 else [])
        name = self.ch(names)
        if name == "hedeleg" and self.p(0.5):
            return self.t_hdeleg()
        self.rand_write(name)

    def g_ctr(self):
        """A counter read into x0: legal, illegal or virtual by mcounteren,
        scounteren and hcounteren."""
        c = self.ch(["cycle", "time", "instret"] + [f"hpmcounter{i}" for i in range(3, 32)])
        self.emit(f"csrrs x0, {c}, x0")

    def g_hstatus(self):
        """SPVP, HU, SPV and GVA (HS and M)."""
        t = self.ch(self.pool)
        bits = 0
        for b in (H_SPVP, H_HU, H_SPV, H_GVA):
            if self.p(0.5):
                bits |= b
        self.li(t, bits or H_SPVP)
        self.emit(f"{self.ch(['csrs', 'csrc'])} hstatus, {gen.fx(t)}")

    def g_fs(self):
        """FS of mstatus (sstatus) and vsstatus."""
        t = self.ch(self.pool)
        if self.mode == 3 or self.mode == 1 and not self.v:
            csr = self.ch(["mstatus" if self.mode == 3 else "sstatus", "vsstatus"])
        else:
            csr = "sstatus"
        self.li(t, 3 << 13)
        self.emit(f"csrc {csr}, {gen.fx(t)}")
        val = self.ch([0, 1, 2, 3])
        if val:
            self.li(t, val << 13)
            self.emit(f"csrs {csr}, {gen.fx(t)}")

    def g_wfi(self):
        """WFI where it traps: U and VU."""
        if self.mode == 0:
            self.emit("wfi")
        else:
            self.g_ctr()

    def g_h(self):
        """One H-specific group, by mode."""
        r = self.r
        hs_or_m = self.mode == 3 or self.mode == 1 and not self.v
        k = r.random()
        if k < 0.35 and (hs_or_m or self.mode == 0 and not self.v):
            return self.g_hlv()
        if k < 0.35:
            return self.g_hlv() if self.p(0.3) else self.g_vmem()
        if k < 0.45:
            return self.g_hfence()
        if k < 0.55:
            return self.g_ctr()
        if k < 0.62:
            return self.g_wfi()
        if k < 0.72:
            return self.g_fs()
        if k < 0.82 and hs_or_m and not self.in_func:
            return self.g_hstatus()
        if k < 0.92 and not self.in_func and self.irq_ok and self.mode != 0:
            return self.g_irq()
        if k < 0.95 and self.mode != 3 and not self.in_func:
            return self.g_xret()
        return self.g_hcsr()

    def g_irq(self):
        """A software-raised interrupt: the pending bit and the enable of an
        interrupt the current mode takes, inside a window of the global
        enable (taken there), or left for the next entry into a less
        privileged mode, which takes it whatever its own enable. The
        handler clears the pending bit and the enable. MIE, SIE, MPIE and
        SPIE are otherwise kept 0, so no interrupt is taken in M, HS or VS
        outside a window."""
        r = self.r
        t = self.ch(self.pool)
        window = self.p(0.6)
        if self.mode == 3:
            # SSI to M.
            self.emit(f"csrci mideleg, {MIP_SSIP}")
            en, ip, ge = "mie", "mip", 8
            bit = MIP_SSIP
        elif not self.v:
            # SSI if mideleg delegates it, else nothing; or VSSI, VSTI or VSEI
            # with hideleg clear, an HS interrupt.
            k = r.randrange(5)
            if k == 4:
                self.li(t, MIP_VSSIP)
                self.emit(f"csrs hideleg, {gen.fx(t)}")
                return
            bit = [MIP_SSIP, MIP_VSSIP, MIP_VSTIP, MIP_VSEIP][k]
            en, ip, ge = ("sie", "sip", 2) if k == 0 else ("hie", "hvip", 2)
            if k:
                self.li(t, bit)
                self.emit(f"csrc hideleg, {gen.fx(t)}")
        else:
            # VSSI if hideleg delegates it, else nothing.
            en, ip, ge = "sie", "sip", 2
            bit = MIP_SSIP
        status = "mstatus" if self.mode == 3 else "sstatus"
        self.li(t, bit)
        self.emit(f"csrs {en}, {gen.fx(t)}")
        if window:
            self.emit(f"csrsi {status}, {ge}")
            self.emit(f"csrs {ip}, {gen.fx(t)}")
            self.emit("nop")
            self.emit(f"csrci {status}, {ge}")
            self.emit(f"csrc {en}, {gen.fx(t)}")
        else:
            self.emit(f"csrs {ip}, {gen.fx(t)}")

    def g_xret(self):
        """xRET that traps: MRET below M, SRET in U and VU."""
        self.emit(self.ch(["mret", "sret"] if self.mode == 0 else ["mret"]))

    def g_trap(self):
        """priv.py's deliberate traps; in VS and VU with vsatp Bare also a
        fetch from a guest physical address the G-stage does not map."""
        if not (self.v and self.vcur is None and not self.gvm.bare and not self.in_func and self.p(0.2)):
            return super().g_trap()
        self.dyn += 20 * self.mult
        back = self.label("resume")
        ra_, rb_ = self.r.sample(self.pool, 2)
        self.li(ra_, self.shared() + priv.RES_OFF)
        self.emit(f"la {gen.fx(rb_)}, {back}", 2)
        self.emit(f"sd {gen.fx(rb_)}, 0({gen.fx(ra_)})")
        self.li(ra_, self.ch([self.unmapped_gpa(), (1 << GPA_BITS) + (self.r.randrange(1 << 20) << 2), 0x1000]))
        self.emit(f"jalr {gen.fx(self.xw())}, 0({gen.fx(ra_)})")
        self.put(f"{back}:")

    def one(self):
        if self.p(0.12):
            return self.g_h()
        return super().one()

    # Delegation.
    def rand_edeleg(self):
        return self.ch([0, 0x100, 0x200, 0x400, 0x300, 0x500, 0x600])

    def t_deleg(self):
        r = self.r
        self.edeleg = self.rand_edeleg()
        t = self.ch(self.pool)
        v = r.getrandbits(24) & 0x00fc_b7ff & ~ECALL_BITS | self.edeleg
        self.li(t, v)
        self.emit(f"csrw medeleg, {gen.fx(t)}")
        if self.p(0.5):
            self.t_hdeleg()
        if self.p(0.5):
            self.li(t, r.getrandbits(11) & (MIP_VSSIP | MIP_VSTIP | MIP_VSEIP))
            self.emit(f"csrw hideleg, {gen.fx(t)}")

    def t_hdeleg(self):
        r = self.r
        self.hdeleg = self.ch([0, 0x100])
        t = self.ch(self.pool)
        self.li(t, r.getrandbits(16) & 0xb1ff & ~0x100 | self.hdeleg)
        self.emit(f"csrw hedeleg, {gen.fx(t)}")

    # Translation contexts.
    def satp_of(self, sp):
        return 0 if sp is None else sp.satp

    def vm_fence(self, old, new):
        """hgatp from old to new VM: a VMID another VM shares is flushed."""
        return new is not old and not new.bare and any(o is not new and not o.bare and o.vmid == new.vmid
                                                      for o in self.vms)

    def needs_vfence(self, a, b, vm):
        return b is not None and b is not a and any(s is not b and s.asid == b.asid for s in vm.guests)

    def fence_bits(self, cur, vcur, vm):
        f = 0
        if self.needs_fence(self.cur, cur) or self.p(0.15):
            f |= 1
        if self.vm_fence(self.gvm, vm):
            f |= 6
        if vm is self.gvm and self.needs_vfence(self.vcur, vcur, vm) or vm is not self.gvm and vcur is not None and \
                self.needs_vfence(None, vcur, vm):
            f |= 4
        if self.p(0.1):
            f |= self.ch([2, 4])
        return f

    def set_ctx(self, cur, vcur, vm, fence, guest_only=False):
        """Emit the satp/vsatp/hgatp writes and fences (M or HS; with
        guest_only, VS writing its satp)."""
        t = self.ch(self.pool)
        if guest_only:
            if vcur is not self.vcur:
                self.li(t, self.satp_of(vcur))
                self.emit(f"csrw satp, {gen.fx(t)}")
            if fence & 5:
                self.emit("sfence.vma")
            return
        if cur is not self.cur:
            self.li(t, self.satp_of(cur))
            self.emit(f"csrw satp, {gen.fx(t)}")
        if vcur is not self.vcur or vm is not self.gvm:
            self.li(t, self.satp_of(vcur))
            self.emit(f"csrw vsatp, {gen.fx(t)}")
        if vm is not self.gvm:
            self.li(t, vm.hgatp)
            self.emit(f"csrw hgatp, {gen.fx(t)}")
        if fence & 1:
            self.emit("sfence.vma")
        if fence & 2:
            self.emit("hfence.gvma x0, x0")
        if fence & 4:
            self.emit("hfence.vvma x0, x0")

    def t_satp(self):
        """satp in HS/M; in VS, its satp (vsatp) among the VM's guests."""
        if self.v:
            new = self.ch(self.gvm.guests + [None])
            f = 1 if self.needs_vfence(self.vcur, new, self.gvm) or self.p(0.2) else 0
            self.set_ctx(self.cur, new, self.gvm, f, guest_only=True)
            self.vcur = new
            self.rehome()
            return
        if self.p(0.6):
            return super().t_satp()
        self.t_hgatp()

    def t_hgatp(self):
        """HS/M: switch the VM (hgatp and vsatp)."""
        vm = self.ch(self.vms)
        vcur = self.ch(vm.guests + [None])
        self.set_ctx(self.cur, vcur, vm, self.fence_bits(self.cur, vcur, vm) & 6)
        self.gvm, self.vcur = vm, vcur

    def rehome(self):
        h = self.home()
        self.li(3, h + 0x800)
        self.li(2, h + 0x1800)

    # Windows of trap-control bits.
    def t_window(self):
        """From M: mstatus.TVM/TSR/TW over a run of HS instructions they
        trap, or hstatus.VTVM/VTW/VTSR over VS ones; back in M by ecall."""
        r = self.r
        t = self.ch(self.pool)
        guest = self.p(0.5)
        if guest and self.edeleg & 0x400 or not guest and self.edeleg & 0x200:
            return
        bits = 0
        while not bits:
            bits = sum(b for b in (1 << 20, 1 << 21, 1 << 22) if self.p(0.5))
        # Illegal instructions from HS go to M.
        self.emit("csrci medeleg, 4")
        self.li(t, bits)
        self.emit(f"csrs {'hstatus' if guest else 'mstatus'}, {gen.fx(t)}")
        label = self.label("win")
        self.emit(f"la {gen.fx(t)}, {label}", 2)
        self.emit(f"csrw mepc, {gen.fx(t)}")
        self.li(t, 0x1800 | M_MPV)
        self.emit(f"csrc mstatus, {gen.fx(t)}")
        self.li(t, (1 << 11) | (M_MPV if guest else 0))
        self.emit(f"csrs mstatus, {gen.fx(t)}")
        self.emit("mret")
        self.set_section("text")
        self.put(f"{label}:")
        ops = []
        if bits & (1 << 20):
            ops += ["csrr {x}, satp", "csrw satp, {y}", "sfence.vma", "sfence.vma {y}, x0", "sinval.vma {y}, x0"]
            if not guest:
                ops += ["hfence.gvma x0, x0", "csrr {x}, hgatp", "hinval.gvma {y}, x0"]
        if bits & (1 << 21):
            ops += ["wfi"]
        if bits & (1 << 22):
            ops += ["sret"]
        for _ in range(r.randrange(1, 5)):
            op = self.ch(ops).format(x=gen.fx(self.xw()), y=gen.fx(self.xr()))
            if op.startswith("csrw satp"):
                y = self.ch(self.pool)
                self.li(y, self.satp_of(self.vcur if guest else self.cur))
                op = f"csrw satp, {gen.fx(y)}"
            self.emit(op)
        back = self.label("seg")
        self.emit("ecall")
        self.desc.append((back, 3, 0, self.satp_of(self.cur), self.satp_of(self.vcur), self.gvm.hgatp, 0))
        self.put(f"    .word {len(self.desc)}")
        self.dyn += 40
        self.put(f"{back}:")
        self.li(t, bits)
        self.emit(f"csrc {'hstatus' if guest else 'mstatus'}, {gen.fx(t)}")

    # Mode changes.
    def ecall_dest(self, mode, v):
        """The handler an ecall from (mode, v) reaches: 'm', 'hs' or 'vs'."""
        if mode == 3:
            return "m"
        cause = {(0, 0): 8, (1, 0): 9, (1, 1): 10, (0, 1): 8}[(mode, v)]
        if not self.edeleg >> cause & 1:
            return "m"
        if v and cause == 8 and self.hdeleg:
            return "vs"
        return "hs"

    MODES = [(3, 0), (1, 0), (0, 0), (1, 1), (0, 1)]

    def pick_target(self):
        r = self.r
        tm, tv = r.choices(self.MODES, [2, 4, 3, 5, 4])[0]
        cur = self.ch(self.spaces + [None]) if self.p(0.5) else self.cur
        vm, vcur = self.gvm, self.vcur
        if tv and self.p(0.5) or self.p(0.15):
            vm = self.ch(self.vms)
            vcur = self.ch(vm.guests + [None])
        elif tv and self.p(0.4):
            vcur = self.ch(vm.guests + [None])
        return tm, tv, cur, vcur, vm

    def final_target(self):
        """The next hop towards M."""
        m, v = self.mode, self.v
        d = self.ecall_dest(m, v)
        if d == "m":
            return (3, 0), "ecall"
        if (m, v) == (1, 0):
            # HS ecalls stay in HS: leave through U or VS, whose ecall reaches M.
            if self.ecall_dest(0, 0) == "m":
                return (0, 0), "sret"
            return (1, 1), "sret"
        if d == "vs":
            return (1, 1), "ecall"
        return (1, 0), "ecall"

    def transition(self, final=False):
        m, v = self.mode, self.v
        if final:
            if m == 3:
                self.emit("j gr_pass")
                return None
            (tm, tv), how = self.final_target()
            cur, vcur, vm = self.cur, self.vcur, self.gvm
        else:
            tm, tv, cur, vcur, vm = self.pick_target()
            if m == 3:
                how = "mret" if self.p(0.8) else "ecall"
            elif (m, v) == (1, 0):
                how = "sret" if tm != 3 and self.p(0.6) else "inline" if (tm, tv) == (1, 0) and self.p(0.4) \
                    else "ecall"
            elif (m, v) == (1, 1):
                how = "sret" if tv and tm != 3 and self.p(0.5) else "inline" if (tm, tv) == (1, 1) and self.p(0.4) \
                    else "ecall"
            else:
                how = "ecall"
        if how == "ecall":
            d = self.ecall_dest(m, v)
            if d == "hs" and tm == 3:
                tm = 1
            if d == "vs":
                tm, tv, vm = (tm if tm != 3 else 1), 1, self.gvm
                cur = self.cur
                if vcur is not None and vcur.vm is not vm:
                    vcur = self.vcur
        elif m == 1 and v == 1:
            # sret or inline within the guest.
            vm, cur = self.gvm, self.cur
            if vcur is not None and vcur.vm is not vm:
                vcur = self.vcur
        if vcur is not None and vcur.vm is not vm:
            vcur = self.ch(vm.guests + [None])
        label = self.label("seg")
        if how == "ecall":
            d = self.ecall_dest(m, v)
            fence = self.fence_bits(cur, vcur, vm)
            if d == "vs":
                fence = 1 if self.needs_vfence(self.vcur, vcur, vm) or self.p(0.2) else 0
            self.emit("ecall")
            self.desc.append((label, tm, tv, self.satp_of(cur), self.satp_of(vcur), vm.hgatp, fence))
            self.put(f"    .word {len(self.desc)}")
            self.dyn += 40
        elif how == "mret":
            t = self.ch(self.pool)
            self.emit(f"la {gen.fx(t)}, {label}", 2)
            self.emit(f"csrw mepc, {gen.fx(t)}")
            self.li(t, 0x1800 | M_MPV)
            self.emit(f"csrc mstatus, {gen.fx(t)}")
            if tm or tv:
                self.li(t, (tm << 11) | (M_MPV if tv and tm != 3 else 0))
                self.emit(f"csrs mstatus, {gen.fx(t)}")
            self.set_ctx(cur, vcur, vm, self.fence_bits(cur, vcur, vm))
            self.emit("mret")
        elif how == "sret" and v == 0:
            t = self.ch(self.pool)
            self.set_ctx(cur, vcur, vm, self.fence_bits(cur, vcur, vm))
            self.emit(f"la {gen.fx(t)}, {label}", 2)
            self.emit(f"csrw sepc, {gen.fx(t)}")
            self.li(t, 1 << 8)
            self.emit(f"csrc sstatus, {gen.fx(t)}")
            if tm:
                self.emit(f"csrs sstatus, {gen.fx(t)}")
            self.li(t, H_SPV)
            self.emit(f"{'csrs' if tv else 'csrc'} hstatus, {gen.fx(t)}")
            self.emit("sret")
        elif how == "sret":
            t = self.ch(self.pool)
            f = 1 if self.needs_vfence(self.vcur, vcur, vm) or self.p(0.15) else 0
            self.set_ctx(cur, vcur, vm, f, guest_only=True)
            self.emit(f"la {gen.fx(t)}, {label}", 2)
            self.emit(f"csrw sepc, {gen.fx(t)}")
            self.li(t, 1 << 8)
            self.emit(f"csrc sstatus, {gen.fx(t)}")
            if tm:
                self.emit(f"csrs sstatus, {gen.fx(t)}")
            self.emit("sret")
        else:
            if v:
                f = 1 if self.needs_vfence(self.vcur, vcur, vm) else 0
                self.set_ctx(cur, vcur, vm, f, guest_only=True)
            else:
                self.set_ctx(cur, vcur, vm, self.fence_bits(cur, vcur, vm))
            self.emit(f"j {label}")
        self.mode, self.v, self.cur, self.vcur, self.gvm = tm, tv, cur, vcur, vm
        self.on_mode()
        self.enter(label)
        return label

    def on_mode(self):
        pass

    def segment(self, length):
        end = self.dyn + length
        while self.dyn < end:
            self.section_mode()
            k = self.r.random()
            hs_or_m = self.mode == 3 or self.mode == 1 and not self.v
            if k < 0.04 and self.mode in (1, 3):
                self.set_section(self.sec)
                self.t_satp()
            elif k < 0.06 and self.mode == 3:
                self.set_section(self.sec)
                self.t_deleg()
            elif k < 0.075 and self.mode == 3:
                self.set_section(self.sec)
                self.t_pmp()
            elif k < 0.09 and self.mode == 3:
                self.set_section(self.sec)
                self.t_window()
            elif k < 0.10 and hs_or_m:
                self.set_section(self.sec)
                self.t_hgatp()
            else:
                self.block()

    # Program.
    def build(self):
        r = self.r
        self.mprv_v = False
        self.fpconst = ([v for v in gen.D_SPECIAL] + [0xffffffff00000000 | v for v in gen.S_SPECIAL]
                        + [0xffffffffffff0000 | v for v in gen.H_SPECIAL]
                        + [r.getrandbits(64) for _ in range(8)]
                        + [0xffffffff00000000 | r.getrandbits(32) for _ in range(4)])
        self.build_tables()
        self.gvm = self.vms[0]
        self.nfunc = r.randrange(2, 5)
        self.fsize = 30
        out = [f"# Generated by test/gr/gen.py --hyp{self.FLAG} --seed {self.seed} --length {self.length}. "
               "Do not edit."]
        menvcfg = int(self.adue) << 61 | 0xf0 | (1 << 62 if self.p(0.5) else 0)
        henvcfg = int(self.hadue) << 61 | (r.getrandbits(8) & 0xf1) | (1 << 62 if self.p(0.5) else 0)
        out.append(self.HEAD.format(pmp15=0x1f << 56, menvcfg=menvcfg, henvcfg=henvcfg, vsstatus=self.vsstatus0()))
        self.lines = []
        self.li(5, r.randrange(32) | (r.randrange(5) << 5))
        self.emit("fscsr x5")
        for i in gen.FR:
            self.emit(f"fld f{i}, {8 * r.randrange(len(self.fpconst))}(x6)")
        self.edeleg = self.rand_edeleg()
        self.li(5, r.getrandbits(24) & 0x00fc_b7ff & ~ECALL_BITS | self.edeleg)
        self.emit("csrw medeleg, x5")
        self.hdeleg = self.ch([0, 0x100])
        self.li(5, r.getrandbits(16) & 0xb1ff & ~0x100 | self.hdeleg)
        self.emit("csrw hedeleg, x5")
        self.li(5, r.getrandbits(16) & 0xffff)
        self.emit("csrw hcounteren, x5")
        for x in gen.XW:
            self.li(x, self.xval())
        self.init_extra()
        out += [f"    li x6, {priv.SHARED_PA + priv.FPC_OFF:#x}"] + self.lines
        out.append("    j gr_main")

        self.out = {"text": [], "utext": []}
        self.lines = self.out["text"]
        self.sec = "text"
        self.rvc = True
        self.mode, self.v, self.cur, self.vcur = 3, 0, None, None
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
        self.finish()
        self.emit("j gr_pass")
        body_dyn = self.dyn
        self.in_func = True
        for sec, pre, mode in (("text", "", 1), ("utext", "u", 0)):
            self.mode, self.v = mode, 0
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
        out.append(self.handler("m"))
        out.append(self.handler("s"))
        out.append(self.handler("vs"))
        out.append(priv.TAIL)
        out += self.out["text"]
        out.append('    .section .utext, "ax"')
        out += self.out["utext"]

        out.append("    .data")
        out.append("    .align 6")
        for x in ("m", "s", "vs"):
            out.append(f"gr_{x}save:")
            out.append(f"    .zero {SAVE}")
        out.append("gr_desc:")
        for label, mode, v, satp, vsatp, hgatp, fence in self.desc:
            out.append(f"    .dword {label}, {mode}, {v}, {satp:#x}, {vsatp:#x}, {hgatp:#x}, {fence}, 0")
        out.append("gr_rtab:")
        for e in self.rtab:
            out.append("    .dword " + ", ".join(f"{v:#x}" for v in e) + ", 0")
        out.append("    .dword 0, 0, 0, 0, 0, 0, 0, 0")
        out.append("gr_gtab:")
        for e in self.gtab:
            out.append("    .dword " + ", ".join(f"{v:#x}" for v in e) + ", 0, 0")
        out.append("    .dword 0, 0, 0, 0, 0, 0, 0, 0")
        out += self.data_extra()

        out.append('    .section .pt, "aw", @progbits')
        last = priv.PT_PA
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
        shared = [0] * (priv.FPC_OFF // 8) + self.fpconst
        shared += [0] * (0x1000 // 8 - len(shared))
        out += [f"    .dword {v:#018x}" for v in shared]
        out.append(f"    .zero {WIN_PA - priv.SHARED_PA - 0x1000}")
        win = [r.getrandbits(64) for _ in range(WIN_PAGES * 0x1000 // 8)]
        out += [f"    .dword {v:#018x}" for v in win]
        return "\n".join(out) + "\n", body_dyn

    FLAG = ""

    def vsstatus0(self):
        return (2 << 32) | (3 << 13)

    def handler(self, x):
        return handler(x, self.VEC)

    VEC = False


HEAD = """\
    .section .text.init, "ax"
    .globl _start
_start:
    la t0, gr_mtrap
    csrw mtvec, t0
    la t0, gr_strap
    csrw stvec, t0
    la t0, gr_vstrap
    csrw vstvec, t0
    la t0, gr_msave
    csrw mscratch, t0
    la t0, gr_ssave
    csrw sscratch, t0
    la t0, gr_vssave
    csrw vsscratch, t0
    li t0, -1
    csrw pmpaddr15, t0
    li t0, {pmp15:#x}
    csrw pmpcfg2, t0
    csrw pmpcfg0, zero
    li t0, {menvcfg:#x}
    csrw menvcfg, t0
    li t0, {henvcfg:#x}
    csrw henvcfg, t0
    csrw mideleg, zero
    csrw mie, zero
    csrw hideleg, zero
    csrw hvip, zero
    csrw satp, zero
    csrw vsatp, zero
    csrw hgatp, zero
    li t0, {vsstatus:#x}
    csrw vsstatus, t0
    li t0, 3 << 13
    csrs mstatus, t0
    li tp, 0
    li ra, 0"""

HypGen.HEAD = HEAD


def handler(x, vec=False):
    """The M ('m'), HS ('s') or VS ('vs') trap handler; see the module
    docstring."""
    m, hs, vs = x == "m", x == "s", x == "vs"
    c = "m" if m else "s"  # CSR prefix (VS sees its own registers as s*)
    L = f".L{x}"
    sum_on = "" if m else "    li t2, 1 << 18\n    csrrs t2, sstatus, t2\n"
    sum_off = "" if m else "    csrw sstatus, t2\n"
    o = []
    a = o.append
    a(f"""\
    .align 2
gr_{x}trap:
    csrrw sp, {c}scratch, sp
    sd t0, 0(sp)
    sd t1, 8(sp)
    sd t2, 16(sp)
    sd t3, 24(sp)
    sd t4, 32(sp)
    sd t5, 40(sp)
    csrr t0, {c}cause
    bltz t0, {L}irq
    li t1, 24
    bgeu t0, t1, gr_fail
    slli t1, t0, 3
    add t1, t1, sp
    ld t2, {CNT}(t1)
    addi t2, t2, 1
    sd t2, {CNT}(t1)""")
    ecalls = [8, 9, 10, 11] if m else [8, 9, 10] if hs else [8]
    for e in ecalls:
        a(f"    li t1, {e}\n    beq t0, t1, {L}ecall")
    for e in [1, 12] + ([] if vs else [20]):
        a(f"    li t1, {e}\n    beq t0, t1, {L}resume")
    for e in [13, 15] + ([] if vs else [21, 23]):
        a(f"    li t1, {e}\n    beq t0, t1, {L}pf")
    if vec:
        if vs:
            vclear = f"""\
    csrr t1, sstatus
    srli t1, t1, 9
    andi t1, t1, 3
    beqz t1, {L}ret
    la t1, gr_vsm
    ld t1, 0(t1)
    beqz t1, {L}ret
    csrr t1, vstart
    csrwi vstart, 0
"""
        else:
            vclear = f"""\
    csrr t1, {c}status
    srli t1, t1, 9
    andi t1, t1, 3
    beqz t1, {L}ret
    csrr t1, vstart
    csrwi vstart, 0
"""
    else:
        vclear = ""
    a(f"""\
{L}skip:
    sd zero, {LASTPC}(sp)
    csrr t0, {c}epc
{sum_on}    lhu t1, 0(t0)
{sum_off}    andi t1, t1, 3
    li t3, 3
    addi t0, t0, 2
    bne t1, t3, 1f
    addi t0, t0, 2
1:  csrw {c}epc, t0
{vclear}{L}ret:
    ld t0, 0(sp)
    ld t1, 8(sp)
    ld t2, 16(sp)
    ld t3, 24(sp)
    ld t4, 32(sp)
    ld t5, 40(sp)
    csrrw sp, {c}scratch, sp
    {c}ret
{L}resume:
    sd zero, {LASTPC}(sp)
    li t0, {priv.SHARED_PA + priv.RES_OFF:#x}
    ld t0, 0(t0)
    csrw {c}epc, t0
    j {L}ret
{L}irq:
    slli t0, t0, 1
    srli t0, t0, 1
    slli t1, t0, 3
    add t1, t1, sp
    ld t2, {CNT + 8 * 24}(t1)
    addi t2, t2, 1
    sd t2, {CNT + 8 * 24}(t1)
    li t1, 1
    sll t1, t1, t0""")
    if m:
        a("    csrc mip, t1\n    csrc mie, t1")
    elif hs:
        a("    csrc sip, t1\n    csrc sie, t1\n    csrc hvip, t1\n    csrc hie, t1")
    else:
        a("    csrc sip, t1\n    csrc sie, t1")
    a(f"    j {L}ret")
    # ecall: the word after it.
    a(f"""\
{L}ecall:
    sd zero, {LASTPC}(sp)
    csrr t0, {c}epc
{sum_on}    lwu t1, 4(t0)
{sum_off}    addi t0, t0, 8
    csrw {c}epc, t0
    beqz t1, {L}ret
    addi t1, t1, -1
    slli t1, t1, 6
    la t2, gr_desc
    add t1, t1, t2
    ld t2, 0(t1)
    csrw {c}epc, t2""")
    if m:
        a(f"""\
    li t3, {0x1800 | M_MPV:#x}
    csrc mstatus, t3
    ld t2, 8(t1)
    slli t2, t2, 11
    csrs mstatus, t2
    ld t2, 16(t1)
    slli t2, t2, 39
    csrs mstatus, t2""")
    else:
        a("""\
    li t3, 0x100
    csrc sstatus, t3
    ld t2, 8(t1)
    slli t2, t2, 8
    csrs sstatus, t2""")
        if hs:
            a(f"""\
    li t3, {H_SPV:#x}
    csrc hstatus, t3
    ld t2, 16(t1)
    slli t2, t2, 7
    csrs hstatus, t2""")
    if vs:
        a(f"""\
    ld t2, 32(t1)
    csrw satp, t2
    ld t2, 48(t1)
    beqz t2, {L}ret
    sfence.vma
    j {L}ret""")
    else:
        a(f"""\
    ld t2, 24(t1)
    csrw satp, t2
    ld t2, 32(t1)
    csrw vsatp, t2
    ld t2, 40(t1)
    csrw hgatp, t2
    ld t2, 48(t1)
    andi t3, t2, 1
    beqz t3, 1f
    sfence.vma
1:  andi t3, t2, 2
    beqz t3, 2f
    hfence.gvma x0, x0
2:  andi t3, t2, 4
    beqz t3, {L}ret
    hfence.vvma x0, x0
    j {L}ret""")
    # Page faults: retry after a fix from gr_rtab unless the same pc (and,
    # with vector, the same tval) faulted just before.
    a(f"""\
{L}pf:
    csrr t0, {c}epc
    ld t1, {LASTPC}(sp)
    sd t0, {LASTPC}(sp)""")
    if vec:
        a(f"""\
    csrr t2, {c}tval
    ld t3, {LASTTVAL}(sp)
    sd t2, {LASTTVAL}(sp)
    bne t0, t1, 8f
    beq t2, t3, {L}skip
8:""")
    else:
        a(f"    beq t0, t1, {L}skip")
    if not vs:
        a(f"""\
    csrr t0, {c}cause
    li t1, 20
    bgeu t0, t1, {L}gpf""")
    a(f"    csrr t0, {c}tval")
    # t1: table key (satp or vsatp); t4: 1 for the U variant of the fix.
    if vs:
        a("""\
    csrr t1, satp
    csrr t4, sstatus
    andi t4, t4, 0x100
    seqz t4, t4""")
    elif hs:
        a(f"""\
    csrr t3, hstatus
    andi t2, t3, {H_GVA}
    beqz t2, 6f
    csrr t1, vsatp
    srli t4, t3, 8
    andi t4, t4, 1
    seqz t4, t4
    j 7f
6:  csrr t1, satp
    csrr t4, sstatus
    andi t4, t4, 0x100
    seqz t4, t4
7:""")
    else:
        a("""\
    csrr t3, mstatus
    srli t2, t3, 38
    andi t2, t2, 1
    beqz t2, 6f
    csrr t1, vsatp
    srli t2, t3, 39
    andi t2, t2, 1
    beqz t2, 5f
    srli t4, t3, 11
    andi t4, t4, 3
    seqz t4, t4
    j 7f
5:  csrr t4, hstatus
    srli t4, t4, 8
    andi t4, t4, 1
    seqz t4, t4
    j 7f
6:  csrr t1, satp
    srli t4, t3, 11
    andi t4, t4, 3
    seqz t4, t4
7:""")
    a(f"""\
    la t2, gr_rtab
2:  ld t3, 0(t2)
    beqz t3, {L}skip
    bne t3, t1, 3f
    ld t3, 8(t2)
    and t3, t3, t0
    ld t5, 16(t2)
    bne t3, t5, 3f
    ld t3, 48(t2)
    beqz t3, {L}skip
    ld t5, 24(t2)
    ld t3, 32(t2)
    beqz t4, 4f
    ld t3, 40(t2)
4:  sd t3, 0(t5)""")
    if vs:
        a("    sfence.vma t0, zero")
    elif hs:
        a(f"""\
    csrr t3, hstatus
    andi t3, t3, {H_GVA}
    beqz t3, 5f
    hfence.vvma t0, zero
    j {L}ret
5:  sfence.vma t0, zero""")
    else:
        a(f"""\
    csrr t3, mstatus
    srli t3, t3, 38
    andi t3, t3, 1
    beqz t3, 5f
    hfence.vvma t0, zero
    j {L}ret
5:  sfence.vma t0, zero""")
    a(f"""\
    j {L}ret
3:  addi t2, t2, 64
    j 2b""")
    if not vs:
        a(f"""\
{L}gpf:
    csrr t0, {'mtval2' if m else 'htval'}
    slli t0, t0, 2
    csrr t1, hgatp
    la t2, gr_gtab
2:  ld t3, 0(t2)
    beqz t3, {L}skip
    bne t3, t1, 3f
    ld t3, 8(t2)
    and t3, t3, t0
    ld t5, 16(t2)
    bne t3, t5, 3f
    ld t3, 40(t2)
    beqz t3, {L}skip
    ld t5, 24(t2)
    ld t3, 32(t2)
    sd t3, 0(t5)
    srli t0, t0, 2
    hfence.gvma t0, zero
    j {L}ret
3:  addi t2, t2, 64
    j 2b""")
    return "\n".join(o) + "\n"


def _vec():
    import vec
    return vec


class VecHypGen(_vec().VecMixin, HypGen):
    """The H stream with RVV: mstatus.VS and, in VS and VU, vsstatus.VS both
    gate vector instructions. The generator tracks both; gr_vsm holds
    whether mstatus.VS is on, for the VS handler, which cannot read it."""

    FLAG = " --vec"
    VEC = True
    MS_KEEP = HypGen.MS_KEEP | (3 << 9)
    SS_KEEP = HypGen.SS_KEEP | (3 << 9)
    VSS_KEEP = HypGen.VSS_KEEP | (3 << 9)
    HEAD = HEAD.replace("li t0, 3 << 13", "li t0, (3 << 13) | (1 << 9)")

    def __init__(self, seed, length):
        super().__init__(seed, length)
        self.v_init_state()
        self.v_mprv = False
        self.vs_m = 1
        self.vs_v = 1

    def vsstatus0(self):
        return super().vsstatus0() | (1 << 9)

    def eff_vs(self):
        if not self.v:
            return self.vs_m
        return self.vs_v if self.vs_m else 0

    def on_mode(self):
        self.vs = self.eff_vs()

    def csr_val(self, name):
        v = super().csr_val(name)
        if name == "mstatus" or name == "sstatus" and not self.v:
            v = (v & ~(3 << 9)) | (self.vs_m << 9)
        elif name in ("sstatus", "vsstatus"):
            v = (v & ~(3 << 9)) | (self.vs_v << 9)
        return v

    def can_write_vs(self):
        return self.depth == 0 and self.mode in (1, 3) and not self.in_func

    def g_vs(self, val=None):
        if not self.can_write_vs():
            return False
        if self.v and not self.vs_m and self.p(0.7):
            return False
        val = self.ch([0, 1, 2, 3]) if val is None else val
        guest = bool(self.v) or self.p(0.25)
        csr = "sstatus" if self.v else "vsstatus" if guest else "mstatus" if self.mode == 3 else "sstatus"
        t = self.xreg()
        self.li(t, 3 << 9)
        self.emit(f"csrc {csr}, {gen.fx(t)}")
        if val:
            self.li(t, val << 9)
            self.emit(f"csrs {csr}, {gen.fx(t)}")
        if self.p(0.3):
            self.emit(f"csrr {gen.fx(self.xw())}, {csr}")
        if guest:
            self.vs_v = val
        else:
            self.vs_m = val
            self.li(t, int(val != 0))
            u = self.ch([x for x in self.pool if x != t])
            self.emit(f"la {gen.fx(u)}, gr_vsm", 2)
            self.emit(f"sd {gen.fx(t)}, 0({gen.fx(u)})")
        self.vs = self.eff_vs()
        self.vs_off_left = self.r.randrange(1, 4) if self.vs == 0 else 0
        return True

    def v_fpconst_ptr(self, rx, off):
        self.li(rx, self.shared() + priv.FPC_OFF + off)

    def v_regions(self):
        home = (self.home(), 0x2000, False)
        guest = self.mprv_v if self.v_mprv else self.v
        if self.v_mprv and not guest:
            return [(sl.va + sl.win_off(), 0x1000, sl.level == 0) for sl in self.slots]
        if not guest:
            if not self.translated():
                return [home, (WIN_PA, WIN_PAGES * 0x1000, False)]
            return [home] + [(sl.va, 0x1000, True) if sl.level == 0 else
                             (sl.va + sl.win_off(), WIN_PAGES * 0x1000, False) for sl in self.slots]
        out = [] if self.v_mprv else [home]
        for base, sz in self.gview_pages(self.gvm, self.vcur):
            out.append((base, sz, sz == 0x1000))
        return out

    def v_base(self, lo, hi, size, fault=None):
        return _vec().VecPrivGen.v_base(self, lo, hi, size, fault)

    def mprv_body(self):
        self.v_mprv = True
        for _ in range(self.r.randrange(1, 4)):
            if self.vs_m and self.p(0.5):
                self.ch([self.g_vunit, self.g_vstrided, self.g_vwhole, lambda: self.g_vunit(ff=True)])()
            else:
                self.g_vmem(self.mprv_addr)
        self.v_mprv = False

    def v_epilogue(self):
        return _vec().VecPrivGen.v_epilogue(self)

    def init_extra(self):
        self.v_prologue()

    def finish(self):
        self.v_epilogue()

    def data_extra(self):
        return ["    .align 3", "gr_vsm:", "    .dword 1"] + self.v_data(vdata=False)
