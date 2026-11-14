//! The spike configuration, derived from the heliodor architecture
//! configuration that the ACT4 flow also checks the DUT against
//! (test/act/config/heliodor/heliodor.yaml), plus the harness memory maps.

use std::collections::HashMap;

use veryl_component::*;

/// The subset of the UDB configuration the cosim reads: the implemented
/// extensions, and `params` keys with scalar or list values.
pub struct ArchCfg {
    pub exts: Vec<String>,
    params: HashMap<String, Vec<String>>,
}

impl ArchCfg {
    pub fn parse(text: &str) -> Result<Self> {
        let mut exts = Vec::new();
        let mut params: HashMap<String, Vec<String>> = HashMap::new();
        let mut section = "";
        let mut open: Option<String> = None;
        for raw in text.lines() {
            let line = raw.split('#').next().unwrap_or("").trim_end();
            if line.trim().is_empty() {
                continue;
            }
            if !line.starts_with(' ') {
                section = if line.starts_with("implemented_extensions:") {
                    "ext"
                } else if line.starts_with("params:") {
                    "params"
                } else {
                    ""
                };
                continue;
            }
            if let Some(key) = open.clone() {
                let t = line.trim();
                if t == "]" {
                    open = None;
                } else if t != "[" {
                    params.get_mut(&key).unwrap().push(t.trim_end_matches(',').to_string());
                }
                continue;
            }
            match section {
                "ext" => {
                    let t = line.trim();
                    let Some(rest) = t.strip_prefix("- { name:") else {
                        bail!("unexpected extension line: {t}");
                    };
                    exts.push(rest.split(',').next().unwrap_or("").trim().to_string());
                }
                "params" if !line.starts_with("   ") => {
                    let Some((k, v)) = line.trim().split_once(':') else {
                        bail!("unexpected params line: {line}");
                    };
                    let v = v.trim();
                    let vals = if v.is_empty() {
                        open = Some(k.to_string());
                        Vec::new()
                    } else if let Some(inner) = v.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
                        inner.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
                    } else {
                        vec![v.trim_matches('"').to_string()]
                    };
                    params.insert(k.to_string(), vals);
                }
                _ => {}
            }
        }
        if exts.is_empty() {
            bail!("no implemented_extensions");
        }
        Ok(ArchCfg { exts, params })
    }

    pub fn has(&self, ext: &str) -> bool {
        self.exts.iter().any(|e| e.eq_ignore_ascii_case(ext))
    }

    fn list(&self, key: &str) -> Result<&[String]> {
        self.params.get(key).map(|v| v.as_slice()).ok_or_else(|| anyhow!("param {key} missing"))
    }

    pub fn u64(&self, key: &str) -> Result<u64> {
        match self.list(key)? {
            [v] => Ok(v.parse()?),
            _ => bail!("param {key} is not a scalar"),
        }
    }

    pub fn str(&self, key: &str) -> Result<&str> {
        match self.list(key)? {
            [v] => Ok(v.as_str()),
            _ => bail!("param {key} is not a scalar"),
        }
    }

    pub fn bool(&self, key: &str) -> Result<bool> {
        match self.list(key)? {
            [v] => Ok(v == "true"),
            _ => bail!("param {key} is not a scalar"),
        }
    }

    /// A list of booleans as a bit mask, element i at bit i.
    pub fn mask(&self, key: &str) -> Result<u64> {
        let mut m = 0;
        for (i, v) in self.list(key)?.iter().enumerate() {
            if v == "true" {
                m |= 1u64 << i;
            }
        }
        Ok(m)
    }

    /// The single-letter extensions in misa bit order.
    fn letters(&self) -> Vec<char> {
        self.exts.iter().filter(|e| e.len() == 1).map(|e| e.chars().next().unwrap().to_ascii_lowercase()).collect()
    }

    pub fn misa(&self) -> u64 {
        let mut m = 2u64 << 62;
        for c in self.letters() {
            m |= 1 << (c as u8 - b'a');
        }
        m
    }

    /// Spike's `--isa` string: the base letters in spike's canonical order,
    /// then every multi-letter extension spike models. Sm is the base
    /// machine mode; the Sv modes are set by max_vaddr_bits; spike always
    /// has Sdtrig (its trigger count is set apart) and does not know
    /// Svrsw60t59b (two PTE bits it leaves reserved, which no image sets).
    pub fn spike_isa(&self) -> String {
        let letters = self.letters();
        let mut s = String::from("rv64");
        for c in "imafdqcbpvh".chars() {
            if letters.contains(&c) {
                s.push(c);
            }
        }
        for e in &self.exts {
            let l = e.to_ascii_lowercase();
            if l.len() > 1 && !matches!(l.as_str(), "sm" | "sdtrig" | "svrsw60t59b" | "sv39" | "sv48" | "sv57") {
                s.push('_');
                s.push_str(&l);
            }
        }
        s
    }

    /// Whether any MUTABLE_MISA_<X> is true.
    pub fn any_mutable_misa(&self) -> bool {
        self.params.iter().any(|(k, v)| k.starts_with("MUTABLE_MISA_") && v.first().is_some_and(|x| x == "true"))
    }

    pub fn spike_priv(&self) -> String {
        let mut p = String::from("M");
        if self.has("S") {
            p.push('S');
        }
        if self.has("U") {
            p.push('U');
        }
        p
    }

    /// Sv39 is the widest translation mode heliodor implements.
    pub fn max_vaddr_bits(&self) -> u64 {
        if self.has("Sv57") {
            57
        } else if self.has("Sv48") {
            48
        } else {
            39
        }
    }
}

/// mstatus at reset where the DUT and spike's reset differ: the DUT leaves
/// FS Initial (csr.veryl reset value), spike Off. The reset value is
/// unspecified by the privileged spec, so spike is set to the DUT's.
pub const MSTATUS_RESET_MASK: u64 = 3 << 13;
pub const MSTATUS_RESET_VAL: u64 = 1 << 13;

/// stimecmp and vstimecmp at reset: the DUT sets them to all ones (never
/// fires), spike to zero; the reset value is unspecified.
pub const STIMECMP_RESET: u64 = !0;

pub const DRAM_BASE: u64 = 0x8000_0000;

pub struct Region {
    pub base: u64,
    pub size: u64,
    pub device: bool,
}

/// The harness memory maps (tb_platform_pkg MAP_ARCH and MAP_BOOT): memory
/// regions and device windows. Device reads return the DUT's values; every
/// other address is a hole and faults.
pub fn memory_map(name: &str) -> Result<(Vec<Region>, u64)> {
    let dev = |base, size| Region { base, size, device: true };
    let mem = |base, size| Region { base, size, device: false };
    let devices = [dev(0x0200_0000, 0x1_0000), dev(0x0c00_0000, 0x40_0000), dev(0x1000_0000, 0x1000)];
    Ok(match name {
        "arch" => {
            let mut v = vec![mem(DRAM_BASE, 4 << 20)];
            v.extend(devices);
            (v, DRAM_BASE)
        }
        "boot" => {
            let mut v = vec![mem(DRAM_BASE, 32 << 20), mem(0, 0x4000)];
            v.extend(devices);
            (v, 0)
        }
        _ => bail!("unknown MAP {name:?} (arch or boot)"),
    })
}
