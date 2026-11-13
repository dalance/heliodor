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
    fn hc_step(h: *mut c_void, out: *mut HcStep);
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

const DRAM_BASE: u64 = 0x8000_0000;

/// Checks every retire record of a single-hart heliodor against spike.
#[derive(Component)]
#[component(kind = clocked, requires(file))]
struct SpikeCosim {
    clk: ClockPort,
    rec0: InputPort,
    rec1: InputPort,
    rec2: InputPort,
    rec3: InputPort,
    /// `$readmemh` image (32-bit words) loaded at PA 0x8000_0000.
    #[param(name = "HEX_FILE")]
    hex_file: Option<String>,
    #[param(name = "ISA")]
    isa: Option<String>,
    #[param(name = "MEM_SIZE")]
    mem_size: Option<u64>,
    #[state]
    spike: Spike,
    compared: u64,
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
        let mut s = HcStep::default();
        unsafe { hc_step(h, &mut s) };
        let mut errs = Vec::new();
        if r.pc != s.pc {
            errs.push(format!("pc dut={:#x} ref={:#x}", r.pc, s.pc));
        }
        if r.priv_ != s.priv_ {
            errs.push(format!("priv dut={} ref={}", r.priv_, s.priv_));
        }
        if r.trap != (s.trap != 0) {
            errs.push(format!("trap dut={} ref={} (ref cause={:#x})", r.trap, s.trap, s.cause));
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
        let isa = CString::new(self.isa.clone().unwrap_or("rv64imafdc_zicsr_zifencei".into()))?;
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
        for r in &recs {
            if let Err(msg) = self.check(r) {
                ctx.fail(msg);
                self.done = true;
                return Ok(());
            }
            self.compared += 1;
        }
        Ok(())
    }

    fn on_finish(&mut self, ctx: &mut SimCtx) -> Result<()> {
        ctx.log(&format!("spike cosim: {} records compared", self.compared));
        if self.compared == 0 {
            ctx.fail("spike cosim: no records compared");
        }
        Ok(())
    }
}

veryl_component_export!("spike_cosim" => SpikeCosim);
