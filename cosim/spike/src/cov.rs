//! Functional coverage of the compared records. When HELIODOR_COV_DIR names
//! a directory, each component instance counts packed keys and writes them
//! there as one JSON file at the end of the run; test/gates/cov_report.py
//! merges and decodes them. Without it nothing is counted.

use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Default)]
struct KeyHasher(u64);

impl Hasher for KeyHasher {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.write_u64(b as u64);
        }
    }
    fn write_u64(&mut self, k: u64) {
        self.0 = (self.0 ^ k).wrapping_mul(0x9e37_79b9_7f4a_7c15).rotate_left(29);
    }
}

// Key layouts, by tag in bits 63:60 (cov_report.py decodes the same fields).
// Mode codes are priv | virt << 2.
const TAG_INSN: u64 = 1; // insn[31:0], mode[34:32], level[36:35], cause[42:37]
const TAG_VEC: u64 = 2; // insn[31:0], vtype[40:32], vl class[42:41], vstart != 0[43], mode[46:44], trap[47]
const TAG_MEM: u64 = 3; // see mem()
const TAG_SC: u64 = 4; // width[2:0], failed[3], mode[6:4]
const TAG_TRAP: u64 = 5; // cause[5:0], source mode[8:6], level[10:9], interrupt[11]

pub const MEM_LOAD: u64 = 0;
pub const MEM_STORE: u64 = 1;
pub const MEM_FLOAD: u64 = 2;
pub const MEM_FSTORE: u64 = 3;
pub const MEM_AMO: u64 = 4;
pub const MEM_LR: u64 = 5;
pub const MEM_SC: u64 = 6;
pub const MEM_VLOAD: u64 = 7;
pub const MEM_VSTORE: u64 = 8;
pub const MEM_CBO: u64 = 9;
pub const MEM_HLV: u64 = 10;
pub const MEM_HSV: u64 = 11;

/// The memory class and log2 size of an expanded instruction.
pub fn mem_class(insn: u64) -> Option<(u64, u64)> {
    let f3 = (insn >> 12) & 7;
    let veew = |f3: u64| match f3 {
        0 => Some(0),
        5..=7 => Some(f3 - 4),
        _ => None,
    };
    match insn & 0x7f {
        0x03 => Some((MEM_LOAD, f3 & 3)),
        0x23 => Some((MEM_STORE, f3 & 3)),
        0x07 => veew(f3).map(|e| (MEM_VLOAD, e)).or(Some((MEM_FLOAD, f3))),
        0x27 => veew(f3).map(|e| (MEM_VSTORE, e)).or(Some((MEM_FSTORE, f3))),
        0x2f => Some((
            match insn >> 27 {
                2 => MEM_LR,
                3 => MEM_SC,
                _ => MEM_AMO,
            },
            f3,
        )),
        0x0f if f3 == 2 => Some((MEM_CBO, 6)),
        0x73 if f3 == 4 && insn >> 28 == 6 => {
            let f7 = insn >> 25;
            Some((if f7 & 1 != 0 { MEM_HSV } else { MEM_HLV }, (f7 >> 1) & 3))
        }
        _ => None,
    }
}

pub fn is_vector(insn: u64) -> bool {
    match insn & 0x7f {
        0x57 => true,
        0x07 | 0x27 => matches!((insn >> 12) & 7, 0 | 5..=7),
        _ => false,
    }
}

pub fn mode(prv: u64, virt: u64) -> u64 {
    (prv & 3) | (virt & 1) << 2
}

/// The vtype fields cov_report.py splits (vlmul, vsew, vta, vma, vill) and
/// the vl class: 0, below VLMAX, VLMAX, or 3 under vill.
fn vtype_key(vtype: u64, vl: u64, vlen: u64) -> u64 {
    let vill = vtype >> 63;
    let v = (vtype & 0xff) | vill << 8;
    let (sew, lmul) = ((vtype >> 3) & 7, vtype & 7);
    let class = if vill != 0 || sew > 3 || lmul == 4 {
        3
    } else {
        let per = vlen >> (3 + sew);
        let vlmax = if lmul < 4 { per << lmul } else { per >> (8 - lmul) };
        if vl == 0 {
            0
        } else if vl < vlmax {
            1
        } else {
            2
        }
    };
    v | class << 9
}

static SEQ: AtomicU64 = AtomicU64::new(0);

#[derive(Default)]
pub struct Cov {
    dir: Option<PathBuf>,
    tag: String,
    keys: HashMap<u64, u64, BuildHasherDefault<KeyHasher>>,
}

impl Cov {
    pub fn new(tag: &str) -> Self {
        let dir = std::env::var_os("HELIODOR_COV_DIR").map(PathBuf::from);
        Cov { dir, tag: tag.to_string(), keys: HashMap::default() }
    }

    pub fn on(&self) -> bool {
        self.dir.is_some()
    }

    fn add(&mut self, key: u64) {
        *self.keys.entry(key).or_default() += 1;
    }

    /// One executed or trapping instruction; `level` 0 if it did not trap.
    pub fn insn(&mut self, raw: u64, mode: u64, level: u64, cause: u64) {
        let c = if level != 0 { cause & 0x3f } else { 0 };
        self.add(TAG_INSN << 60 | (raw & 0xffff_ffff) | mode << 32 | (level & 3) << 35 | c << 37);
    }

    pub fn vec(&mut self, raw: u64, vtype: u64, vl: u64, vstart: u64, vlen: u64, mode: u64, trap: bool) {
        let k = (raw & 0xffff_ffff) | vtype_key(vtype, vl, vlen) << 32 | ((vstart != 0) as u64) << 43;
        self.add(TAG_VEC << 60 | k | mode << 44 | (trap as u64) << 47);
    }

    /// One access: class[3:0], size[6:4], misaligned[7], page crossing[8],
    /// io[9], effective mode[12:10] (7: HLV/HSV), first-stage MODE[16:13]
    /// (15: no translation), G-stage MODE[20:17] (15: V = 0), MPRV in
    /// effect[21], trap[22], cause[28:23], performed[29].
    #[allow(clippy::too_many_arguments)]
    pub fn mem(
        &mut self,
        class: u64,
        size: u64,
        span: Option<(bool, bool, bool)>,
        eff: u64,
        s1: u64,
        g: u64,
        mprv: bool,
        cause: Option<u64>,
    ) {
        let (mis, cross, io) = span.unwrap_or_default();
        let mut k = class | (size & 7) << 4 | (mis as u64) << 7 | (cross as u64) << 8 | (io as u64) << 9;
        k |= (eff & 7) << 10 | (s1 & 15) << 13 | (g & 15) << 17 | (mprv as u64) << 21;
        if let Some(c) = cause {
            k |= 1 << 22 | (c & 0x3f) << 23;
        }
        k |= (span.is_some() as u64) << 29;
        self.add(TAG_MEM << 60 | k);
    }

    pub fn sc(&mut self, width: u64, failed: bool, mode: u64) {
        self.add(TAG_SC << 60 | (width & 7) | (failed as u64) << 3 | mode << 4);
    }

    pub fn trap(&mut self, cause: u64, src: u64, level: u64, intr: bool) {
        self.add(TAG_TRAP << 60 | (cause & 0x3f) | src << 6 | (level & 3) << 9 | (intr as u64) << 11);
    }

    pub fn write(&self, harts: usize, records: u64) -> std::io::Result<()> {
        let Some(dir) = &self.dir else { return Ok(()) };
        std::fs::create_dir_all(dir)?;
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        let path = dir.join(format!("{}-{}-{n}.json", self.tag, std::process::id()));
        let mut keys: Vec<_> = self.keys.iter().collect();
        keys.sort();
        let body: Vec<String> = keys.iter().map(|(k, c)| format!("[{k},{c}]")).collect();
        let text = format!(
            "{{\"tag\":\"{}\",\"harts\":{harts},\"records\":{records},\"keys\":[{}]}}\n",
            self.tag,
            body.join(",")
        );
        std::fs::write(path, text)
    }
}
