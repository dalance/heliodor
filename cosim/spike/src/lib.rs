//! Online spike co-simulation of heliodor's retire records: each
//! `retire_pkg::RetireRec` steps one spike instruction and each IrqEvent
//! makes spike take that interrupt, and the two are compared field by field.
//!
//! With several harts, each has its own spike hart on one shared memory,
//! stepped in retire order (by cycle, then hart, then record order). That
//! order is not the DUT's coherence order, so a read that may observe another
//! hart (load, LR, AMO) gets the bytes the DUT read written into spike's
//! memory for its step; spike then executes it as usual, and the bytes the
//! step did not store are put back afterwards.

use std::ffi::{CString, c_char, c_void};
use std::io::Read;

use veryl_component::*;

mod platform;
use platform::ArchCfg;

#[repr(C)]
struct HcRegion {
    base: u64,
    size: u64,
    kind: u64,
}

#[repr(C)]
struct HcCfg {
    isa: *const c_char,
    priv_: *const c_char,
    pmp_regions: u64,
    pmp_granularity: u64,
    trigger_count: u64,
    max_vaddr_bits: u64,
    geilen: u64,
    mstatus_reset_mask: u64,
    mstatus_reset_val: u64,
    reset_pc: u64,
    misa_ro: u64,
    stimecmp_reset: u64,
    harts: u64,
}

#[repr(C)]
#[derive(Default)]
struct HcDutMem {
    paddr: u64,
    rmask: u64,
    rdata: u64,
    rdata_hi: u64,
}

#[repr(C)]
#[derive(Default)]
struct HcStep {
    pc: u64,
    next_pc: u64,
    insn: u64,
    priv_: u64,
    virt: u64,
    trap: u64,
    cause: u64,
    tval: u64,
    tval2: u64,
    tinst: u64,
    xpr_written: u64,
    fpr_written: u64,
    vr_written: u64,
    fflags_before: u64,
    fflags_after: u64,
    dev_read_miss: u64,
    dev_read_addr: u64,
    dev_store_n: u64,
    dev_store_addr: u64,
    dev_store_len: u64,
    dev_store_data: u64,
    suppress_fail: u64,
}

unsafe extern "C" {
    fn hc_new(cfg: *const HcCfg, regions: *const HcRegion, n: usize) -> *mut c_void;
    fn hc_free(h: *mut c_void);
    fn hc_region_mem(h: *mut c_void, i: usize) -> *mut u8;
    fn hc_get_misa(h: *mut c_void, t: u32) -> u64;
    fn hc_get_xpr(h: *mut c_void, t: u32, i: u32) -> u64;
    fn hc_set_xpr(h: *mut c_void, t: u32, i: u32, v: u64);
    fn hc_get_fpr(h: *mut c_void, t: u32, i: u32) -> u64;
    fn hc_get_csr(h: *mut c_void, t: u32, addr: u32) -> u64;
    fn hc_set_csr(h: *mut c_void, t: u32, addr: u32, v: u64);
    fn hc_get_vreg(h: *mut c_void, t: u32, i: u32) -> *const u8;
    fn hc_vlenb(h: *mut c_void) -> u64;
    fn hc_get_vcsr(h: *mut c_void, t: u32, which: u32) -> u64;
    fn hc_step(h: *mut c_void, t: u32, irq: i32, dut: *const HcDutMem, out: *mut HcStep, flags: u64);
}

/// Owns one spike instance. The host serializes calls into an instance, and
/// instances share no state, so moving it across threads is sound.
struct Spike(*mut c_void);
unsafe impl Send for Spike {}
impl Default for Spike {
    fn default() -> Self {
        Spike(std::ptr::null_mut())
    }
}
impl Drop for Spike {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { hc_free(self.0) };
        }
    }
}

// retire_pkg::RetireRec members in declaration order; the first member is
// the most significant (packed-struct flattening).
const FIELDS: &[(&str, u32)] = &[
    ("valid", 1),
    ("order", 64),
    ("pc", 64),
    ("next_pc", 64),
    ("insn", 32),
    ("is_rvc", 1),
    ("trap", 1),
    ("cause", 6),
    ("tval", 64),
    ("priv", 2),
    ("virt", 1),
    ("rd_kind", 2),
    ("rd_addr", 5),
    ("rd_wdata", 64),
    ("rd2_valid", 1),
    ("rd2_wdata", 64),
    ("mem_size", 3),
    ("mem_vaddr", 64),
    ("mem_paddr", 64),
    ("mem_io", 1),
    ("mem_rmask", 16),
    ("mem_wmask", 16),
    ("mem_rdata", 64),
    ("mem_rdata_hi", 64),
    ("mem_wdata", 64),
    ("mem_wdata_hi", 64),
    ("csr_valid", 1),
    ("csr_addr", 12),
    ("csr_wdata", 64),
    ("fflags", 5),
    ("vec_v", 1),
    ("vrf_wcnt", 8),
    ("vrf_hash", 64),
    ("vtype", 64),
    ("vl", 64),
    ("vstart", 64),
    ("intr", 1),
    ("rs1_kind", 2),
    ("rs1_addr", 5),
    ("rs1_rdata", 64),
    ("rs2_kind", 2),
    ("rs2_addr", 5),
    ("rs2_rdata", 64),
    ("rs3_kind", 2),
    ("rs3_addr", 5),
    ("rs3_rdata", 64),
    ("csr_read", 1),
    ("csr_rdata", 64),
    ("csr_new", 64),
    ("tval2", 64),
    ("tinst", 64),
    ("vrf_wmask", 32),
    ("vrf_xhash", 64),
];

fn rec_width() -> u32 {
    FIELDS.iter().map(|f| f.1).sum()
}

fn bits(words: &[u64], lsb: u32, width: u32) -> u64 {
    let w = (lsb / 64) as usize;
    let s = lsb % 64;
    let mut v = words[w] >> s;
    if s != 0 && s + width > 64 {
        v |= words[w + 1] << (64 - s);
    }
    if width < 64 { v & ((1u64 << width) - 1) } else { v }
}

/// One decoded record: field i of FIELDS is `f[i]`.
struct Rec {
    f: [u64; FIELDS.len()],
}

macro_rules! field {
    ($name:literal) => {{
        const I: usize = field_index($name);
        I
    }};
}

const fn str_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut i = 0;
    while i < a.len() {
        if a[i] != b[i] {
            return false;
        }
        i += 1;
    }
    true
}

const fn field_index(name: &str) -> usize {
    let mut i = 0;
    while i < FIELDS.len() {
        if str_eq(FIELDS[i].0, name) {
            return i;
        }
        i += 1;
    }
    panic!("no such RetireRec field");
}

impl Rec {
    fn get(&self, i: usize) -> u64 {
        self.f[i]
    }
    fn on(&self, i: usize) -> bool {
        self.f[i] != 0
    }
}
/// How the cosim treats a CSR whose value spike cannot reproduce.
#[derive(Clone, Copy, PartialEq)]
enum CsrKind {
    Plain,
    /// Timing, pins or events spike does not model (the counters, the HPM
    /// event selectors, the interrupt-pending views) or a capability list
    /// spike cannot be configured to (tinfo): the DUT's read is copied into
    /// spike, not compared.
    DutValued,
    /// Read-only, fixed by the configuration where spike hardwires its own.
    Configured(u64),
    /// A WARL whose legal set spike cannot be configured to (the trigger
    /// data, the indirect-CSR selectors): the DUT's legalized write is
    /// copied into spike.
    DutLegal,
    /// Compared outside these bits (spike's reset or writable mask differs
    /// from the configuration's).
    Masked(u64),
    /// Fields the configuration leaves to the implementation where spike
    /// chose differently: the legalization of a reserved CBIE or PMM, and
    /// the henvcfg bits gated by menvcfg, whose value after leaving
    /// read-only zero is unspecified.
    /// Reads and writes are compared outside them, and the DUT's value of
    /// them is copied into spike.
    Unspecified(u64),
    /// mstatus, sstatus, vsstatus: the privileged spec lets an
    /// implementation mark FS or VS Dirty without a write to that state; a
    /// Dirty field where spike has none is accepted and copied into spike.
    Status,
}

const STATUS_DIRTY: u64 = (1 << 63) | (3 << 13) | (3 << 9);

/// Whether `got` differs from `want` only by FS or VS fields that `got`
/// holds Dirty (and the SD that follows from them).
fn dirty_only(got: u64, want: u64) -> bool {
    let d = got ^ want;
    if d & !STATUS_DIRTY != 0 {
        return false;
    }
    let field_ok = |sh: u32| (d >> sh) & 3 == 0 || (got >> sh) & 3 == 3;
    let sd = (got >> 13) & 3 == 3 || (got >> 9) & 3 == 3 || (got >> 15) & 3 == 3;
    field_ok(13) && field_ok(9) && (got >> 63 != 0) == sd
}

const VLEN_MAX: usize = 1024;

/// retire_pkg::mix64.
fn mix64(x: u64) -> u64 {
    let mut y = x ^ (x >> 30);
    y = y.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    y ^= y >> 27;
    y = y.wrapping_mul(0x94d0_49bb_1331_11eb);
    y ^ (y >> 31)
}

/// retire_pkg::vrf_hash_step.
fn vrf_hash_step(h: u64, vd: u64, data: &[u8]) -> u64 {
    let mut a = mix64(h ^ vd ^ 0x9e37_79b9_7f4a_7c15);
    for c in data.chunks(8) {
        a = mix64(a ^ u64::from_le_bytes(c.try_into().unwrap()));
    }
    a
}

fn is_csr_op(insn: u64) -> bool {
    insn & 0x7f == 0x73 && (insn >> 12) & 3 != 0
}

/// hc_step flags.
const STEP_SC_FAIL: u64 = 1;
const STEP_NO_MISALIGNED: u64 = 2;

/// Width of retire_pkg::IrqEvent {valid, cause<6>, epc<64>, order<64>},
/// valid on top.
const IRQ_W: u32 = 135;

#[derive(Default)]
struct HartState {
    /// The next record is the first of a trap handler.
    intr_next: bool,
    /// An interrupt the DUT took, checked with the handler's first record.
    irq_pending: Option<(u64, u64, u64)>,
}

/// An AMO with rd = x0 whose old value its store does not determine (and,
/// or, min, max): the DUT's store is accepted if some old value yields it.
#[derive(Clone, Copy)]
struct AmoFree {
    funct5: u64,
    bytes: u64,
    rs2: u64,
}

impl AmoFree {
    fn reachable(&self, w: u64) -> bool {
        let sh = 64 - 8 * self.bytes as u32;
        let (w, r) = ((w << sh) >> sh, (self.rs2 << sh) >> sh);
        let sx = |v: u64| ((v << sh) as i64) >> sh;
        match self.funct5 {
            0x08 => w & r == r,
            0x0c => w & !r == 0,
            0x10 => w == r || sx(w) < sx(r),
            0x14 => w == r || sx(w) > sx(r),
            0x18 => w <= r,
            0x1c => w >= r,
            _ => false,
        }
    }
}

/// A DRAM byte holding the DUT's read for one step: its offset, the value it
/// replaced, and its index relative to mem_paddr.
struct Patched {
    off: usize,
    saved: u8,
    rel: u64,
}

/// The `#[param]`s both component types take.
struct Params {
    hex_file: Option<String>,
    rom_hex: Option<String>,
    map: Option<String>,
    config: Option<String>,
    triggers: Option<u64>,
    tohost_pa: Option<u64>,
}

/// Spike, the per-hart comparison state and the counters.
#[derive(Default)]
struct Engine {
    spike: Spike,
    harts: Vec<HartState>,
    compared: u64,
    irqs: u64,
    /// Source and CSR values compared.
    src_checked: u64,
    csr_checked: u64,
    vec_checked: u64,
    dev_checked: u64,
    /// Reads whose DUT bytes differed from spike's memory, and AMO stores
    /// taken from the DUT (several harts only).
    reads_forced: u64,
    amo_forced: u64,
    at_tohost: bool,
    done: bool,
    tohost_pa: u64,
    medeleg_skip: u64,
    mideleg_skip: u64,
    /// xstateen0.C and CONTEXT, writable on spike, which always has
    /// scontext; mcountinhibit bits the configuration and spike disagree on.
    stateen_skip: u64,
    inhibit_skip: u64,
    vsatp_ignore: bool,
    marchid: u64,
    mimpid: u64,
    mvendorid: u64,
    vec_misaligned: bool,
    vec_wholereg_misaligned: bool,
    dram_size: u64,
    /// Field LSBs within one record.
    offs: Vec<u32>,
}

impl Engine {
    fn load_hex(&mut self, ctx: &mut SimCtx, path: &str, region: usize, size: u64) -> Result<()> {
        let mut text = String::new();
        ctx.open(path)?.read_to_string(&mut text)?;
        let mem = unsafe { std::slice::from_raw_parts_mut(hc_region_mem(self.spike.0, region), size as usize) };
        let mut idx: u64 = 0;
        for tok in text.split_whitespace() {
            if let Some(a) = tok.strip_prefix('@') {
                idx = u64::from_str_radix(a, 16)?;
                continue;
            }
            let w = u32::from_str_radix(tok, 16)?;
            let off = (idx * 4) as usize;
            if off + 4 > mem.len() {
                bail!("{path}: image exceeds its region");
            }
            mem[off..off + 4].copy_from_slice(&w.to_le_bytes());
            idx += 1;
        }
        Ok(())
    }

    fn init(&mut self, ctx: &mut SimCtx, p: &Params, harts: usize) -> Result<()> {
        let cfg_path = p.config.clone().unwrap_or("test/act/config/heliodor/heliodor.yaml".into());
        let mut text = String::new();
        ctx.open(&cfg_path)?.read_to_string(&mut text)?;
        let a = ArchCfg::parse(&text)?;
        if a.bool("MISALIGNED_LDST")? != a.has("Zicclsm") {
            bail!("{cfg_path}: MISALIGNED_LDST disagrees with Zicclsm");
        }
        let map = p.map.clone().unwrap_or("arch".into());
        let (regions, reset_pc) = platform::memory_map(&map)?;
        self.dram_size = regions[0].size;
        let hr: Vec<HcRegion> = regions
            .iter()
            .map(|g| HcRegion { base: g.base, size: g.size, kind: g.device as u64 })
            .collect();
        let isa = CString::new(a.spike_isa())?;
        let priv_ = CString::new(a.spike_priv())?;
        let hc = HcCfg {
            isa: isa.as_ptr(),
            priv_: priv_.as_ptr(),
            pmp_regions: a.u64("NUM_PMP_ENTRIES")?,
            pmp_granularity: 1 << a.u64("PMP_GRANULARITY")?,
            trigger_count: p.triggers.unwrap_or(a.u64("SDTRIG_NUM_TRIGGERS")?),
            max_vaddr_bits: a.max_vaddr_bits(),
            geilen: a.u64("NUM_EXTERNAL_GUEST_INTERRUPTS")?,
            mstatus_reset_mask: platform::MSTATUS_RESET_MASK,
            mstatus_reset_val: platform::MSTATUS_RESET_VAL,
            reset_pc,
            misa_ro: !a.any_mutable_misa() as u64,
            stimecmp_reset: platform::STIMECMP_RESET,
            harts: harts as u64,
        };
        let h = unsafe { hc_new(&hc, hr.as_ptr(), hr.len()) };
        if h.is_null() {
            bail!("spike construction failed (isa {})", a.spike_isa());
        }
        self.spike = Spike(h);
        self.harts = (0..harts).map(|_| HartState::default()).collect();
        let misa = unsafe { hc_get_misa(h, 0) };
        if misa != a.misa() {
            bail!("spike misa {misa:#x} != configured {:#x}", a.misa());
        }
        let vlenb = unsafe { hc_vlenb(h) };
        if a.has("V") && vlenb * 8 != a.u64("VLEN")? {
            bail!("spike VLEN {} != configured {}", vlenb * 8, a.u64("VLEN")?);
        }
        // Delegation bits the configuration and spike disagree on, found by
        // probing spike's reset and writable masks.
        let geilen = a.u64("NUM_EXTERNAL_GUEST_INTERRUPTS")?;
        self.medeleg_skip = a.mask("MEDELEG_DELEGATABLE")? ^ probe_writable(h, 0x302);
        let ro1 = unsafe { hc_get_csr(h, 0, 0x303) };
        let want_ro1 = if a.has("H") { (1 << 2) | (1 << 6) | (1 << 10) | if geilen > 0 { 1 << 12 } else { 0 } } else { 0 };
        self.mideleg_skip = ro1 ^ want_ro1;
        self.marchid = 0;
        self.mimpid = 0;
        if a.bool("MARCHID_IMPLEMENTED")? || a.bool("MIMPID_IMPLEMENTED")? {
            bail!("{cfg_path}: marchid/mimpid values are not modelled");
        }
        self.mvendorid = a.u64("VENDOR_ID_BANK")? << 7 | a.u64("VENDOR_ID_OFFSET")?;
        self.vec_misaligned = a.bool("VECTOR_LS_MISALIGNED_LEGAL")?;
        if a.str("MSTATEEN_CONTEXT_TYPE")? == "read-only-0" {
            self.stateen_skip |= 1 << 57;
        }
        if !a.bool("NON_STANDARD_EXTENSION_IMPLEMENTED")? {
            self.stateen_skip |= 1;
        }
        self.inhibit_skip = a.mask("COUNTINHIBIT_EN")? ^ probe_writable(h, 0x320);
        self.vsatp_ignore = a.bool("IGNORE_INVALID_VSATP_MODE_WRITES_WHEN_V_EQ_ZERO")?;
        self.vec_wholereg_misaligned = a.bool("VECTOR_LS_WHOLEREG_MISALIGNED_LEGAL")?;
        self.tohost_pa = p.tohost_pa.unwrap_or(0);
        let Some(path) = p.hex_file.clone() else {
            bail!("HEX_FILE is required");
        };
        self.load_hex(ctx, &path, 0, regions[0].size)?;
        if let Some(rom) = p.rom_hex.clone() {
            if map != "boot" {
                bail!("ROM_HEX needs MAP = \"boot\"");
            }
            self.load_hex(ctx, &rom, 1, regions[1].size)?;
        }
        let mut top = rec_width();
        self.offs = FIELDS
            .iter()
            .map(|&(_, fw)| {
                top -= fw;
                top
            })
            .collect();
        ctx.log(&format!(
            "spike cosim: {harts} hart(s), isa {} priv {} medeleg skip {:#x} mideleg skip {:#x}",
            a.spike_isa(),
            a.spike_priv(),
            self.medeleg_skip,
            self.mideleg_skip
        ));
        Ok(())
    }

    /// The record whose LSB is bit `base` of `buf`, if valid.
    fn decode(&self, buf: &[u64], base: u32) -> Option<Rec> {
        if bits(buf, base + self.offs[0], 1) == 0 {
            return None;
        }
        let mut r = Rec { f: [0; FIELDS.len()] };
        for (i, &(_, w)) in FIELDS.iter().enumerate() {
            r.f[i] = bits(buf, base + self.offs[i], w);
        }
        Some(r)
    }

    fn csr_kind(&self, csr: u64) -> CsrKind {
        // SGEIE has no interrupt behind it with GEILEN = 0, like mideleg.SGEI.
        let sgei = self.mideleg_skip & (1 << 12);
        match csr {
            0xc00..=0xc1f | 0xb00..=0xb1f | 0x323..=0x33f | 0x344 | 0x144 | 0x244 | 0x644 | 0xda0 | 0x7a4 => {
                CsrKind::DutValued
            }
            0xf11 => CsrKind::Configured(self.mvendorid),
            0xf12 => CsrKind::Configured(self.marchid),
            0xf13 => CsrKind::Configured(self.mimpid),
            0x7a1..=0x7a3 | 0x350 | 0x150 | 0x250 => CsrKind::DutLegal,
            0x302 | 0x602 if self.medeleg_skip != 0 => CsrKind::Masked(!self.medeleg_skip),
            0x303 if self.mideleg_skip != 0 => CsrKind::Masked(!self.mideleg_skip),
            0x304 | 0x604 if sgei != 0 => CsrKind::Masked(!sgei),
            0x30c | 0x60c | 0x10c if self.stateen_skip != 0 => CsrKind::Masked(!self.stateen_skip),
            0x320 if self.inhibit_skip != 0 => CsrKind::Masked(!self.inhibit_skip),
            0x300 | 0x100 | 0x200 => CsrKind::Status,
            0x747 => CsrKind::Unspecified(3 << 32),
            0x30a | 0x10a => CsrKind::Unspecified((3 << 32) | 0x30),
            0x60a => CsrKind::Unspecified((7 << 61) | (1 << 59) | (3 << 32) | 0x30),
            _ => CsrKind::Plain,
        }
    }

    /// `vs`: the handler runs with V = 1, so the interrupt went to VS. A VS
    /// interrupt arrives as its VS cause (1, 5, 9), one below its mip bit.
    fn check_irq(&mut self, t: u32, cause: u64, epc: u64, vs: bool) -> std::result::Result<(), String> {
        let h = self.spike.0;
        let bit = if vs { cause + 1 } else { cause };
        let mut s = HcStep::default();
        unsafe { hc_step(h, t, bit as i32, &HcDutMem::default(), &mut s, 0) };
        if s.trap == 0 || s.cause >> 63 == 0 || s.cause & 0x3f != cause || s.pc != epc || vs != (s.trap == 3) {
            return Err(format!(
                "spike mismatch at interrupt: hart {t} dut cause={cause} epc={epc:#x} vs={vs}, \
                 ref level={} cause={:#x} pc={:#x}",
                s.trap, s.cause, s.pc
            ));
        }
        Ok(())
    }

    fn step_flags(&self, r: &Rec) -> u64 {
        let insn = r.get(field!("insn"));
        let mut f = 0;
        if r.on(field!("is_rvc")) {
            return 0;
        }
        // An SC may fail for reasons outside the architecture; one the DUT
        // failed must fail in spike too.
        if !r.on(field!("trap")) && insn & 0x7f == 0x2f && (insn >> 27) == 3 && r.get(field!("rd_wdata")) != 0 {
            f |= STEP_SC_FAIL;
        }
        let op = insn & 0x7f;
        if (op == 0x07 || op == 0x27) && matches!((insn >> 12) & 7, 0 | 5 | 6 | 7) {
            let wholereg = (insn >> 26) & 3 == 0 && (insn >> 20) & 0x1f == 8;
            let legal = if wholereg { self.vec_wholereg_misaligned } else { self.vec_misaligned };
            if !legal {
                f |= STEP_NO_MISALIGNED;
            }
        }
        f
    }

    fn dram<'a>(&self) -> &'a mut [u8] {
        unsafe { std::slice::from_raw_parts_mut(hc_region_mem(self.spike.0, 0), self.dram_size as usize) }
    }

    /// The bytes the DUT read in a scalar access that another hart may have
    /// raced, relative to mem_paddr: a load or LR (its read data), an AMO
    /// (the old value in rd, or recovered from the store for add and xor).
    fn dut_read(&self, r: &Rec) -> (Vec<(u64, u8)>, Option<AmoFree>) {
        let mut v = Vec::new();
        if r.on(field!("mem_io")) {
            return (v, None);
        }
        let rd_kind = r.get(field!("rd_kind"));
        let rd = r.get(field!("rd_addr"));
        let rd_known = rd_kind == 2 || (rd_kind == 1 && rd != 0);
        let rmask = r.get(field!("mem_rmask"));
        if rmask != 0 {
            // A load to x0 reports no read data.
            if rd_known {
                for i in 0..16u64 {
                    if rmask >> i & 1 != 0 {
                        let w = if i < 8 { r.get(field!("mem_rdata")) } else { r.get(field!("mem_rdata_hi")) };
                        v.push((i, (w >> (8 * (i & 7))) as u8));
                    }
                }
            }
            return (v, None);
        }
        let insn = r.get(field!("insn"));
        let funct5 = insn >> 27;
        if r.on(field!("is_rvc")) || insn & 0x7f != 0x2f || funct5 == 2 || funct5 == 3 {
            return (v, None);
        }
        let bytes = match (insn >> 12) & 7 {
            0 => 1,
            1 => 2,
            2 => 4,
            3 => 8,
            4 => 16,
            _ => return (v, None),
        };
        let (lo, hi) = if rd_known {
            (r.get(field!("rd_wdata")), r.get(field!("rd2_wdata")))
        } else {
            let (w, rs2) = (r.get(field!("mem_wdata")), r.get(field!("rs2_rdata")));
            match funct5 {
                0x00 => (w.wrapping_sub(rs2), 0),
                0x04 => (w ^ rs2, 0),
                0x08 | 0x0c | 0x10 | 0x14 | 0x18 | 0x1c => {
                    return (v, Some(AmoFree { funct5, bytes, rs2 }));
                }
                _ => return (v, None),
            }
        };
        for i in 0..bytes {
            let w = if i < 8 { lo } else { hi };
            v.push((i, (w >> (8 * (i & 7))) as u8));
        }
        (v, None)
    }

    fn check(&mut self, t: u32, r: &Rec) -> std::result::Result<(), String> {
        let h = self.spike.0;
        let mut errs = Vec::new();
        let pc = r.get(field!("pc"));
        let insn = r.get(field!("insn"));
        let is_rvc = r.on(field!("is_rvc"));
        let dtrap = r.on(field!("trap"));
        let csr_addr = r.get(field!("csr_addr"));
        let csr_op = !dtrap && !is_rvc && is_csr_op(insn);
        let kind = if csr_op { self.csr_kind(insn >> 20) } else { CsrKind::Plain };
        // Source values and the CSR read, against spike's state before the
        // step.
        let srcs = [
            (field!("rs1_kind"), field!("rs1_addr"), field!("rs1_rdata")),
            (field!("rs2_kind"), field!("rs2_addr"), field!("rs2_rdata")),
            (field!("rs3_kind"), field!("rs3_addr"), field!("rs3_rdata")),
        ];
        // amocas.q writes rd+1 in place, so a source that is rd+1 reads the
        // written value back at retire.
        let pair_hi = if r.on(field!("rd2_valid")) { Some(r.get(field!("rd_addr")) + 1) } else { None };
        for (i, &(k, a, d)) in srcs.iter().enumerate() {
            let (sk, addr, v) = (r.get(k), r.get(a), r.get(d));
            let want = match sk {
                1 if pair_hi == Some(addr) => r.get(field!("rd2_wdata")),
                1 => unsafe { hc_get_xpr(h, t, addr as u32) },
                2 => unsafe { hc_get_fpr(h, t, addr as u32) },
                _ => {
                    if addr != 0 || v != 0 {
                        errs.push(format!("rs{} unused but addr={addr} value={v:#x}", i + 1));
                    }
                    continue;
                }
            };
            if v != want {
                let rf = if sk == 2 { "f" } else { "x" };
                errs.push(format!("rs{} {rf}{addr} dut={v:#x} ref={want:#x}", i + 1));
            }
            self.src_checked += 1;
        }
        if r.on(field!("csr_read")) {
            let got = r.get(field!("csr_rdata"));
            let want = unsafe { hc_get_csr(h, t, csr_addr as u32) };
            let bad = match self.csr_kind(csr_addr) {
                CsrKind::DutValued => false,
                CsrKind::Configured(v) => got != v,
                CsrKind::Masked(m) => (got ^ want) & m != 0,
                CsrKind::Unspecified(m) => {
                    if (got ^ want) & m != 0 {
                        unsafe { hc_set_csr(h, t, csr_addr as u32, (want & !m) | (got & m)) };
                    }
                    (got ^ want) & !m != 0
                }
                CsrKind::Status => {
                    let ok = dirty_only(got, want);
                    if ok && got != want {
                        unsafe { hc_set_csr(h, t, csr_addr as u32, (want & !STATUS_DIRTY) | (got & STATUS_DIRTY)) };
                    }
                    !ok
                }
                CsrKind::Plain | CsrKind::DutLegal => got != want,
            };
            if bad {
                errs.push(format!("csr {csr_addr:#x} read dut={got:#x} ref={want:#x}"));
            }
            self.csr_checked += 1;
        }
        let hs = &mut self.harts[t as usize];
        let intr = r.on(field!("intr"));
        if intr != hs.intr_next {
            errs.push(format!("intr dut={intr} expected={}", hs.intr_next));
        }
        hs.intr_next = dtrap;

        let paddr = r.get(field!("mem_paddr"));
        let mut patched = Vec::new();
        let mut amo_free = None;
        if self.harts.len() > 1 && !dtrap && !r.on(field!("vec_v")) {
            let (bytes, free) = self.dut_read(r);
            amo_free = free;
            let base = platform::DRAM_BASE;
            let mem = self.dram();
            let mut differs = false;
            for (rel, b) in bytes {
                let a = paddr + rel;
                if (a ^ paddr) >> 12 != 0 || a < base || a - base >= self.dram_size {
                    continue;
                }
                let off = (a - base) as usize;
                differs |= mem[off] != b;
                patched.push(Patched { off, saved: mem[off], rel });
                mem[off] = b;
            }
            self.reads_forced += differs as u64;
        }

        let dm = HcDutMem {
            paddr,
            rmask: r.get(field!("mem_rmask")),
            rdata: r.get(field!("mem_rdata")),
            rdata_hi: r.get(field!("mem_rdata_hi")),
        };
        let mut s = HcStep::default();
        unsafe { hc_step(h, t, -1, &dm, &mut s, self.step_flags(r)) };
        if s.suppress_fail != 0 {
            errs.push("a pending interrupt could not be held off for this step".into());
        }
        if pc != s.pc {
            errs.push(format!("pc dut={pc:#x} ref={:#x}", s.pc));
        }
        if r.get(field!("priv")) != s.priv_ {
            errs.push(format!("priv dut={} ref={}", r.get(field!("priv")), s.priv_));
        }
        if r.on(field!("virt")) != (s.virt != 0) {
            errs.push(format!("virt dut={} ref={}", r.get(field!("virt")), s.virt));
        }
        if dtrap != (s.trap != 0) {
            errs.push(format!("trap dut={dtrap} ref={} (ref cause={:#x} insn={:#x})", s.trap, s.cause, s.insn));
        } else if dtrap {
            // A double trap delivers cause 16 to M with the exception's cause
            // in mtval2; the record keeps the exception's cause.
            let want = if s.trap == 1 && s.cause == 16 { s.tval2 & 0x3f } else { s.cause & 0x3f };
            let cause = r.get(field!("cause"));
            if cause != want || s.cause >> 63 != 0 {
                errs.push(format!("cause dut={cause:#x} ref={:#x} (level {})", s.cause, s.trap));
            }
            let tval = r.get(field!("tval"));
            if tval != s.tval {
                errs.push(format!("tval dut={tval:#x} ref={:#x}", s.tval));
            }
            let (tval2, tinst) = (r.get(field!("tval2")), r.get(field!("tinst")));
            if tval2 != s.tval2 || tinst != s.tinst {
                errs.push(format!(
                    "tval2/tinst dut={tval2:#x}/{tinst:#x} ref={:#x}/{:#x} (level {})",
                    s.tval2, s.tinst, s.trap
                ));
            }
        }
        if !dtrap {
            let rvc = s.insn & 3 != 3;
            if is_rvc != rvc {
                errs.push(format!("is_rvc dut={is_rvc} ref insn={:#x}", s.insn));
            } else if !rvc && insn != s.insn & 0xffff_ffff {
                errs.push(format!("insn dut={insn:#010x} ref={:#010x}", s.insn));
            }
            let next_pc = r.get(field!("next_pc"));
            if next_pc != s.next_pc {
                errs.push(format!("next_pc dut={next_pc:#x} ref={:#x}", s.next_pc));
            }
        }
        let rd_kind = r.get(field!("rd_kind"));
        let rd = r.get(field!("rd_addr")) as u32;
        let rd_wdata = r.get(field!("rd_wdata"));
        let (mut want_x, want_f) = match rd_kind {
            1 if rd != 0 => (1u64 << rd, 0),
            2 => (0, 1u64 << rd),
            _ => (0, 0),
        };
        // The odd register of an amocas.q pair.
        if r.on(field!("rd2_valid")) && want_x != 0 && rd < 31 {
            want_x |= 1u64 << (rd + 1);
            let v = unsafe { hc_get_xpr(h, t, rd + 1) };
            let d = r.get(field!("rd2_wdata"));
            if v != d {
                errs.push(format!("x{} dut={d:#x} ref={v:#x}", rd + 1));
            }
        }
        if s.xpr_written & !want_x != 0 {
            errs.push(format!("ref wrote x regs {:#x}, dut rd_kind={rd_kind} rd={rd}", s.xpr_written));
        }
        if want_x != 0 {
            let v = unsafe { hc_get_xpr(h, t, rd) };
            let m = match kind {
                CsrKind::DutValued => 0,
                CsrKind::Configured(c) => {
                    if rd_wdata != c {
                        errs.push(format!("x{rd} dut={rd_wdata:#x} configured={c:#x}"));
                    }
                    0
                }
                CsrKind::Masked(m) => m,
                CsrKind::Plain | CsrKind::DutLegal | CsrKind::Unspecified(_) | CsrKind::Status => !0,
            };
            if (v ^ rd_wdata) & m != 0 || s.xpr_written & (1u64 << rd) == 0 {
                errs.push(format!("x{rd} dut={rd_wdata:#x} ref={v:#x} (ref wrote {:#x})", s.xpr_written));
            }
            if m != !0 {
                unsafe { hc_set_xpr(h, t, rd, rd_wdata) };
            }
        }
        if s.fpr_written & !want_f != 0 {
            errs.push(format!("ref wrote f regs {:#x}, dut rd_kind={rd_kind} rd={rd}", s.fpr_written));
        }
        if want_f != 0 {
            let v = unsafe { hc_get_fpr(h, t, rd) };
            if v != rd_wdata {
                errs.push(format!("f{rd} dut={rd_wdata:#x} ref={v:#x}"));
            }
        }
        // A CSR write sets fflags without raising them.
        if !dtrap && !csr_op {
            let fl = r.get(field!("fflags"));
            if (fl | s.fflags_before) != s.fflags_after {
                errs.push(format!("fflags dut raised {fl:#x}, ref {:#x} -> {:#x}", s.fflags_before, s.fflags_after));
            }
        }
        if r.on(field!("csr_valid")) && !dtrap {
            let got = r.get(field!("csr_new"));
            let want = unsafe { hc_get_csr(h, t, csr_addr as u32) };
            // A reserved xtvec MODE: the legalization of stvec's and vstvec's
            // is left to the implementation, and spike cannot be set to the
            // configured one for mtvec (retain).
            let reserved_tvec = matches!(csr_addr, 0x305 | 0x105 | 0x205) && r.get(field!("csr_wdata")) & 2 != 0;
            // A vsatp write of an unsupported MODE with V = 0: the configuration
            // ignores it, spike keeps the fields WARL.
            let wmode = r.get(field!("csr_wdata")) >> 60;
            let ignored_vsatp = csr_addr == 0x280 && self.vsatp_ignore && !r.on(field!("virt")) && wmode != 0 && wmode != 8;
            let kind = if reserved_tvec || ignored_vsatp { CsrKind::DutLegal } else { self.csr_kind(csr_addr) };
            let bad = match kind {
                CsrKind::DutValued | CsrKind::Configured(_) => false,
                CsrKind::DutLegal => {
                    unsafe { hc_set_csr(h, t, csr_addr as u32, got) };
                    false
                }
                CsrKind::Masked(m) => (got ^ want) & m != 0,
                CsrKind::Unspecified(m) => {
                    if (got ^ want) & m != 0 {
                        unsafe { hc_set_csr(h, t, csr_addr as u32, (want & !m) | (got & m)) };
                    }
                    (got ^ want) & !m != 0
                }
                CsrKind::Status => !dirty_only(got, want),
                CsrKind::Plain => got != want,
            };
            if bad {
                errs.push(format!("csr {csr_addr:#x} after write dut={got:#x} ref={want:#x}"));
            }
            self.csr_checked += 1;
        }
        self.check_vec(t, r, &s, &mut errs);
        self.check_mem(r, &s, amo_free, &mut errs);
        // Bytes the step did not store go back to the latest store in retire
        // order.
        let wmask = r.get(field!("mem_wmask"));
        let mem = self.dram();
        for p in &patched {
            if wmask >> p.rel & 1 == 0 {
                mem[p.off] = p.saved;
            }
        }
        if errs.is_empty() {
            Ok(())
        } else {
            let who = if self.harts.len() > 1 { format!("hart {t} ") } else { String::new() };
            Err(format!(
                "spike mismatch at {who}order {} pc={pc:#x} insn={insn:#010x}: {}",
                r.get(field!("order")),
                errs.join("; ")
            ))
        }
    }

    /// The registers the DUT's VRF writes reached, against the ones spike
    /// changed, and their final values through the write-order-free fold.
    fn check_vec(&mut self, t: u32, r: &Rec, s: &HcStep, errs: &mut Vec<String>) {
        let h = self.spike.0;
        if !r.on(field!("vec_v")) {
            if s.vr_written != 0 && s.trap == 0 {
                errs.push(format!("ref wrote v regs {:#x}, dut has no vector record", s.vr_written));
            }
            return;
        }
        if s.trap != 0 {
            return;
        }
        let wmask = r.get(field!("vrf_wmask"));
        let vlenb = (unsafe { hc_vlenb(h) } as usize).min(VLEN_MAX / 8);
        let mut x = 0u64;
        for v in 0..32u32 {
            if (wmask >> v) & 1 != 0 {
                let data = unsafe { std::slice::from_raw_parts(hc_get_vreg(h, t, v), vlenb) };
                x ^= vrf_hash_step(0, v as u64, data);
            }
        }
        let xhash = r.get(field!("vrf_xhash"));
        if s.vr_written & !wmask != 0 || xhash != x {
            errs.push(format!(
                "vrf dut regs={wmask:#x} xhash={xhash:#x}, ref regs={:#x} xhash={x:#x}",
                s.vr_written
            ));
        }
        let names = ["vtype", "vl", "vstart"];
        let idx = [field!("vtype"), field!("vl"), field!("vstart")];
        for i in 0..3 {
            let got = r.get(idx[i]);
            let want = unsafe { hc_get_vcsr(h, t, i as u32) };
            if got != want {
                errs.push(format!("{} dut={got:#x} ref={want:#x}", names[i]));
            }
        }
        self.vec_checked += 1;
    }

    fn check_mem(&mut self, r: &Rec, s: &HcStep, amo_free: Option<AmoFree>, errs: &mut Vec<String>) {
        if s.dev_read_miss != 0 {
            errs.push(format!("ref read device {:#x} that the dut did not read", s.dev_read_addr));
        }
        if r.on(field!("vec_v")) || r.on(field!("trap")) {
            return;
        }
        let paddr = r.get(field!("mem_paddr"));
        let wmask = r.get(field!("mem_wmask")) & 0xffff;
        let base = platform::DRAM_BASE;
        let in_dram = |a: u64| a >= base && a - base < self.dram_size;
        if wmask != 0 && !in_dram(paddr) {
            let lo = wmask.trailing_zeros() as u64;
            let len = 64 - (wmask >> lo).leading_zeros() as u64;
            let data = r.get(field!("mem_wdata")) >> (8 * lo);
            let data = if len < 8 { data & ((1u64 << (8 * len)) - 1) } else { data };
            if s.dev_store_n != 1 || s.dev_store_addr != paddr + lo || s.dev_store_len != len || s.dev_store_data != data
            {
                errs.push(format!(
                    "device store dut {:#x}/{len}={data:#x}, ref {} stores, first {:#x}/{}={:#x}",
                    paddr + lo,
                    s.dev_store_n,
                    s.dev_store_addr,
                    s.dev_store_len,
                    s.dev_store_data
                ));
            }
            self.dev_checked += 1;
            return;
        }
        if s.dev_store_n != 0 {
            errs.push(format!("ref stored to device {:#x}, dut did not", s.dev_store_addr));
            return;
        }
        if wmask == 0 {
            return;
        }
        let mem = self.dram();
        // An AMO to x0 whose old value is unknown: spike's store used the old
        // value of its own memory order; the DUT's must be one the operation
        // can produce, and then replaces it.
        if let Some(a) = amo_free.filter(|a| a.bytes <= 8 && in_dram(paddr) && paddr & (a.bytes - 1) == 0) {
            let off = (paddr - base) as usize;
            let w = r.get(field!("mem_wdata"));
            let got = (0..a.bytes as usize).fold(0u64, |v, i| v | (mem[off + i] as u64) << (8 * i));
            let sh = 64 - 8 * a.bytes as u32;
            if (got ^ w) << sh != 0 && a.reachable(w) {
                for i in 0..a.bytes as usize {
                    mem[off + i] = (w >> (8 * i)) as u8;
                }
                self.amo_forced += 1;
            }
        }
        // Bytes past a page boundary sit at another PA.
        for i in 0..16u64 {
            let a = paddr + i;
            if wmask >> i & 1 == 0 || (a ^ paddr) >> 12 != 0 || !in_dram(a) {
                continue;
            }
            let got = mem[(a - base) as usize];
            let w = if i < 8 { r.get(field!("mem_wdata")) } else { r.get(field!("mem_wdata_hi")) };
            let want = (w >> (8 * (i & 7))) as u8;
            if got != want {
                errs.push(format!("store byte {a:#x} dut={want:#04x} ref={got:#04x}"));
                break;
            }
        }
        let tohost = self.tohost_pa;
        if tohost != 0 && paddr <= tohost && tohost < paddr + 16 && wmask >> (tohost - paddr) & 0xff != 0 {
            self.at_tohost = true;
        }
    }

    /// One cycle of hart `t`: the interrupt it took, then its records in
    /// order. False once the comparison has ended.
    fn hart_cycle(&mut self, ctx: &mut SimCtx, t: u32, irq: Option<(u64, u64, u64)>, recs: &[Rec]) -> bool {
        let ti = t as usize;
        if let Some(ev) = irq {
            // A second interrupt before the first handler retired anything
            // preempted it from a higher level, so the first went to M or HS.
            if let Some((cause, epc, order)) = self.harts[ti].irq_pending.take() {
                if let Err(msg) = self.check_irq(t, cause, epc, false) {
                    ctx.fail(format!("{msg} (before order {order})"));
                    self.done = true;
                    return false;
                }
            }
            self.harts[ti].irq_pending = Some(ev);
            self.irqs += 1;
            self.harts[ti].intr_next = true;
        }
        for r in recs {
            if let Some((cause, epc, order)) = self.harts[ti].irq_pending.take() {
                if let Err(msg) = self.check_irq(t, cause, epc, r.on(field!("virt"))) {
                    ctx.fail(format!("{msg} (before order {order})"));
                    self.done = true;
                    return false;
                }
            }
            if let Err(msg) = self.check(t, r) {
                ctx.fail(msg);
                self.done = true;
                return false;
            }
            self.compared += 1;
            if self.at_tohost {
                self.done = true;
                return false;
            }
        }
        true
    }

    fn finish(&mut self, ctx: &mut SimCtx) {
        let smp = if self.harts.len() > 1 {
            format!(
                "; {} reads and {} AMO stores taken from the DUT",
                self.reads_forced, self.amo_forced
            )
        } else {
            String::new()
        };
        ctx.log(&format!(
            "spike cosim: {} records and {} interrupts compared ({} source, {} CSR, {} vector, {} device values){}{}",
            self.compared,
            self.irqs,
            self.src_checked,
            self.csr_checked,
            self.vec_checked,
            self.dev_checked,
            smp,
            if self.at_tohost { ", stopped at the tohost store" } else { "" }
        ));
        if self.compared == 0 {
            ctx.fail("spike cosim: no records compared");
        }
    }
}

/// IrqEvent at bit `base` of `w`, if valid: (cause, epc, order).
fn irq_event(w: &[u64], base: u32) -> Option<(u64, u64, u64)> {
    if bits(w, base + IRQ_W - 1, 1) == 0 {
        return None;
    }
    Some((bits(w, base + 128, 6), bits(w, base + 64, 64), bits(w, base, 64)))
}

/// Checks every retire record of a single-hart heliodor against spike.
#[derive(Component)]
#[component(kind = clocked, requires(file))]
struct SpikeCosim {
    clk: ClockPort,
    rec0: InputPort,
    rec1: InputPort,
    rec2: InputPort,
    rec3: InputPort,
    /// retire_pkg::IrqEvent.
    irq: InputPort,
    /// `$readmemh` image (32-bit words) loaded at PA 0x8000_0000.
    #[param(name = "HEX_FILE")]
    hex_file: Option<String>,
    /// Firmware ROM image at PA 0 (MAP = "boot").
    #[param(name = "ROM_HEX")]
    rom_hex: Option<String>,
    /// Harness memory map: "arch" (default) or "boot".
    #[param(name = "MAP")]
    map: Option<String>,
    /// UDB architecture configuration spike is built from.
    #[param(name = "CONFIG")]
    config: Option<String>,
    /// Trigger count when the core differs from the configuration's (W4).
    #[param(name = "TRIGGERS")]
    triggers: Option<u64>,
    /// PA of tohost: the comparison ends after the first store to it.
    #[param(name = "TOHOST_PA")]
    tohost_pa: Option<u64>,
    #[state]
    eng: Engine,
    buf: Vec<u64>,
}

#[component_impl]
impl SpikeCosim {
    fn on_init(&mut self, ctx: &mut SimCtx) -> Result<()> {
        let p = Params {
            hex_file: self.hex_file.clone(),
            rom_hex: self.rom_hex.clone(),
            map: self.map.clone(),
            config: self.config.clone(),
            triggers: self.triggers,
            tohost_pa: self.tohost_pa,
        };
        self.eng.init(ctx, &p, 1)?;
        let w = self.rec0.width();
        if w != rec_width() {
            bail!("rec0 is {w} bits, RetireRec layout here is {}", rec_width());
        }
        self.buf = vec![0; w.div_ceil(64) as usize];
        Ok(())
    }

    fn on_clock(&mut self, ctx: &mut SimCtx) -> Result<()> {
        let _ = ctx.fired(self.clk);
        if self.eng.done {
            return Ok(());
        }
        let mut recs = Vec::new();
        for p in [self.rec0, self.rec1, self.rec2, self.rec3] {
            ctx.read_words(p, &mut self.buf);
            if let Some(r) = self.eng.decode(&self.buf, 0) {
                recs.push(r);
            }
        }
        recs.sort_by_key(|r| r.get(field!("order")));
        let mut iw = [0u64; 3];
        ctx.read_words(self.irq, &mut iw);
        self.eng.hart_cycle(ctx, 0, irq_event(&iw, 0), &recs);
        Ok(())
    }

    fn on_finish(&mut self, ctx: &mut SimCtx) -> Result<()> {
        self.eng.finish(ctx);
        Ok(())
    }
}

/// Checks every retire record of a multi-hart heliodor against spike harts
/// sharing one memory.
#[derive(Component)]
#[component(kind = clocked, requires(file))]
struct SpikeCosimSmp {
    clk: ClockPort,
    /// Every hart's retire lanes, concatenated: lane l of hart t is element
    /// t * lanes + l, element 0 in the low bits.
    rec: InputPort,
    /// Every hart's retire_pkg::IrqEvent, concatenated, hart 0 in the low
    /// bits. Its width sets the hart count.
    irq: InputPort,
    /// `$readmemh` image (32-bit words) loaded at PA 0x8000_0000.
    #[param(name = "HEX_FILE")]
    hex_file: Option<String>,
    /// Firmware ROM image at PA 0 (MAP = "boot").
    #[param(name = "ROM_HEX")]
    rom_hex: Option<String>,
    /// Harness memory map: "arch" (default) or "boot".
    #[param(name = "MAP")]
    map: Option<String>,
    /// UDB architecture configuration spike is built from.
    #[param(name = "CONFIG")]
    config: Option<String>,
    /// Trigger count when the core differs from the configuration's (W4).
    #[param(name = "TRIGGERS")]
    triggers: Option<u64>,
    /// PA of tohost: the comparison ends after the first store to it by any
    /// hart.
    #[param(name = "TOHOST_PA")]
    tohost_pa: Option<u64>,
    #[state]
    eng: Engine,
    lanes: u32,
    buf: Vec<u64>,
    ibuf: Vec<u64>,
}

#[component_impl]
impl SpikeCosimSmp {
    fn on_init(&mut self, ctx: &mut SimCtx) -> Result<()> {
        let iw = self.irq.width();
        let rw = rec_width();
        if iw % IRQ_W != 0 || iw == 0 {
            bail!("irq is {iw} bits, not a multiple of the {IRQ_W}-bit IrqEvent");
        }
        let harts = iw / IRQ_W;
        let w = self.rec.width();
        if w % (harts * rw) != 0 || w == 0 {
            bail!("rec is {w} bits, not {harts} harts of {rw}-bit RetireRec lanes");
        }
        self.lanes = w / (harts * rw);
        let p = Params {
            hex_file: self.hex_file.clone(),
            rom_hex: self.rom_hex.clone(),
            map: self.map.clone(),
            config: self.config.clone(),
            triggers: self.triggers,
            tohost_pa: self.tohost_pa,
        };
        self.eng.init(ctx, &p, harts as usize)?;
        self.buf = vec![0; w.div_ceil(64) as usize];
        self.ibuf = vec![0; iw.div_ceil(64) as usize];
        Ok(())
    }

    fn on_clock(&mut self, ctx: &mut SimCtx) -> Result<()> {
        let _ = ctx.fired(self.clk);
        if self.eng.done {
            return Ok(());
        }
        ctx.read_words(self.rec, &mut self.buf);
        ctx.read_words(self.irq, &mut self.ibuf);
        let rw = rec_width();
        for t in 0..self.eng.harts.len() as u32 {
            let mut recs = Vec::new();
            for l in 0..self.lanes {
                if let Some(r) = self.eng.decode(&self.buf, (t * self.lanes + l) * rw) {
                    recs.push(r);
                }
            }
            recs.sort_by_key(|r| r.get(field!("order")));
            if !self.eng.hart_cycle(ctx, t, irq_event(&self.ibuf, t * IRQ_W), &recs) {
                break;
            }
        }
        Ok(())
    }

    fn on_finish(&mut self, ctx: &mut SimCtx) -> Result<()> {
        self.eng.finish(ctx);
        Ok(())
    }
}

/// The writable bits of a WARL CSR of hart 0, by writing all ones and
/// reading back; the CSR is restored.
fn probe_writable(h: *mut c_void, addr: u32) -> u64 {
    unsafe {
        let old = hc_get_csr(h, 0, addr);
        hc_set_csr(h, 0, addr, !0);
        let m = hc_get_csr(h, 0, addr);
        hc_set_csr(h, 0, addr, old);
        m
    }
}

veryl_component_export!("spike_cosim" => SpikeCosim, "spike_cosim_smp" => SpikeCosimSmp);
