// C ABI over spike harts sharing one platform. The platform (memories,
// device windows) is the simif_t below; device reads return the values the
// DUT read, and a hart only takes an interrupt when the caller says the DUT
// took one. Instances share no state, so separate instances may run on
// separate threads.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

#include "riscv/cfg.h"
#include "riscv/mmu.h"
#include "riscv/processor.h"
#include "riscv/simif.h"

extern "C" {

struct hc_region_t {
  uint64_t base;
  uint64_t size;
  uint64_t kind;  // 0 memory, 1 device
};

struct hc_cfg_t {
  const char* isa;
  const char* priv;
  uint64_t pmp_regions;
  uint64_t pmp_granularity;
  uint64_t trigger_count;
  uint64_t max_vaddr_bits;
  uint64_t geilen;
  uint64_t mstatus_reset_mask;  // mstatus bits forced after reset
  uint64_t mstatus_reset_val;
  uint64_t reset_pc;
  uint64_t misa_ro;  // misa is read-only on the DUT
  uint64_t stimecmp_reset;
  uint64_t harts;
};

// The DUT's data access of the record being stepped, for device reads.
struct hc_dut_mem_t {
  uint64_t paddr;
  uint64_t rmask;
  uint64_t rdata;
  uint64_t rdata_hi;
};

struct hc_step_t {
  uint64_t pc;
  uint64_t next_pc;
  uint64_t insn;  // raw fetched bits, 16 or 32; 0 if the fetch faults
  uint64_t priv;  // mode before the step
  uint64_t virt;
  uint64_t trap;  // 0 none, 1 M, 2 HS, 3 VS
  uint64_t cause;
  uint64_t tval;
  uint64_t tval2;  // htval or mtval2
  uint64_t tinst;  // htinst or mtinst
  uint64_t xpr_written;  // bit i: x[i] written
  uint64_t fpr_written;
  uint64_t vr_written;
  uint64_t fflags_before;
  uint64_t fflags_after;
  // Device accesses of the step: reads not covered by the DUT's access,
  // and the stores (first one kept).
  uint64_t dev_read_miss;
  uint64_t dev_read_addr;
  uint64_t dev_store_n;
  uint64_t dev_store_addr;
  uint64_t dev_store_len;
  uint64_t dev_store_data;
  uint64_t suppress_fail;  // a pending interrupt could not be held off
};

}  // extern "C"

namespace {

constexpr uint64_t kCauseKey(uint64_t csr) { return (csr << 4) | 4; }

bool is_csr_op(uint64_t insn) { return (insn & 0x7f) == 0x73 && ((insn >> 12) & 3) != 0; }

class plat_sim_t : public simif_t {
 public:
  bool misa_ro = false;

  plat_sim_t(const hc_cfg_t& c, const hc_region_t* r, size_t n) : misa_ro(c.misa_ro) {
    for (size_t i = 0; i < n; i++) {
      region_t g{r[i].base, r[i].size, r[i].kind == 1, {}};
      if (!g.device) {
        g.mem.assign(r[i].size, 0);
        cfg_.mem_layout.push_back(mem_cfg_t(r[i].base, r[i].size));
      }
      regions_.push_back(std::move(g));
    }
    cfg_.isa = isa_.assign(c.isa).c_str();
    cfg_.priv = priv_.assign(c.priv).c_str();
    cfg_.pmpregions = c.pmp_regions;
    cfg_.pmpgranularity = c.pmp_granularity;
    cfg_.trigger_count = c.trigger_count;
    cfg_.hartids.clear();
    for (uint64_t i = 0; i < c.harts; i++) cfg_.hartids.push_back(i);
    // The DUT retires a WFI and stalls without records; the interrupt that
    // ends the wait arrives as its own step.
    cfg_.wfi_as_nop = true;
    log_ = fopen("/dev/null", "w");
    for (uint64_t i = 0; i < c.harts; i++) {
      procs_.push_back(new processor_t(cfg_.isa, cfg_.priv, &cfg_, this, i, false, log_, std::cerr));
      harts_[i] = procs_.back();
    }
  }
  ~plat_sim_t() override {
    for (auto* p : procs_) delete p;
    if (log_) fclose(log_);
  }

  char* addr_to_mem(reg_t paddr) override {
    for (auto& g : regions_)
      if (!g.device && paddr >= g.base && paddr - g.base < g.size)
        return reinterpret_cast<char*>(&g.mem[paddr - g.base]);
    return nullptr;
  }
  bool mmio_fetch(reg_t, size_t, uint8_t*) override { return false; }
  bool mmio_load(reg_t paddr, size_t len, uint8_t* bytes) override {
    if (!dev_access_ok(paddr, len)) return false;
    uint64_t off = paddr - dut_.paddr;
    bool hit = paddr >= dut_.paddr && off + len <= 16;
    for (size_t i = 0; hit && i < len; i++) hit = (dut_.rmask >> (off + i)) & 1;
    if (!hit) {
      if (!out_->dev_read_miss) out_->dev_read_addr = paddr;
      out_->dev_read_miss = 1;
      memset(bytes, 0, len);
      return true;
    }
    for (size_t i = 0; i < len; i++) {
      uint64_t b = off + i;
      uint64_t w = b < 8 ? dut_.rdata : dut_.rdata_hi;
      bytes[i] = uint8_t(w >> (8 * (b & 7)));
    }
    return true;
  }
  bool mmio_store(reg_t paddr, size_t len, const uint8_t* bytes) override {
    if (!dev_access_ok(paddr, len)) return false;
    if (out_->dev_store_n++ == 0) {
      uint64_t v = 0;
      for (size_t i = 0; i < len && i < 8; i++) v |= uint64_t(bytes[i]) << (8 * i);
      out_->dev_store_addr = paddr;
      out_->dev_store_len = len;
      out_->dev_store_data = v;
    }
    return true;
  }
  void proc_reset(unsigned) override {}
  const cfg_t& get_cfg() const override { return cfg_; }
  const std::map<size_t, processor_t*>& get_harts() const override { return harts_; }
  const char* get_symbol(uint64_t) override { return nullptr; }

  size_t nharts() const { return procs_.size(); }
  processor_t* proc(unsigned i) { return procs_.at(i); }
  uint8_t* region_mem(size_t i) { return i < regions_.size() ? regions_[i].mem.data() : nullptr; }

  // Per-step context for the device callbacks.
  void begin_step(const hc_dut_mem_t& d, hc_step_t* out, uint64_t insn) {
    dut_ = d;
    out_ = out;
    insn_ = insn;
  }

 private:
  struct region_t {
    uint64_t base, size;
    bool device;
    std::vector<uint8_t> mem;
  };

  // Device windows take naturally aligned scalar accesses of the
  // instruction's own size only: spike splits a misaligned access into
  // bytes, and an AMO reaches here as a load and a store; the DUT's PMA
  // faults both.
  bool dev_access_ok(reg_t paddr, size_t len) const {
    bool in = false;
    for (auto& g : regions_)
      if (g.device && paddr >= g.base && paddr - g.base < g.size) in = true;
    if (!in || (paddr & (len - 1)) != 0) return false;
    uint64_t op = insn_ & 0x7f;
    if ((insn_ & 3) == 3 && op == 0x2f) return false;
    size_t want = access_size(insn_);
    return want == 0 || want == len;
  }

  static size_t access_size(uint64_t insn) {
    if ((insn & 3) != 3) {
      uint64_t q = insn & 3, f3 = (insn >> 13) & 7;
      if (q == 0 && (f3 == 2 || f3 == 6)) return 4;
      if (q == 0 && (f3 == 3 || f3 == 7 || f3 == 1 || f3 == 5)) return 8;
      if (q == 0 && f3 == 4) return ((insn >> 10) & 7) == 0 || ((insn >> 10) & 7) == 2 ? 1 : 2;
      if (q == 2 && (f3 == 2 || f3 == 6)) return 4;
      if (q == 2 && (f3 == 3 || f3 == 7 || f3 == 1 || f3 == 5)) return 8;
      return 0;
    }
    uint64_t op = insn & 0x7f, f3 = (insn >> 12) & 7;
    if (op == 0x03 || op == 0x23) return size_t(1) << (f3 & 3);
    if (op == 0x07 || op == 0x27) return f3 >= 1 && f3 <= 4 ? size_t(1) << f3 : 0;
    return 0;
  }

  cfg_t cfg_;
  std::string isa_, priv_;
  std::vector<region_t> regions_;
  FILE* log_ = nullptr;
  std::vector<processor_t*> procs_;
  std::map<size_t, processor_t*> harts_;
  hc_dut_mem_t dut_{};
  hc_step_t* out_ = nullptr;
  uint64_t insn_ = 0;
};

plat_sim_t* S(void* h) { return static_cast<plat_sim_t*>(h); }

bool logged(state_t* st, uint64_t key) { return st->log_reg_write.count(key) != 0; }

uint64_t csr_or(processor_t* p, unsigned addr, uint64_t dflt) {
  try {
    return p->get_csr(addr);
  } catch (...) {
    return dflt;
  }
}

}  // namespace

extern "C" {

void* hc_new(const hc_cfg_t* c, const hc_region_t* r, size_t n) {
  try {
    if (c->harts == 0) throw std::runtime_error("no harts");
    auto* s = new plat_sim_t(*c, r, n);
    for (unsigned i = 0; i < s->nharts(); i++) {
      auto* p = s->proc(i);
      p->geilen = unsigned(c->geilen);
      p->set_max_vaddr_bits(unsigned(c->max_vaddr_bits));
      p->enable_log_commits();
      p->reset();
      auto* st = p->get_state();
      // Without Smcntrpmf, spike's Smcdeleg setup leaves null entries for
      // mcyclecfg/minstretcfg in the CSR map, and an access dereferences
      // them; dropped, the access is the illegal instruction it is on the DUT.
      for (auto it = st->csrmap.begin(); it != st->csrmap.end();)
        it = it->second ? std::next(it) : st->csrmap.erase(it);
      st->mstatus->write((st->mstatus->read() & ~c->mstatus_reset_mask) | c->mstatus_reset_val);
      if (st->stimecmp) st->stimecmp->write(c->stimecmp_reset);
      if (st->vstimecmp) st->vstimecmp->write(c->stimecmp_reset);
      st->pc = c->reset_pc;
    }
    return s;
  } catch (std::exception& e) {
    std::cerr << "hc_new: " << e.what() << "\n";
    return nullptr;
  }
}

void hc_free(void* h) { delete S(h); }

uint8_t* hc_region_mem(void* h, size_t i) { return S(h)->region_mem(i); }

uint64_t hc_get_misa(void* h, unsigned t) { return S(h)->proc(t)->get_state()->misa->read(); }

uint64_t hc_get_xpr(void* h, unsigned t, unsigned i) { return S(h)->proc(t)->get_state()->XPR[i]; }

void hc_set_xpr(void* h, unsigned t, unsigned i, uint64_t v) { S(h)->proc(t)->get_state()->XPR.write(i, v); }

uint64_t hc_get_fpr(void* h, unsigned t, unsigned i) { return S(h)->proc(t)->get_state()->FPR[i].v[0]; }

uint64_t hc_get_csr(void* h, unsigned t, unsigned addr) {
  return csr_or(S(h)->proc(t), addr, 0xdeadbeefdeadbeefULL);
}

void hc_set_csr(void* h, unsigned t, unsigned addr, uint64_t v) {
  try {
    S(h)->proc(t)->put_csr(addr, v);
  } catch (...) {
  }
}

// VLEN/8 bytes of v[i], or null without V.
const uint8_t* hc_get_vreg(void* h, unsigned t, unsigned i) {
  auto& vu = S(h)->proc(t)->VU;
  if (!vu.reg_file || vu.VLEN == 0) return nullptr;
  return static_cast<const uint8_t*>(vu.reg_file) + i * (vu.VLEN / 8);
}

// Translation state of hart t: satp (non-virtual), vsatp and hgatp MODE in
// bits 3:0, 7:4 and 11:8, then mstatus.MPRV, MPV and MPP in bits 12, 13 and
// 15:14.
uint64_t hc_get_xlate(void* h, unsigned t) {
  auto* st = S(h)->proc(t)->get_state();
  const reg_t ms = st->mstatus->read();
  uint64_t v = st->satp->readvirt(false) >> 60;
  if (st->vsatp) v |= (st->vsatp->read() >> 60) << 4;
  if (st->hgatp) v |= (st->hgatp->read() >> 60) << 8;
  v |= uint64_t((ms & MSTATUS_MPRV) != 0) << 12;
  v |= uint64_t((ms & MSTATUS_MPV) != 0) << 13;
  v |= ((ms & MSTATUS_MPP) >> 11) << 14;
  return v;
}

uint64_t hc_vlenb(void* h) { return S(h)->proc(0)->VU.VLEN / 8; }

uint64_t hc_get_vcsr(void* h, unsigned t, unsigned which) {
  auto& vu = S(h)->proc(t)->VU;
  if (!vu.vl) return 0;
  switch (which) {
    case 0: return vu.vtype->read();
    case 1: return vu.vl->read();
    default: return vu.vstart->read();
  }
}

// Steps one record of hart t. irq >= 0: the DUT took interrupt `irq` here;
// the step takes it and executes nothing. irq < 0: the step executes one
// instruction and takes no interrupt, whatever spike would pend.
// flags bit 0: drop spike's reservation first (the DUT's SC failed).
// flags bit 1: misaligned accesses fault in this step (a vector access).
void hc_step(void* h, unsigned t, int irq, const hc_dut_mem_t* dut, hc_step_t* out, uint64_t flags) {
  auto* s = S(h);
  auto* p = s->proc(t);
  auto* st = p->get_state();
  memset(out, 0, sizeof(*out));
  out->pc = st->pc;
  out->priv = st->prv;
  out->virt = st->v;
  out->fflags_before = csr_or(p, CSR_FFLAGS, 0);
  if (irq < 0) {
    try {
      out->insn = p->get_mmu()->load_insn(st->pc).insn.bits();
    } catch (...) {
    }
  }
  s->begin_step(*dut, out, out->insn);

  // Spike takes any pending enabled interrupt at the start of a step, but
  // the DUT takes one when its pipeline lets it. Hold the pending set off for
  // this step through the one of mie and mip the instruction does not touch.
  // mip's own bits: VSEIP/VSTIP read through from hvip and SEIP from mvip;
  // nothing but an injected interrupt sets them in mip itself.
  const reg_t ip_save = st->mip->read();
  const reg_t ipv_save = ip_save & ~(MIP_VSEIP | MIP_VSTIP | MIP_SEIP);
  const reg_t hvip_save = st->hvip ? st->hvip->read() : 0;
  const reg_t mvip_save = st->mvip ? st->mvip->read() : 0;
  const reg_t ie_save = st->mie->read();
  bool hide_ie = false, hide_ip = false;
  if (irq >= 0) {
    st->mip->backdoor_write_with_mask(reg_t(1) << irq, reg_t(1) << irq);
  } else if (ip_save & ie_save) {
    uint64_t csr = out->insn >> 20;
    bool ie_op = is_csr_op(out->insn) && (csr == CSR_MIE || csr == CSR_SIE || csr == CSR_HIE || csr == CSR_VSIE);
    if (!ie_op) {
      st->mie->write_with_mask(~reg_t(0), 0);
      hide_ie = true;
    } else {
      st->mip->backdoor_write_with_mask(~reg_t(0), 0);
      if (st->hvip) st->hvip->write(0);
      if (st->mvip) st->mvip->write_with_mask(MIP_SEIP, 0);
      hide_ip = true;
      if (st->mip->read() & ie_save) out->suppress_fail = 1;
    }
  }

  const reg_t misa_save = st->misa->read();
  if (flags & 1) p->get_mmu()->yield_load_reservation();
  const bool lsm = p->extension_enabled(EXT_ZICCLSM);
  if ((flags & 2) && lsm) p->set_extension_enable(EXT_ZICCLSM, false);
  st->log_reg_write.clear();
  st->log_mem_read.clear();
  st->log_mem_write.clear();
  p->step(1);
  // A counter CSR access first returns to serialize, executing nothing.
  if (st->serialized) p->step(1);

  if ((flags & 2) && lsm) p->set_extension_enable(EXT_ZICCLSM, true);
  out->next_pc = st->pc;
  struct lvl_t {
    uint64_t cause, epc, tval, tval2, tinst;
  };
  static const lvl_t lv[3] = {
      {CSR_MCAUSE, CSR_MEPC, CSR_MTVAL, CSR_MTVAL2, CSR_MTINST},
      {CSR_SCAUSE, CSR_SEPC, CSR_STVAL, CSR_HTVAL, CSR_HTINST},
      {CSR_VSCAUSE, CSR_VSEPC, CSR_VSTVAL, 0, 0},
  };
  // A trap writes the cause and the epc of its level; no instruction writes
  // both.
  for (int i = 0; i < 3; i++) {
    if (logged(st, kCauseKey(lv[i].cause)) && logged(st, kCauseKey(lv[i].epc))) {
      out->trap = i + 1;
      // Each level's own registers, not the V-dependent aliases.
      if (i == 0) {
        out->cause = st->mcause->read();
        out->tval = st->mtval->read();
        out->tval2 = st->mtval2 ? st->mtval2->read() : 0;
        out->tinst = st->mtinst ? st->mtinst->read() : 0;
      } else if (i == 1) {
        out->cause = st->nonvirtual_scause->read();
        out->tval = st->nonvirtual_stval->read();
        out->tval2 = st->htval ? st->htval->read() : 0;
        out->tinst = st->htinst ? st->htinst->read() : 0;
      } else {
        out->cause = st->vscause->read();
        out->tval = st->vstval->read();
      }
      break;
    }
  }
  for (auto& [key, val] : st->log_reg_write) {
    uint64_t r = key >> 4;
    switch (key & 0xf) {
      case 0:
        if (r) out->xpr_written |= uint64_t(1) << r;
        break;
      case 1: out->fpr_written |= uint64_t(1) << r; break;
      case 2: out->vr_written |= uint64_t(1) << r; break;
      default: break;
    }
  }
  out->fflags_after = csr_or(p, CSR_FFLAGS, 0);
  // spike's misa has writable extension bits; undo a write the DUT ignores.
  if (s->misa_ro && st->misa->read() != misa_save) st->misa->write(misa_save);

  if (irq >= 0) {
    st->mip->backdoor_write_with_mask(~reg_t(0), ipv_save);
  } else if (hide_ie) {
    st->mie->write_with_mask(~reg_t(0), ie_save);
  } else if (hide_ip) {
    st->mip->backdoor_write_with_mask(~reg_t(0), ipv_save);
    if (st->hvip) st->hvip->write(hvip_save);
    if (st->mvip) st->mvip->write_with_mask(MIP_SEIP, mvip_save);
  }
}

}  // extern "C"
