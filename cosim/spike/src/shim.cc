// C ABI over one spike hart with a flat DRAM and no devices. Instances share
// no state, so separate instances may run on separate threads.
#include <cstdint>
#include <cstring>
#include <iostream>
#include <map>
#include <vector>

#include "riscv/cfg.h"
#include "riscv/mmu.h"
#include "riscv/processor.h"
#include "riscv/simif.h"

namespace {

class flat_sim_t : public simif_t {
 public:
  flat_sim_t(const char* isa, const char* priv, uint64_t base, uint64_t size)
      : base_(base), mem_(size, 0) {
    cfg_.isa = isa;
    cfg_.priv = priv;
    cfg_.mem_layout = {mem_cfg_t(base, size)};
    cfg_.hartids = {0};
    // The DUT retires a WFI and stalls without records; spike must not
    // wait, since it never sees the pending interrupt that ends the wait.
    cfg_.wfi_as_nop = true;
    proc_ = new processor_t(isa, priv, &cfg_, this, 0, false, nullptr, std::cerr);
    harts_[0] = proc_;
  }
  ~flat_sim_t() override { delete proc_; }

  char* addr_to_mem(reg_t paddr) override {
    if (paddr >= base_ && paddr - base_ < mem_.size())
      return reinterpret_cast<char*>(&mem_[paddr - base_]);
    return nullptr;
  }
  bool mmio_load(reg_t, size_t, uint8_t*) override { return false; }
  bool mmio_store(reg_t, size_t, const uint8_t*) override { return false; }
  void proc_reset(unsigned) override {}
  const cfg_t& get_cfg() const override { return cfg_; }
  const std::map<size_t, processor_t*>& get_harts() const override { return harts_; }
  const char* get_symbol(uint64_t) override { return nullptr; }

  processor_t* proc() { return proc_; }
  uint8_t* mem() { return mem_.data(); }
  uint64_t mem_size() const { return mem_.size(); }

 private:
  cfg_t cfg_;
  uint64_t base_;
  std::vector<uint8_t> mem_;
  processor_t* proc_;
  std::map<size_t, processor_t*> harts_;
};

}  // namespace

extern "C" {

struct hc_step_t {
  uint64_t pc;
  uint64_t next_pc;
  uint64_t insn;  // raw fetched bits, 16 or 32
  uint64_t trap;
  uint64_t cause;
  uint64_t tval;
  uint64_t priv;  // mode before the step
  uint64_t xpr_changed;  // bit i: x[i] changed value
  uint64_t fpr_changed;
};

void* hc_new(const char* isa, const char* priv, uint64_t base, uint64_t size, uint64_t pc) {
  try {
    auto* s = new flat_sim_t(isa, priv, base, size);
    s->proc()->set_max_vaddr_bits(39);
    s->proc()->reset();
    s->proc()->get_state()->pc = pc;
    return s;
  } catch (std::exception& e) {
    std::cerr << "hc_new: " << e.what() << "\n";
    return nullptr;
  }
}

void hc_free(void* h) { delete static_cast<flat_sim_t*>(h); }

uint8_t* hc_mem(void* h) { return static_cast<flat_sim_t*>(h)->mem(); }

uint64_t hc_get_xpr(void* h, unsigned i) {
  return static_cast<flat_sim_t*>(h)->proc()->get_state()->XPR[i];
}

void hc_set_xpr(void* h, unsigned i, uint64_t v) {
  static_cast<flat_sim_t*>(h)->proc()->get_state()->XPR.write(i, v);
}

uint64_t hc_get_fpr(void* h, unsigned i) {
  return static_cast<flat_sim_t*>(h)->proc()->get_state()->FPR[i].v[0];
}

uint64_t hc_get_csr(void* h, unsigned addr) {
  try {
    return static_cast<flat_sim_t*>(h)->proc()->get_csr(addr);
  } catch (...) {
    return 0xdeadbeefdeadbeefULL;
  }
}

// irq = 0: a pending enabled interrupt must not be taken, since the DUT
// decides when it takes one; mie reads as 0 for this step. irq = 1: the DUT
// took an interrupt here, so the step takes it and executes nothing.
// misa is read-only on the DUT, so a write to it is undone.
void hc_step(void* h, hc_step_t* out, int irq) {
  auto* p = static_cast<flat_sim_t*>(h)->proc();
  auto* st = p->get_state();
  reg_t x0[NXPR];
  uint64_t f0[NFPR];
  for (int i = 0; i < NXPR; i++) x0[i] = st->XPR[i];
  for (int i = 0; i < NFPR; i++) f0[i] = st->FPR[i].v[0];
  out->pc = st->pc;
  out->priv = st->prv;
  out->insn = 0;
  try {
    out->insn = p->get_mmu()->load_insn(st->pc).insn.bits();
  } catch (...) {
  }
  reg_t instret = st->minstret->read();
  reg_t misa = st->misa->read();
  reg_t mie = st->mie->read();
  bool masked = !irq && (st->mip->read() & mie);
  if (masked) st->mie->write(0);
  p->step(1);
  // A timer CSR access first returns to serialize, executing nothing.
  if (st->serialized) p->step(1);
  if (masked && st->mie->read() == 0) st->mie->write(mie);
  if (st->misa->read() != misa) st->misa->write(misa);
  out->next_pc = st->pc;
  // A trapping instruction does not retire, so minstret stands still.
  out->trap = st->minstret->read() == instret;
  if (out->trap) {
    bool m = st->prv == PRV_M;
    out->cause = p->get_csr(m ? CSR_MCAUSE : CSR_SCAUSE);
    out->tval = p->get_csr(m ? CSR_MTVAL : CSR_STVAL);
  } else {
    out->cause = 0;
    out->tval = 0;
  }
  out->xpr_changed = 0;
  out->fpr_changed = 0;
  for (int i = 0; i < NXPR; i++)
    if (st->XPR[i] != x0[i]) out->xpr_changed |= 1ULL << i;
  for (int i = 0; i < NFPR; i++)
    if (st->FPR[i].v[0] != f0[i]) out->fpr_changed |= 1ULL << i;
}

}  // extern "C"
