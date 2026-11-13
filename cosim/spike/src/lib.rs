//! Online spike co-simulation of heliodor's retire records: each
//! `retire_pkg::RetireRec` steps one spike instruction and the two are
//! compared field by field.

use std::ffi::{CString, c_char, c_void};
use std::io::Read;

use veryl_component::*;

#[repr(C)]
#[derive(Default)]
struct HcStep {
    pc: u64,
    next_pc: u64,
    insn: u64,
    trap: u64,
    cause: u64,
    tval: u64,
    priv_: u64,
    xpr_changed: u64,
    fpr_changed: u64,
}

unsafe extern "C" {
    fn hc_new(isa: *const c_char, priv_: *const c_char, base: u64, size: u64, pc: u64)
        -> *mut c_void;
    fn hc_free(h: *mut c_void);
    fn hc_mem(h: *mut c_void) -> *mut u8;
    fn hc_get_xpr(h: *mut c_void, i: u32) -> u64;
    fn hc_set_xpr(h: *mut c_void, i: u32, v: u64);
    fn hc_get_fpr(h: *mut c_void, i: u32) -> u64;
    fn hc_get_csr(h: *mut c_void, addr: u32) -> u64;
    fn hc_step(h: *mut c_void, out: *mut HcStep, irq: i32);
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

#[derive(Default, Debug)]
struct Rec {
    valid: bool,
    order: u64,
    pc: u64,
    next_pc: u64,
    insn: u64,
    is_rvc: bool,
    trap: bool,
    cause: u64,
    tval: u64,
    priv_: u64,
    rd_kind: u64,
    rd_addr: u64,
    rd_wdata: u64,
    mem_paddr: u64,
    mem_wmask: u64,
    mem_wdata: u64,
    csr_valid: bool,
    csr_addr: u64,
    intr: bool,
    /// (kind, addr, value) of rs1, rs2, rs3.
    rs: [(u64, u64, u64); 3],
    csr_read: bool,
    csr_rdata: u64,
    csr_new: u64,
}

fn decode(words: &[u64]) -> Rec {
    let total = rec_width();
    let mut top = total;
    let mut r = Rec::default();
    for &(name, w) in FIELDS {
        top -= w;
        let v = bits(words, top, w);
        match name {
            "valid" => r.valid = v != 0,
            "order" => r.order = v,
            "pc" => r.pc = v,
            "next_pc" => r.next_pc = v,
            "insn" => r.insn = v,
            "is_rvc" => r.is_rvc = v != 0,
            "trap" => r.trap = v != 0,
            "cause" => r.cause = v,
            "tval" => r.tval = v,
            "priv" => r.priv_ = v,
            "rd_kind" => r.rd_kind = v,
            "rd_addr" => r.rd_addr = v,
            "rd_wdata" => r.rd_wdata = v,
            "mem_paddr" => r.mem_paddr = v,
            "mem_wmask" => r.mem_wmask = v,
            "mem_wdata" => r.mem_wdata = v,
            "csr_valid" => r.csr_valid = v != 0,
            "csr_addr" => r.csr_addr = v,
            "intr" => r.intr = v != 0,
            "rs1_kind" => r.rs[0].0 = v,
            "rs1_addr" => r.rs[0].1 = v,
            "rs1_rdata" => r.rs[0].2 = v,
            "rs2_kind" => r.rs[1].0 = v,
            "rs2_addr" => r.rs[1].1 = v,
            "rs2_rdata" => r.rs[1].2 = v,
            "rs3_kind" => r.rs[2].0 = v,
            "rs3_addr" => r.rs[2].1 = v,
            "rs3_rdata" => r.rs[2].2 = v,
            "csr_read" => r.csr_read = v != 0,
            "csr_rdata" => r.csr_rdata = v,
            "csr_new" => r.csr_new = v,
            _ => {}
        }
    }
    r
}

/// Counter CSRs whose value is timing-dependent: the DUT's read is copied
/// into spike instead of compared.
fn is_timing_csr_read(insn: u64) -> bool {
    if insn & 0x7f != 0x73 || (insn >> 12) & 7 == 0 {
        return false;
    }
    let csr = (insn >> 20) & 0xfff;
    matches!(csr, 0xc00 | 0xc01 | 0xb00) || (0xc03..=0xc1f).contains(&csr)
        || (0xb03..=0xb1f).contains(&csr)
}

/// CSRs whose value spike cannot reproduce: the counters, and the interrupt
/// pending bits (spike sees no interrupt pins).
fn is_unmodeled_csr(csr: u64) -> bool {
    matches!(csr, 0xc00..=0xc1f | 0xb00..=0xb1f | 0x344 | 0x144 | 0x644)
}

/// Bits of a CSR whose value differs between the DUT and spike by an
/// implementation choice, not compared: the FS/VS/SD reset state of mstatus
/// and sstatus (the DUT leaves FS Initial, spike Off), mideleg.SGEI
/// (read-only one on spike, zero on the DUT, which has GEILEN = 0) and
/// medeleg bit 0 (writable on the DUT, read-only zero on spike with C).
fn csr_cmp_mask(csr: u64) -> u64 {
    match csr {
        0x300 | 0x100 => !((1u64 << 63) | (3 << 13) | (3 << 9)),
        0x302 => !1u64,
        0x303 => !(1u64 << 12),
        _ => !0,
    }
}

const DRAM_BASE: u64 = 0x8000_0000;
const DEFAULT_ISA: &str = "rv64imafdcbvh_zicsr_zifencei_zicntr_zihpm_zicclsm";

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
    #[param(name = "ISA")]
    isa: Option<String>,
    #[param(name = "MEM_SIZE")]
    mem_size: Option<u64>,
    /// PA of tohost; the record count at its first store is logged.
    #[param(name = "TOHOST_PA")]
    tohost_pa: Option<u64>,
    #[state]
    spike: Spike,
    compared: u64,
    at_tohost: Option<u64>,
    irqs: u64,
    /// Source and CSR values compared.
    src_checked: u64,
    csr_checked: u64,
    /// The next record is the first of a trap handler.
    intr_next: bool,
    done: bool,
    buf: Vec<u64>,
}

impl SpikeCosim {
    fn load_hex(&mut self, ctx: &mut SimCtx, path: &str, size: u64) -> Result<()> {
        let mut text = String::new();
        ctx.open(path)?.read_to_string(&mut text)?;
        let mem = unsafe { std::slice::from_raw_parts_mut(hc_mem(self.spike.0), size as usize) };
        let mut idx: u64 = 0;
        for tok in text.split_whitespace() {
            if let Some(a) = tok.strip_prefix('@') {
                idx = u64::from_str_radix(a, 16)?;
                continue;
            }
            let w = u32::from_str_radix(tok, 16)?;
            let off = (idx * 4) as usize;
            if off + 4 > mem.len() {
                bail!("{path}: image exceeds MEM_SIZE");
            }
            mem[off..off + 4].copy_from_slice(&w.to_le_bytes());
            idx += 1;
        }
        Ok(())
    }

    fn check(&mut self, r: &Rec) -> std::result::Result<(), String> {
        let h = self.spike.0;
        let mut errs = Vec::new();
        // Source values and the CSR read, against spike's state before the
        // step.
        for (i, &(kind, addr, v)) in r.rs.iter().enumerate() {
            let want = match kind {
                1 => unsafe { hc_get_xpr(h, addr as u32) },
                2 => unsafe { hc_get_fpr(h, addr as u32) },
                _ => {
                    if addr != 0 || v != 0 {
                        errs.push(format!("rs{} unused but addr={addr} value={v:#x}", i + 1));
                    }
                    continue;
                }
            };
            if v != want {
                let rf = if kind == 2 { "f" } else { "x" };
                errs.push(format!("rs{} {rf}{addr} dut={v:#x} ref={want:#x}", i + 1));
            }
            self.src_checked += 1;
        }
        if r.csr_read && !is_unmodeled_csr(r.csr_addr) {
            let want = unsafe { hc_get_csr(h, r.csr_addr as u32) };
            if (r.csr_rdata ^ want) & csr_cmp_mask(r.csr_addr) != 0 {
                errs.push(format!("csr {:#x} read dut={:#x} ref={want:#x}", r.csr_addr, r.csr_rdata));
            }
            self.csr_checked += 1;
        }
        if r.intr != self.intr_next {
            errs.push(format!("intr dut={} expected={}", r.intr, self.intr_next));
        }
        self.intr_next = r.trap;
        let mut s = HcStep::default();
        unsafe { hc_step(h, &mut s, 0) };
        if r.pc != s.pc {
            errs.push(format!("pc dut={:#x} ref={:#x}", r.pc, s.pc));
        }
        if r.priv_ != s.priv_ {
            errs.push(format!("priv dut={} ref={}", r.priv_, s.priv_));
        }
        if r.trap != (s.trap != 0) {
            errs.push(format!(
                "trap dut={} ref={} (ref cause={:#x} insn={:#x})",
                r.trap, s.trap, s.cause, s.insn
            ));
        } else if r.trap {
            if r.cause != s.cause & 0x3f || s.cause >> 63 != 0 {
                errs.push(format!("cause dut={:#x} ref={:#x}", r.cause, s.cause));
            }
            if r.tval != s.tval {
                errs.push(format!("tval dut={:#x} ref={:#x}", r.tval, s.tval));
            }
        }
        if !r.trap {
            let rvc = s.insn & 3 != 3;
            if r.is_rvc != rvc {
                errs.push(format!("is_rvc dut={} ref insn={:#x}", r.is_rvc, s.insn));
            } else if !rvc && r.insn != s.insn & 0xffff_ffff {
                errs.push(format!("insn dut={:#010x} ref={:#010x}", r.insn, s.insn));
            }
            if r.next_pc != s.next_pc {
                errs.push(format!("next_pc dut={:#x} ref={:#x}", r.next_pc, s.next_pc));
            }
        }
        let rd = r.rd_addr as u32;
        let (want_x, want_f) = match r.rd_kind {
            1 if rd != 0 => (1u64 << rd, 0),
            2 => (0, 1u64 << rd),
            _ => (0, 0),
        };
        if want_x != 0 && !r.is_rvc && is_timing_csr_read(r.insn) {
            unsafe { hc_set_xpr(h, rd, r.rd_wdata) };
        } else {
            if s.xpr_changed & !want_x != 0 {
                errs.push(format!("ref wrote x regs {:#x}, dut rd_kind={} rd={}", s.xpr_changed, r.rd_kind, rd));
            }
            if want_x != 0 {
                let v = unsafe { hc_get_xpr(h, rd) };
                if v != r.rd_wdata {
                    errs.push(format!("x{rd} dut={:#x} ref={:#x}", r.rd_wdata, v));
                }
            }
        }
        if s.fpr_changed & !want_f != 0 {
            errs.push(format!("ref wrote f regs {:#x}, dut rd_kind={} rd={}", s.fpr_changed, r.rd_kind, rd));
        }
        if want_f != 0 {
            let v = unsafe { hc_get_fpr(h, rd) };
            if v != r.rd_wdata {
                errs.push(format!("f{rd} dut={:#x} ref={:#x}", r.rd_wdata, v));
            }
        }
        if r.csr_valid && !r.trap && !is_unmodeled_csr(r.csr_addr) {
            let want = unsafe { hc_get_csr(h, r.csr_addr as u32) };
            if (r.csr_new ^ want) & csr_cmp_mask(r.csr_addr) != 0 {
                errs.push(format!("csr {:#x} after write dut={:#x} ref={want:#x}", r.csr_addr, r.csr_new));
            }
            self.csr_checked += 1;
        }
        let size = self.mem_size.unwrap_or(4 << 20);
        if r.mem_wmask & 0xff != 0 && r.mem_paddr >= DRAM_BASE && r.mem_paddr - DRAM_BASE + 8 <= size {
            let mem = unsafe { hc_mem(h).add((r.mem_paddr - DRAM_BASE) as usize) };
            for i in 0..8 {
                if r.mem_wmask >> i & 1 != 0 {
                    let got = unsafe { *mem.add(i) };
                    let want = (r.mem_wdata >> (8 * i)) as u8;
                    if got != want {
                        errs.push(format!("store byte {:#x} dut={want:#04x} ref={got:#04x}", r.mem_paddr + i as u64));
                        break;
                    }
                }
            }
        }
        if errs.is_empty() {
            Ok(())
        } else {
            Err(format!(
                "spike mismatch at order {} pc={:#x} insn={:#010x}: {}",
                r.order, r.pc, r.insn, errs.join("; ")
            ))
        }
    }
}

#[component_impl]
impl SpikeCosim {
    fn on_init(&mut self, ctx: &mut SimCtx) -> Result<()> {
        let isa = CString::new(self.isa.clone().unwrap_or(DEFAULT_ISA.into()))?;
        let priv_ = CString::new("MSU")?;
        let size = self.mem_size.unwrap_or(4 << 20);
        let h = unsafe { hc_new(isa.as_ptr(), priv_.as_ptr(), DRAM_BASE, size, DRAM_BASE) };
        if h.is_null() {
            bail!("spike construction failed");
        }
        self.spike = Spike(h);
        let Some(path) = self.hex_file.clone() else {
            bail!("HEX_FILE is required");
        };
        self.load_hex(ctx, &path, size)?;
        let w = self.rec0.width();
        if w != rec_width() {
            bail!("rec0 is {w} bits, RetireRec layout here is {}", rec_width());
        }
        self.buf = vec![0; w.div_ceil(64) as usize];
        Ok(())
    }

    fn on_clock(&mut self, ctx: &mut SimCtx) -> Result<()> {
        let _ = ctx.fired(self.clk);
        if self.done {
            return Ok(());
        }
        let mut recs = Vec::new();
        for p in [self.rec0, self.rec1, self.rec2, self.rec3] {
            ctx.read_words(p, &mut self.buf);
            let r = decode(&self.buf);
            if r.valid {
                recs.push(r);
            }
        }
        recs.sort_by_key(|r| r.order);
        let mut iw = [0u64; 3];
        ctx.read_words(self.irq, &mut iw);
        // IrqEvent {valid, cause<6>, epc<64>, order<64>}, valid on top.
        if bits(&iw, 134, 1) != 0 {
            let cause = bits(&iw, 128, 6);
            let epc = bits(&iw, 64, 64);
            let order = bits(&iw, 0, 64);
            let mut s = HcStep::default();
            unsafe { hc_step(self.spike.0, &mut s, 1) };
            if s.trap == 0 || s.cause >> 63 == 0 || s.cause & 0x3f != cause || s.pc != epc {
                ctx.fail(format!(
                    "spike mismatch at interrupt before order {order}: dut cause={cause} epc={epc:#x}, \
                     ref trap={} cause={:#x} pc={:#x}",
                    s.trap, s.cause, s.pc
                ));
                self.done = true;
                return Ok(());
            }
            self.irqs += 1;
            self.intr_next = true;
        }
        for r in &recs {
            if let Err(msg) = self.check(r) {
                ctx.fail(msg);
                self.done = true;
                return Ok(());
            }
            self.compared += 1;
            if self.at_tohost.is_none()
                && r.mem_wmask != 0
                && r.mem_paddr == self.tohost_pa.unwrap_or(0x8000_1000)
            {
                self.at_tohost = Some(self.compared);
            }
        }
        Ok(())
    }

    fn on_finish(&mut self, ctx: &mut SimCtx) -> Result<()> {
        ctx.log(&format!(
            "spike cosim: {} records and {} interrupts compared ({} source and {} CSR values), \
             {} records up to the tohost store",
            self.compared,
            self.irqs,
            self.src_checked,
            self.csr_checked,
            self.at_tohost.map_or("none".into(), |n| n.to_string())
        ));
        if self.compared == 0 {
            ctx.fail("spike cosim: no records compared");
        }
        Ok(())
    }
}

veryl_component_export!("spike_cosim" => SpikeCosim);
